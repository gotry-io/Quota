use crate::catalog::ProviderId;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

use super::common::{
    CliTool, CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, ValidatedBrowserSession,
    account_identity, clamp_percent, collect_official_or_browser, decode_jwt_payload,
    discover_official_or_browser, mask_email, number, obj_get, obj_get_any, parse_date,
    read_bounded_file, slug, string,
};

pub mod refresh;
mod web;

pub const SOURCE_API: &str = "chatgpt_usage_api";
pub const WEB_SOURCE: &str = web::SOURCE;

/// How close to its own expiry an access token has to be before this build asks Codex to
/// renew it. The same minute Claude Code and Grok get, and well inside the five minutes the
/// Codex CLI itself treats as expired, so every renewal this build asks for is one the CLI
/// agrees is due.
const AUTH_REFRESH_SKEW: i64 = 60;
pub const SOURCE_PAT: &str = "codex_pat_usage_api";
pub const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const WHOAMI_URL: &str = "https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami";

#[derive(Clone, Debug)]
pub(super) struct Credentials {
    access_token: String,
    id_token: Option<String>,
    account_id: Option<String>,
    /// When the access token says it stops being accepted, from its own payload. Codex signs
    /// these; nothing here verifies that signature, because the only claim read is a
    /// timestamp and a forged one would buy a spawn rather than a reading.
    expires_at: Option<i64>,
    /// When Codex last rewrote this file, as it stamps it. Not a freshness rule — the CLI
    /// ignores it entirely — but it is the one field that moves when a renewal lands even if
    /// the new token's payload cannot be read.
    last_refresh: Option<i64>,
}

impl Credentials {
    /// The bearer a ChatGPT web session hands out, as the WHAM rung's credential.
    ///
    /// It carries no expiry and no refresh stamp: those describe `auth.json`, which this token
    /// never came from and which no renewal will rewrite on its behalf.
    pub(super) fn from_web_session(access_token: &str, account_id: Option<String>) -> Self {
        Self {
            access_token: access_token.to_owned(),
            id_token: None,
            account_id,
            expires_at: None,
            last_refresh: None,
        }
    }
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

/// This device's Codex sign-in, and a stored ChatGPT browser session only when there is none.
pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    discover_official_or_browser(
        ProviderId::Codex,
        load_auth(context).map(|auth| ProviderSession {
            provider: ProviderId::Codex,
            credential_source: auth.source,
        }),
        context,
    )
}

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    web::validate_browser_session(cookie_header, context)
}

/// Personal access token, then OAuth, then the stored browser session.
pub fn collect(
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_official_or_browser(
        session,
        context,
        ProviderId::Codex,
        SOURCE_API,
        || collect_local(context),
        || web::collect(context),
    )
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
    // Codex owns token renewal. The refresh worker already gave it its one chance to renew an
    // expired grant ([`refresh`]); one still out of time here is a sign-in only the reader can
    // restore, and saying so beats spending a token the endpoint has already stopped taking.
    // A token whose own expiry could not be read is not that, and is still tried.
    if credentials
        .expires_at
        .is_some_and(|expires_at| expires_at <= context.observed_unix() + AUTH_REFRESH_SKEW)
    {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE_API));
    }
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
    let last_refresh =
        obj_get_any(value, &["last_refresh", "lastRefresh"]).and_then(|v| parse_date(Some(v)));
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
    let expires_at = decode_jwt_payload(&access_token)
        .as_ref()
        .and_then(|payload| obj_get(payload, "exp"))
        .and_then(|value| parse_date(Some(value)));
    Some(Credentials {
        access_token,
        id_token,
        account_id,
        expires_at,
        last_refresh,
    })
}

/// Whether this device's Codex sign-in is the thing standing between the refresh and a
/// reading.
///
/// The access token's own `exp` decides it. An unreadable one counts as expiring: a token this
/// build cannot date is one it cannot spend with any confidence, and the CLI is the thing that
/// can tell. `last_refresh` deliberately does not: measured against codex-cli 0.149.0, the CLI
/// renews only when that `exp` is within five minutes, and a file thirty days stale with a
/// live token is left exactly as it was — so asking on its age would spawn for nothing.
///
/// A personal access token is not this: nothing renews one, and an `auth.json` holding only
/// that has no OAuth grant to speak of.
fn sign_in_expiring(context: &CollectionContext) -> bool {
    load_auth(context)
        .and_then(|auth| auth.oauth)
        .is_some_and(|credentials| {
            credentials
                .expires_at
                .is_none_or(|expires_at| expires_at <= context.observed_unix() + AUTH_REFRESH_SKEW)
        })
}

/// Whether `auth.json` now holds a token this refresh can use.
///
/// Deliberately not `!sign_in_expiring`: an `auth.json` the CLI removed or emptied of its
/// tokens is neither, and that third answer is a Codex that signed itself out rather than one
/// that could not renew.
fn sign_in_usable(context: &CollectionContext) -> bool {
    load_auth(context)
        .and_then(|auth| auth.oauth)
        .is_some_and(|credentials| {
            credentials
                .expires_at
                .is_some_and(|expires_at| expires_at > context.observed_unix() + AUTH_REFRESH_SKEW)
        })
}

/// When Codex last rewrote `auth.json`, as it stamps it there.
fn last_refresh(context: &CollectionContext) -> Option<i64> {
    load_auth(context)
        .and_then(|auth| auth.oauth)
        .and_then(|credentials| credentials.last_refresh)
}

/// Whether Codex has rewritten `auth.json` since it carried `stamped`.
///
/// The second half of the renewal verdict, for the token whose own expiry cannot be read: the
/// stamp moving is the CLI saying it wrote this file, and that is the whole claim.
fn rewritten_since(context: &CollectionContext, stamped: Option<i64>) -> bool {
    match (last_refresh(context), stamped) {
        (Some(written), Some(before)) => written > before,
        (Some(_), None) => true,
        (None, _) => false,
    }
}

fn collect_pat(token: &str, context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    collect_pat_at(token, context, WHOAMI_URL, USAGE_URL)
}

fn collect_pat_at(
    token: &str,
    context: &CollectionContext,
    whoami_url: &str,
    usage_url: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    let client = HttpClient::new()?;
    let bearer = format!("Bearer {token}");
    let user_agent = pat_user_agent(context);
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
        ("originator", "codex_cli_rs"),
    ];
    let (_, whoami) = client.get_json(whoami_url, &headers, SOURCE_PAT)?;
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
    let (_, value) = client.get_json(usage_url, &usage_headers, SOURCE_PAT)?;
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

/// Codex only honors personal access tokens from requests that identify as its CLI, so the
/// request presents the CLI's own user agent — carrying the version of the Codex install that
/// is actually on this device when one could be read, and no version at all when it could not.
fn pat_user_agent(context: &CollectionContext) -> String {
    build_pat_user_agent(context.cli_version(CliTool::Codex), os_version().as_deref())
}

fn build_pat_user_agent(cli_version: Option<&str>, os_version: Option<&str>) -> String {
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
    let system = match os_version {
        Some(version) => format!("{platform} {version}"),
        None => platform.to_owned(),
    };
    match cli_version {
        Some(version) => format!("codex_cli_rs/{version} ({system}; {arch})"),
        None => format!("codex_cli_rs ({system}; {arch})"),
    }
}

/// The macOS product version, read from the kernel rather than by starting `sw_vers`: a
/// scheduled refresh starts no process it did not have to.
#[cfg(target_os = "macos")]
fn os_version() -> Option<String> {
    let mut buffer = [0_u8; 32];
    let mut length = buffer.len();
    let result = unsafe {
        libc::sysctlbyname(
            c"kern.osproductversion".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 {
        return None;
    }
    let end = length.min(buffer.len());
    let value = std::str::from_utf8(&buffer[..end])
        .ok()?
        .trim_end_matches('\0');
    // A user agent carries the version and nothing else; anything unexpected is dropped.
    (!value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || byte == b'.'))
    .then(|| value.to_owned())
}

#[cfg(not(target_os = "macos"))]
fn os_version() -> Option<String> {
    None
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

    /// The endpoint only honors a personal access token from the Codex CLI, so the request
    /// says it is the Codex CLI — and, when this device could read one, which one.
    #[test]
    fn the_personal_access_token_request_names_the_installed_codex() {
        use std::io::{Read as _, Write as _};
        use std::net::TcpListener;

        for (installed, expected) in [
            (Some("0.42.1"), "user-agent: codex_cli_rs/0.42.1 ("),
            (None, "user-agent: codex_cli_rs ("),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
            let address = listener.local_addr().expect("address");
            let server = std::thread::spawn(move || {
                let mut heads = Vec::new();
                for body in [
                    r#"{"chatgpt_account_id":"acct-owner","email":"ada@example.com"}"#,
                    r#"{"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}}}"#,
                ] {
                    let Ok((mut stream, _)) = listener.accept() else {
                        break;
                    };
                    let mut request = [0_u8; 2048];
                    let read = stream.read(&mut request).unwrap_or(0);
                    heads.push(String::from_utf8_lossy(&request[..read]).to_lowercase());
                    let _ = write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                }
                heads
            });
            let mut context = isolated_context();
            if let Some(version) = installed {
                context
                    .cli_versions
                    .insert(CliTool::Codex, version.to_owned());
            }
            let snapshot = collect_pat_at(
                "pat-token",
                &context,
                &format!("http://{address}/whoami"),
                &format!("http://{address}/usage"),
            )
            .expect("snapshot");
            assert_eq!(snapshot.windows.len(), 1);
            let heads = server.join().expect("server");
            for head in &heads {
                assert!(head.contains(expected), "{head}");
                assert!(head.contains("originator: codex_cli_rs"));
            }
            // The account id whoami named travels as a header, never as reported identity.
            assert!(heads[1].contains("chatgpt-account-id: acct-owner"));
        }
    }

    /// The user agent states the platform whether or not a version could be read, and never
    /// invents a version field.
    #[test]
    fn the_user_agent_states_a_version_only_when_one_was_read() {
        let known = build_pat_user_agent(Some("0.42.1"), Some("15.6"));
        assert!(known.starts_with("codex_cli_rs/0.42.1 ("), "{known}");
        assert!(known.contains(" 15.6; "), "{known}");
        assert!(known.ends_with(')'), "{known}");
        let unknown = build_pat_user_agent(None, Some("15.6"));
        assert!(unknown.starts_with("codex_cli_rs ("), "{unknown}");
        assert!(!unknown.contains('/'), "{unknown}");
        // Without an OS version the platform stands alone rather than trailing a blank.
        let bare = build_pat_user_agent(None, None);
        assert!(!bare.contains("  ") && !bare.contains(" ;"), "{bare}");
        assert!(build_pat_user_agent(Some("1.0.0"), None).starts_with("codex_cli_rs/1.0.0 ("));
        // The kernel answers on macOS and is not consulted anywhere else.
        assert_eq!(os_version().is_some(), cfg!(target_os = "macos"));
    }

    /// Codex owns this grant, so a Mac without one has nothing for this collector to try.
    /// There is no second rung to fall to.
    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-codex-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: None,
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
        }
    }

    /// Without a Codex grant and without a stored cookie there is nothing to try; a stored
    /// cookie alone is the last rung, and it is discovered as one.
    #[test]
    fn the_browser_session_is_discovered_only_without_a_local_grant() {
        let mut context = isolated_context();
        assert!(discover(&context).is_empty());
        context.browser_sessions.insert(
            ProviderId::Codex,
            "__Secure-next-auth.session-token=abc".to_owned(),
        );
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(
            sessions[0].credential_source,
            super::super::BROWSER_SESSION_SOURCE
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
            provider: ProviderId::Codex,
            credential_source: "auth.json".to_owned(),
        };
        // Nothing on disk and nothing stored: the credential path's verdict is the answer.
        assert_eq!(
            collect(&official, &context)
                .expect_err("no credential")
                .source_id,
            SOURCE_API
        );
        // With a session stored, that same verdict hands off to it, and the rung that answers
        // names itself. The header is one this rung rejects without a request.
        context
            .browser_sessions
            .insert(ProviderId::Codex, "_account=acct".to_owned());
        assert_eq!(
            collect(&official, &context)
                .expect_err("stored session")
                .source_id,
            web::SOURCE
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
        assert_eq!(error.source_id, SOURCE_API);
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
            expires_at: None,
            last_refresh: None,
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
