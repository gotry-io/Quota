use crate::catalog::ProviderId;
use serde_json::Value;
use std::path::{Path, PathBuf};

use super::common::{
    Cadence, CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProbeEnvironment,
    ProviderError, ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, account_identity,
    clamp_percent, decode_jwt_payload, mask_email, number, obj_get, obj_get_any, parse_date,
    plan_slug, read_bounded_file, resolve_binary, string, unix_seconds_to_iso, url_encode,
};

pub const SOURCE: &str = "gemini_code_assist_quota";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const CODE_ASSIST_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal";
/// Where the installed Gemini CLI keeps its installed-application OAuth client. The CLI ships
/// the id and the secret in its own package (`packages/core/src/code_assist/oauth2.ts`, where
/// Google's comment says the secret is not treated as one), and a refresh presents that
/// client. Quota reads the pair from the binary that is actually installed here rather than
/// carrying a copy: the values are the CLI's to change, and a copy would be a credential in
/// this repository whatever its author calls it.
const OAUTH_CLIENT_FILE: &str = "code_assist/oauth2.js";
const OAUTH_CLIENT_PACKAGE: &str = "gemini-cli-core";
const OAUTH_CLIENT_FILE_LIMIT: usize = 512 * 1024;
const GEMINI_BINARY: &str = "gemini";
const TOKEN_SKEW_SECONDS: i64 = 60;
const CREDENTIAL_FILE: &str = "oauth_creds.json";

#[derive(Clone, Debug)]
struct Credentials {
    access_token: String,
    refresh_token: Option<String>,
    expiry: Option<i64>,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    load_credentials(context)
        .ok()
        .map(|credentials| {
            vec![ProviderSession {
                provider: ProviderId::Gemini,
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
    let project = load_project(&client, context, code_assist_url, &access_token)?;
    let quota = retrieve_user_quota(&client, context, code_assist_url, &access_token, &project)?;
    let windows = map_windows(&quota, context.observed_unix());
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let (fingerprint, scope, label) = identity(&access_token);
    Ok(QuotaSnapshot {
        provider: ProviderId::Gemini,
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
    context.home_directory.join(".gemini")
}

fn load_credentials(context: &CollectionContext) -> Result<Credentials, ProviderError> {
    let path = gemini_home(context).join(CREDENTIAL_FILE);
    let bytes = read_bounded_file(&path, LOCAL_FILE_LIMIT)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    parse_credentials(&value, &path)
}

fn parse_credentials(value: &Value, path: &Path) -> Result<Credentials, ProviderError> {
    let access_token = obj_get_any(value, &["access_token", "accessToken"]).and_then(as_token);
    let refresh_token = obj_get_any(value, &["refresh_token", "refreshToken"]).and_then(as_token);
    if access_token.is_none() && refresh_token.is_none() {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    Ok(Credentials {
        access_token: access_token.unwrap_or_default(),
        refresh_token,
        expiry: obj_get_any(
            value,
            &["expiry_date", "expiryDate", "expires_at", "expiresAt"],
        )
        .and_then(|value| parse_date(Some(value))),
        source: path.to_string_lossy().into_owned(),
    })
}

fn as_token(value: &Value) -> Option<String> {
    string(Some(value)).filter(|token| token.len() <= 8_192 && !token.chars().any(char::is_control))
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
    refresh_access_token(refresh_token, context, token_url)
}

fn refresh_access_token(
    refresh_token: &str,
    context: &CollectionContext,
    token_url: &str,
) -> Result<String, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    // Without the installed CLI's client there is nothing to present, and the stored grant
    // is only as good as its access token: sign in through the CLI restores it.
    let client_pair = installed_oauth_client(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let body = format!(
        "client_id={}&client_secret={}&refresh_token={}&grant_type=refresh_token",
        url_encode(&client_pair.id),
        url_encode(&client_pair.secret),
        url_encode(refresh_token)
    );
    let user_agent = context.user_agent();
    let headers = [
        ("Content-Type", "application/x-www-form-urlencoded"),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let client = HttpClient::new()?;
    let (_, bytes) = client.post_bytes(token_url, &headers, body.as_bytes(), SOURCE)?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    as_token(obj_get(&value, "access_token").unwrap_or(&Value::Null))
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))
}

/// The OAuth client the installed Gemini CLI presents, read from its package on disk.
struct OAuthClient {
    id: String,
    secret: String,
}

/// Resolves the `gemini` binary the way every CLI is resolved here, walks up from its real
/// path to the `node_modules` that holds `@google/gemini-cli-core`, and reads the two
/// constants from `dist/src/code_assist/oauth2.js`. None when the CLI is not installed or its
/// layout changed; a refresh then answers `auth_required` rather than guessing a client.
fn installed_oauth_client(context: &CollectionContext) -> Option<OAuthClient> {
    let environment = ProbeEnvironment::new(
        context.home_directory.clone(),
        context.environment.get("PATH").cloned(),
    );
    let binary = resolve_binary(GEMINI_BINARY, &environment)?;
    let file = oauth_client_file(&binary)?;
    let bytes = read_bounded_file(&file, OAUTH_CLIENT_FILE_LIMIT)?;
    oauth_client_from_source(std::str::from_utf8(&bytes).ok()?)
}

fn oauth_client_file(binary: &Path) -> Option<PathBuf> {
    let mut directory = binary.parent()?;
    for _ in 0..8 {
        let candidate = directory
            .join("node_modules")
            .join("@google")
            .join(OAUTH_CLIENT_PACKAGE)
            .join("dist")
            .join("src")
            .join(OAUTH_CLIENT_FILE);
        if candidate.is_file() {
            return Some(candidate);
        }
        directory = directory.parent()?;
    }
    None
}

fn oauth_client_from_source(text: &str) -> Option<OAuthClient> {
    let id = js_string_constant(text, "OAUTH_CLIENT_ID")?;
    let secret = js_string_constant(text, "OAUTH_CLIENT_SECRET")?;
    (id.ends_with(".apps.googleusercontent.com") && !secret.is_empty())
        .then_some(OAuthClient { id, secret })
}

/// `const NAME = '...'` or `"..."`, the first occurrence, no escapes: the CLI writes plain
/// literals and anything else is not the constant this build knows how to read.
fn js_string_constant(text: &str, name: &str) -> Option<String> {
    let start = text.find(name)? + name.len();
    let rest = text[start..].trim_start();
    let rest = rest.strip_prefix('=')?.trim_start();
    let quote = rest.chars().next()?;
    if quote != '\'' && quote != '"' {
        return None;
    }
    let body = &rest[1..];
    let end = body.find(quote)?;
    let value = &body[..end];
    (!value.is_empty() && value.len() <= 256 && !value.contains('\\')).then(|| value.to_owned())
}

struct Project {
    id: String,
    plan: Option<String>,
}

fn load_project(
    client: &HttpClient,
    context: &CollectionContext,
    code_assist_url: &str,
    access_token: &str,
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
            "ideType": "GEMINI_CLI",
            "pluginType": "GEMINI"
        }
    });
    if let Some(project) = &env_project {
        body["cloudaicompanionProject"] = Value::String(project.clone());
    }
    let bearer = format!("Bearer {access_token}");
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, value) = client.post_json(&url, &headers, &body, SOURCE)?;
    let project = string(obj_get(&value, "cloudaicompanionProject"))
        .or(env_project)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    let plan = obj_get(&value, "currentTier")
        .and_then(|tier| string(obj_get(tier, "id")).or_else(|| string(obj_get(tier, "name"))))
        .and_then(|id| plan_slug(Some(&id)));
    Ok(Project { id: project, plan })
}

fn retrieve_user_quota(
    client: &HttpClient,
    context: &CollectionContext,
    code_assist_url: &str,
    access_token: &str,
    project: &Project,
) -> Result<Value, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let url = format!(
        "{}:retrieveUserQuota",
        code_assist_url.trim_end_matches('/')
    );
    let bearer = format!("Bearer {access_token}");
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let body = serde_json::json!({ "project": project.id });
    let (_, value) = client.post_json(&url, &headers, &body, SOURCE)?;
    Ok(value)
}

fn identity(access_token: &str) -> (String, &'static str, Option<String>) {
    let payload = decode_jwt_payload(access_token);
    let email = payload
        .as_ref()
        .and_then(|value| string(obj_get(value, "email")));
    let subject = payload
        .as_ref()
        .and_then(|value| string(obj_get(value, "sub")));
    let owner = email.clone().or(subject);
    let (fingerprint, scope) = account_identity("gemini", "oauth", owner.as_deref());
    (fingerprint, scope, mask_email(email.as_deref()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WindowKind {
    PerMinute,
    Daily,
    Weekly,
    Monthly,
}

impl WindowKind {
    fn id(self) -> &'static str {
        match self {
            Self::PerMinute => "per_minute",
            Self::Daily => "daily",
            Self::Weekly => Cadence::Weekly.wire(),
            Self::Monthly => Cadence::Monthly.wire(),
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::PerMinute => "Per Minute",
            Self::Daily => "Daily",
            Self::Weekly => Cadence::Weekly.title(),
            Self::Monthly => Cadence::Monthly.title(),
        }
    }

    fn cadence(self) -> Option<Cadence> {
        match self {
            Self::Weekly => Some(Cadence::Weekly),
            Self::Monthly => Some(Cadence::Monthly),
            Self::PerMinute | Self::Daily => None,
        }
    }

    fn duration_seconds(self) -> Option<u64> {
        match self {
            Self::PerMinute => Some(60),
            Self::Daily => Some(86_400),
            Self::Weekly => Some(7 * 86_400),
            Self::Monthly => None,
        }
    }
}

struct Bucket {
    remaining: f64,
    limit: f64,
    resets_at: Option<String>,
    kind: WindowKind,
}

fn map_windows(value: &Value, now: i64) -> Vec<QuotaWindow> {
    let Some(buckets) = value.get("buckets").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut pooled: Vec<(WindowKind, f64, f64, Option<String>)> = Vec::new();
    for bucket in buckets.iter().filter_map(|entry| map_bucket(entry, now)) {
        if let Some((_, remaining, limit, resets_at)) = pooled
            .iter_mut()
            .find(|(kind, _, _, _)| *kind == bucket.kind)
        {
            *remaining += bucket.remaining;
            *limit += bucket.limit;
            if resets_at.is_none() {
                *resets_at = bucket.resets_at;
            }
        } else {
            pooled.push((
                bucket.kind,
                bucket.remaining,
                bucket.limit,
                bucket.resets_at,
            ));
        }
    }
    pooled.sort_by_key(|(kind, _, _, _)| match kind {
        WindowKind::PerMinute => 0,
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

fn map_bucket(value: &Value, now: i64) -> Option<Bucket> {
    let token_type = string(obj_get(value, "tokenType")).unwrap_or_else(|| "REQUESTS".to_owned());
    if !token_type.eq_ignore_ascii_case("REQUESTS") && !token_type.is_empty() {
        return None;
    }
    let remaining_amount = number(obj_get(value, "remainingAmount"));
    let remaining_fraction = number(obj_get(value, "remainingFraction"));
    let (remaining, limit) = match (remaining_amount, remaining_fraction) {
        (Some(remaining), Some(fraction)) if fraction > 0.0 => (remaining, remaining / fraction),
        (Some(remaining), _) => (remaining, remaining),
        (None, Some(fraction)) => (fraction * 100.0, 100.0),
        (None, None) => return None,
    };
    let reset = obj_get(value, "resetTime").and_then(|value| parse_date(Some(value)));
    let kind = classify_reset(reset, now);
    Some(Bucket {
        remaining,
        limit,
        resets_at: reset.map(unix_seconds_to_iso),
        kind,
    })
}

fn classify_reset(reset: Option<i64>, now: i64) -> WindowKind {
    let Some(reset) = reset else {
        return WindowKind::Daily;
    };
    let until = reset.saturating_sub(now);
    if until <= 5 * 60 {
        WindowKind::PerMinute
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
            home_directory: std::path::PathBuf::from("/tmp/quota-gemini-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: Some(std::path::PathBuf::from(
                "/tmp/quota-gemini-missing-config/providers.json",
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

    fn serve(responses: Vec<(u16, &str)>) -> (String, std::thread::JoinHandle<Vec<String>>) {
        crate::providers::common::serve_responses(
            responses
                .into_iter()
                .map(|(status, body)| (status, body.as_bytes().to_vec()))
                .collect(),
        )
    }

    fn write_creds(dir: &std::path::Path, body: &str) {
        std::fs::create_dir_all(dir.join(".gemini")).expect("gemini dir");
        std::fs::write(dir.join(".gemini").join(CREDENTIAL_FILE), body).expect("creds");
    }

    #[test]
    fn maps_pooled_daily_and_per_minute_request_buckets() {
        let windows = map_windows(
            &serde_json::json!({
                "buckets": [
                    {
                        "modelId": "gemini-2.5-pro",
                        "tokenType": "REQUESTS",
                        "remainingAmount": "800",
                        "remainingFraction": 0.8,
                        "resetTime": "2026-08-11T00:00:00Z"
                    },
                    {
                        "modelId": "gemini-2.5-flash",
                        "tokenType": "REQUESTS",
                        "remainingAmount": "400",
                        "remainingFraction": 0.8,
                        "resetTime": "2026-08-11T00:00:00Z"
                    },
                    {
                        "modelId": "gemini-2.5-pro",
                        "tokenType": "REQUESTS",
                        "remainingAmount": "50",
                        "remainingFraction": 0.5,
                        "resetTime": "2026-08-10T00:01:00Z"
                    }
                ]
            }),
            1_786_320_000,
        );
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["per_minute", "daily"]
        );
        assert_eq!(windows[0].remaining_value, Some(50.0));
        assert_eq!(windows[0].limit_value, Some(100.0));
        assert_eq!(windows[0].duration_seconds, Some(60));
        assert_eq!(windows[1].remaining_value, Some(1_200.0));
        assert_eq!(windows[1].limit_value, Some(1_500.0));
        assert_eq!(windows[1].used_percent, 20.0);
        assert_eq!(windows[1].duration_seconds, Some(86_400));
        assert_eq!(windows[1].value_unit, Some("count"));
    }

    #[test]
    fn derives_limit_from_remaining_fraction_alone() {
        let windows = map_windows(
            &serde_json::json!({
                "buckets": [{
                    "modelId": "gemini-3-flash-preview",
                    "remainingFraction": 0.96,
                    "resetTime": "2026-08-11T00:00:00Z"
                }]
            }),
            1_786_320_000,
        );
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].remaining_value, Some(96.0));
        assert_eq!(windows[0].limit_value, Some(100.0));
        assert_eq!(windows[0].used_percent, 4.0);
    }

    #[test]
    fn skips_non_request_token_types() {
        let windows = map_windows(
            &serde_json::json!({
                "buckets": [{
                    "tokenType": "TOKENS",
                    "remainingAmount": "10",
                    "remainingFraction": 1.0
                }]
            }),
            1_786_320_000,
        );
        assert!(windows.is_empty());
    }

    #[test]
    fn collect_loads_code_assist_then_quota() {
        let root = std::env::temp_dir().join(format!("quota-gemini-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_creds(
            &root,
            r#"{"access_token":"ya29.live","refresh_token":"1//refresh","expiry_date":1786406400000}"#,
        );
        let (address, server) = serve(vec![
            (
                200,
                r#"{"cloudaicompanionProject":"gen-lang-client-1","currentTier":{"id":"standard-tier"}}"#,
            ),
            (
                200,
                r#"{"buckets":[{"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","remainingAmount":"800","remainingFraction":0.8,"resetTime":"2026-08-11T00:00:00Z"}]}"#,
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
        assert_eq!(snapshot.account.plan.as_deref(), Some("standard_tier"));
        assert_eq!(snapshot.windows[0].id, "daily");
        let heads = server.join().expect("server");
        assert!(heads[0].contains("authorization: bearer ya29.live"));
        assert!(heads[0].contains(":loadcodeassist"));
        assert!(heads[1].contains(":retrieveuserquota"));
        let _ = std::fs::remove_dir_all(root);
    }

    /// A `gemini` launcher and the package file the client is read from, laid out the way npm
    /// installs them: `<prefix>/bin/gemini` → `<prefix>/lib/node_modules/@google/gemini-cli/…`
    /// with `gemini-cli-core` beside it.
    fn install_fake_cli(root: &std::path::Path) -> String {
        let prefix = root.join("npm");
        let bin = prefix.join("bin");
        let core = prefix
            .join("lib")
            .join("node_modules")
            .join("@google")
            .join("gemini-cli-core")
            .join("dist")
            .join("src")
            .join("code_assist");
        std::fs::create_dir_all(&bin).expect("bin");
        std::fs::create_dir_all(&core).expect("core");
        let cli = prefix
            .join("lib")
            .join("node_modules")
            .join("@google")
            .join("gemini-cli")
            .join("dist");
        std::fs::create_dir_all(&cli).expect("cli");
        std::fs::write(cli.join("index.js"), "#!/usr/bin/env node\n").expect("index");
        std::os::unix::fs::symlink(cli.join("index.js"), bin.join("gemini")).expect("link");
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(cli.join("index.js"), std::fs::Permissions::from_mode(0o755))
            .expect("mode");
        std::fs::write(
            core.join("oauth2.js"),
            "const OAUTH_CLIENT_ID = 'test-id.apps.googleusercontent.com';\nconst OAUTH_CLIENT_SECRET = \"test-secret\";\n",
        )
        .expect("oauth2");
        bin.to_string_lossy().into_owned()
    }

    #[test]
    fn expired_access_token_is_refreshed_in_memory() {
        let root =
            std::env::temp_dir().join(format!("quota-gemini-refresh-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_creds(
            &root,
            r#"{"access_token":"ya29.stale","refresh_token":"1//refresh","expiry_date":1000}"#,
        );
        let (address, server) = serve(vec![
            (200, r#"{"access_token":"ya29.fresh","expires_in":3600}"#),
            (
                200,
                r#"{"cloudaicompanionProject":"gen-lang-client-1","currentTier":{"id":"free-tier"}}"#,
            ),
            (
                200,
                r#"{"buckets":[{"remainingFraction":1.0,"resetTime":"2026-08-11T00:00:00Z"}]}"#,
            ),
        ]);
        let mut context = isolated_context();
        context.home_directory = root.clone();
        let bin = install_fake_cli(&root);
        context.environment.insert("PATH".to_owned(), bin);
        let snapshot = collect_at(
            &context,
            &format!("http://{address}/token"),
            &format!("http://{address}/v1internal"),
        )
        .expect("snapshot");
        assert_eq!(snapshot.account.plan.as_deref(), Some("free_tier"));
        let heads = server.join().expect("server");
        assert!(heads[0].contains("grant_type=refresh_token"));
        assert!(heads[0].contains("client_id=test-id.apps.googleusercontent.com"));
        assert!(heads[0].contains("client_secret=test-secret"));
        assert!(heads[1].contains("authorization: bearer ya29.fresh"));
        let on_disk =
            std::fs::read_to_string(root.join(".gemini").join(CREDENTIAL_FILE)).expect("disk");
        assert!(on_disk.contains("ya29.stale"));
        assert!(!on_disk.contains("ya29.fresh"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn an_expired_token_without_the_installed_cli_is_auth_required() {
        let root = std::env::temp_dir().join(format!("quota-gemini-nocli-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_creds(
            &root,
            r#"{"access_token":"ya29.stale","refresh_token":"1//refresh","expiry_date":1000}"#,
        );
        let mut context = isolated_context();
        context.home_directory = root.clone();
        context.environment.insert(
            "PATH".to_owned(),
            root.join("empty").to_string_lossy().into_owned(),
        );
        let error = collect_at(
            &context,
            "http://127.0.0.1:9/token",
            "http://127.0.0.1:9/v1",
        )
        .expect_err("no client to present");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_oauth_client_is_read_from_the_cli_source_only_as_plain_literals() {
        let source = "export const OAUTH_CLIENT_ID = '1-a.apps.googleusercontent.com';\nconst OAUTH_CLIENT_SECRET = \"s\";";
        let client = oauth_client_from_source(source).expect("client");
        assert_eq!(client.id, "1-a.apps.googleusercontent.com");
        assert_eq!(client.secret, "s");
        assert!(oauth_client_from_source("const OAUTH_CLIENT_ID = process.env.X;").is_none());
        assert!(
            oauth_client_from_source(
                "const OAUTH_CLIENT_ID = 'x.example';\nconst OAUTH_CLIENT_SECRET='s';"
            )
            .is_none()
        );
    }

    #[test]
    fn missing_credential_is_auth_required() {
        let error = collect(
            &ProviderSession {
                provider: ProviderId::Gemini,
                credential_source: "missing".into(),
                cookie_header: None,
            },
            &isolated_context(),
        )
        .expect_err("missing");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        assert_eq!(error.source_id, SOURCE);
    }

    #[test]
    fn jwt_email_is_a_global_fingerprint() {
        // {"email":"ab@example.com","sub":"user-1"}
        let token = "header.eyJlbWFpbCI6ImFiQGV4YW1wbGUuY29tIiwic3ViIjoidXNlci0xIn0.sig";
        let (fingerprint, scope, label) = identity(token);
        assert_eq!(scope, "global");
        assert_eq!(label.as_deref(), Some("ab***@example.com"));
        assert_eq!(
            fingerprint,
            account_identity("gemini", "oauth", Some("ab@example.com")).0
        );
    }
}
