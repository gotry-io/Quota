use crate::catalog::ProviderId;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, KeychainSecret, LOCAL_FILE_LIMIT, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, ValidatedBrowserSession,
    account_identity, clamp_percent, collect_official_or_browser, discover_official_or_browser,
    mask_email, number, obj_get, obj_get_any, parse_date, read_bounded_file, run_bounded_command,
    slug, string,
};

mod web;

pub const SOURCE: &str = "anthropic_oauth_usage_api";
pub const WEB_SOURCE: &str = web::WEB_SOURCE;
pub const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const PROFILE_URL: &str = "https://api.anthropic.com/api/oauth/profile";
pub const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const AUTH_REFRESH_SKEW: i64 = 60;

#[derive(Clone, Debug)]
struct Credentials {
    access_token: String,
    expires_at: Option<i64>,
    scopes: Vec<String>,
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    discover_official_or_browser(
        ProviderId::Claude,
        load_credentials(context).map(|credentials| ProviderSession {
            provider: ProviderId::Claude,
            credential_source: credentials.source,
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

pub fn collect(
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_official_or_browser(
        session,
        context,
        ProviderId::Claude,
        SOURCE,
        || collect_official(context),
        || web::collect(context),
    )
}

fn collect_official(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let lookup = look_up_credentials(context);
    let Some(credentials) = lookup.credentials else {
        // A withheld secret is not an expired sign-in, and reporting it as one sends the
        // reader to sign in again for as long as the access decision stands.
        return Err(ProviderError::new(
            if lookup.keychain_refused {
                ErrorCategory::AccessDenied
            } else {
                ErrorCategory::AuthRequired
            },
            SOURCE,
        ));
    };
    // Claude Code owns token renewal, and this build no longer drives its CLI to trigger
    // one. A grant that is out of time is therefore a sign-in only Claude Code can renew,
    // and saying so is what sends the reader somewhere that can actually fix it.
    if is_expiring(&credentials, context.observed_unix()) {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    collect_with_credentials(&credentials, context)
}

/// This device's Claude sign-in, and whether the Keychain refused to hand one over.
struct CredentialLookup {
    credentials: Option<Credentials>,
    keychain_refused: bool,
}

fn look_up_credentials(context: &CollectionContext) -> CredentialLookup {
    let root = context
        .env("CLAUDE_CONFIG_DIR")
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".claude"));
    let file_credentials = read_credentials_file(&root.join(".credentials.json"));
    let keychain = (cfg!(target_os = "macos") && context.allows_host_keychain())
        .then(|| context.keychain_secret(|| read_keychain(context)));
    let keychain_refused = matches!(keychain, Some(KeychainSecret::Refused));
    let keychain_credentials = match keychain {
        Some(KeychainSecret::Found(secret)) => serde_json::from_slice::<Value>(secret)
            .ok()
            .and_then(|value| {
                parse_credentials(&value, &format!("macOS Keychain: {KEYCHAIN_SERVICE}"))
            }),
        Some(KeychainSecret::Absent | KeychainSecret::Refused) | None => None,
    };
    // Claude renews the Keychain entry in place, so that is the live grant and the file is
    // what an older version left behind.  Reading the file first let one that had been
    // revoked but not yet expired mask the renewed grant for as long as its clock ran.
    CredentialLookup {
        credentials: preferred_credentials(
            keychain_credentials,
            file_credentials,
            context.observed_unix(),
        ),
        keychain_refused,
    }
}

/// The Keychain grant wins unless it is the only expiring one of the two.
fn preferred_credentials(
    keychain: Option<Credentials>,
    file: Option<Credentials>,
    now: i64,
) -> Option<Credentials> {
    match (keychain, file) {
        (Some(keychain), Some(file)) => {
            Some(if !is_expiring(&keychain, now) || is_expiring(&file, now) {
                keychain
            } else {
                file
            })
        }
        (Some(keychain), None) => Some(keychain),
        (None, file) => file,
    }
}

fn load_credentials(context: &CollectionContext) -> Option<Credentials> {
    look_up_credentials(context).credentials
}

fn read_credentials_file(path: &Path) -> Option<Credentials> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let value: Value = serde_json::from_slice(&read_bounded_file(path, LOCAL_FILE_LIMIT)?).ok()?;
    parse_credentials(&value, &path.to_string_lossy())
}

/// The Claude Code credential entry, or why it did not produce one.
///
/// The collection context memoizes this, so one refresh reads the Keychain once however
/// many collectors ask.  `/usr/bin/security` is the only process a scheduled refresh
/// still starts.
fn read_keychain(context: &CollectionContext) -> KeychainSecret {
    let mut command = Command::new("/usr/bin/security");
    command.args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]);
    let Some(secret) = run_bounded_command(
        command,
        Duration::from_secs(10),
        context.cancel.as_ref(),
        1_048_576,
    ) else {
        // A refresh that was cancelled proves nothing about access, and the probe below shares
        // its cancellation, so ask first rather than read a stopped command as a refusal.
        let cancelled = context
            .cancel
            .as_ref()
            .is_some_and(|cancel| cancel.load(std::sync::atomic::Ordering::Acquire));
        return if !cancelled && keychain_entry_exists(context) {
            KeychainSecret::Refused
        } else {
            KeychainSecret::Absent
        };
    };
    KeychainSecret::Found(secret)
}

/// Asks only whether the entry is there.  Answering that needs no access to the secret it
/// holds, which is what separates an account that was never signed in from one this device
/// is not allowed to read.  Only [`read_keychain`] calls it, and only when the read it
/// memoizes already failed.
fn keychain_entry_exists(context: &CollectionContext) -> bool {
    let mut command = Command::new("/usr/bin/security");
    command.args(["find-generic-password", "-s", KEYCHAIN_SERVICE]);
    run_bounded_command(
        command,
        Duration::from_secs(10),
        context.cancel.as_ref(),
        1_048_576,
    )
    .is_some()
}

fn parse_credentials(value: &Value, source: &str) -> Option<Credentials> {
    if value.get("claudeAiOauth").is_none() && value.get("mcpOAuth").is_some() {
        return None;
    }
    let oauth = value.get("claudeAiOauth")?.as_object()?;
    let access_token = obj_get_any(
        &Value::Object(oauth.clone()),
        &["accessToken", "access_token"],
    )
    .and_then(|v| string(Some(v)))?;
    let expires_at = obj_get_any(&Value::Object(oauth.clone()), &["expiresAt", "expires_at"])
        .and_then(|v| parse_date(Some(v)));
    let scopes = oauth
        .get("scopes")
        .and_then(Value::as_array)
        .map(|values| values.iter().filter_map(|v| string(Some(v))).collect())
        .unwrap_or_default();
    Some(Credentials {
        access_token,
        expires_at,
        scopes,
        subscription_type: obj_get_any(
            &Value::Object(oauth.clone()),
            &["subscriptionType", "subscription_type"],
        )
        .and_then(|v| string(Some(v))),
        rate_limit_tier: obj_get_any(
            &Value::Object(oauth.clone()),
            &["rateLimitTier", "rate_limit_tier"],
        )
        .and_then(|v| string(Some(v))),
        source: source.to_owned(),
    })
}

fn is_expiring(credentials: &Credentials, now: i64) -> bool {
    credentials
        .expires_at
        .map(|expiry| expiry <= now + AUTH_REFRESH_SKEW)
        .unwrap_or(false)
}

/// One of Claude's fixed usage windows, named once so the OAuth body's key, the
/// window id this build reports, and its title cannot drift apart.
struct ClaudeWindow {
    /// Key in the OAuth usage body.
    field: &'static str,
    id: &'static str,
    title: &'static str,
    duration_seconds: u64,
    /// Weekly-group limits meter one seven-day cycle and therefore share its reset.
    /// Claude's other seven-day-long limits, such as Routines, are not in that group.
    weekly_group: bool,
}

const CLAUDE_WINDOWS: &[ClaudeWindow] = &[
    ClaudeWindow {
        field: "five_hour",
        id: "five_hour",
        title: "5 hour",
        duration_seconds: 18_000,
        weekly_group: false,
    },
    ClaudeWindow {
        field: "seven_day",
        id: "seven_day",
        title: "Weekly",
        duration_seconds: 604_800,
        weekly_group: true,
    },
    ClaudeWindow {
        field: "seven_day_sonnet",
        id: "seven_day_sonnet",
        title: "Sonnet weekly",
        duration_seconds: 604_800,
        weekly_group: true,
    },
    ClaudeWindow {
        field: "seven_day_opus",
        id: "seven_day_opus",
        title: "Opus weekly",
        duration_seconds: 604_800,
        weekly_group: true,
    },
    ClaudeWindow {
        field: "seven_day_oauth_apps",
        id: "seven_day_oauth_apps",
        title: "OAuth apps weekly",
        duration_seconds: 604_800,
        weekly_group: true,
    },
];

const WEEK_SECONDS: u64 = 604_800;
const SCOPED_WEEKLY_PREFIX: &str = "claude-weekly-scoped-";

/// The weekly window a model-scoped row belongs to, whether it comes from the
/// OAuth `limits[]` array or the panel's `Current week (<Model>)` heading.
fn scoped_weekly_window(name: &str) -> (String, String) {
    (
        format!("{SCOPED_WEEKLY_PREFIX}{}", slug(name, '-')),
        format!("{name} only"),
    )
}

/// Every weekly limit meters the same seven-day cycle, so a weekly window that reports no
/// reset of its own resets with `seven_day`.
///
/// `group` lists the windows that belong to that cycle, recorded by the code that built
/// each one. Membership is a Claude limit group, not a duration: Routines also spans seven
/// days and does not share the weekly reset, so it is never added.
fn inherit_weekly_reset(windows: &mut [QuotaWindow], group: &[String]) {
    let Some(weekly) = windows
        .iter()
        .find(|window| window.id == "seven_day")
        .and_then(|window| window.resets_at.clone())
    else {
        return;
    };
    for window in windows
        .iter_mut()
        .filter(|window| window.resets_at.is_none() && group.contains(&window.id))
    {
        window.resets_at = Some(weekly.clone());
    }
}

fn collect_with_credentials(
    credentials: &Credentials,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if !credentials
        .scopes
        .iter()
        .any(|scope| scope == "user:profile")
    {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    let client = HttpClient::new()?;
    let bearer = format!("Bearer {}", credentials.access_token);
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("anthropic-beta", "oauth-2025-04-20"),
        ("User-Agent", "claude-code/2.1.0"),
    ];
    let usage = match client.get_json(USAGE_URL, &headers, SOURCE) {
        Ok((_, value)) => value,
        Err(error) => return Err(error),
    };
    let windows = map_usage(&usage);
    // An account that answers for a window this build knows, even to say it has none, has
    // nothing to report and is read successfully.  A response that answers for none of them
    // is one this build cannot read, and only that is a collection failure.  Reporting both
    // as a failure told a reader whose account simply had no windows that their source was
    // broken, and left them a retry that could never succeed.
    if windows.is_empty() && !answers_for_a_known_window(&usage) {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let (email, organization_id) = {
        let profile_headers = [
            ("Authorization", bearer.as_str()),
            ("Accept", "application/json"),
        ];
        match client.get_json(PROFILE_URL, &profile_headers, SOURCE) {
            Ok((_, value)) => map_profile(&value),
            Err(_) => (None, None),
        }
    };
    let plan = credentials
        .subscription_type
        .clone()
        .or_else(|| credentials.rate_limit_tier.clone());
    let (fingerprint, scope) =
        account_identity("claude", "organization_id", organization_id.as_deref());
    Ok(QuotaSnapshot {
        provider: ProviderId::Claude,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: mask_email(email.as_deref()),
            plan,
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

/// Whether the response named a window this build knows and answered `null` for it, which is
/// an account stating it has no such window rather than a shape this build failed to read.
fn answers_for_a_known_window(value: &Value) -> bool {
    CLAUDE_WINDOWS
        .iter()
        .any(|entry| matches!(obj_get(value, entry.field), Some(Value::Null)))
}

pub(super) fn map_usage(value: &Value) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    let mut weekly_group: Vec<String> = Vec::new();
    for entry in CLAUDE_WINDOWS {
        if let Some(window) = usage_window(
            obj_get(value, entry.field),
            entry.id,
            entry.title,
            entry.duration_seconds,
        ) {
            if entry.weekly_group {
                weekly_group.push(window.id.clone());
            }
            windows.push(window);
        }
    }
    // `limits[]` reports only `weekly_scoped` entries of the `weekly` group, filtered below.
    if let Some(limits) = obj_get(value, "limits").and_then(Value::as_array) {
        let mut seen = std::collections::HashSet::new();
        for entry in limits {
            if string(obj_get(entry, "kind")).as_deref() != Some("weekly_scoped")
                || string(obj_get(entry, "group")).as_deref() != Some("weekly")
            {
                continue;
            }
            let Some(percent) = number(obj_get(entry, "percent")) else {
                continue;
            };
            let model = obj_get(entry, "scope").and_then(|v| obj_get(v, "model"));
            let Some(model_name) = obj_get_any(
                model.unwrap_or(&Value::Null),
                &["display_name", "displayName"],
            )
            .and_then(|v| string(Some(v))) else {
                continue;
            };
            let model_id =
                obj_get(model.unwrap_or(&Value::Null), "id").and_then(|v| string(Some(v)));
            if is_all_models(model_id.as_deref(), &model_name) {
                continue;
            }
            let identity = model_id.as_deref().unwrap_or(&model_name);
            let (id, _) = scoped_weekly_window(identity);
            if !seen.insert(id.clone()) {
                continue;
            }
            weekly_group.push(id.clone());
            windows.push(QuotaWindow {
                id,
                title: format!("{model_name} only"),
                used_percent: clamp_percent(percent),
                resets_at: obj_get_any(entry, &["resets_at", "resetsAt"])
                    .and_then(|v| parse_date(Some(v)))
                    .map(super::common::unix_seconds_to_iso),
                duration_seconds: Some(WEEK_SECONDS),
                remaining_value: None,
                limit_value: None,
                value_unit: None,
            });
        }
    }
    let routines = [
        "seven_day_routines",
        "seven_day_claude_routines",
        "claude_routines",
        "routines",
        "routine",
        "seven_day_cowork",
        "cowork",
    ]
    .iter()
    .find_map(|key| obj_get(value, key));
    if let Some(window) = usage_window(routines, "claude-routines", "Daily Routines", WEEK_SECONDS)
    {
        windows.push(window);
    }
    let extra = obj_get(value, "extra_usage").or_else(|| obj_get(value, "extraUsage"));
    if let Some(utilization) = extra.and_then(|v| number(obj_get(v, "utilization"))) {
        windows.push(QuotaWindow {
            id: "extra_usage".to_owned(),
            title: "Extra usage".to_owned(),
            used_percent: clamp_percent(utilization),
            resets_at: None,
            duration_seconds: None,
            remaining_value: None,
            limit_value: None,
            value_unit: None,
        });
    }
    inherit_weekly_reset(&mut windows, &weekly_group);
    windows
}

fn usage_window(
    value: Option<&Value>,
    id: &str,
    title: &str,
    duration: u64,
) -> Option<QuotaWindow> {
    let value = value?;
    let utilization = number(obj_get_any(
        value,
        &["utilization", "utilization_pct", "percent"],
    ))?;
    Some(QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(utilization),
        resets_at: obj_get_any(value, &["resets_at", "resetsAt", "reset_at", "resetAt"])
            .and_then(|v| parse_date(Some(v)))
            .map(super::common::unix_seconds_to_iso),
        duration_seconds: Some(duration),
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    })
}

fn map_profile(value: &Value) -> (Option<String>, Option<String>) {
    let account = obj_get(value, "account");
    let organization = obj_get(value, "organization");
    (
        obj_get_any(
            account.unwrap_or(&Value::Null),
            &["emailAddress", "email_address", "email"],
        )
        .and_then(|v| string(Some(v)))
        .or_else(|| {
            obj_get_any(value, &["emailAddress", "email_address", "email"])
                .and_then(|v| string(Some(v)))
        }),
        obj_get(organization.unwrap_or(&Value::Null), "uuid")
            .and_then(|v| string(Some(v)))
            .or_else(|| {
                obj_get_any(value, &["organizationUuid", "organization_uuid"])
                    .and_then(|v| string(Some(v)))
            }),
    )
}

fn is_all_models(model_id: Option<&str>, model_name: &str) -> bool {
    if slug(model_name, '-') == "all-models" {
        return true;
    }
    model_id
        .map(|id| {
            let id = slug(id, '-');
            id == "all-models" || id.ends_with("-all-models")
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn credential(source: &str, expires_at: Option<i64>) -> Credentials {
        Credentials {
            access_token: format!("token-{source}"),
            expires_at,
            scopes: Vec::new(),
            subscription_type: None,
            rate_limit_tier: None,
            source: source.to_owned(),
        }
    }

    /// Claude renews the Keychain entry in place, so a file left behind by an older version
    /// must not decide this device's sign-in just because its clock has not run out yet: a
    /// revoked-but-unexpired file token used to mask the live grant, and to swallow the
    /// renewal this collector performs, because `/status` writes where nothing was reading.
    #[test]
    fn the_renewed_grant_outranks_the_file_left_behind() {
        let now = 1_000_000;
        let live = || Some(credential("keychain", Some(now + 86_400)));
        let stale = || Some(credential("file", Some(now + 86_400)));
        let expired = |source: &'static str| Some(credential(source, Some(now - 1)));

        // Both usable: the Keychain is the one Claude renews.
        assert_eq!(
            preferred_credentials(live(), stale(), now)
                .expect("credentials")
                .source,
            "keychain"
        );
        // Only the file is usable: an expiring Keychain grant is not worth preferring.
        assert_eq!(
            preferred_credentials(expired("keychain"), stale(), now)
                .expect("credentials")
                .source,
            "file"
        );
        // Both expiring: still the Keychain, so the caller reports one expired sign-in
        // rather than reporting the one that cannot be renewed.
        assert_eq!(
            preferred_credentials(expired("keychain"), expired("file"), now)
                .expect("credentials")
                .source,
            "keychain"
        );
        // Either alone is used, and neither means neither.
        assert_eq!(
            preferred_credentials(live(), None, now)
                .expect("credentials")
                .source,
            "keychain"
        );
        assert_eq!(
            preferred_credentials(None, stale(), now)
                .expect("credentials")
                .source,
            "file"
        );
        assert!(preferred_credentials(None, None, now).is_none());
    }

    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-claude-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: None,
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
        }
    }

    #[test]
    fn discovers_browser_session_when_oauth_is_absent() {
        let mut context = isolated_context();
        assert!(!context.allows_host_keychain());
        assert!(discover(&context).is_empty());
        context
            .browser_sessions
            .insert(ProviderId::Claude, "sessionKey=sk-ant-ok".to_owned());
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].credential_source, "browser_session");
    }

    #[test]
    fn maps_optional_usage_windows_and_extra_usage() {
        let windows = map_usage(&serde_json::json!({
            "five_hour": null,
            "seven_day": {"utilization": 41.5, "resets_at": "2026-08-09T12:00:00Z"},
            "extra_usage": {"utilization": 12.5}
        }));
        assert!(windows.iter().any(|window| window.id == "seven_day"));
        assert!(windows.iter().any(|window| window.id == "extra_usage"));
        let aliased = map_usage(&serde_json::json!({
            "five_hour": {"utilization_pct": 10, "reset_at": "2026-08-09T12:00:00Z"}
        }));
        assert_eq!(aliased[0].id, "five_hour");
        assert_eq!(aliased[0].used_percent, 10.0);
    }

    #[test]
    fn parses_oauth_credentials_and_rejects_mcp_only_payloads() {
        let credentials = parse_credentials(
            &serde_json::json!({
                "claudeAiOauth": {
                    "accessToken": "claude-access",
                    "refreshToken": "claude-refresh",
                    "expiresAt": "2026-08-11T00:00:00Z",
                    "scopes": ["user:profile"],
                    "subscriptionType": "pro",
                    "rateLimitTier": "max"
                }
            }),
            "fixture",
        )
        .unwrap();
        assert_eq!(credentials.access_token, "claude-access");
        assert_eq!(credentials.expires_at, Some(1786406400));
        assert_eq!(credentials.scopes, ["user:profile"]);
        assert_eq!(credentials.subscription_type.as_deref(), Some("pro"));
        assert!(
            parse_credentials(
                &serde_json::json!({
                    "mcpOAuth": {"token": "mcp-only"}
                }),
                "fixture"
            )
            .is_none()
        );
        assert!(
            parse_credentials(
                &serde_json::json!({
                    "claudeAiOauth": {"scopes": ["user:profile"]}
                }),
                "fixture"
            )
            .is_none()
        );
    }

    /// A collection failure and an account with nothing to report are different answers, and
    /// only one of them is worth telling the reader to retry.
    #[test]
    fn an_account_stating_it_has_no_windows_is_not_a_failure() {
        // The account answered for a window it knows: no windows, read successfully.
        assert!(answers_for_a_known_window(&serde_json::json!({
            "five_hour": null,
            "seven_day": null
        })));
        // A response naming none of them is one this build cannot read.
        assert!(!answers_for_a_known_window(&serde_json::json!({})));
        assert!(!answers_for_a_known_window(&serde_json::json!({
            "something_else": {"utilization": 10}
        })));
        // A window that is present but unreadable is not an account stating it has none.
        assert!(!answers_for_a_known_window(&serde_json::json!({
            "five_hour": {"unexpected": true}
        })));
        assert!(map_usage(&serde_json::json!({"five_hour": null, "seven_day": null})).is_empty());
    }

    #[test]
    fn keeps_scoped_model_limits_and_drops_all_models_scope() {
        let windows = map_usage(&serde_json::json!({
            "limits": [
                {"kind": "weekly_scoped", "group": "weekly", "percent": 17,
                 "scope": {"model": {"id": "claude-sonnet-4", "display_name": "Claude Sonnet"}},
                 "resets_at": "2026-08-12T00:00:00Z"},
                {"kind": "weekly_scoped", "group": "weekly", "percent": 90,
                 "scope": {"model": {"id": "all-models", "display_name": "All models"}}}
            ]
        }));
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "claude-weekly-scoped-claude-sonnet-4");
        assert_eq!(windows[0].used_percent, 17.0);
        assert_eq!(
            windows[0].resets_at.as_deref(),
            Some("2026-08-12T00:00:00Z")
        );
    }

    #[test]
    fn scoped_weekly_limit_without_its_own_reset_uses_the_weekly_reset() {
        let windows = map_usage(&serde_json::json!({
            "seven_day": {"utilization": 5, "resets_at": "2026-08-23T04:00:00Z"},
            "limits": [
                {"kind": "weekly_scoped", "group": "weekly", "percent": 5,
                 "scope": {"model": {"id": "claude-fable-5", "display_name": "Fable"}}}
            ]
        }));
        let scoped = windows
            .iter()
            .find(|window| window.id == "claude-weekly-scoped-claude-fable-5")
            .expect("scoped window");
        assert_eq!(scoped.title, "Fable only");
        assert_eq!(scoped.resets_at.as_deref(), Some("2026-08-23T04:00:00Z"));
        // Routines spans seven days but is not a weekly-group limit, so it keeps its own.
        let routines = map_usage(&serde_json::json!({
            "seven_day": {"utilization": 5, "resets_at": "2026-08-23T04:00:00Z"},
            "seven_day_opus": {"utilization": 1},
            "routines": {"utilization": 2}
        }));
        let reset_for = |id: &str| {
            routines
                .iter()
                .find(|window| window.id == id)
                .and_then(|window| window.resets_at.clone())
        };
        assert_eq!(
            reset_for("seven_day_opus").as_deref(),
            Some("2026-08-23T04:00:00Z")
        );
        assert_eq!(reset_for("claude-routines"), None);
        // Without a weekly window there is nothing to inherit.
        let alone = map_usage(&serde_json::json!({
            "limits": [
                {"kind": "weekly_scoped", "group": "weekly", "percent": 5,
                 "scope": {"model": {"id": "claude-fable-5", "display_name": "Fable"}}}
            ]
        }));
        assert_eq!(alone[0].resets_at, None);
    }
}
