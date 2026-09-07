use crate::catalog::ProviderId;
use serde_json::Value;
use std::path::{Path, PathBuf};

use super::common::{
    Cadence, CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, account_identity, clamp_percent,
    decode_jwt_payload, mask_email, number, obj_get, obj_get_any, parse_date, plan_slug,
    read_bounded_file, string, unix_seconds_to_iso, url_encode,
};

pub const SOURCE: &str = "antigravity_code_assist_quota";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const CODE_ASSIST_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal";
const TOKEN_SKEW_SECONDS: i64 = 60;
const TOKEN_FILE: &str = "antigravity-oauth-token";
const USER_AGENT: &str = "antigravity";

#[derive(Clone, Debug)]
struct Credentials {
    access_token: String,
    refresh_token: Option<String>,
    expiry: Option<i64>,
    client_id: Option<String>,
    client_secret: Option<String>,
    project_id: Option<String>,
    email: Option<String>,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    load_credentials(context)
        .ok()
        .map(|credentials| {
            vec![ProviderSession {
                provider: ProviderId::Antigravity,
                credential_source: credentials.source,
                cookie_header: None,
            }]
        })
        .unwrap_or_default()
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_at(context, TOKEN_URL, CODE_ASSIST_URL)
}

fn collect_at(
    context: &CollectionContext,
    token_url: &str,
    code_assist_url: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let credentials = load_credentials(context)?;
    let access_token = access_token(&credentials, context, token_url)?;
    let client = HttpClient::new()?;
    let project = load_project(
        &client,
        context,
        code_assist_url,
        &access_token,
        credentials.project_id.as_deref(),
    )?;
    let quota = retrieve_quota(
        &client,
        context,
        code_assist_url,
        &access_token,
        project.id.as_deref(),
    )?;
    let windows = map_windows(&quota, context.observed_unix());
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let (fingerprint, scope, label) = identity(&access_token, credentials.email.as_deref());
    Ok(QuotaSnapshot {
        provider: ProviderId::Antigravity,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label,
            plan: project.plan,
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn gemini_home(context: &CollectionContext) -> PathBuf {
    context
        .env("GEMINI_CLI_HOME")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".gemini"))
}

fn load_credentials(context: &CollectionContext) -> Result<Credentials, ProviderError> {
    let path = gemini_home(context)
        .join("antigravity-cli")
        .join(TOKEN_FILE);
    let bytes = read_bounded_file(&path, LOCAL_FILE_LIMIT)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    parse_credentials(&value, &path)
}

fn parse_credentials(value: &Value, path: &Path) -> Result<Credentials, ProviderError> {
    let token = obj_get(value, "token").unwrap_or(value);
    let access_token = obj_get_any(token, &["access_token", "accessToken"]).and_then(as_token);
    let refresh_token = obj_get_any(token, &["refresh_token", "refreshToken"]).and_then(as_token);
    if access_token.is_none() && refresh_token.is_none() {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    Ok(Credentials {
        access_token: access_token.unwrap_or_default(),
        refresh_token,
        expiry: obj_get_any(
            token,
            &[
                "expiry",
                "expiry_date",
                "expiryDate",
                "expires_at",
                "expiresAt",
            ],
        )
        .and_then(|value| parse_date(Some(value))),
        client_id: obj_get_any(value, &["client_id", "clientId"])
            .or_else(|| obj_get_any(token, &["client_id", "clientId"]))
            .and_then(as_token),
        client_secret: obj_get_any(value, &["client_secret", "clientSecret"])
            .or_else(|| obj_get_any(token, &["client_secret", "clientSecret"]))
            .and_then(as_token),
        project_id: obj_get_any(value, &["project_id", "projectId"]).and_then(string_value),
        email: obj_get_any(value, &["email"]).and_then(string_value),
        source: path.to_string_lossy().into_owned(),
    })
}

fn as_token(value: &Value) -> Option<String> {
    string(Some(value)).filter(|token| token.len() <= 8_192 && !token.chars().any(char::is_control))
}

fn string_value(value: &Value) -> Option<String> {
    string(Some(value))
}

fn access_token(
    credentials: &Credentials,
    context: &CollectionContext,
    token_url: &str,
) -> Result<String, ProviderError> {
    let now = context.observed_unix();
    let fresh = !credentials.access_token.is_empty()
        && credentials
            .expiry
            .is_none_or(|expiry| expiry > now + TOKEN_SKEW_SECONDS);
    if fresh {
        return Ok(credentials.access_token.clone());
    }
    let refresh_token = credentials
        .refresh_token
        .as_deref()
        .filter(|token| !token.is_empty())
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    refresh_access_token(credentials, refresh_token, context, token_url)
}

fn refresh_access_token(
    credentials: &Credentials,
    refresh_token: &str,
    context: &CollectionContext,
    token_url: &str,
) -> Result<String, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let client_id = credentials
        .client_id
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let client_secret = credentials
        .client_secret
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let body = format!(
        "client_id={}&client_secret={}&refresh_token={}&grant_type=refresh_token",
        url_encode(client_id),
        url_encode(client_secret),
        url_encode(refresh_token)
    );
    let headers = [
        ("Content-Type", "application/x-www-form-urlencoded"),
        ("Accept", "application/json"),
        ("User-Agent", USER_AGENT),
    ];
    let client = HttpClient::new()?;
    let (_, bytes) = client.post_bytes(token_url, &headers, body.as_bytes(), SOURCE)?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    as_token(obj_get(&value, "access_token").unwrap_or(&Value::Null))
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))
}

struct Project {
    id: Option<String>,
    plan: Option<String>,
}

fn load_project(
    client: &HttpClient,
    context: &CollectionContext,
    code_assist_url: &str,
    access_token: &str,
    stored_project: Option<&str>,
) -> Result<Project, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let url = format!("{}:loadCodeAssist", code_assist_url.trim_end_matches('/'));
    let env_project = context
        .env("GOOGLE_CLOUD_PROJECT")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let mut body = serde_json::json!({
        "metadata": {
            "ideType": "ANTIGRAVITY",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI"
        }
    });
    if let Some(project) = &env_project {
        body["cloudaicompanionProject"] = Value::String(project.clone());
    }
    let bearer = format!("Bearer {access_token}");
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", USER_AGENT),
    ];
    let (_, value) = client.post_json(&url, &headers, &body, SOURCE)?;
    let project = string(obj_get(&value, "cloudaicompanionProject"))
        .or(env_project)
        .or_else(|| stored_project.map(str::to_owned));
    let plan = obj_get(&value, "currentTier")
        .and_then(|tier| string(obj_get(tier, "id")).or_else(|| string(obj_get(tier, "name"))))
        .or_else(|| obj_get(&value, "planInfo").and_then(|info| string(obj_get(info, "planType"))))
        .and_then(|id| plan_slug(Some(&id)));
    Ok(Project { id: project, plan })
}

fn retrieve_quota(
    client: &HttpClient,
    context: &CollectionContext,
    code_assist_url: &str,
    access_token: &str,
    project: Option<&str>,
) -> Result<Value, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let bearer = format!("Bearer {access_token}");
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", USER_AGENT),
    ];
    let body = match project {
        Some(project) if !project.is_empty() => serde_json::json!({ "project": project }),
        _ => serde_json::json!({}),
    };
    let summary_url = format!(
        "{}:retrieveUserQuotaSummary",
        code_assist_url.trim_end_matches('/')
    );
    if let Ok((_, value)) = client.post_json(&summary_url, &headers, &body, SOURCE)
        && quota_has_windows(&value)
    {
        return Ok(value);
    }
    let quota_url = format!(
        "{}:retrieveUserQuota",
        code_assist_url.trim_end_matches('/')
    );
    let (_, value) = client.post_json(&quota_url, &headers, &body, SOURCE)?;
    Ok(value)
}

fn quota_has_windows(value: &Value) -> bool {
    !map_windows(value, 0).is_empty()
}

fn identity(
    access_token: &str,
    stored_email: Option<&str>,
) -> (String, &'static str, Option<String>) {
    let payload = decode_jwt_payload(access_token);
    let email = payload
        .as_ref()
        .and_then(|value| string(obj_get(value, "email")))
        .or_else(|| stored_email.map(str::to_owned));
    let subject = payload
        .as_ref()
        .and_then(|value| string(obj_get(value, "sub")));
    let owner = email.clone().or(subject);
    let (fingerprint, scope) = account_identity("antigravity", "oauth", owner.as_deref());
    (fingerprint, scope, mask_email(email.as_deref()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WindowKind {
    FiveHour,
    Weekly,
    Daily,
    Monthly,
}

impl WindowKind {
    fn id(self) -> &'static str {
        match self {
            Self::FiveHour => Cadence::FiveHour.wire(),
            Self::Weekly => Cadence::Weekly.wire(),
            Self::Daily => "daily",
            Self::Monthly => Cadence::Monthly.wire(),
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::FiveHour => Cadence::FiveHour.title(),
            Self::Weekly => Cadence::Weekly.title(),
            Self::Daily => "Daily",
            Self::Monthly => Cadence::Monthly.title(),
        }
    }

    fn cadence(self) -> Option<Cadence> {
        match self {
            Self::FiveHour => Some(Cadence::FiveHour),
            Self::Weekly => Some(Cadence::Weekly),
            Self::Monthly => Some(Cadence::Monthly),
            Self::Daily => None,
        }
    }

    fn duration_seconds(self) -> Option<u64> {
        match self {
            Self::FiveHour => Some(5 * 3_600),
            Self::Weekly => Some(7 * 86_400),
            Self::Daily => Some(86_400),
            Self::Monthly => None,
        }
    }
}

fn map_windows(value: &Value, now: i64) -> Vec<QuotaWindow> {
    let root = obj_get(value, "response").unwrap_or(value);
    if let Some(groups) = obj_get(root, "groups").and_then(Value::as_array) {
        let mut windows = Vec::new();
        for group in groups {
            let group_name = string(obj_get(group, "displayName")).unwrap_or_default();
            let Some(buckets) = obj_get(group, "buckets").and_then(Value::as_array) else {
                continue;
            };
            for bucket in buckets {
                if let Some(window) = map_named_bucket(bucket, &group_name, now) {
                    windows.push(window);
                }
            }
        }
        if !windows.is_empty() {
            return windows;
        }
    }
    map_request_buckets(root, now)
}

fn map_named_bucket(value: &Value, group_name: &str, now: i64) -> Option<QuotaWindow> {
    let remaining = obj_get(value, "remaining").unwrap_or(value);
    let fraction = number(obj_get(remaining, "remainingFraction"))
        .or_else(|| number(obj_get(value, "remainingFraction")))?;
    if !fraction.is_finite() || fraction < 0.0 {
        return None;
    }
    let remaining_amount = number(obj_get(remaining, "remainingAmount"))
        .or_else(|| number(obj_get(value, "remainingAmount")));
    let (remaining_value, limit_value) = match remaining_amount {
        Some(remaining) if fraction > 0.0 => (remaining, remaining / fraction),
        Some(remaining) => (remaining, remaining),
        None => (fraction * 100.0, 100.0),
    };
    let display = string(obj_get(value, "displayName")).unwrap_or_default();
    let bucket_id = string(obj_get(value, "bucketId")).unwrap_or_default();
    let kind = classify_named(&display, &bucket_id, group_name, value, now);
    let title = window_title(group_name, kind);
    let used_percent = if limit_value > 0.0 {
        clamp_percent((limit_value - remaining_value).max(0.0) / limit_value * 100.0)
    } else {
        clamp_percent((1.0 - fraction) * 100.0)
    };
    Some(QuotaWindow {
        id: format!("{}-{}", slug_id(group_name), kind.id()),
        title,
        used_percent,
        resets_at: obj_get_any(value, &["resetTime", "reset_time"])
            .and_then(|value| parse_date(Some(value)))
            .map(unix_seconds_to_iso),
        duration_seconds: kind.duration_seconds(),
        primary_cadence: kind.cadence(),
        remaining_value: Some(remaining_value.max(0.0)),
        limit_value: (limit_value > 0.0).then_some(limit_value),
        value_unit: Some("count"),
    })
}

fn window_title(group_name: &str, kind: WindowKind) -> String {
    let family = if group_name.to_ascii_lowercase().contains("claude")
        || group_name.to_ascii_lowercase().contains("gpt")
    {
        "Claude + GPT"
    } else if group_name.to_ascii_lowercase().contains("gemini") {
        "Gemini"
    } else if group_name.is_empty() {
        kind.title()
    } else {
        group_name
    };
    if family == kind.title() {
        family.to_owned()
    } else {
        format!("{family} {}", kind.title())
    }
}

fn slug_id(value: &str) -> String {
    let slug = super::common::slug(value, '-');
    if slug.is_empty() {
        "quota".to_owned()
    } else {
        slug
    }
}

fn classify_named(
    display: &str,
    bucket_id: &str,
    group_name: &str,
    value: &Value,
    now: i64,
) -> WindowKind {
    let haystack = format!("{display} {bucket_id} {group_name}").to_ascii_lowercase();
    if haystack.contains("five") || haystack.contains("5-hour") || haystack.contains("5 hour") {
        return WindowKind::FiveHour;
    }
    if haystack.contains("week") {
        return WindowKind::Weekly;
    }
    if haystack.contains("month") {
        return WindowKind::Monthly;
    }
    if haystack.contains("day") || haystack.contains("daily") {
        return WindowKind::Daily;
    }
    let reset =
        obj_get_any(value, &["resetTime", "reset_time"]).and_then(|value| parse_date(Some(value)));
    classify_reset(reset, now)
}

fn map_request_buckets(value: &Value, now: i64) -> Vec<QuotaWindow> {
    let Some(buckets) = value.get("buckets").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut pooled: Vec<(WindowKind, f64, f64, Option<String>)> = Vec::new();
    for bucket in buckets {
        let token_type =
            string(obj_get(bucket, "tokenType")).unwrap_or_else(|| "REQUESTS".to_owned());
        if !token_type.eq_ignore_ascii_case("REQUESTS") && !token_type.is_empty() {
            continue;
        }
        let remaining_amount = number(obj_get(bucket, "remainingAmount"));
        let remaining_fraction = number(obj_get(bucket, "remainingFraction"));
        let (remaining, limit) = match (remaining_amount, remaining_fraction) {
            (Some(remaining), Some(fraction)) if fraction > 0.0 => {
                (remaining, remaining / fraction)
            }
            (Some(remaining), _) => (remaining, remaining),
            (None, Some(fraction)) => (fraction * 100.0, 100.0),
            (None, None) => continue,
        };
        let reset = obj_get(bucket, "resetTime").and_then(|value| parse_date(Some(value)));
        let kind = classify_reset(reset, now);
        if let Some((_, remaining_acc, limit_acc, resets_at)) = pooled
            .iter_mut()
            .find(|(existing, _, _, _)| *existing == kind)
        {
            *remaining_acc += remaining;
            *limit_acc += limit;
            if resets_at.is_none() {
                *resets_at = reset.map(unix_seconds_to_iso);
            }
        } else {
            pooled.push((kind, remaining, limit, reset.map(unix_seconds_to_iso)));
        }
    }
    pooled.sort_by_key(|(kind, _, _, _)| match kind {
        WindowKind::FiveHour => 0,
        WindowKind::Daily => 1,
        WindowKind::Weekly => 2,
        WindowKind::Monthly => 3,
    });
    pooled
        .into_iter()
        .filter(|(_, remaining, limit, _)| *remaining > 0.0 || *limit > 0.0)
        .map(|(kind, remaining, limit, resets_at)| {
            let denom = if limit > 0.0 { limit } else { remaining };
            QuotaWindow {
                id: kind.id().to_owned(),
                title: kind.title().to_owned(),
                used_percent: if denom > 0.0 {
                    clamp_percent((limit - remaining).max(0.0) / denom * 100.0)
                } else {
                    100.0
                },
                resets_at,
                duration_seconds: kind.duration_seconds(),
                primary_cadence: kind.cadence(),
                remaining_value: Some(remaining.max(0.0)),
                limit_value: (limit > 0.0).then_some(limit),
                value_unit: Some("count"),
            }
        })
        .collect()
}

fn classify_reset(reset: Option<i64>, now: i64) -> WindowKind {
    let Some(reset) = reset else {
        return WindowKind::Daily;
    };
    let until = reset.saturating_sub(now);
    if until <= 6 * 3_600 {
        WindowKind::FiveHour
    } else if until <= 2 * 86_400 {
        WindowKind::Daily
    } else if until <= 8 * 86_400 {
        WindowKind::Weekly
    } else {
        WindowKind::Monthly
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::common::account_identity;

    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: std::path::PathBuf::from("/tmp/quota-antigravity-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: Some(std::path::PathBuf::from(
                "/tmp/quota-antigravity-missing-config/providers.json",
            )),
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        }
    }

    fn write_token(dir: &std::path::Path, body: &str) {
        let path = dir.join(".gemini").join("antigravity-cli");
        std::fs::create_dir_all(&path).expect("antigravity dir");
        std::fs::write(path.join(TOKEN_FILE), body).expect("token");
    }

    #[test]
    fn maps_quota_summary_groups_into_named_windows() {
        let windows = map_windows(
            &serde_json::json!({
                "groups": [
                    {
                        "displayName": "Gemini Models",
                        "buckets": [
                            {
                                "bucketId": "gemini-five-hour",
                                "displayName": "Five-hour limit",
                                "remaining": { "remainingFraction": 0.4 },
                                "resetTime": "2026-08-10T05:00:00Z"
                            },
                            {
                                "bucketId": "gemini-weekly",
                                "displayName": "Weekly limit",
                                "remaining": { "remainingFraction": 0.8 },
                                "resetTime": "2026-08-16T00:00:00Z"
                            }
                        ]
                    }
                ]
            }),
            1_786_320_000,
        );
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].id, "gemini-models-five_hour");
        assert_eq!(windows[0].title, "Gemini 5 Hours");
        assert_eq!(windows[0].used_percent, 60.0);
        assert_eq!(windows[0].primary_cadence, Some(Cadence::FiveHour));
        assert_eq!(windows[1].id, "gemini-models-weekly");
        assert_eq!(windows[1].used_percent, 20.0);
    }

    #[test]
    fn maps_pooled_request_buckets_when_summary_groups_are_absent() {
        let windows = map_windows(
            &serde_json::json!({
                "buckets": [
                    {
                        "modelId": "gemini-3-pro",
                        "tokenType": "REQUESTS",
                        "remainingAmount": "800",
                        "remainingFraction": 0.8,
                        "resetTime": "2026-08-16T00:00:00Z"
                    },
                    {
                        "modelId": "claude-sonnet",
                        "tokenType": "REQUESTS",
                        "remainingAmount": "400",
                        "remainingFraction": 0.8,
                        "resetTime": "2026-08-16T00:00:00Z"
                    }
                ]
            }),
            1_786_320_000,
        );
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "weekly");
        assert_eq!(windows[0].remaining_value, Some(1_200.0));
        assert_eq!(windows[0].limit_value, Some(1_500.0));
    }

    #[test]
    fn collect_prefers_quota_summary_then_falls_back_to_retrieve_user_quota() {
        let root = std::env::temp_dir().join(format!("quota-antigravity-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_token(
            &root,
            r#"{"auth_method":"consumer","token":{"access_token":"ya29.live","refresh_token":"1//refresh","expiry":"2026-09-01T00:00:00Z"}}"#,
        );
        let (address, server) = crate::providers::common::serve_responses(vec![
            (
                200,
                br#"{"cloudaicompanionProject":"gen-lang-client-1","currentTier":{"id":"pro"}}"#
                    .to_vec(),
            ),
            (403, b"{}".to_vec()),
            (
                200,
                br#"{"buckets":[{"tokenType":"REQUESTS","remainingFraction":0.5,"resetTime":"2026-08-10T04:00:00Z"}]}"#
                    .to_vec(),
            ),
        ]);
        let mut context = isolated_context();
        context.home_directory = root.clone();
        let snapshot = collect_at(
            &context,
            "http://127.0.0.1:1/token",
            &format!("http://{address}/v1internal"),
        )
        .expect("snapshot");
        assert_eq!(snapshot.account.plan.as_deref(), Some("pro"));
        assert_eq!(snapshot.windows[0].id, "five_hour");
        let heads = server.join().expect("server");
        assert!(heads[0].contains("authorization: bearer ya29.live"));
        assert!(heads[0].contains("user-agent: antigravity"));
        assert!(heads[0].contains(":loadcodeassist"));
        assert!(heads[1].contains(":retrieveuserquotasummary"));
        assert!(heads[2].contains(":retrieveuserquota"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn nested_cli_token_file_is_read() {
        let root = std::env::temp_dir().join(format!(
            "quota-antigravity-token-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("time")
                .as_nanos()
        ));
        write_token(
            &root,
            r#"{"auth_method":"consumer","token":{"access_token":"ya29.a","refresh_token":"1//r","expiry":"2026-09-01T00:00:00Z"}}"#,
        );
        let mut context = isolated_context();
        context.home_directory = root.clone();
        let credentials = load_credentials(&context).expect("credentials");
        assert_eq!(credentials.access_token, "ya29.a");
        assert_eq!(credentials.refresh_token.as_deref(), Some("1//r"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn expired_token_without_oauth_client_is_auth_required() {
        let root =
            std::env::temp_dir().join(format!("quota-antigravity-noclient-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_token(
            &root,
            r#"{"token":{"access_token":"ya29.stale","refresh_token":"1//r","expiry":"2020-01-01T00:00:00Z"}}"#,
        );
        let mut context = isolated_context();
        context.home_directory = root.clone();
        let error = collect_at(
            &context,
            "http://127.0.0.1:9/token",
            "http://127.0.0.1:9/v1",
        )
        .expect_err("no client");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn jwt_email_is_a_global_fingerprint() {
        let token = "header.eyJlbWFpbCI6ImFiQGV4YW1wbGUuY29tIiwic3ViIjoidXNlci0xIn0.sig";
        let (fingerprint, scope, label) = identity(token, None);
        assert_eq!(scope, "global");
        assert_eq!(label.as_deref(), Some("ab***@example.com"));
        assert_eq!(
            fingerprint,
            account_identity("antigravity", "oauth", Some("ab@example.com")).0
        );
    }

    #[test]
    fn missing_credential_is_auth_required() {
        let error = collect(
            &ProviderSession {
                provider: ProviderId::Antigravity,
                credential_source: "missing".into(),
                cookie_header: None,
            },
            &isolated_context(),
        )
        .expect_err("missing");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        assert_eq!(error.source_id, SOURCE);
    }
}
