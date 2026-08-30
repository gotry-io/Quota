use crate::catalog::ProviderId;
use serde_json::Value;
use std::path::{Path, PathBuf};

use super::common::{
    ApiKeyCredentials, CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient,
    LOCAL_FILE_LIMIT, ProviderError, ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow,
    VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity, api_key_identity, clamp_percent,
    collect_official_or_browser, cookie_named_value, discover_official_or_browser, jwt_subject,
    number, obj_get, obj_get_any, parse_date, read_bounded_file, resolve_api_key, string,
};

pub const SOURCE: &str = "kimi_code_usages_api";
pub const CLI_SOURCE: &str = "kimi_code_cli_credential";
pub const WEB_SOURCE: &str = "kimi_web_billing_api";
const DEFAULT_CODE_BASE_URL: &str = "https://api.kimi.com";
const WEB_ORIGIN: &str = "https://www.kimi.com";
const WEB_USAGES_PATH: &str = "/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages";
/// What a stored Kimi session is called, since the billing RPC names nobody.
const WEB_ACCOUNT_LABEL: &str = "Kimi";
const CLI_TOKEN_SKEW_SECONDS: i64 = 60;

#[derive(Clone, Debug)]
struct CliCredentials {
    access_token: String,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    discover_official_or_browser(
        ProviderId::Kimi,
        resolve(context)
            .ok()
            .map(|credentials| credentials.source)
            .or_else(|| load_cli_credentials(context).map(|credentials| credentials.source))
            .map(|credential_source| ProviderSession {
                provider: ProviderId::Kimi,
                credential_source,
                cookie_header: None,
            }),
        context,
    )
}

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    validate_at(
        cookie_header,
        context,
        &format!("{WEB_ORIGIN}{WEB_USAGES_PATH}"),
    )
}

/// Proves the cookie belongs to a signed-in kimi.com account before anything is stored.
///
/// The billing RPC names nobody, so the proof is that it answers with the coding allowance
/// this build would read: a session kimi.com no longer accepts is refused outright, and one
/// that carries no coding usage is a session there is nothing here to show.
fn validate_at(
    cookie_header: &str,
    context: &CollectionContext,
    url: &str,
) -> Result<ValidatedBrowserSession, ProviderError> {
    let token = kimi_auth_token(cookie_header)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let data = fetch_web_usages(&token, context, url, VALIDATION_TIMEOUT)?;
    if map_web_usages(&data).is_none() {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let (account_fingerprint, _) = web_account_identity(&token);
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: Some(WEB_ACCOUNT_LABEL.to_owned()),
    })
}

/// An API key, then the token Kimi Code writes, then the stored kimi.com session.
pub fn collect(
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_official_or_browser(
        session,
        context,
        ProviderId::Kimi,
        SOURCE,
        || collect_local(context),
        || {
            let cookie = context
                .cookie_for_session(session)
                .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE))?;
            collect_web(context, cookie)
        },
    )
}

fn collect_local(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    match resolve(context) {
        Ok(credentials) => match collect_with_bearer(&BearerAuth::ApiKey(&credentials), context) {
            Ok(snapshot) => return Ok(snapshot),
            Err(error) if error.category == ErrorCategory::AuthRequired => {}
            Err(error) => return Err(error),
        },
        Err(error) if error.category == ErrorCategory::AuthRequired => {}
        Err(error) => return Err(error),
    }
    let cli = load_cli_credentials(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, CLI_SOURCE))?;
    collect_with_bearer(&BearerAuth::Cli(&cli), context)
}

/// A bearer token accepted by the Kimi Code usages endpoint.
enum BearerAuth<'a> {
    ApiKey(&'a ApiKeyCredentials),
    Cli(&'a CliCredentials),
}

impl BearerAuth<'_> {
    fn token(&self) -> &str {
        match self {
            Self::ApiKey(credentials) => &credentials.api_key,
            Self::Cli(credentials) => &credentials.access_token,
        }
    }

    fn base_url(&self) -> &str {
        match self {
            Self::ApiKey(credentials) => &credentials.base_url,
            Self::Cli(_) => DEFAULT_CODE_BASE_URL,
        }
    }

    fn source(&self) -> &'static str {
        match self {
            Self::ApiKey(_) => SOURCE,
            Self::Cli(_) => CLI_SOURCE,
        }
    }

    fn label(&self) -> String {
        match self {
            Self::ApiKey(credentials) => credentials.label.clone(),
            Self::Cli(_) => "Kimi Code".to_owned(),
        }
    }

    /// The CLI token is only honored when the request identifies as the CLI.
    fn platform_header(&self) -> Option<&'static str> {
        match self {
            Self::ApiKey(_) => None,
            Self::Cli(_) => Some("kimi_code_cli"),
        }
    }

    /// API keys are stable, so their hash identifies the account. CLI access
    /// tokens rotate on refresh, so they stay source-scoped like the web path.
    fn identity(&self) -> (String, &'static str) {
        match self {
            Self::ApiKey(credentials) => api_key_identity("kimi", &credentials.api_key),
            Self::Cli(_) => account_identity("kimi", "cli_credential", None),
        }
    }
}

fn collect_with_bearer(
    auth: &BearerAuth<'_>,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    let source = auth.source();
    let client = HttpClient::new()?;
    let url = format!("{}/coding/v1/usages", auth.base_url().trim_end_matches('/'));
    let bearer = format!("Bearer {}", auth.token());
    let user_agent = context.user_agent();
    let mut headers = vec![
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    if let Some(platform) = auth.platform_header() {
        headers.push(("X-Msh-Platform", platform));
    }
    let (_, value) = client.get_json(&url, &headers, source)?;
    let data =
        map_usages(&value).ok_or_else(|| ProviderError::new(ErrorCategory::Error, source))?;
    let windows = map_windows(&data);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, source));
    }
    let (fingerprint, scope) = auth.identity();
    Ok(QuotaSnapshot {
        provider: ProviderId::Kimi,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some(auth.label()),
            plan: None,
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn resolve(context: &CollectionContext) -> Result<ApiKeyCredentials, ProviderError> {
    resolve_api_key(context, ProviderId::Kimi, SOURCE)
}

/// Whether a discovered session came from the Kimi Code CLI's credential file rather than
/// a configured or environment API key.
pub fn is_cli_credential_source(credential_source: &str) -> bool {
    credential_source.ends_with(CLI_CREDENTIAL_FILE)
}

const CLI_CREDENTIAL_FILE: &str = "kimi-code.json";

fn load_cli_credentials(context: &CollectionContext) -> Option<CliCredentials> {
    let home = context
        .env("KIMI_CODE_HOME")
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".kimi-code"));
    let path = home.join("credentials").join(CLI_CREDENTIAL_FILE);
    read_cli_credentials(&path, context)
}

fn read_cli_credentials(path: &Path, context: &CollectionContext) -> Option<CliCredentials> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let value: Value = serde_json::from_slice(&read_bounded_file(path, LOCAL_FILE_LIMIT)?).ok()?;
    parse_cli_credentials(&value, &path.to_string_lossy(), context.observed_unix())
}

fn parse_cli_credentials(value: &Value, source: &str, now: i64) -> Option<CliCredentials> {
    let access_token = obj_get_any(value, &["access_token", "accessToken"])
        .and_then(|value| string(Some(value)))?;
    // Kimi Code writes this stamp in milliseconds. Reading a number as seconds put the expiry
    // fifty thousand years out, so a token that had run out looked live and the request that
    // spent it came back `auth_required`.
    let expires_at = obj_get_any(value, &["expires_at", "expiresAt"])
        .and_then(|value| parse_date(Some(value)))?;
    if expires_at <= now + CLI_TOKEN_SKEW_SECONDS {
        return None;
    }
    Some(CliCredentials {
        access_token,
        source: source.to_owned(),
    })
}

fn collect_web(
    context: &CollectionContext,
    cookie_header: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_web_at(
        cookie_header,
        context,
        &format!("{WEB_ORIGIN}{WEB_USAGES_PATH}"),
    )
}

fn collect_web_at(
    cookie_header: &str,
    context: &CollectionContext,
    url: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    let token = kimi_auth_token(cookie_header)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let value = fetch_web_usages(&token, context, url, HTTP_TIMEOUT)?;
    let data = map_web_usages(&value)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let windows = map_windows(&data);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let (fingerprint, scope) = web_account_identity(&token);
    Ok(QuotaSnapshot {
        provider: ProviderId::Kimi,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some(WEB_ACCOUNT_LABEL.to_owned()),
            plan: None,
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

/// The coding allowance kimi.com's own billing RPC reports for this session.
///
/// The request asks for the one scope this app shows, and identifies with both the bearer and
/// the cookie the value came from, as kimi.com's own console does.
fn fetch_web_usages(
    token: &str,
    context: &CollectionContext,
    url: &str,
    timeout: std::time::Duration,
) -> Result<Value, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    let client = HttpClient::with_timeout(timeout)?;
    let auth = format!("Bearer {token}");
    let cookie = format!("kimi-auth={token}");
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", auth.as_str()),
        ("Cookie", cookie.as_str()),
        ("Accept", "application/json"),
        ("Origin", WEB_ORIGIN),
        ("Referer", "https://www.kimi.com/code/console"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, value) = client.post_json_session(
        url,
        &headers,
        &serde_json::json!({"scope": ["FEATURE_CODING"]}),
        WEB_SOURCE,
    )?;
    Ok(value)
}

/// Whose kimi.com account a stored session speaks for.
///
/// The billing RPC names nobody, so the cookie itself has to: it is spent as a bearer, and the
/// subject it carries is what tells two signed-in accounts apart. A token that names no one
/// keeps the source-wide fingerprint, which says exactly that.
fn web_account_identity(token: &str) -> (String, &'static str) {
    account_identity("kimi", "browser_session", jwt_subject(token).as_deref())
}

/// The `kimi-auth` cookie is a whole sign-in: kimi.com spends its value as the bearer.
fn kimi_auth_token(header: &str) -> Option<String> {
    let value = cookie_named_value(header, "kimi-auth")?.trim();
    (!value.is_empty() && value.len() <= 8_192 && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
}

fn map_web_usages(value: &Value) -> Option<Usage> {
    let usages = value.get("usages").and_then(Value::as_array)?;
    let entry = usages.iter().find(|entry| {
        matches!(
            string(obj_get(entry, "scope")).as_deref(),
            Some("FEATURE_CODING" | "coding")
        )
    })?;
    let usage = obj_get(entry, "detail")
        .or_else(|| obj_get(entry, "usage"))
        .cloned()
        .unwrap_or(Value::Null);
    map_usages(&serde_json::json!({
        "usage": usage,
        "limits": entry.get("limits").cloned().unwrap_or(Value::Null),
    }))
}

#[derive(Clone, Debug)]
struct Detail {
    limit: f64,
    used: f64,
    remaining: f64,
    resets_at: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct Usage {
    weekly: Option<Detail>,
    five_hour: Option<Detail>,
}

fn map_usages(value: &Value) -> Option<Usage> {
    let root = value.as_object()?;
    let weekly = map_detail(
        root.get("usage")
            .filter(|value| value.is_object())
            .or(Some(value)),
    );
    let five_hour = root
        .get("limits")
        .and_then(Value::as_array)
        .and_then(|limits| {
            limits.iter().find_map(|entry| {
                let window = obj_get(entry, "window")?;
                let duration = number(obj_get(window, "duration"))?;
                let unit =
                    string(obj_get(window, "timeUnit").or_else(|| obj_get(window, "time_unit")));
                if (duration - 300.0).abs() > f64::EPSILON
                    || unit
                        .as_deref()
                        .map(|v| !matches!(v, "TIME_UNIT_MINUTE" | "minute" | "MINUTE"))
                        .unwrap_or(false)
                {
                    return None;
                }
                map_detail(obj_get(entry, "detail").or(Some(entry)))
            })
        });
    (weekly.is_some() || five_hour.is_some()).then_some(Usage { weekly, five_hour })
}

fn map_detail(value: Option<&Value>) -> Option<Detail> {
    let value = value?;
    let limit = number(obj_get(value, "limit"));
    let used = number(obj_get(value, "used"));
    let remaining = number(obj_get(value, "remaining"));
    if limit.is_none() && used.is_none() && remaining.is_none() {
        return None;
    }
    let limit = limit.unwrap_or_else(|| used.unwrap_or(0.0) + remaining.unwrap_or(0.0));
    let used = used.unwrap_or_else(|| {
        if limit > 0.0 {
            (limit - remaining.unwrap_or(0.0)).max(0.0)
        } else {
            0.0
        }
    });
    let remaining = remaining.unwrap_or_else(|| {
        if limit > 0.0 {
            (limit - used).max(0.0)
        } else {
            0.0
        }
    });
    let resets_at = obj_get_any(value, &["resetTime", "reset_time", "resets_at"])
        .and_then(|value| parse_date(Some(value)).map(super::common::unix_seconds_to_iso));
    Some(Detail {
        limit,
        used,
        remaining,
        resets_at,
    })
}

fn map_windows(data: &Usage) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    if let Some(detail) = &data.weekly {
        windows.push(window("weekly", "Weekly", detail));
    }
    if let Some(detail) = &data.five_hour {
        windows.push(window("five_hour", "5 Hours", detail));
    }
    windows
}

fn window(id: &str, title: &str, detail: &Detail) -> QuotaWindow {
    let denom = if detail.limit > 0.0 {
        detail.limit
    } else {
        detail.used + detail.remaining
    };
    QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent: if denom > 0.0 {
            clamp_percent(detail.used / denom * 100.0)
        } else if detail.remaining > 0.0 {
            0.0
        } else {
            100.0
        },
        resets_at: detail.resets_at.clone(),
        duration_seconds: None,
        remaining_value: Some(detail.remaining.max(0.0)),
        limit_value: (denom > 0.0).then_some(denom),
        value_unit: Some("count"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: std::path::PathBuf::from("/tmp/quota-kimi-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: Some(std::path::PathBuf::from(
                "/tmp/quota-kimi-missing-config/providers.json",
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

    /// Kimi is reached with a key or with the token its own CLI writes. Without either, the
    /// stored kimi.com session is the last thing left to try.
    #[test]
    fn the_browser_session_is_discovered_only_without_a_key_or_cli_credential() {
        let mut context = isolated_context();
        assert!(discover(&context).is_empty());
        context.browser_sessions.insert(
            ProviderId::Kimi,
            vec!["kimi-auth=eyJhbGciOiJIUzI1NiJ9.e30.ok".to_owned()],
        );
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(
            sessions[0].credential_source,
            crate::providers::BROWSER_SESSION_SOURCE
        );
    }

    #[test]
    fn accepts_fresh_cli_credential_and_rejects_stale_or_missing_expiry() {
        let fresh = parse_cli_credentials(
            &serde_json::json!({
                "access_token": "cli-token",
                "refresh_token": "refresh",
                "expires_at": 1_786_406_400_i64
            }),
            "fixture",
            1_786_320_000,
        )
        .unwrap();
        assert_eq!(fresh.access_token, "cli-token");
        assert!(
            parse_cli_credentials(
                &serde_json::json!({
                    "access_token": "cli-token",
                    "expires_at": 1_786_320_030_i64
                }),
                "fixture",
                1_786_320_000,
            )
            .is_none()
        );
        assert!(
            parse_cli_credentials(
                &serde_json::json!({
                    "access_token": "cli-token"
                }),
                "fixture",
                1_786_320_000,
            )
            .is_none()
        );
        // Kimi Code stamps this in milliseconds. Read as seconds it was fifty thousand years
        // out, so a token that had run out an hour ago read as live.
        assert!(
            parse_cli_credentials(
                &serde_json::json!({
                    "access_token": "cli-token",
                    "expires_at": 1_786_316_400_000_i64
                }),
                "fixture",
                1_786_320_000,
            )
            .is_none()
        );
        assert_eq!(
            parse_cli_credentials(
                &serde_json::json!({
                    "access_token": "cli-token",
                    "expires_at": 1_786_323_600_000_i64
                }),
                "fixture",
                1_786_320_000,
            )
            .map(|credentials| credentials.access_token),
            Some("cli-token".to_owned())
        );
    }

    /// The Kimi Code token names no account of its own, so its fingerprint is scoped to the
    /// source rather than to an owner — and what is stored is a digest, never the credential.
    #[test]
    fn the_cli_credential_fingerprint_is_source_scoped_and_irreversible() {
        let (fingerprint, scope) = account_identity("kimi", "cli_credential", None);
        assert_eq!(scope, "source");
        assert_eq!(fingerprint.len(), 64);
        assert!(
            fingerprint
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        );
        // And a name an owner does take part in is a different name, so the source-scoped one
        // is not standing in for an account it never read.
        assert_ne!(
            fingerprint,
            account_identity("kimi", "cli_credential", Some("owner")).0
        );
    }

    /// The stored session is the last rung, and only the last rung.
    ///
    /// It answers when this Mac's own credential said "sign in again"; it never answers first,
    /// it is not reached at all when nothing was stored, and a cancelled refresh reads neither.
    #[test]
    fn the_stored_session_is_reached_only_after_the_grant_says_sign_in_again() {
        let mut context = isolated_context();
        let official = ProviderSession {
            provider: ProviderId::Kimi,
            credential_source: "providers.json".to_owned(),
            cookie_header: None,
        };
        // Nothing on disk and nothing stored: the credential path's verdict is the answer,
        // named by its last rung — the Kimi Code token, not the key that was never set.
        assert_eq!(
            collect(&official, &context)
                .expect_err("no credential")
                .source_id,
            CLI_SOURCE
        );
        // With a session stored, that same verdict hands off to it, and the rung that answers
        // names itself. The header is one this rung rejects without a request.
        context
            .browser_sessions
            .insert(ProviderId::Kimi, vec!["sessionKey=sk-ant-ok".to_owned()]);
        assert_eq!(
            collect(&official, &context)
                .expect_err("stored session")
                .source_id,
            WEB_SOURCE
        );
        // A cancelled refresh reads neither rung.
        let cancelled = CollectionContext {
            cancel: Some(std::sync::Arc::new(std::sync::atomic::AtomicBool::new(
                true,
            ))),
            ..context.clone()
        };
        let error = collect(&official, &cancelled).expect_err("cancelled");
        assert_eq!(error.category, ErrorCategory::Unavailable);
        assert_eq!(error.source_id, SOURCE);
    }

    #[test]
    fn the_catalog_names_the_kimi_session_cookie() {
        let spec = ProviderId::Kimi
            .metadata()
            .browser_session
            .expect("kimi browser session");
        assert_eq!(spec.cookie_names, &["kimi-auth"]);
        assert_eq!(
            kimi_auth_token("kimi-auth=eyJhbGciOiJIUzI1NiJ9.e30.ok").as_deref(),
            Some("eyJhbGciOiJIUzI1NiJ9.e30.ok")
        );
        assert!(kimi_auth_token("kimi-auth=").is_none());
        assert!(kimi_auth_token("sessionKey=sk-ant-ok").is_none());
    }

    /// One request, one canned answer, and the request head handed back for inspection.
    /// One response, over the shared stub.
    fn serve(status: u16, body: &str) -> (String, std::thread::JoinHandle<String>) {
        let (address, handle) =
            crate::providers::common::serve_responses(vec![(status, body.as_bytes().to_vec())]);
        (
            address,
            std::thread::spawn(move || handle.join().expect("server").remove(0)),
        )
    }

    const CODING_USAGES: &str = r#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"25","remaining":"75"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","used":"10","remaining":"40"}}]}]}"#;

    /// The cookie is kept only once kimi.com has answered with the coding allowance this app
    /// would read; an answer that carries no coding scope is nothing to store.
    #[test]
    fn validate_keeps_only_a_session_with_a_coding_allowance() {
        let (address, server) = serve(200, CODING_USAGES);
        let validated = validate_at(
            "kimi-auth=eyJhbGciOiJIUzI1NiJ9.e30.ok",
            &isolated_context(),
            &format!("http://{address}/usages"),
        )
        .expect("validated");
        assert_eq!(validated.account_label.as_deref(), Some("Kimi"));
        // A bearer that names no one keeps the source-wide fingerprint, which says exactly
        // that.
        assert_eq!(
            validated.account_fingerprint,
            account_identity("kimi", "browser_session", None).0
        );
        let head = server.join().expect("server");
        assert!(head.contains("authorization: bearer eyjhbgcioijiuzi1nij9.e30.ok"));
        assert!(head.contains("cookie: kimi-auth=eyjhbgcioijiuzi1nij9.e30.ok"));
        assert!(head.contains("feature_coding"));

        let (address, server) = serve(200, r#"{"usages":[{"scope":"FEATURE_CHAT"}]}"#);
        let error = validate_at(
            "kimi-auth=eyJhbGciOiJIUzI1NiJ9.e30.ok",
            &isolated_context(),
            &format!("http://{address}/usages"),
        )
        .expect_err("no coding scope");
        assert_eq!(error.category, ErrorCategory::Error);
        assert_eq!(error.source_id, WEB_SOURCE);
        server.join().expect("server");

        // Two signed-in accounts are two accounts. The billing RPC names nobody, so the bearer
        // is what tells them apart; without it every cookie on a Mac hashed to one fingerprint
        // and the second account overwrote the first.
        let owned = |subject: &str, encoded: &str| {
            let (address, server) = serve(200, CODING_USAGES);
            let validated = validate_at(
                &format!("kimi-auth=header.{encoded}.signature"),
                &isolated_context(),
                &format!("http://{address}/usages"),
            )
            .expect("validated");
            server.join().expect("server");
            assert_eq!(
                validated.account_fingerprint,
                account_identity("kimi", "browser_session", Some(subject)).0
            );
            validated.account_fingerprint
        };
        assert_ne!(
            owned("user-1", "eyJzdWIiOiJ1c2VyLTEifQ"),
            owned("user-2", "eyJzdWIiOiJ1c2VyLTIifQ")
        );
    }

    /// A header with no `kimi-auth` is refused before a request is made.
    #[test]
    fn validate_rejects_a_header_that_names_no_session() {
        let error = validate_at(
            "sessionKey=sk-ant-ok",
            &isolated_context(),
            "http://127.0.0.1:1",
        )
        .expect_err("no kimi-auth");
        assert_eq!(error.category, ErrorCategory::Error);
        assert_eq!(error.source_id, WEB_SOURCE);
    }

    #[test]
    fn maps_web_coding_usages() {
        let (address, server) = serve(200, CODING_USAGES);
        let snapshot = collect_web_at(
            "kimi-auth=eyJhbGciOiJIUzI1NiJ9.e30.ok",
            &isolated_context(),
            &format!("http://{address}/usages"),
        )
        .expect("snapshot");
        assert_eq!(
            snapshot
                .windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["weekly", "five_hour"]
        );
        server.join().expect("server");
    }

    #[test]
    fn maps_weekly_and_five_hour_windows() {
        let data = map_usages(&serde_json::json!({
            "usage": {"limit": "100", "used": "25", "remaining": "75"},
            "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": "50", "used": "10", "remaining": "40"}}]
        })).unwrap();
        let windows = map_windows(&data);
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["weekly", "five_hour"]
        );
        assert_eq!(windows[1].value_unit, Some("count"));
    }

    #[test]
    fn derives_missing_values_and_rejects_non_five_hour_limits() {
        let data = map_usages(&serde_json::json!({
            "usage": {"used": "25", "remaining": "75"},
            "limits": [
                {"window": {"duration": 60, "timeUnit": "minute"}, "detail": {"limit": 10, "used": 1}},
                {"window": {"duration": 300, "timeUnit": "minute"}, "detail": {"remaining": 40}}
            ]
        })).unwrap();
        let windows = map_windows(&data);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].limit_value, Some(100.0));
        assert_eq!(windows[1].limit_value, Some(40.0));
        assert_eq!(windows[1].used_percent, 0.0);
    }
}
