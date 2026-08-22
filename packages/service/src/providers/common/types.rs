use crate::catalog::ProviderId;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, atomic::AtomicBool};

use super::json::{parse_date, unix_now, unix_seconds_to_iso};

pub const BROWSER_COOKIE_HEADER_LIMIT: usize = 8_192;
pub const BROWSER_SESSION_SOURCE: &str = "browser_session";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ErrorCategory {
    AuthRequired,
    Unavailable,
    Unsupported,
    Error,
}

impl ErrorCategory {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AuthRequired => "auth_required",
            Self::Unavailable => "unavailable",
            Self::Unsupported => "unsupported",
            Self::Error => "error",
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("{message}")]
pub struct ProviderError {
    pub category: ErrorCategory,
    pub message: &'static str,
    pub source_id: &'static str,
}

impl ProviderError {
    pub const fn new(category: ErrorCategory, source: &'static str) -> Self {
        Self {
            category,
            message: fixed_message(category),
            source_id: source,
        }
    }

    pub const fn with_message(
        category: ErrorCategory,
        source: &'static str,
        message: &'static str,
    ) -> Self {
        Self {
            category,
            message,
            source_id: source,
        }
    }
}

pub const fn fixed_message(category: ErrorCategory) -> &'static str {
    match category {
        ErrorCategory::AuthRequired => "Provider authentication is required.",
        ErrorCategory::Unavailable => "Provider is temporarily unavailable.",
        ErrorCategory::Unsupported => "Provider operation is not supported.",
        ErrorCategory::Error => "Provider returned invalid quota data.",
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
    pub source: &'static str,
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
        }
    }
}

impl CollectionContext {
    pub fn user_agent(&self) -> String {
        format!("{}/{}", self.client_name, self.client_version)
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
                .join("quotacli/providers.json")
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
}

pub fn discover_official_or_browser(
    provider: ProviderId,
    official: Option<ProviderSession>,
    context: &CollectionContext,
) -> Vec<ProviderSession> {
    if let Some(session) = official {
        return vec![session];
    }
    context
        .browser_session(provider)
        .map(|_| ProviderSession {
            provider,
            credential_source: BROWSER_SESSION_SOURCE.to_owned(),
        })
        .into_iter()
        .collect()
}

/// Collects from a provider's local credentials, falling back to a stored
/// browser session.
///
/// **`collect_official` must report [`ErrorCategory::AuthRequired`] when no
/// usable local credential exists.** That category is the only one that reaches
/// `collect_web`; any other ends the refresh, so a provider whose official
/// closure chains several credential sources internally has to surface the
/// chain's verdict rather than the last step's incidental error.
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

pub fn cookie_named_value<'a>(header: &'a str, name: &str) -> Option<&'a str> {
    header.split(';').find_map(|pair| {
        let pair = pair.trim_matches([' ', '\t']);
        let (cookie_name, value) = pair.split_once('=')?;
        (cookie_name == name && !value.is_empty()).then_some(value)
    })
}

fn is_cookie_octet(byte: u8) -> bool {
    matches!(byte, 0x21 | 0x23..=0x2B | 0x2D..=0x3A | 0x3C..=0x5B | 0x5D..=0x7E)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_auth_required_reaches_the_browser_session() {
        let mut context = CollectionContext::default();
        context
            .browser_sessions
            .insert(ProviderId::Claude, "sessionKey=sk-ant-x".to_owned());
        let session = ProviderSession {
            provider: ProviderId::Claude,
            credential_source: "local".to_owned(),
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

    #[test]
    fn cancelled_browser_session_collect_uses_web_source() {
        let session = ProviderSession {
            provider: ProviderId::Claude,
            credential_source: BROWSER_SESSION_SOURCE.to_owned(),
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
}
