use crate::catalog::ProviderId;
use reqwest::blocking::Client;
use reqwest::redirect::Policy;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, atomic::AtomicBool, mpsc};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const HTTP_TIMEOUT: Duration = Duration::from_secs(20);
pub const HTTP_BODY_LIMIT: usize = 1_048_576;
pub const LOCAL_FILE_LIMIT: usize = 1_048_576;
pub const BROWSER_COOKIE_HEADER_LIMIT: usize = 8_192;

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

/// Run a provider-owned helper without allowing it to retain an unbounded
/// stdout buffer or to outlive the collection request. Stderr is discarded;
/// helpers are never allowed to use it as an implicit data channel.
pub fn run_bounded_command(
    mut command: Command,
    timeout: Duration,
    cancel: Option<&Arc<AtomicBool>>,
    output_limit: usize,
) -> Option<Vec<u8>> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut output = Vec::new();
        let result = stdout
            .take(output_limit.saturating_add(1) as u64)
            .read_to_end(&mut output)
            .map(|_| output);
        let _ = sender.send(result.ok());
    });

    let started = std::time::Instant::now();
    let mut output = None;
    loop {
        if cancel
            .map(|value| value.load(std::sync::atomic::Ordering::Acquire))
            .unwrap_or(false)
        {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        if output.is_none() {
            match receiver.try_recv() {
                Ok(Some(bytes)) => {
                    if bytes.len() > output_limit {
                        let _ = child.kill();
                        let _ = child.wait();
                        return None;
                    }
                    output = Some(bytes);
                }
                Ok(None) | Err(mpsc::TryRecvError::Disconnected) => return None,
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = output
                    .or_else(|| receiver.recv_timeout(Duration::from_secs(1)).ok().flatten())?;
                if !status.success() {
                    return None;
                }
                return Some(output);
            }
            Ok(None) if started.elapsed() < timeout => {
                thread::sleep(Duration::from_millis(25));
            }
            Ok(None) | Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
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

pub fn normalize_browser_cookie_header(
    provider: ProviderId,
    header: &str,
) -> Result<String, ProviderError> {
    let source = provider_source(provider.as_str());
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

pub fn read_bounded_file(path: &Path, limit: usize) -> Option<Vec<u8>> {
    read_bounded_file_inner(path, limit, false)
}

fn read_bounded_file_inner(path: &Path, limit: usize, owner_only: bool) -> Option<Vec<u8>> {
    #[cfg(unix)]
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
            .ok()?
    };
    #[cfg(not(unix))]
    let file = fs::File::open(path).ok()?;

    // Validate the descriptor that will actually be read. The path may have been replaced
    // between discovery and open; O_NOFOLLOW plus fstat-style metadata avoids consuming a
    // swapped-in symlink or a file that exceeds the bound/permissions.
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > limit as u64 {
        return None;
    }
    #[cfg(unix)]
    if owner_only {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return None;
        }
    }
    let mut bytes = Vec::new();
    file.take(limit.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() <= limit).then_some(bytes)
}

pub fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

#[derive(Clone, Debug)]
pub struct ApiKeyCredentials {
    pub api_key: String,
    pub label: String,
    pub source: String,
    pub base_url: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    schema_version: u64,
    providers: HashMap<String, ConfigEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigEntry {
    api_key: String,
    #[serde(default)]
    base_url: ConfigBaseUrl,
}

#[derive(Clone, Debug, Default)]
enum ConfigBaseUrl {
    #[default]
    Missing,
    Value(String),
}

impl<'de> Deserialize<'de> for ConfigBaseUrl {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        String::deserialize(deserializer).map(Self::Value)
    }
}

pub fn resolve_api_key(
    context: &CollectionContext,
    provider: ProviderId,
) -> Result<ApiKeyCredentials, ProviderError> {
    let metadata = provider.metadata();
    let provider = provider.as_str();
    let config = metadata
        .credential_config
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, provider_source(provider)))?;
    let env_keys = metadata.environment_keys;
    let default_base_url = metadata.default_base_url;
    let base_url_env_key = metadata.base_url_environment_key;
    let stored = read_config(context).ok().and_then(|file| {
        if file.schema_version != 1 {
            return None;
        }
        file.providers.get(provider).and_then(|entry| {
            let key = entry.api_key.trim();
            (!key.is_empty()).then(|| {
                let base = match &entry.base_url {
                    ConfigBaseUrl::Missing => None,
                    ConfigBaseUrl::Value(value) => Some(value.clone()),
                };
                (key.to_owned(), base)
            })
        })
    });

    let (api_key, source, stored_base) = if let Some((key, base)) = stored {
        (key, format!("config:{provider}"), base)
    } else {
        let found = env_keys.iter().find_map(|key| {
            if base_url_env_key.is_some_and(|base_key| base_key == *key) {
                return None;
            }
            context
                .env(key)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| (value.to_owned(), (*key).to_owned()))
        });
        match found {
            Some((key, env_key)) => (key, format!("env:{env_key}"), None),
            None => {
                return Err(ProviderError::new(
                    ErrorCategory::AuthRequired,
                    provider_source(provider),
                ));
            }
        }
    };

    // Fixed official endpoints ignore persisted custom URLs; configurable providers validate the
    // stored URL before considering the environment.
    let raw_base = if !config.supports_base_url {
        default_base_url.map(str::to_owned)
    } else {
        stored_base
            .or_else(|| base_url_env_key.and_then(|key| context.env(key).map(str::to_owned)))
            .or_else(|| default_base_url.map(str::to_owned))
    };
    let base_url = match raw_base {
        Some(value) => validate_base_url(&value, config.allow_private_http)
            .map_err(|_| ProviderError::new(ErrorCategory::Error, provider_source(provider)))?,
        None if config.requires_base_url => {
            return Err(ProviderError::new(
                ErrorCategory::AuthRequired,
                provider_source(provider),
            ));
        }
        None => {
            return Err(ProviderError::new(
                ErrorCategory::Error,
                provider_source(provider),
            ));
        }
    };

    if !config.supports_base_url {
        let expected = default_base_url
            .ok_or_else(|| ProviderError::new(ErrorCategory::Error, provider_source(provider)))?;
        if base_url.trim_end_matches('/') != expected.trim_end_matches('/') {
            return Err(ProviderError::new(
                ErrorCategory::Error,
                provider_source(provider),
            ));
        }
    }

    Ok(ApiKeyCredentials {
        label: mask_secret(config.mask_label, &api_key),
        api_key,
        source,
        base_url,
    })
}

fn read_config(context: &CollectionContext) -> Result<ConfigFile, ()> {
    let path = context.config_path();
    if let Some(parent) = path.parent() {
        let parent_metadata = fs::symlink_metadata(parent).map_err(|_| ())?;
        if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
            return Err(());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if parent_metadata.permissions().mode() & 0o077 != 0 {
                return Err(());
            }
        }
    }
    let bytes = read_bounded_file_inner(&path, LOCAL_FILE_LIMIT, true).ok_or(())?;
    let config: ConfigFile = serde_json::from_slice(&bytes).map_err(|_| ())?;
    if config.schema_version != 1
        || config.providers.iter().any(|(provider, entry)| {
            ProviderId::parse(provider)
                .and_then(|id| id.metadata().credential_config)
                .is_none()
                || entry.api_key.trim().is_empty()
                || matches!(&entry.base_url, ConfigBaseUrl::Value(value) if value.trim().is_empty())
        })
    {
        return Err(());
    }
    Ok(config)
}

fn validate_base_url(value: &str, allow_private_http: bool) -> Result<String, ()> {
    let trimmed = value.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return Err(());
    }
    let candidate = if trimmed.contains("://") {
        trimmed.to_owned()
    } else {
        format!("https://{trimmed}")
    };
    let mut parsed = reqwest::Url::parse(&candidate).map_err(|_| ())?;
    if parsed.username() != "" || parsed.password().is_some() || parsed.fragment().is_some() {
        return Err(());
    }
    parsed.set_query(None);
    let normalized = parsed.as_str().trim_end_matches('/').to_owned();
    match parsed.scheme() {
        "https" => Ok(normalized),
        "http" if allow_private_http && is_private_http_host(parsed.host_str().unwrap_or("")) => {
            Ok(normalized)
        }
        _ => Err(()),
    }
}

fn is_private_http_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host == "localhost" || host.ends_with(".local") {
        return true;
    }
    host.parse::<std::net::IpAddr>()
        .map(|ip| match ip {
            std::net::IpAddr::V4(ip) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
            std::net::IpAddr::V6(ip) => {
                ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local()
            }
        })
        .unwrap_or(false)
}

pub struct HttpClient {
    client: Client,
}

impl HttpClient {
    pub fn new() -> Result<Self, ProviderError> {
        Self::with_timeout(HTTP_TIMEOUT)
    }

    pub fn with_timeout(timeout: Duration) -> Result<Self, ProviderError> {
        Client::builder()
            .timeout(timeout)
            .redirect(Policy::none())
            .build()
            .map(|client| Self { client })
            .map_err(|_| ProviderError::new(ErrorCategory::Unavailable, "http"))
    }

    pub fn get_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        source: &'static str,
    ) -> Result<(u16, Value), ProviderError> {
        let mut request = self.client.get(url);
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let response = request
            .send()
            .map_err(|_| ProviderError::new(ErrorCategory::Unavailable, source))?;
        let status = response.status().as_u16();
        if (300..400).contains(&status) {
            // Redirects are deliberately disabled for bearer requests. Treat an explicit 3xx
            // response as a transport failure rather than exposing or following its location.
            return Err(ProviderError::new(ErrorCategory::Unavailable, source));
        }
        if response
            .content_length()
            .is_some_and(|length| length > HTTP_BODY_LIMIT as u64)
        {
            return Err(ProviderError::new(ErrorCategory::Error, source));
        }
        let mut body = Vec::with_capacity(
            response
                .content_length()
                .unwrap_or(0)
                .min(HTTP_BODY_LIMIT as u64) as usize,
        );
        response
            .take(HTTP_BODY_LIMIT.saturating_add(1) as u64)
            .read_to_end(&mut body)
            .map_err(|_| ProviderError::new(ErrorCategory::Unavailable, source))?;
        if body.len() > HTTP_BODY_LIMIT {
            return Err(ProviderError::new(ErrorCategory::Error, source));
        }
        let value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        if !(200..300).contains(&status) {
            return Err(ProviderError::new(http_category(status), source));
        }
        Ok((status, value))
    }
}

fn http_category(status: u16) -> ErrorCategory {
    match status {
        401 | 403 => ErrorCategory::AuthRequired,
        404 | 501 => ErrorCategory::Unsupported,
        408 | 429 | 500..=599 => ErrorCategory::Unavailable,
        _ => ErrorCategory::Error,
    }
}

pub fn account_identity(
    provider: &str,
    namespace: &str,
    owner: Option<&str>,
) -> (String, &'static str) {
    match owner.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => (
            sha256_hex(&format!("{provider}:global:{namespace}:{value}")),
            "global",
        ),
        None => (sha256_hex(&format!("{provider}:source")), "source"),
    }
}

pub fn api_key_identity(provider: &str, api_key: &str) -> (String, &'static str) {
    let key_hash = sha256_hex(api_key);
    account_identity(provider, "api_key", Some(&key_hash))
}

pub fn sha256_hex(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    hex_lower(&hasher.finalize())
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

pub fn mask_secret(label: &str, secret: &str) -> String {
    let secret = secret.trim();
    if secret.chars().count() <= 8 {
        return format!("{label} key");
    }
    let visible = secret
        .chars()
        .rev()
        .take(4)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    format!("{label} ···{visible}")
}

pub fn mask_email(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    let (local, domain) = value.split_once('@')?;
    if local.is_empty() || domain.is_empty() {
        return None;
    }
    Some(format!(
        "{}***@{}",
        local.chars().take(2).collect::<String>(),
        domain
    ))
}

pub fn mask_display_name(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() {
        return None;
    }
    if value.contains('@') {
        return mask_email(Some(value));
    }
    let chars: Vec<char> = value.chars().collect();
    Some(if chars.len() <= 2 {
        format!("{}*", chars.first().copied().unwrap_or('*'))
    } else {
        format!("{}***", chars.iter().take(2).collect::<String>())
    })
}

pub fn string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

pub fn number(value: Option<&Value>) -> Option<f64> {
    match value {
        Some(Value::Number(number)) => number.as_f64().filter(|value| value.is_finite()),
        Some(Value::String(value)) if !value.trim().is_empty() => value
            .trim()
            .parse::<f64>()
            .ok()
            .filter(|value| value.is_finite()),
        _ => None,
    }
}

pub fn clamp_percent(value: f64) -> f64 {
    if !value.is_finite() {
        0.0
    } else {
        value.clamp(0.0, 100.0)
    }
}

pub fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

pub fn unix_seconds_to_iso(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let remainder = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        remainder / 3600,
        (remainder % 3600) / 60,
        remainder % 60
    )
}

pub fn parse_date(value: Option<&Value>) -> Option<i64> {
    match value {
        Some(Value::Number(number)) => number.as_f64().and_then(parse_numeric_date),
        Some(Value::String(value)) => {
            let value = value.trim();
            if value.is_empty() {
                return None;
            }
            if let Ok(number) = value.parse::<f64>() {
                return parse_numeric_date(number);
            }
            parse_rfc3339(value)
        }
        _ => None,
    }
}

fn parse_numeric_date(value: f64) -> Option<i64> {
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    Some(if value > 10_000_000_000.0 {
        (value / 1000.0).floor() as i64
    } else {
        value.floor() as i64
    })
}

fn parse_rfc3339(value: &str) -> Option<i64> {
    let (date, time_and_zone) = value.split_once('T').or_else(|| value.split_once(' '))?;
    let mut date_parts = date.split('-');
    let year: i32 = date_parts.next()?.parse().ok()?;
    let month: u32 = date_parts.next()?.parse().ok()?;
    let day: u32 = date_parts.next()?.parse().ok()?;
    let (time, offset) = if let Some(time) = time_and_zone.strip_suffix('Z') {
        (time, 0i64)
    } else {
        let marker = time_and_zone.rfind(['+', '-'])?;
        let (time, zone) = time_and_zone.split_at(marker);
        let sign = if zone.starts_with('-') { -1 } else { 1 };
        let mut parts = zone[1..].split(':');
        let hours: i64 = parts.next()?.parse().ok()?;
        let minutes: i64 = parts.next().unwrap_or("0").parse().ok()?;
        (time, sign * (hours * 3600 + minutes * 60))
    };
    let mut time_parts = time.split(':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let second = time_parts.next()?.split('.').next()?.parse::<i64>().ok()?;
    if month == 0 || month > 12 || day == 0 || day > 31 || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset)
}

fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let year = year - i32::from(month <= 2);
    let era = (year as i64).div_euclid(400);
    let year_of_era = year as i64 - era * 400;
    let month = month as i64;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day as i64 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }).div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_part = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_part + 2) / 5 + 1;
    let month = month_part + if month_part < 10 { 3 } else { -9 };
    (
        year as i32 + i32::from(month <= 2),
        month as u32,
        day as u32,
    )
}

pub fn duration_seconds(start: Option<i64>, end: Option<i64>) -> Option<u64> {
    let seconds = end?.checked_sub(start?)?;
    (seconds >= 0).then_some(seconds as u64)
}

pub fn provider_source(provider: &str) -> &'static str {
    match provider {
        "openrouter" => "openrouter_api",
        "deepseek" => "deepseek_balance_api",
        "kimi" => "kimi_code_usages_api",
        "litellm" => "litellm_budget_api",
        "codex" => "chatgpt_usage_api",
        "claude" => "anthropic_oauth_usage_api",
        "grok" => "grok_billing_api",
        _ => "provider",
    }
}

pub fn obj_get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.as_object()?.get(key)
}

pub fn obj_get_any<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| obj_get(value, key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::Ordering;

    fn temp_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("quota-provider-{name}-{}", uuid::Uuid::new_v4()))
    }

    fn context_with_config(path: PathBuf, environment: &[(&str, &str)]) -> CollectionContext {
        CollectionContext {
            home_directory: temp_path("home"),
            environment: environment
                .iter()
                .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
                .collect(),
            config_path: Some(path),
            browser_sessions: HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
        }
    }

    fn write_config(path: &Path, contents: &str) {
        if let Some(parent) = path.parent()
            && !parent.exists()
        {
            fs::create_dir_all(parent).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).unwrap();
            }
        }
        fs::write(path, contents).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
    }

    #[test]
    fn config_precedes_environment_and_fixed_urls_ignore_stale_values() {
        let path = temp_path("config/providers.json");
        write_config(
            &path,
            r#"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-config","base_url":"https://old.invalid/v1"}}}"#,
        );
        let context = context_with_config(path.clone(), &[("OPENROUTER_API_KEY", "sk-env")]);
        let credentials = resolve_api_key(&context, ProviderId::OpenRouter).unwrap();
        assert_eq!(credentials.api_key, "sk-config");
        assert_eq!(credentials.source, "config:openrouter");
        assert_eq!(credentials.base_url, "https://openrouter.ai/api/v1");
        assert!(!credentials.label.contains("sk-config"));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn base_url_environment_is_not_used_as_an_api_key() {
        let path = temp_path("config/providers.json");
        let context =
            context_with_config(path, &[("LITELLM_BASE_URL", "https://proxy.example.test")]);
        let error = resolve_api_key(&context, ProviderId::LiteLlm).unwrap_err();
        assert_eq!(error.category, ErrorCategory::AuthRequired);
    }

    #[test]
    fn rejects_invalid_config_entries_and_falls_back_to_environment() {
        let path = temp_path("config/providers.json");
        write_config(
            &path,
            r#"{"schema_version":1,"providers":{"not-a-provider":{"api_key":"secret"}}}"#,
        );
        let context = context_with_config(path.clone(), &[("OPENROUTER_API_KEY", "sk-env")]);
        let credentials = resolve_api_key(&context, ProviderId::OpenRouter).unwrap();
        assert_eq!(credentials.api_key, "sk-env");
        assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn rejects_empty_or_null_saved_base_urls_instead_of_using_them() {
        for base_url in ["\"\"", "null"] {
            let path = temp_path("config/providers.json");
            write_config(
                &path,
                &format!(
                    "{{\"schema_version\":1,\"providers\":{{\"litellm\":{{\"api_key\":\"sk-config\",\"base_url\":{base_url}}}}}}}"
                ),
            );
            let context = context_with_config(
                path.clone(),
                &[
                    ("LITELLM_API_KEY", "sk-env"),
                    ("LITELLM_BASE_URL", "https://proxy.example.test"),
                ],
            );
            let credentials = resolve_api_key(&context, ProviderId::LiteLlm).unwrap();
            assert_eq!(credentials.api_key, "sk-env");
            let _ = fs::remove_file(path);
        }
    }

    #[test]
    fn identity_and_redaction_are_stable_and_non_secret() {
        let first = account_identity("grok", "user_id", Some("owner"));
        let second = account_identity("grok", "user_id", Some("owner"));
        assert_eq!(first, second);
        assert_eq!(first.0.len(), 64);
        assert_eq!(first.1, "global");
        assert_ne!(
            first.0,
            account_identity("grok", "team_id", Some("owner")).0
        );
        assert_eq!(
            mask_email(Some("ada@example.com")).as_deref(),
            Some("ad***@example.com")
        );
        assert_eq!(
            mask_display_name(Some("Ada Lovelace")).as_deref(),
            Some("Ad***")
        );
        assert_eq!(mask_secret("API", "opaque-secret"), "API ···cret");
        assert_eq!(mask_secret("API", "short"), "API key");
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
    fn classifies_provider_http_statuses_without_response_details() {
        assert_eq!(http_category(401), ErrorCategory::AuthRequired);
        assert_eq!(http_category(403), ErrorCategory::AuthRequired);
        assert_eq!(http_category(404), ErrorCategory::Unsupported);
        assert_eq!(http_category(429), ErrorCategory::Unavailable);
        assert_eq!(http_category(500), ErrorCategory::Unavailable);
        assert_eq!(http_category(400), ErrorCategory::Error);
        let error = ProviderError::new(ErrorCategory::AuthRequired, "fixture");
        assert!(!error.to_string().contains("opaque-secret"));
    }

    #[test]
    fn normalizes_urls_without_query_credentials_or_public_http() {
        assert_eq!(
            validate_base_url("proxy.example.test/v1/?ignored=1", false).unwrap(),
            "https://proxy.example.test/v1"
        );
        assert!(validate_base_url("https://user:secret@example.test", false).is_err());
        assert!(validate_base_url("http://example.test", true).is_err());
        assert_eq!(
            validate_base_url("http://127.0.0.1:4000/v1", true).unwrap(),
            "http://127.0.0.1:4000/v1"
        );
    }

    #[test]
    fn bounded_command_stops_on_timeout_and_cancellation() {
        #[cfg(unix)]
        {
            let command = {
                let mut command = Command::new("/bin/sh");
                command.args(["-c", "while :; do :; done"]);
                command
            };
            assert!(run_bounded_command(command, Duration::from_millis(100), None, 1024).is_none());

            let cancelled = Arc::new(AtomicBool::new(true));
            let command = {
                let mut command = Command::new("/bin/sh");
                command.args(["-c", "while :; do :; done"]);
                command
            };
            assert!(
                run_bounded_command(command, Duration::from_secs(1), Some(&cancelled), 1024)
                    .is_none()
            );
            assert!(cancelled.load(Ordering::Acquire));
        }
    }

    #[test]
    fn executable_resolution_requires_execute_permission() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let path = temp_path("provider-cli");
            fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            assert!(!is_executable_file(&path));
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            assert!(is_executable_file(&path));
            let _ = fs::remove_file(path);
        }
    }

    #[test]
    fn bounded_credentials_reject_symlinks_and_oversized_files() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let target = temp_path("credential-target");
            let link = temp_path("credential-link");
            fs::write(&target, b"small").unwrap();
            symlink(&target, &link).unwrap();
            assert!(read_bounded_file(&link, 1024).is_none());

            let oversized = temp_path("credential-oversized");
            fs::write(&oversized, vec![b'x'; 1025]).unwrap();
            assert!(read_bounded_file(&oversized, 1024).is_none());
            let _ = fs::remove_file(target);
            let _ = fs::remove_file(link);
            let _ = fs::remove_file(oversized);
        }
    }

    #[test]
    fn config_reader_rejects_symlink_oversized_and_permissive_files() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::{PermissionsExt, symlink};
            let environment = [("OPENROUTER_API_KEY", "sk-env")];

            let config_root = temp_path("config-root");
            fs::create_dir_all(&config_root).unwrap();
            fs::set_permissions(&config_root, fs::Permissions::from_mode(0o700)).unwrap();
            let target = config_root.join("target");
            write_config(
                &target,
                r#"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-config"}}}"#,
            );
            let link = config_root.join("link");
            symlink(&target, &link).unwrap();
            let context = context_with_config(link.clone(), &environment);
            let credentials = resolve_api_key(&context, ProviderId::OpenRouter).unwrap();
            assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");

            let oversized = temp_path("config-oversized");
            write_config(&oversized, &"x".repeat(LOCAL_FILE_LIMIT + 1));
            let credentials = resolve_api_key(
                &context_with_config(oversized.clone(), &environment),
                ProviderId::OpenRouter,
            )
            .unwrap();
            assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");

            let permissive = temp_path("config-permissive");
            write_config(
                &permissive,
                r#"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-config"}}}"#,
            );
            fs::set_permissions(&permissive, fs::Permissions::from_mode(0o644)).unwrap();
            let credentials = resolve_api_key(
                &context_with_config(permissive.clone(), &environment),
                ProviderId::OpenRouter,
            )
            .unwrap();
            assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");

            let _ = fs::remove_file(target);
            let _ = fs::remove_file(link);
            let _ = fs::remove_file(oversized);
            let _ = fs::remove_file(permissive);
            let _ = fs::remove_dir_all(config_root);
        }
    }

    #[test]
    fn bounded_http_body_rejects_streams_without_content_length() {
        use std::io::Read as _;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
                .unwrap();
            let chunk = [b'x'; 8192];
            for _ in 0..((HTTP_BODY_LIMIT / chunk.len()) + 2) {
                if stream.write_all(&chunk).is_err() {
                    break;
                }
            }
        });
        let client = HttpClient::new().unwrap();
        let error = client
            .get_json(&format!("http://{address}"), &[], "fixture")
            .unwrap_err();
        assert_eq!(error.category, ErrorCategory::Error);
        server.join().unwrap();
    }

    #[test]
    fn non_json_auth_errors_keep_status_classification_and_redact_body() {
        use std::io::Read as _;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 512];
            let _ = stream.read(&mut request);
            let body = b"<html>provider secret diagnostics</html>";
            let header = format!(
                "HTTP/1.1 401 Unauthorized\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(header.as_bytes()).unwrap();
            let _ = stream.write_all(body);
        });
        let client = HttpClient::new().unwrap();
        let error = client
            .get_json(&format!("http://{address}"), &[], "fixture")
            .unwrap_err();
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        assert!(!error.to_string().contains("provider secret diagnostics"));
        server.join().unwrap();
    }
}
