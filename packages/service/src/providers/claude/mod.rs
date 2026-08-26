use crate::catalog::ProviderId;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use super::common::{
    CliTool, CollectionContext, ErrorCategory, HttpClient, KeychainSecret, LOCAL_FILE_LIMIT,
    ProviderError, ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, account_identity,
    clamp_percent, mask_email, number, obj_get, obj_get_any, parse_date, read_bounded_file,
    run_bounded_command, slug, string,
};

pub mod refresh;

pub const SOURCE: &str = "anthropic_oauth_usage_api";
/// What an emptied credential reports under.
///
/// Not a rung: the same OAuth path answered, and what it found was a Claude Code that signed
/// itself out. It is a source of its own because it is the one sign-in failure whose recovery
/// is not "open Claude Code" — the app opens onto the same emptied entry — and the recovery
/// text is chosen by the source that reached the verdict.
pub const SIGNED_OUT_SOURCE: &str = "anthropic_oauth_signed_out";
pub const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const PROFILE_URL: &str = "https://api.anthropic.com/api/oauth/profile";
pub const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const AUTH_REFRESH_SKEW: i64 = 60;
/// What the header claims when this device has no readable Claude Code install to ask.
const FALLBACK_CLI_VERSION: &str = "2.1.0";

/// The usage endpoint answers Claude Code, so the request identifies as Claude Code — with
/// the version of the install that is actually on this device when one could be read.
fn user_agent(context: &CollectionContext) -> String {
    format!(
        "claude-code/{}",
        context
            .cli_version(CliTool::Claude)
            .unwrap_or(FALLBACK_CLI_VERSION)
    )
}

#[derive(Clone, Debug)]
struct Credentials {
    access_token: String,
    expires_at: Option<i64>,
    scopes: Vec<String>,
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
    /// Whether Claude Code holds a refresh token in this entry.  The token itself is never
    /// read into this process — only the CLI that owns it may ever spend it — and this
    /// decides one thing: whether asking that CLI to renew is worth a spawn.
    refresh_token_present: bool,
    source: String,
}

/// One credential document as this build reads it.
#[derive(Clone, Debug)]
enum Entry {
    Grant(Credentials),
    /// The entry Claude Code leaves when it signs itself out, and the store it was read from.
    SignedOut(String),
}

impl Entry {
    fn source(&self) -> &str {
        match self {
            Self::Grant(credentials) => &credentials.source,
            Self::SignedOut(source) => source,
        }
    }

    /// Whether this entry is the thing standing between the refresh and a reading. An emptied
    /// one always is, and no clock will change that.
    fn expiring(&self, now: i64) -> bool {
        match self {
            Self::Grant(credentials) => is_expiring(credentials, now),
            Self::SignedOut(_) => true,
        }
    }

    fn grant(self) -> Option<Credentials> {
        match self {
            Self::Grant(credentials) => Some(credentials),
            Self::SignedOut(_) => None,
        }
    }
}

/// The Claude sign-in this device holds, emptied entries included: a Claude Code that signed
/// itself out is a credential this Mac has and cannot use, which is a different thing to tell
/// the reader from a Mac that never had one.
pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    look_up_credentials(context)
        .entry
        .map(|entry| ProviderSession {
            provider: ProviderId::Claude,
            credential_source: entry.source().to_owned(),
        })
        .into_iter()
        .collect()
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    collect_official(context)
}

fn collect_official(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let lookup = look_up_credentials(context);
    let Some(entry) = lookup.entry else {
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
    let Some(credentials) = entry.grant() else {
        // Claude Code emptied its own credential rather than renew it, which is the one
        // sign-in problem that opening Claude Code does not fix: it opens onto the same
        // emptied entry.  Unless the Keychain withheld the entry it holds — then the emptied
        // one is a file an older Claude Code left behind, and it says nothing about the grant
        // this device was refused.
        return Err(if lookup.keychain_refused {
            ProviderError::new(ErrorCategory::AccessDenied, SOURCE)
        } else {
            ProviderError::new(ErrorCategory::AuthRequired, SIGNED_OUT_SOURCE)
        });
    };
    // Claude Code owns token renewal. The refresh worker already gave it its one chance to
    // renew an expired grant ([`refresh`]); one still out of time here is a sign-in only the
    // reader can restore, and saying so sends them somewhere that can actually fix it.
    if is_expiring(&credentials, context.observed_unix()) {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    collect_at(&credentials, context, USAGE_URL, PROFILE_URL)
}

/// This device's Claude credential, and whether the Keychain refused to hand one over.
struct CredentialLookup {
    entry: Option<Entry>,
    keychain_refused: bool,
}

fn look_up_credentials(context: &CollectionContext) -> CredentialLookup {
    let root = context
        .env("CLAUDE_CONFIG_DIR")
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".claude"));
    let file_entry = read_credentials_file(&root.join(".credentials.json"));
    let keychain = (cfg!(target_os = "macos") && context.allows_host_keychain())
        .then(|| context.keychain_secret(|| read_keychain(context)));
    let keychain_refused = matches!(keychain, Some(KeychainSecret::Refused));
    let keychain_entry = match keychain {
        Some(KeychainSecret::Found(secret)) => serde_json::from_slice::<Value>(secret)
            .ok()
            .and_then(|value| parse_entry(&value, &format!("macOS Keychain: {KEYCHAIN_SERVICE}"))),
        Some(KeychainSecret::Absent | KeychainSecret::Refused) | None => None,
    };
    // Claude renews the Keychain entry in place, so that is the live grant and the file is
    // what an older version left behind.  Reading the file first let one that had been
    // revoked but not yet expired mask the renewed grant for as long as its clock ran.
    CredentialLookup {
        entry: preferred_entry(keychain_entry, file_entry, context.observed_unix()),
        keychain_refused,
    }
}

/// The Keychain entry wins unless it is the only expiring one of the two.
fn preferred_entry(keychain: Option<Entry>, file: Option<Entry>, now: i64) -> Option<Entry> {
    match (keychain, file) {
        (Some(keychain), Some(file)) => Some(if !keychain.expiring(now) || file.expiring(now) {
            keychain
        } else {
            file
        }),
        (Some(keychain), None) => Some(keychain),
        (None, file) => file,
    }
}

/// Whether this device's Claude sign-in is the thing standing between the refresh and a
/// reading, and Claude Code holds what it needs to renew it.
///
/// The refresh token is that: 2.1.x can leave a Keychain item holding only `mcpOAuth`, and an
/// entry carrying no refresh token cannot be renewed by anything, so neither earns a spawn.
fn sign_in_expiring(context: &CollectionContext) -> bool {
    matches!(
        look_up_credentials(context).entry,
        Some(Entry::Grant(credentials))
            if credentials.refresh_token_present
                && is_expiring(&credentials, context.observed_unix())
    )
}

/// Whether the credential holds a grant this refresh can spend, under the preference
/// discovery uses.
///
/// Deliberately not `!sign_in_expiring`: an emptied entry, or a store the CLI removed, is
/// neither expiring nor usable, and that third answer is what tells a Claude Code that signed
/// itself out — which no number of attempts would restore — from one that could not renew.
fn sign_in_usable(context: &CollectionContext) -> bool {
    matches!(
        look_up_credentials(context).entry,
        Some(Entry::Grant(credentials)) if !is_expiring(&credentials, context.observed_unix())
    )
}

fn read_credentials_file(path: &Path) -> Option<Entry> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let value: Value = serde_json::from_slice(&read_bounded_file(path, LOCAL_FILE_LIMIT)?).ok()?;
    parse_entry(&value, &path.to_string_lossy())
}

/// The Claude Code credential entry, or why it did not produce one.
///
/// The collection context memoizes this, so one refresh reads the Keychain once however
/// many collectors ask.  A renewal that actually ran forgets that memo and costs a second
/// read, because the CLI rewrites the entry the first one described.
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

/// The Claude sign-in a credential document holds, or the emptied entry in its place.
///
/// A document with no `claudeAiOauth` object is no Claude sign-in at all — 2.1.x can leave a
/// Keychain item holding only `mcpOAuth`, which belongs to MCP servers — and is no entry
/// here. One that has the object without a usable access token is the opposite: Claude Code
/// signs itself out by emptying the entry in place, blanking the tokens and setting
/// `expiresAt` to zero, and that is a credential this device holds and cannot use.
fn parse_entry(value: &Value, source: &str) -> Option<Entry> {
    value.get("claudeAiOauth")?.as_object()?;
    Some(match parse_credentials(value, source) {
        Some(credentials) => Entry::Grant(credentials),
        None => Entry::SignedOut(source.to_owned()),
    })
}

fn parse_credentials(value: &Value, source: &str) -> Option<Credentials> {
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
        refresh_token_present: obj_get_any(
            &Value::Object(oauth.clone()),
            &["refreshToken", "refresh_token"],
        )
        .and_then(|v| string(Some(v)))
        .is_some(),
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

fn collect_at(
    credentials: &Credentials,
    context: &CollectionContext,
    usage_url: &str,
    profile_url: &str,
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
    let user_agent = user_agent(context);
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("anthropic-beta", "oauth-2025-04-20"),
        ("User-Agent", user_agent.as_str()),
    ];
    let usage = match client.get_json(usage_url, &headers, SOURCE) {
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
        match client.get_json(profile_url, &profile_headers, SOURCE) {
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
            refresh_token_present: true,
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
        let entry = |source: &'static str, expires_at| {
            Some(Entry::Grant(credential(source, Some(expires_at))))
        };
        let live = || entry("keychain", now + 86_400);
        let stale = || entry("file", now + 86_400);
        let expired = |source: &'static str| entry(source, now - 1);
        let preferred = |keychain, file| {
            preferred_entry(keychain, file, now).map(|entry| entry.source().to_owned())
        };

        // Both usable: the Keychain is the one Claude renews.
        assert_eq!(preferred(live(), stale()).as_deref(), Some("keychain"));
        // Only the file is usable: an expiring Keychain grant is not worth preferring.
        assert_eq!(
            preferred(expired("keychain"), stale()).as_deref(),
            Some("file")
        );
        // Both expiring: still the Keychain, so the caller reports one expired sign-in
        // rather than reporting the one that cannot be renewed.
        assert_eq!(
            preferred(expired("keychain"), expired("file")).as_deref(),
            Some("keychain")
        );
        // Either alone is used, and neither means neither.
        assert_eq!(preferred(live(), None).as_deref(), Some("keychain"));
        assert_eq!(preferred(None, stale()).as_deref(), Some("file"));
        assert!(preferred(None, None).is_none());
        // An emptied Keychain entry is always the expiring one, so a file grant with time
        // left is what this refresh reads — and when neither has time, the reader is told
        // about the Claude Code that signed itself out rather than about a stale file.
        let emptied = || Some(Entry::SignedOut("keychain".to_owned()));
        assert_eq!(preferred(emptied(), stale()).as_deref(), Some("file"));
        assert_eq!(
            preferred(emptied(), expired("file")).as_deref(),
            Some("keychain")
        );
    }

    /// A withheld secret is not a sign-out.  An emptied file next to a Keychain this device
    /// was refused is what an older Claude Code left behind, and the grant that was withheld
    /// may be perfectly good — so the reader is told about the refusal, which they can act on,
    /// rather than sent to sign in again for as long as the access decision stands.
    #[cfg(target_os = "macos")]
    #[test]
    fn an_emptied_file_beside_a_refused_keychain_reports_the_refusal() {
        let home = std::env::temp_dir().join(format!("quota-claude-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(home.join(".claude")).expect("home");
        fs::write(
            home.join(".claude/.credentials.json"),
            r#"{"claudeAiOauth": {"accessToken": "", "refreshToken": "", "expiresAt": 0}}"#,
        )
        .expect("credential");
        let context = |secret: KeychainSecret| {
            let context = CollectionContext {
                home_directory: home.clone(),
                environment: std::collections::HashMap::from([(
                    "HOME".to_owned(),
                    home.to_string_lossy().into_owned(),
                )]),
                now: Some("2026-08-26T12:00:00Z".to_owned()),
                ..CollectionContext::default()
            };
            // Seeded, so the one Keychain read of this refresh has already happened and no
            // test starts `/usr/bin/security`.
            context.keychain.set(secret).expect("unread");
            context
        };
        assert!(context(KeychainSecret::Absent).allows_host_keychain());
        let verdict = |secret| {
            let error = collect_official(&context(secret)).expect_err("no reading");
            (error.category, error.source_id)
        };
        assert_eq!(
            verdict(KeychainSecret::Refused),
            (ErrorCategory::AccessDenied, SOURCE)
        );
        assert_eq!(
            verdict(KeychainSecret::Absent),
            (ErrorCategory::AuthRequired, SIGNED_OUT_SOURCE)
        );
        fs::remove_dir_all(&home).expect("cleanup");
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
            cli_versions: Default::default(),
        }
    }

    /// The usage endpoint answers Claude Code, so the request says it is Claude Code — and
    /// says which one.  A device that could not read an install still asks, under the version
    /// this build falls back to, because the reading matters more than the accuracy of a
    /// header field neither side can verify.
    #[test]
    fn the_usage_request_names_the_installed_claude_code() {
        use std::io::{Read as _, Write as _};
        use std::net::TcpListener;

        for (installed, expected) in [
            (Some("2.4.7"), "user-agent: claude-code/2.4.7"),
            (None, "user-agent: claude-code/2.1.0"),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
            let address = listener.local_addr().expect("address");
            let server = std::thread::spawn(move || {
                let mut heads = Vec::new();
                for body in [
                    r#"{"five_hour":{"utilization":12}}"#,
                    r#"{"account":{"email":"ada@example.com"}}"#,
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
                    .insert(CliTool::Claude, version.to_owned());
            }
            let mut credentials = credential("fixture", None);
            credentials.scopes = vec!["user:profile".to_owned()];
            let snapshot = collect_at(
                &credentials,
                &context,
                &format!("http://{address}/usage"),
                &format!("http://{address}/profile"),
            )
            .expect("snapshot");
            assert_eq!(snapshot.windows.len(), 1);
            let heads = server.join().expect("server");
            assert!(heads[0].contains(expected), "{}", heads[0]);
            assert!(heads[0].contains("anthropic-beta: oauth-2025-04-20"));
        }
    }

    /// Claude Code owns this grant, so a Mac without one has nothing for this collector to
    /// try. There is no second rung to fall to.
    #[test]
    fn no_local_grant_discovers_nothing() {
        let context = isolated_context();
        assert!(!context.allows_host_keychain());
        assert!(discover(&context).is_empty());
        assert!(ProviderId::Claude.metadata().browser_session.is_none());
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
        // The token itself is never read into this process: only whether Claude Code holds
        // one, which is the whole question a renewal turns on.
        assert!(credentials.refresh_token_present);
        assert!(
            !parse_credentials(
                &serde_json::json!({
                    "claudeAiOauth": {"accessToken": "claude-access", "refreshToken": "  "}
                }),
                "fixture"
            )
            .expect("credentials")
            .refresh_token_present
        );
    }

    /// The three shapes a Claude Code credential comes in, and what each one is.
    #[test]
    fn an_emptied_entry_is_a_signed_out_claude_code_and_mcp_items_are_not_a_sign_in() {
        // A Keychain item holding only MCP server tokens is not a Claude sign-in at all, and
        // a device holding one has nothing for this provider.
        assert!(
            parse_entry(
                &serde_json::json!({"mcpOAuth": {"token": "mcp-only"}}),
                "fixture"
            )
            .is_none()
        );
        // Claude Code signs itself out by emptying the entry in place. That is a credential
        // this device holds and cannot use, which is not the same as holding none.
        for emptied in [
            serde_json::json!({"claudeAiOauth": {
                "accessToken": "", "refreshToken": "", "expiresAt": 0
            }}),
            serde_json::json!({"claudeAiOauth": {"scopes": ["user:profile"]}}),
        ] {
            assert!(matches!(
                parse_entry(&emptied, "fixture"),
                Some(Entry::SignedOut(_))
            ));
        }
        assert!(matches!(
            parse_entry(
                &serde_json::json!({"claudeAiOauth": {"accessToken": "live"}}),
                "fixture"
            ),
            Some(Entry::Grant(_))
        ));
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
