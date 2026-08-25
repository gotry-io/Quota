use crate::catalog::ProviderId;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError, ProviderSession,
    QuotaAccount, QuotaSnapshot, QuotaWindow, account_identity, clamp_percent, decode_jwt_payload,
    mask_email, number, obj_get, obj_get_any, parse_date, read_bounded_file, slug, string,
};

pub const SOURCE_API: &str = "chatgpt_usage_api";
pub const SOURCE_PAT: &str = "codex_pat_usage_api";
pub const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const WHOAMI_URL: &str = "https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami";

#[derive(Clone, Debug)]
pub(super) struct Credentials {
    access_token: String,
    id_token: Option<String>,
    account_id: Option<String>,
}

#[derive(Clone, Debug)]
struct AuthMaterial {
    pat: Option<String>,
    oauth: Option<Credentials>,
    source: String,
}

#[derive(Clone, Debug, Default)]
pub(super) struct Identity {
    email: Option<String>,
    plan: Option<String>,
    account_id: Option<String>,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    load_auth(context)
        .map(|auth| ProviderSession {
            provider: ProviderId::Codex,
            credential_source: auth.source,
        })
        .into_iter()
        .collect()
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE_API));
    }
    collect_local(context)
}

fn collect_local(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let auth = load_auth(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE_API))?;
    if let Some(pat) = auth.pat.as_deref() {
        match collect_pat(pat, context) {
            Ok(snapshot) => return Ok(snapshot),
            Err(error) if error.category == ErrorCategory::AuthRequired => {}
            Err(error) => return Err(error),
        }
    }
    let credentials = auth
        .oauth
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE_API))?;
    let identity = extract_identity(&credentials);
    collect_api(&credentials, &identity, context, SOURCE_API)?
        .ok_or_else(|| ProviderError::new(ErrorCategory::Unavailable, SOURCE_API))
}

fn load_auth(context: &CollectionContext) -> Option<AuthMaterial> {
    let mut paths = Vec::new();
    if let Some(home) = context
        .env("CODEX_HOME")
        .filter(|value| !value.trim().is_empty())
    {
        paths.push(PathBuf::from(home).join("auth.json"));
    }
    paths.push(context.home_directory.join(".codex/auth.json"));
    for path in paths {
        if let Some(auth) = read_auth(&path) {
            return Some(auth);
        }
    }
    None
}

fn read_auth(path: &Path) -> Option<AuthMaterial> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let value: Value = serde_json::from_slice(&read_bounded_file(path, LOCAL_FILE_LIMIT)?).ok()?;
    parse_auth(&value, &path.to_string_lossy())
}

fn parse_auth(value: &Value, source: &str) -> Option<AuthMaterial> {
    let pat = obj_get_any(value, &["personal_access_token", "personalAccessToken"])
        .and_then(|v| string(Some(v)));
    let oauth = parse_oauth_credentials(value);
    if pat.is_none() && oauth.is_none() {
        return None;
    }
    Some(AuthMaterial {
        pat,
        oauth,
        source: source.to_owned(),
    })
}

fn parse_oauth_credentials(value: &Value) -> Option<Credentials> {
    let tokens = value.get("tokens")?.as_object()?;
    let access_token = obj_get_any(
        &Value::Object(tokens.clone()),
        &["access_token", "accessToken"],
    )
    .and_then(|v| string(Some(v)))?;
    let id_token = obj_get_any(&Value::Object(tokens.clone()), &["id_token", "idToken"])
        .and_then(|v| string(Some(v)));
    let account_id = obj_get_any(&Value::Object(tokens.clone()), &["account_id", "accountId"])
        .and_then(|v| string(Some(v)));
    Some(Credentials {
        access_token,
        id_token,
        account_id,
    })
}

fn collect_pat(token: &str, context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let client = HttpClient::new()?;
    let bearer = format!("Bearer {token}");
    let user_agent = pat_user_agent();
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
        ("originator", "codex_cli_rs"),
    ];
    let (_, whoami) = client.get_json(WHOAMI_URL, &headers, SOURCE_PAT)?;
    let account_id = obj_get_any(&whoami, &["chatgpt_account_id", "chatgptAccountId"])
        .and_then(|v| string(Some(v)));
    let email = obj_get(&whoami, "email").and_then(|v| string(Some(v)));
    let plan = obj_get_any(&whoami, &["chatgpt_plan_type", "chatgptPlanType"])
        .and_then(|v| string(Some(v)));
    let mut usage_headers = vec![
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
        ("originator", "codex_cli_rs"),
    ];
    if let Some(account_id) = account_id.as_deref() {
        usage_headers.push(("ChatGPT-Account-Id", account_id));
    }
    let (_, value) = client.get_json(USAGE_URL, &usage_headers, SOURCE_PAT)?;
    let mapped = map_usage(&value);
    if mapped.malformed_success {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE_PAT));
    }
    if mapped.windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE_PAT));
    }
    Ok(snapshot(
        &mapped.windows,
        mapped.plan.as_deref().or(plan.as_deref()),
        mapped.email.as_deref().or(email.as_deref()),
        mapped.account_id.as_deref().or(account_id.as_deref()),
        &context.observed_at(),
    ))
}

/// Codex only honors personal access tokens from requests that identify as its CLI.
fn pat_user_agent() -> String {
    let platform = if cfg!(target_os = "macos") {
        "Mac OS"
    } else if cfg!(target_os = "linux") {
        "Linux"
    } else {
        "Darwin"
    };
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "x86_64") {
        "x86_64"
    } else {
        "unknown"
    };
    format!("codex_cli_rs ({platform}; {arch})")
}

fn extract_identity(credentials: &Credentials) -> Identity {
    let payload = credentials.id_token.as_deref().and_then(decode_jwt_payload);
    let auth = payload
        .as_ref()
        .and_then(|value| value.get("https://api.openai.com/auth"));
    let profile = payload
        .as_ref()
        .and_then(|value| value.get("https://api.openai.com/profile"));
    Identity {
        email: obj_get_any(payload.as_ref().unwrap_or(&Value::Null), &["email"])
            .and_then(|v| string(Some(v)))
            .or_else(|| {
                obj_get_any(profile.unwrap_or(&Value::Null), &["email"])
                    .and_then(|v| string(Some(v)))
            }),
        plan: obj_get_any(auth.unwrap_or(&Value::Null), &["chatgpt_plan_type"])
            .and_then(|v| string(Some(v)))
            .or_else(|| {
                obj_get_any(
                    payload.as_ref().unwrap_or(&Value::Null),
                    &["chatgpt_plan_type"],
                )
                .and_then(|v| string(Some(v)))
            }),
        account_id: credentials
            .account_id
            .clone()
            .or_else(|| {
                obj_get_any(auth.unwrap_or(&Value::Null), &["chatgpt_account_id"])
                    .and_then(|v| string(Some(v)))
            })
            .or_else(|| {
                obj_get_any(
                    payload.as_ref().unwrap_or(&Value::Null),
                    &["chatgpt_account_id"],
                )
                .and_then(|v| string(Some(v)))
            }),
    }
}

pub(super) fn collect_api(
    credentials: &Credentials,
    identity: &Identity,
    context: &CollectionContext,
    source: &'static str,
) -> Result<Option<QuotaSnapshot>, ProviderError> {
    let client = HttpClient::new()?;
    let bearer = format!("Bearer {}", credentials.access_token);
    let mut headers = vec![
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
    ];
    if let Some(account_id) = identity
        .account_id
        .as_deref()
        .or(credentials.account_id.as_deref())
    {
        headers.push(("ChatGPT-Account-Id", account_id));
    }
    let (_, value) = client.get_json(USAGE_URL, &headers, source)?;
    let mapped = map_usage(&value);
    if mapped.malformed_success {
        return Err(ProviderError::new(ErrorCategory::Error, source));
    }
    if !mapped.windows.is_empty() {
        let plan = mapped.plan.or_else(|| identity.plan.clone());
        let email = mapped.email.or_else(|| identity.email.clone());
        let account_id = mapped
            .account_id
            .or_else(|| identity.account_id.clone())
            .or_else(|| credentials.account_id.clone());
        return Ok(Some(snapshot(
            &mapped.windows,
            plan.as_deref(),
            email.as_deref(),
            account_id.as_deref(),
            &context.observed_at(),
        )));
    }
    Ok(None)
}

#[derive(Default)]
pub(super) struct MappedUsage {
    plan: Option<String>,
    email: Option<String>,
    account_id: Option<String>,
    windows: Vec<QuotaWindow>,
    malformed_success: bool,
}

pub(super) fn map_usage(value: &Value) -> MappedUsage {
    let Some(_root) = value.as_object() else {
        return MappedUsage {
            malformed_success: true,
            ..Default::default()
        };
    };
    let plan = obj_get_any(value, &["plan_type", "planType"]).and_then(|v| string(Some(v)));
    let email = obj_get(value, "email").and_then(|v| string(Some(v)));
    let account_id = obj_get_any(value, &["account_id", "accountId"]).and_then(|v| string(Some(v)));
    let rate_limit = obj_get_any(value, &["rate_limit", "rateLimit"]);
    let primary = rate_limit
        .and_then(|v| obj_get_any(v, &["primary_window", "primaryWindow"]))
        .and_then(|v| map_window(v, "five_hour", "5 hour"));
    let secondary = rate_limit
        .and_then(|v| obj_get_any(v, &["secondary_window", "secondaryWindow"]))
        .and_then(|v| map_window(v, "weekly", "Weekly"));
    let mut windows = normalize_primary_secondary(primary, secondary);
    windows.extend(map_additional(obj_get_any(
        value,
        &["additional_rate_limits", "additionalRateLimits"],
    )));
    windows.extend(map_code_review(obj_get_any(
        value,
        &["code_review_rate_limit", "codeReviewRateLimit"],
    )));
    let primary_present = rate_limit
        .and_then(|v| obj_get_any(v, &["primary_window", "primaryWindow"]))
        .map(|v| !v.is_null())
        .unwrap_or(false);
    let secondary_present = rate_limit
        .and_then(|v| obj_get_any(v, &["secondary_window", "secondaryWindow"]))
        .map(|v| !v.is_null())
        .unwrap_or(false);
    let malformed_primary = primary_present
        && !rate_limit
            .and_then(|v| obj_get_any(v, &["primary_window", "primaryWindow"]))
            .and_then(|v| map_window(v, "five_hour", "5 hour"))
            .is_some();
    let malformed_secondary = secondary_present
        && !rate_limit
            .and_then(|v| obj_get_any(v, &["secondary_window", "secondaryWindow"]))
            .and_then(|v| map_window(v, "weekly", "Weekly"))
            .is_some();
    MappedUsage {
        plan,
        email,
        account_id,
        malformed_success: windows.is_empty() && (malformed_primary || malformed_secondary),
        windows,
    }
}

const FIVE_HOUR_SECONDS: u64 = 18_000;
const WEEKLY_SECONDS: u64 = 604_800;
const MONTHLY_SECONDS: u64 = 2_592_000;

/// Ordered as the windows are displayed: shortest cadence first.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum WindowKind {
    FiveHour,
    Weekly,
    Monthly,
}

impl WindowKind {
    /// A window whose reported duration names no known cadence keeps the
    /// cadence of the payload slot it arrived in.
    fn classify(duration: Option<u64>, fallback: Self) -> Self {
        match duration {
            Some(FIVE_HOUR_SECONDS) => Self::FiveHour,
            Some(WEEKLY_SECONDS) => Self::Weekly,
            Some(MONTHLY_SECONDS) => Self::Monthly,
            _ => fallback,
        }
    }

    fn labels(self) -> (&'static str, &'static str) {
        match self {
            Self::FiveHour => ("five_hour", "5 hour"),
            Self::Weekly => ("weekly", "Weekly"),
            Self::Monthly => ("monthly", "Monthly"),
        }
    }
}

fn map_window(value: &Value, id: &str, title: &str) -> Option<QuotaWindow> {
    let used =
        obj_get_any(value, &["used_percent", "usedPercent"]).and_then(|v| number(Some(v)))?;
    let reset = obj_get_any(value, &["reset_at", "resetAt", "resetsAt", "resets_at"])
        .and_then(|v| parse_date(Some(v)))
        .map(super::common::unix_seconds_to_iso);
    Some(QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(used),
        resets_at: reset,
        duration_seconds: window_duration_seconds(value),
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    })
}

fn window_duration_seconds(value: &Value) -> Option<u64> {
    if let Some(seconds) = obj_get_any(value, &["limit_window_seconds", "limitWindowSeconds"])
        .and_then(|v| number(Some(v)))
        .filter(|value| *value >= 0.0)
    {
        return Some(seconds.floor() as u64);
    }
    obj_get_any(
        value,
        &[
            "windowDurationMins",
            "window_duration_mins",
            "windowMinutes",
            "window_minutes",
        ],
    )
    .and_then(|v| number(Some(v)))
    .filter(|value| *value >= 0.0)
    .map(|minutes| (minutes * 60.0).floor() as u64)
}

fn normalize_primary_secondary(
    primary: Option<QuotaWindow>,
    secondary: Option<QuotaWindow>,
) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    if let Some(window) = primary {
        windows.push(label_window(window, WindowKind::FiveHour));
    }
    if let Some(window) = secondary {
        let labeled = label_window(window, WindowKind::Weekly);
        if !windows.iter().any(|(kind, _)| *kind == labeled.0) {
            windows.push(labeled);
        }
    }
    windows.sort_by_key(|(kind, _)| *kind);
    windows.into_iter().map(|(_, window)| window).collect()
}

fn label_window(mut window: QuotaWindow, fallback: WindowKind) -> (WindowKind, QuotaWindow) {
    let kind = WindowKind::classify(window.duration_seconds, fallback);
    let (id, title) = kind.labels();
    window.id = id.to_owned();
    window.title = title.to_owned();
    (kind, window)
}

fn map_additional(value: Option<&Value>) -> Vec<QuotaWindow> {
    let Some(entries) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut used = std::collections::HashSet::<String>::new();
    let mut windows = Vec::new();
    for entry in entries {
        let limit_name =
            obj_get_any(entry, &["limit_name", "limitName"]).and_then(|v| string(Some(v)));
        let metered = obj_get_any(entry, &["metered_feature", "meteredFeature"])
            .and_then(|v| string(Some(v)));
        let rate = obj_get_any(entry, &["rate_limit", "rateLimit"]);
        let primary = rate.and_then(|v| obj_get_any(v, &["primary_window", "primaryWindow"]));
        let secondary = rate.and_then(|v| obj_get_any(v, &["secondary_window", "secondaryWindow"]));
        let spark = [limit_name.as_deref(), metered.as_deref()]
            .into_iter()
            .flatten()
            .any(|value| value.to_ascii_lowercase().contains("spark"));
        if spark {
            windows.extend(map_named_windows(
                primary,
                secondary,
                "codex-spark",
                "Codex Spark 5-hour",
                "codex-spark-weekly",
                "Codex Spark Weekly",
                &mut used,
            ));
            continue;
        }
        let Some(source) = metered.as_deref().or(limit_name.as_deref()) else {
            continue;
        };
        let id = format!("codex-{}", slug(source, '-'));
        if used.contains(&id) {
            continue;
        }
        if let Some(window) = primary.or(secondary).and_then(|v| {
            map_window(
                v,
                &id,
                limit_name
                    .as_deref()
                    .or(metered.as_deref())
                    .unwrap_or("Codex extra limit"),
            )
        }) {
            used.insert(id.clone());
            windows.push(window);
        }
    }
    windows
}

fn map_code_review(value: Option<&Value>) -> Vec<QuotaWindow> {
    let Some(value) = value.filter(|value| value.is_object()) else {
        return Vec::new();
    };
    let mut used = std::collections::HashSet::<String>::new();
    map_named_windows(
        obj_get_any(value, &["primary_window", "primaryWindow"]),
        obj_get_any(value, &["secondary_window", "secondaryWindow"]),
        "codex-code-review",
        "Code Review 5-hour",
        "codex-code-review-weekly",
        "Code Review Weekly",
        &mut used,
    )
}

fn map_named_windows(
    primary: Option<&Value>,
    secondary: Option<&Value>,
    five_id: &str,
    five_title: &str,
    weekly_id: &str,
    weekly_title: &str,
    used: &mut std::collections::HashSet<String>,
) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    for (candidate, fallback) in [
        (primary, WindowKind::FiveHour),
        (secondary, WindowKind::Weekly),
    ] {
        let Some(value) = candidate else {
            continue;
        };
        let kind = WindowKind::classify(window_duration_seconds(value), fallback);
        let (id, title) = match kind {
            WindowKind::FiveHour => (five_id, five_title),
            WindowKind::Weekly | WindowKind::Monthly => (weekly_id, weekly_title),
        };
        if let Some(window) = map_window(value, id, title)
            && used.insert(id.to_owned())
        {
            windows.push(window);
        }
    }
    windows
}

pub(super) fn snapshot(
    windows: &[QuotaWindow],
    plan: Option<&str>,
    email: Option<&str>,
    account_id: Option<&str>,
    observed_at: &str,
) -> QuotaSnapshot {
    let (fingerprint, scope) = account_identity("codex", "account_id", account_id);
    QuotaSnapshot {
        provider: ProviderId::Codex,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: mask_email(email),
            plan: plan.map(str::to_owned),
        },
        windows: windows.to_vec(),
        status: "available",
        observed_at: observed_at.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;

    /// Codex owns this grant, so a Mac without one has nothing for this collector to try.
    /// There is no second rung to fall to.
    #[test]
    fn no_local_grant_discovers_nothing() {
        let context = CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-codex-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: None,
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
        };
        assert!(discover(&context).is_empty());
        assert!(ProviderId::Codex.metadata().browser_session.is_none());
    }

    #[test]
    fn maps_primary_and_secondary_windows() {
        let usage = map_usage(
            &serde_json::json!({"rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 18000}, "secondary_window": {"used_percent": 33, "limit_window_seconds": 604800}}}),
        );
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["five_hour", "weekly"]
        );
        assert!(!usage.malformed_success);
    }

    #[test]
    fn maps_swapped_weekly_primary_and_five_hour_secondary() {
        let usage = map_usage(&serde_json::json!({
            "rate_limit": {
                "primary_window": {"used_percent": 33, "limit_window_seconds": 604800},
                "secondary_window": {"used_percent": 12, "limit_window_seconds": 18000}
            }
        }));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| (
                    window.id.as_str(),
                    window.title.as_str(),
                    window.used_percent
                ))
                .collect::<Vec<_>>(),
            [("five_hour", "5 hour", 12.0), ("weekly", "Weekly", 33.0)]
        );
    }

    #[test]
    fn maps_free_monthly_and_weekly_windows_by_duration() {
        let usage = map_usage(&serde_json::json!({
            "plan_type": "free",
            "rate_limit": {
                "primary_window": {"used_percent": 41, "limit_window_seconds": 2592000},
                "secondary_window": {"used_percent": 12, "limit_window_seconds": 604800}
            }
        }));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| (
                    window.id.as_str(),
                    window.title.as_str(),
                    window.used_percent
                ))
                .collect::<Vec<_>>(),
            [("weekly", "Weekly", 12.0), ("monthly", "Monthly", 41.0),]
        );
        assert!(!usage.malformed_success);
        // The same cadences stated in minutes rather than seconds.
        let minutes = map_usage(&serde_json::json!({
            "rate_limit": {
                "primary_window": {"used_percent": 22, "window_minutes": 43200},
                "secondary_window": {"usedPercent": 8, "windowDurationMins": 10080}
            }
        }));
        assert_eq!(
            minutes
                .windows
                .iter()
                .map(|window| (window.id.as_str(), window.duration_seconds))
                .collect::<Vec<_>>(),
            [("weekly", Some(604_800)), ("monthly", Some(2_592_000))]
        );
    }

    #[test]
    fn maps_free_monthly_primary_without_calling_it_five_hour() {
        let usage = map_usage(&serde_json::json!({
            "plan_type": "free",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 67,
                    "limit_window_seconds": 2592000,
                    "reset_at": 1787842532
                },
                "secondary_window": null
            }
        }));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| (window.id.as_str(), window.title.as_str()))
                .collect::<Vec<_>>(),
            [("monthly", "Monthly")]
        );
        assert!(!usage.malformed_success);
    }

    #[test]
    fn maps_weekly_only_primary_window() {
        let usage = map_usage(&serde_json::json!({
            "rate_limit": {
                "primary_window": {"used_percent": 100, "limit_window_seconds": 604800},
                "secondary_window": null
            }
        }));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["weekly"]
        );
        assert_eq!(usage.windows[0].title, "Weekly");
        assert!(!usage.malformed_success);
    }

    #[test]
    fn maps_code_review_rate_limit_when_present() {
        let usage = map_usage(&serde_json::json!({
            "rate_limit": {
                "primary_window": {"used_percent": 12, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 33, "limit_window_seconds": 604800}
            },
            "code_review_rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {"used_percent": 8, "limit_window_seconds": 604800},
                "secondary_window": null
            }
        }));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| (
                    window.id.as_str(),
                    window.title.as_str(),
                    window.used_percent
                ))
                .collect::<Vec<_>>(),
            [
                ("five_hour", "5 hour", 12.0),
                ("weekly", "Weekly", 33.0),
                ("codex-code-review-weekly", "Code Review Weekly", 8.0),
            ]
        );
        assert!(!usage.malformed_success);
    }

    #[test]
    fn maps_code_review_five_hour_and_weekly_windows() {
        let usage = map_usage(&serde_json::json!({
            "codeReviewRateLimit": {
                "primaryWindow": {"usedPercent": 4, "limitWindowSeconds": 18000},
                "secondaryWindow": {"usedPercent": 19, "limitWindowSeconds": 604800}
            }
        }));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["codex-code-review", "codex-code-review-weekly"]
        );
        assert_eq!(usage.windows[0].title, "Code Review 5-hour");
        assert_eq!(usage.windows[1].title, "Code Review Weekly");
        assert!(!usage.malformed_success);
    }

    #[test]
    fn ignores_null_code_review_rate_limit() {
        let usage = map_usage(&serde_json::json!({
            "rate_limit": {
                "primary_window": {"used_percent": 12, "limit_window_seconds": 18000}
            },
            "code_review_rate_limit": null
        }));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["five_hour"]
        );
        assert!(!usage.malformed_success);
    }

    #[test]
    fn accepts_snake_and_camel_case_credentials_but_requires_access_token() {
        let snake = parse_oauth_credentials(&serde_json::json!({
            "tokens": {"access_token": "access-snake", "id_token": "id-snake", "account_id": "acct-snake"}
        }))
        .unwrap();
        assert_eq!(snake.access_token, "access-snake");
        assert_eq!(snake.account_id.as_deref(), Some("acct-snake"));

        let camel = parse_oauth_credentials(&serde_json::json!({
            "tokens": {"accessToken": "access-camel", "idToken": "id-camel", "accountId": "acct-camel"}
        }))
        .unwrap();
        assert_eq!(camel.access_token, "access-camel");
        assert_eq!(camel.account_id.as_deref(), Some("acct-camel"));

        assert!(parse_oauth_credentials(&serde_json::json!({"tokens": {}})).is_none());
        assert!(parse_oauth_credentials(&serde_json::json!({})).is_none());
    }

    #[test]
    fn discovers_pat_only_auth_without_oauth_tokens() {
        let auth = parse_auth(
            &serde_json::json!({
                "personal_access_token": "pat-token"
            }),
            "fixture",
        )
        .unwrap();
        assert_eq!(auth.pat.as_deref(), Some("pat-token"));
        assert!(auth.oauth.is_none());

        let camel = parse_auth(
            &serde_json::json!({
                "personalAccessToken": "pat-camel",
                "tokens": {"access_token": "oauth"}
            }),
            "fixture",
        )
        .unwrap();
        assert_eq!(camel.pat.as_deref(), Some("pat-camel"));
        assert_eq!(camel.oauth.unwrap().access_token, "oauth");
        assert!(parse_auth(&serde_json::json!({}), "fixture").is_none());
    }

    #[test]
    fn extracts_identity_from_jwt_namespaces_without_emitting_raw_claims() {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&serde_json::json!({
                "email": "ada@example.com",
                "https://api.openai.com/auth": {
                    "chatgpt_plan_type": "pro",
                    "chatgpt_account_id": "acct-owner"
                }
            }))
            .unwrap(),
        );
        let credentials = Credentials {
            access_token: "opaque-access".to_owned(),
            id_token: Some(format!("header.{payload}.signature")),
            account_id: None,
        };
        let identity = extract_identity(&credentials);
        assert_eq!(identity.plan.as_deref(), Some("pro"));
        assert_eq!(identity.account_id.as_deref(), Some("acct-owner"));
        let snapshot = snapshot(
            &[],
            identity.plan.as_deref(),
            identity.email.as_deref(),
            identity.account_id.as_deref(),
            "2026-08-10T00:00:00Z",
        );
        let serialized = serde_json::to_string(&snapshot).unwrap();
        assert!(!serialized.contains("acct-owner"));
        assert!(!serialized.contains("ada@example.com"));
    }
}
