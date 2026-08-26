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
    pub browser_sessions: HashMap<ProviderId, String>,
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

    pub fn browser_session(&self, provider: ProviderId) -> Option<&str> {
        self.browser_sessions.get(&provider).map(String::as_str)
    }

    /// The macOS Keychain secret this refresh may read, fetched at most once however
    /// many collectors ask for it.  Discovery and collection both need the same answer,
    /// and asking twice starts a second `/usr/bin/security` for no new information.
    pub fn keychain_secret(&self, read: impl FnOnce() -> KeychainSecret) -> &KeychainSecret {
        self.keychain.get_or_init(read)
    }
}

pub fn normalize_browser_cookie_header(
    provider: ProviderId,
    header: &str,
) -> Result<String, ProviderError> {
    let source = super::json::provider_source(provider.as_str());
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
