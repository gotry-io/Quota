use crate::catalog::ProviderId;
use chrono_tz::Tz;
use serde::Serialize;

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock, atomic::AtomicBool};

use super::cli_version::CliTool;
use super::json::{parse_date, unix_now, unix_seconds_to_iso};

pub const BROWSER_COOKIE_HEADER_LIMIT: usize = 8_192;
pub const BROWSER_SESSION_SOURCE: &str = "browser_session";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ErrorCategory {
    AuthRequired,
    /// This device was refused a credential it holds.  It reads as `unavailable` on the wire,
    /// because a reader on another device can neither see nor change this one's access; the
    /// marker that separates it travels with the local collection result.
    AccessDenied,
    Unavailable,
    Unsupported,
    Error,
}

impl ErrorCategory {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AuthRequired => "auth_required",
            Self::AccessDenied | Self::Unavailable => "unavailable",
            Self::Unsupported => "unsupported",
            Self::Error => "error",
        }
    }

    /// The category as itself, including the refusal [`Self::as_str`] folds away.  Only a
    /// reader on this device can act on that difference, and only the local collection
    /// report carries it.
    pub const fn name(self) -> &'static str {
        match self {
            Self::AuthRequired => "auth_required",
            Self::AccessDenied => "access_denied",
            Self::Unavailable => "unavailable",
            Self::Unsupported => "unsupported",
            Self::Error => "error",
        }
    }
}

/// A failed provider read. The category is the whole answer: it is what the collection
/// boundary branches on and what the client renders. Provider text never enters it, so a
/// provider response can never carry a secret into an error, a log line, or the UI.
#[derive(Debug, thiserror::Error)]
#[error("{}", category.as_str())]
pub struct ProviderError {
    pub category: ErrorCategory,
    pub source_id: &'static str,
}

impl ProviderError {
    pub const fn new(category: ErrorCategory, source: &'static str) -> Self {
        Self {
            category,
            source_id: source,
        }
    }
}

/// One recurring allowance a subscription meters.
///
/// The protocol spelling a client trusts and the title a person reads are one fact, so they are
/// stated here once rather than paired by hand at each collector. A provider decides *whether* a
/// window is a headline meter — that derivation is its own, and differs by provider — but not
/// what the answer is called. Declared shortest first, which is the order a stacked item reads.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Cadence {
    FiveHour,
    Weekly,
    Monthly,
}

impl Cadence {
    /// The `primary_cadence` member, for the callers that need it outside serde — a Codex window
    /// is ided by its cadence. The derive writes the same string, and
    /// `a_cadence_serializes_as_the_protocol_member` holds the two together.
    pub const fn wire(self) -> &'static str {
        match self {
            Self::FiveHour => "five_hour",
            Self::Weekly => "weekly",
            Self::Monthly => "monthly",
        }
    }

    /// The window title a person reads.
    pub const fn title(self) -> &'static str {
        match self {
            Self::FiveHour => "5 Hours",
            Self::Weekly => "Weekly",
            Self::Monthly => "Monthly",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct QuotaWindow {
    pub id: String,
    pub title: String,
    pub used_percent: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_cadence: Option<Cadence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remaining_value: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit_value: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value_unit: Option<&'static str>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct QuotaAccount {
    pub fingerprint: String,
    pub fingerprint_scope: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct QuotaSnapshot {
    pub provider: ProviderId,
    pub account: QuotaAccount,
    pub windows: Vec<QuotaWindow>,
    pub status: &'static str,
    pub observed_at: String,
}

#[derive(Clone, Debug)]
pub struct ProviderSession {
    pub provider: ProviderId,
    pub credential_source: String,
    pub cookie_header: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ValidatedBrowserSession {
    pub cookie_header: String,
    pub account_fingerprint: String,
    pub account_label: Option<String>,
}

/// What one macOS Keychain generic-password read found.
///
/// `Debug` is written by hand: the secret is the whole point of the entry, and a
/// context that derives `Debug` around it must not be able to print it.
#[derive(Clone, Eq, PartialEq)]
pub enum KeychainSecret {
    Found(Vec<u8>),
    /// No entry for that service, or this build does not read the Keychain at all.
    Absent,
    /// The entry is there and its secret was withheld.  That is an access decision, and
    /// signing in again only rewrites a secret this device still would not be handed.
    Refused,
}

impl std::fmt::Debug for KeychainSecret {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Found(_) => "KeychainSecret::Found(<redacted>)",
            Self::Absent => "KeychainSecret::Absent",
            Self::Refused => "KeychainSecret::Refused",
        })
    }
}

#[derive(Clone, Debug)]
pub struct CollectionContext {
    pub home_directory: PathBuf,
    pub environment: HashMap<String, String>,
    pub config_path: Option<PathBuf>,
    pub browser_sessions: HashMap<ProviderId, Vec<String>>,
    pub client_name: String,
    pub client_version: String,
    pub now: Option<String>,
    pub cancel: Option<Arc<AtomicBool>>,
    /// The one macOS Keychain read a refresh performs, shared by every collector running
    /// under this context.  Claude Code's credential entry is the only Keychain item any
    /// collector reads, and `/usr/bin/security` is the only process the scheduled refresh
    /// starts on its own account.
    pub keychain: Arc<OnceLock<KeychainSecret>>,
    /// The installed version of each provider CLI this refresh identifies as, resolved on the
    /// refresh worker before collection.  A collector reads it; it never probes for it, so no
    /// collector can turn a five-minute timer into a spawn.
    pub cli_versions: BTreeMap<CliTool, String>,
    /// For each provider, an irreversible digest of the credential that last produced a
    /// reading here.  A credential this build cannot judge on its own — an access token whose
    /// expiry it cannot decode — is judged by whether it has already been spent, which is the
    /// only evidence that outlives a refresh.  Written by the refresh worker after collection;
    /// a collector only reads it.
    pub proven_credentials: BTreeMap<String, String>,
}

impl Default for CollectionContext {
    fn default() -> Self {
        let home_directory = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"));
        let environment = std::env::vars().collect();
        Self {
            home_directory,
            environment,
            config_path: None,
            browser_sessions: HashMap::new(),
            client_name: "Quota".to_owned(),
            client_version: "development".to_owned(),
            now: None,
            cancel: None,
            keychain: Arc::new(OnceLock::new()),
            cli_versions: BTreeMap::new(),
            proven_credentials: BTreeMap::new(),
        }
    }
}

/// The IANA zone this process runs in: an explicit valid `TZ`, then the host zone, then
/// UTC. Provider text that names a wall-clock instant without a zone is read in it.
pub fn resolve_timezone(environment: &HashMap<String, String>) -> Tz {
    environment
        .get("TZ")
        .and_then(|value| value.parse::<Tz>().ok())
        .or_else(|| {
            iana_time_zone::get_timezone()
                .ok()
                .and_then(|value| value.parse::<Tz>().ok())
        })
        .unwrap_or(Tz::UTC)
}

impl CollectionContext {
    pub fn timezone(&self) -> Tz {
        resolve_timezone(&self.environment)
    }

    pub fn user_agent(&self) -> String {
        format!("{}/{}", self.client_name, self.client_version)
    }

    /// Whether this exact credential has already produced a reading on this device.
    pub fn credential_is_proven(&self, provider: ProviderId, fingerprint: &str) -> bool {
        self.proven_credentials
            .get(provider.as_str())
            .is_some_and(|proven| proven == fingerprint)
    }

    /// The installed version of a provider CLI, when this device has one and it answered.
    pub fn cli_version(&self, tool: CliTool) -> Option<&str> {
        self.cli_versions.get(&tool).map(String::as_str)
    }

    pub fn env(&self, key: &str) -> Option<&str> {
        self.environment.get(key).map(String::as_str)
    }

    /// The macOS Keychain is process-global. Isolated collection (tests, remapped
    /// homes) must not read the live user store.
    pub fn allows_host_keychain(&self) -> bool {
        self.env("HOME")
            .filter(|value| !value.trim().is_empty())
            .is_some_and(|home| self.home_directory == Path::new(home))
    }

    pub fn config_path(&self) -> PathBuf {
        self.config_path.clone().unwrap_or_else(|| {
            self.environment
                .get("XDG_CONFIG_HOME")
                .filter(|value| !value.trim().is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| self.home_directory.join(".config"))
                .join("quota/providers.json")
        })
    }

    pub fn observed_at(&self) -> String {
        self.now
            .clone()
            .unwrap_or_else(|| unix_seconds_to_iso(unix_now()))
    }

    /// [`Self::observed_at`] as unix seconds, for the providers that compare
    /// against credential expiry or reset instants.
    pub fn observed_unix(&self) -> i64 {
        self.now
            .as_deref()
            .and_then(|value| parse_date(Some(&serde_json::Value::String(value.to_owned()))))
            .unwrap_or_else(unix_now)
    }

    pub fn cancelled(&self) -> bool {
        self.cancel
            .as_ref()
            .map(|value| value.load(std::sync::atomic::Ordering::Acquire))
            .unwrap_or(false)
    }

    pub fn browser_sessions_for(&self, provider: ProviderId) -> &[String] {
        self.browser_sessions
            .get(&provider)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    pub fn browser_session(&self, provider: ProviderId) -> Option<&str> {
        self.browser_sessions_for(provider)
            .first()
            .map(String::as_str)
    }

    pub fn cookie_for_session<'a>(&'a self, session: &'a ProviderSession) -> Option<&'a str> {
        session
            .cookie_header
            .as_deref()
            .or_else(|| self.browser_session(session.provider))
    }

    /// The macOS Keychain secret this refresh may read, fetched at most once however
    /// many collectors ask for it.  Discovery and collection both need the same answer,
    /// and asking twice starts a second `/usr/bin/security` for no new information.
    pub fn keychain_secret(&self, read: impl FnOnce() -> KeychainSecret) -> &KeychainSecret {
        self.keychain.get_or_init(read)
    }

    /// Forgets a secret this refresh actually held, so the next ask starts a fresh
    /// `/usr/bin/security`.
    ///
    /// Called for one plan: Claude Code's, whose CLI rewrites the Keychain entry in place.  A
    /// memo taken before it ran describes the grant that was replaced, and every collector
    /// after it would spend a token that no longer exists.  A refusal is an access decision,
    /// not a secret: keeping it avoids a second prompt for a grant Claude Code rewrites into
    /// the file this collector can already read.  No other renewal may call this — the memo
    /// is what holds a refresh to one Keychain read — and it is `&mut` because the renewal
    /// runs before any collector has a clone.
    pub fn forget_keychain(&mut self) {
        if matches!(self.keychain.get(), Some(KeychainSecret::Refused)) {
            return;
        }
        self.keychain = Arc::new(OnceLock::new());
    }
}

/// The ladder every provider with a stored browser session ends on.
///
/// A browser session is the last rung: it is only ever reported when this Mac holds no
/// official credential for the provider at all.  A device that has one reports that, and
/// [`collect_official_or_browser`] decides at collection time whether the stored session is
/// reached.
pub fn discover_official_or_browser(
    provider: ProviderId,
    official: Option<ProviderSession>,
    context: &CollectionContext,
) -> Vec<ProviderSession> {
    if let Some(session) = official {
        return vec![session];
    }
    context
        .browser_sessions_for(provider)
        .iter()
        .map(|cookie_header| ProviderSession {
            provider,
            credential_source: BROWSER_SESSION_SOURCE.to_owned(),
            cookie_header: Some(cookie_header.clone()),
        })
        .collect()
}

/// Reads the provider's own credential path, and falls back to the stored browser session
/// only when that path ended in [`ErrorCategory::AuthRequired`].
///
/// **`collect_official` must report `AuthRequired` when no usable official credential
/// exists.** That category is the only one that reaches `collect_web`; any other ends the
/// refresh, so a provider whose official closure chains several rungs internally has to
/// surface the chain's verdict rather than the last rung's incidental error.  A refusal
/// ([`ErrorCategory::AccessDenied`]) is deliberately not that verdict: a secret this Mac was
/// withheld says nothing about the account, and spending a cookie on it would report a
/// sign-in problem the reader does not have.
pub fn collect_official_or_browser(
    session: &ProviderSession,
    context: &CollectionContext,
    provider: ProviderId,
    official_source: &'static str,
    collect_official: impl FnOnce() -> Result<QuotaSnapshot, ProviderError>,
    collect_web: impl FnOnce() -> Result<QuotaSnapshot, ProviderError>,
) -> Result<QuotaSnapshot, ProviderError> {
    if session.credential_source == BROWSER_SESSION_SOURCE {
        return collect_web();
    }
    if context.cancelled() {
        return Err(ProviderError::new(
            ErrorCategory::Unavailable,
            official_source,
        ));
    }
    match collect_official() {
        Ok(snapshot) => Ok(snapshot),
        Err(error)
            if error.category == ErrorCategory::AuthRequired
                && context.browser_session(provider).is_some() =>
        {
            collect_web()
        }
        Err(error) => Err(error),
    }
}

/// One cookie's value out of a `Cookie:` header this build assembled itself.
pub fn cookie_named_value<'a>(header: &'a str, name: &str) -> Option<&'a str> {
    header.split(';').find_map(|pair| {
        let pair = pair.trim_matches([' ', '\t']);
        let (cookie_name, value) = pair.split_once('=')?;
        (cookie_name == name && !value.is_empty()).then_some(value)
    })
}

/// The `Cookie:` header this build will send for a stored browser session, or why it will
/// not.
///
/// A header this build refuses is a browser session that was never usable, so that is the rung
/// every refusal here names.
pub fn normalize_browser_cookie_header(
    provider: ProviderId,
    header: &str,
) -> Result<String, ProviderError> {
    let source = BROWSER_SESSION_SOURCE;
    let Some(spec) = provider.metadata().browser_session else {
        return Err(ProviderError::new(ErrorCategory::Unsupported, source));
    };
    if header.is_empty()
        || header.len() > BROWSER_COOKIE_HEADER_LIMIT
        || header.chars().any(char::is_control)
    {
        return Err(ProviderError::new(ErrorCategory::Error, source));
    }
    let mut cookies = std::collections::BTreeMap::new();
    for pair in header.split(';') {
        let pair = pair.trim_matches([' ', '\t']);
        let (name, value) = pair
            .split_once('=')
            .ok_or_else(|| ProviderError::new(ErrorCategory::Error, source))?;
        if name.is_empty()
            || value.is_empty()
            || !spec.cookie_names.contains(&name)
            || !value.bytes().all(is_cookie_octet)
            || cookies.insert(name, value).is_some()
        {
            return Err(ProviderError::new(ErrorCategory::Error, source));
        }
    }
    if cookies.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, source));
    }
    Ok(cookies
        .into_iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("; "))
}

fn is_cookie_octet(byte: u8) -> bool {
    matches!(byte, 0x21 | 0x23..=0x2B | 0x2D..=0x3A | 0x3C..=0x5B | 0x5D..=0x7E)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The enum exists so a collector cannot pair the wrong title with the wrong member, but the
    /// bytes that leave this process still have to be the ones `PrimaryCadenceSchema` accepts,
    /// and `wire()` has to keep answering the same string the derive writes.
    #[test]
    fn a_cadence_serializes_as_the_protocol_member() {
        for (cadence, wire, title) in [
            (Cadence::FiveHour, "five_hour", "5 Hours"),
            (Cadence::Weekly, "weekly", "Weekly"),
            (Cadence::Monthly, "monthly", "Monthly"),
        ] {
            assert_eq!(
                serde_json::to_string(&cadence).unwrap(),
                format!("\"{wire}\"")
            );
            assert_eq!(cadence.wire(), wire);
            assert_eq!(cadence.title(), title);
        }
    }

    /// The browser session is the last rung and only the last rung: a credential path that
    /// answered anything but "sign in again" is this refresh's answer, and a refusal is
    /// never a reason to spend a cookie.
    #[test]
    fn only_auth_required_reaches_the_browser_session() {
        let mut context = CollectionContext::default();
        context
            .browser_sessions
            .insert(ProviderId::Claude, vec!["sessionKey=sk-ant-x".to_owned()]);
        let session = ProviderSession {
            provider: ProviderId::Claude,
            credential_source: "local".to_owned(),
            cookie_header: None,
        };
        let web = || {
            Err::<QuotaSnapshot, _>(ProviderError::new(ErrorCategory::Unsupported, "web_source"))
        };
        // A missing local credential hands off to the stored session...
        let handed_off = collect_official_or_browser(
            &session,
            &context,
            ProviderId::Claude,
            "official_source",
            || {
                Err(ProviderError::new(
                    ErrorCategory::AuthRequired,
                    "official_source",
                ))
            },
            web,
        );
        assert_eq!(handed_off.unwrap_err().source_id, "web_source");
        // ...while every other failure is the refresh's final answer.
        for category in [
            ErrorCategory::Error,
            ErrorCategory::Unavailable,
            ErrorCategory::Unsupported,
            ErrorCategory::AccessDenied,
        ] {
            let error = collect_official_or_browser(
                &session,
                &context,
                ProviderId::Claude,
                "official_source",
                || Err(ProviderError::new(category, "official_source")),
                web,
            )
            .expect_err("official failure");
            assert_eq!(error.category, category);
            assert_eq!(error.source_id, "official_source");
        }
        // And a working official credential never reaches the cookie at all.
        let snapshot = collect_official_or_browser(
            &session,
            &context,
            ProviderId::Claude,
            "official_source",
            || {
                Ok(QuotaSnapshot {
                    provider: ProviderId::Claude,
                    account: QuotaAccount {
                        fingerprint: "fp".to_owned(),
                        fingerprint_scope: "source",
                        label: None,
                        plan: None,
                    },
                    windows: Vec::new(),
                    status: "available",
                    observed_at: "2026-08-10T00:00:00Z".to_owned(),
                })
            },
            || panic!("browser session reached"),
        );
        assert!(snapshot.is_ok());
    }

    /// A stored session is discovered only when this Mac holds no official credential.
    #[test]
    fn the_browser_session_is_discovered_last() {
        let mut context = CollectionContext::default();
        assert!(discover_official_or_browser(ProviderId::Claude, None, &context).is_empty());
        context
            .browser_sessions
            .insert(ProviderId::Claude, vec!["sessionKey=sk-ant-x".to_owned()]);
        let stored = discover_official_or_browser(ProviderId::Claude, None, &context);
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].credential_source, BROWSER_SESSION_SOURCE);
        let official = ProviderSession {
            provider: ProviderId::Claude,
            credential_source: "keychain".to_owned(),
            cookie_header: None,
        };
        let discovered = discover_official_or_browser(ProviderId::Claude, Some(official), &context);
        assert_eq!(discovered.len(), 1);
        assert_eq!(discovered[0].credential_source, "keychain");
    }

    #[test]
    fn cancelled_browser_session_collect_uses_web_source() {
        let session = ProviderSession {
            provider: ProviderId::Claude,
            credential_source: BROWSER_SESSION_SOURCE.to_owned(),
            cookie_header: None,
        };
        let context = CollectionContext {
            cancel: Some(std::sync::Arc::new(std::sync::atomic::AtomicBool::new(
                true,
            ))),
            ..CollectionContext::default()
        };
        let error = collect_official_or_browser(
            &session,
            &context,
            ProviderId::Claude,
            "official",
            || panic!("official collect"),
            || {
                Err(ProviderError::new(
                    ErrorCategory::Unavailable,
                    "claude_web_usage_api",
                ))
            },
        )
        .unwrap_err();
        assert_eq!(error.source_id, "claude_web_usage_api");
    }

    #[test]
    fn one_cookie_value_is_read_out_of_a_header() {
        assert_eq!(
            cookie_named_value("sessionKey=sk-ant-ok; lastActiveOrg=org-2", "lastActiveOrg"),
            Some("org-2")
        );
        assert_eq!(cookie_named_value("sessionKey=", "sessionKey"), None);
        assert_eq!(cookie_named_value("sso-rw=alt", "sso"), None);
    }

    /// Discovery and collection both need this device's Claude grant, and asking twice
    /// starts a second `/usr/bin/security` for an answer the first already gave.
    #[test]
    fn the_keychain_is_read_once_per_context() {
        let context = CollectionContext::default();
        let mut reads = 0;
        for _ in 0..3 {
            let secret = context.keychain_secret(|| {
                reads += 1;
                KeychainSecret::Found(b"{}".to_vec())
            });
            assert_eq!(*secret, KeychainSecret::Found(b"{}".to_vec()));
        }
        assert_eq!(reads, 1);
        // A clone of the context is the same refresh, and shares the same answer.
        let cloned = context.clone();
        assert_eq!(
            *cloned.keychain_secret(|| panic!("second read")),
            KeychainSecret::Found(b"{}".to_vec())
        );
        // A secret must not be printable through the context that carries it.
        assert_eq!(
            format!("{:?}", KeychainSecret::Found(b"sk-ant-secret".to_vec())),
            "KeychainSecret::Found(<redacted>)"
        );
    }

    /// A refusal is an access decision, not a secret. Forgetting it would send the collector
    /// through a second prompt for a grant Claude Code may already have rewritten into the file.
    #[test]
    fn forgetting_the_keychain_keeps_a_refusal() {
        let mut context = CollectionContext::default();
        context.keychain_secret(|| KeychainSecret::Refused);
        context.forget_keychain();
        assert!(matches!(
            context.keychain_secret(|| panic!("refusal was forgotten")),
            KeychainSecret::Refused
        ));

        let mut context = CollectionContext::default();
        context.keychain_secret(|| KeychainSecret::Found(b"stale".to_vec()));
        context.forget_keychain();
        assert!(matches!(
            context.keychain_secret(|| KeychainSecret::Absent),
            KeychainSecret::Absent
        ));
    }

    #[test]
    fn host_keychain_requires_live_home() {
        let mut context = CollectionContext {
            home_directory: PathBuf::from("/Users/ada"),
            environment: HashMap::from([("HOME".into(), "/Users/ada".into())]),
            ..CollectionContext::default()
        };
        assert!(context.allows_host_keychain());
        context.home_directory = PathBuf::from("/tmp/quota-isolated-home");
        assert!(!context.allows_host_keychain());
        context.home_directory = PathBuf::from("/Users/ada");
        context.environment.clear();
        assert!(!context.allows_host_keychain());
    }

    #[test]
    fn browser_cookie_header_is_allowlisted_canonical_and_bounded() {
        let normalized =
            normalize_browser_cookie_header(ProviderId::Cursor, "wos-session=abc==:%25")
                .expect("header");
        assert_eq!(normalized, "wos-session=abc==:%25");
        for header in [
            "unknown=value",
            "wos-session=",
            "wos-session=has space",
            "wos-session= value",
            "wos-session =value",
            "wos-session=\"quoted\"",
            "wos-session=a,b",
            "wos-session=a\\b",
            "wos-session=é",
            "wos-session=ok\r\nInjected: yes",
            "wos-session=one; wos-session=two",
        ] {
            assert!(normalize_browser_cookie_header(ProviderId::Cursor, header).is_err());
        }
        assert!(
            normalize_browser_cookie_header(
                ProviderId::Cursor,
                &format!("wos-session={}", "x".repeat(BROWSER_COOKIE_HEADER_LIMIT))
            )
            .is_err()
        );
    }
}
