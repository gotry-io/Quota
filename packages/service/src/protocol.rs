//! The private QuotaBar/service protocol.
//!
//! This is intentionally a small, versioned protocol.  Network protocol-v2 payloads are carried
//! as JSON values in component state; they remain owned by the provider/usage/pricing modules and
//! are validated before they cross this boundary.

use std::collections::BTreeMap;
use std::str::FromStr;

use chrono::NaiveDate;
use chrono_tz::Tz;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;

pub const IPC_VERSION: u32 = 5;
pub const MAXIMUM_LINE_BYTES: usize = 1_048_576;
pub const MAXIMUM_REQUEST_ID_BYTES: usize = 128;
/// Fixed Quota collection intervals, in seconds. Automatic is the default mode; five minutes is
/// the fixed interval an identity holds until someone picks another.
pub const QUOTA_REFRESH_INTERVALS_SECONDS: [u64; 5] = [60, 120, 300, 600, 900];
pub const DEFAULT_QUOTA_REFRESH_INTERVAL_SECONDS: u64 = 300;
/// How many local days one `usage_period` request may fold, which is a year and a leap day.
pub const MAXIMUM_USAGE_PERIOD_DAYS: i64 = 366;
/// How often a signed-in helper asks Relay for an Account summary without collecting quota.
pub const ACCOUNT_SYNC_INTERVAL_SECONDS: u64 = 60;
/// How often the helper polls each catalog status page. Failures keep the last reading.
pub const PROVIDER_STATUS_INTERVAL_SECONDS: u64 = 600;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Ping,
    GetState,
    Diagnose,
    RecheckDiagnostics,
    Refresh,
    ResetCache,
    UsagePeriod,
    QuotaHistory,
    Login,
    CancelLogin,
    Logout,
    SetUsageUpload,
    SetAccountSettings,
    RefreshAccountSettings,
    SetGroupUsageByProject,
    SetQuotaRefreshInterval,
    SetOverviewSourcePin,
    SetProviderConfig,
    RemoveProviderConfig,
    ValidateProviderBrowserSession,
    SetProviderBrowserScan,
    ReplaceProviderBrowserSessions,
    Shutdown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ComponentName {
    Quota,
    Usage,
    Account,
    Pricing,
    Providers,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ComponentStatus {
    Ready,
    Stale,
    AuthRequired,
    Unavailable,
    Error,
    SignedOut,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthStatus {
    SignedOut,
    LoggingIn,
    SignedIn,
    LogoutPending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidRequest,
    UnsupportedOperation,
    InvalidState,
    ClientUpgradeRequired,
    Busy,
    Cancelled,
    AuthenticationRequired,
    DeviceDeleted,
    StaleGeneration,
    Unavailable,
    ProviderError,
    NetworkError,
    InvalidResponse,
    Internal,
}

impl ErrorCode {
    pub const fn requires_login(self) -> bool {
        matches!(
            self,
            Self::AuthenticationRequired | Self::DeviceDeleted | Self::StaleGeneration
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryAction {
    None,
    Retry,
    Login,
    ConfigureProvider,
    Upgrade,
    Reinstall,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct IpcError {
    pub code: ErrorCode,
    pub recovery_action: RecoveryAction,
}

impl IpcError {
    pub const fn new(code: ErrorCode, recovery_action: RecoveryAction) -> Self {
        Self {
            code,
            recovery_action,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IpcRequest {
    #[serde(rename = "type")]
    pub message_type: RequestMessageType,
    pub request_id: String,
    pub operation: Operation,
    pub payload: Value,
}

impl IpcRequest {
    pub fn decode_payload<T: DeserializeOwned>(&self) -> Result<T, IpcError> {
        if self.request_id.is_empty()
            || self.request_id.len() > MAXIMUM_REQUEST_ID_BYTES
            || !self
                .request_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
        {
            return Err(IpcError::new(
                ErrorCode::InvalidRequest,
                RecoveryAction::None,
            ));
        }
        serde_json::from_value(self.payload.clone())
            .map_err(|_| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestMessageType {
    Request,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct IpcResponse {
    #[serde(rename = "type")]
    pub message_type: ResponseMessageType,
    pub request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<IpcError>,
}

impl IpcResponse {
    pub fn result<T: Serialize>(request_id: &str, value: &T) -> Self {
        Self {
            message_type: ResponseMessageType::Response,
            request_id: request_id.to_owned(),
            result: serde_json::to_value(value).ok(),
            error: None,
        }
    }

    pub fn error(request_id: &str, error: IpcError) -> Self {
        Self {
            message_type: ResponseMessageType::Response,
            request_id: request_id.to_owned(),
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResponseMessageType {
    Response,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct IpcEvent {
    #[serde(rename = "type")]
    pub message_type: EventMessageType,
    pub event: EventName,
    pub revision: u64,
    pub changed_components: Vec<ComponentName>,
}

impl IpcEvent {
    pub fn state_changed(revision: u64, changed_components: Vec<ComponentName>) -> Self {
        Self {
            message_type: EventMessageType::Event,
            event: EventName::StateChanged,
            revision,
            changed_components,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EventMessageType {
    Event,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EventName {
    Ready,
    StateChanged,
}

/// Announces that the helper finished opening its local state and will now read requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct IpcReadyEvent {
    #[serde(rename = "type")]
    pub message_type: EventMessageType,
    pub event: EventName,
    pub ipc_version: u32,
}

impl IpcReadyEvent {
    pub const fn ready() -> Self {
        Self {
            message_type: EventMessageType::Event,
            event: EventName::Ready,
            ipc_version: IPC_VERSION,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmptyPayload {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageSource {
    Local,
    Account,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsagePeriod {
    Today,
    Last7Days,
    Last30Days,
    All,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderPayload {
    pub provider: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetProviderConfigPayload {
    pub provider: String,
    pub api_key: String,
    #[serde(default)]
    pub base_url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderBrowserSessionPayload {
    pub provider: String,
    pub cookie_header: String,
}

/// Why macOS handed the client nothing when it opened a browser's cookie store.
///
/// The reason is a closed set, not prose: the store's path and the underlying error's text
/// stay on the client's side of the boundary, because neither belongs in a report a person
/// copies out of the app.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserAccessDenialReason {
    /// Safari keeps its cookies where only an app with Full Disk Access may look.
    FullDiskAccess,
    /// A Chrome-family store is sealed with a Keychain item macOS would not release.
    KeychainRefused,
    /// The store is there, and could not be opened or parsed.
    StoreUnreadable,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderBrowserAccessDenial {
    /// The browser's display name. Never a profile name or a store path.
    pub browser: String,
    pub reason: BrowserAccessDenialReason,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetProviderBrowserScanPayload {
    pub provider: String,
    pub enabled: bool,
}

/// Replaces every stored browser session for one provider with the cookies this scan produced.
///
/// Access denials are recorded beside them: a refused store is not an absent session.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReplaceProviderBrowserSessionsPayload {
    pub provider: String,
    #[serde(default)]
    pub cookie_headers: Vec<String>,
    #[serde(default)]
    pub access_denials: Vec<ProviderBrowserAccessDenial>,
}

/// The custom period a Usage page asks this device to fold, as two inclusive local dates.
///
/// `get_state` carries the four periods every panel opens on. Anything else — a week, a month,
/// a range someone picked — is asked for one range at a time rather than folded four more times
/// on every refresh. `source` chooses This Mac's hours or Relay's Account period read; Account
/// also names the caller's IANA timezone. There is no alias for a request that omits `source`.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UsagePeriodPayload {
    pub from: String,
    pub to: String,
    pub source: UsageSource,
    #[serde(default)]
    pub timezone: Option<String>,
}

impl UsagePeriodPayload {
    /// Inclusive local dates, at most a year and a leap day. Account requires a real IANA zone.
    pub fn validate(&self) -> Result<(), IpcError> {
        let invalid = || IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None);
        let first = NaiveDate::parse_from_str(&self.from, "%Y-%m-%d").map_err(|_| invalid())?;
        let last = NaiveDate::parse_from_str(&self.to, "%Y-%m-%d").map_err(|_| invalid())?;
        let days = (last - first).num_days();
        if !(0..MAXIMUM_USAGE_PERIOD_DAYS).contains(&days) {
            return Err(invalid());
        }
        if self.source == UsageSource::Account {
            let timezone = self
                .timezone
                .as_deref()
                .filter(|value| !value.is_empty())
                .ok_or_else(invalid)?;
            if !valid_iana_timezone(timezone) {
                return Err(invalid());
            }
        }
        Ok(())
    }
}

fn valid_iana_timezone(value: &str) -> bool {
    if value.is_empty() || value.len() > 64 {
        return false;
    }
    let mut start = 0;
    loop {
        let rest = &value[start..];
        let end = rest.find('/').unwrap_or(rest.len());
        let label = &rest[..end];
        if label.is_empty()
            || !label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._+-".contains(&byte))
        {
            return false;
        }
        if end == rest.len() {
            break;
        }
        start += end + 1;
    }
    Tz::from_str(value).is_ok()
}

/// Where `quota_history` reads. Omitted means this Mac, so a caller that predates the field is
/// unchanged. `ipc_version` still moves, because `get_state` gains `history_sync`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaHistorySource {
    #[default]
    Local,
    Account,
}

/// The start of the sample range Dashboard asks this device to read, as one RFC 3339 instant.
///
/// `get_state` restates only the current window Overview already draws. Thirty days of every
/// window is asked for here rather than folded onto every state push (ADR 0051). `source:
/// account` names one global-scope subscription; Relay already merged it.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaHistoryPayload {
    pub since: String,
    #[serde(default)]
    pub source: QuotaHistorySource,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub fingerprint: Option<String>,
}

impl QuotaHistoryPayload {
    pub fn validate(&self) -> Result<(), IpcError> {
        let invalid = || IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None);
        if self.since.len() > 64 || chrono::DateTime::parse_from_rfc3339(&self.since).is_err() {
            return Err(invalid());
        }
        if self.source != QuotaHistorySource::Account {
            return Ok(());
        }
        let provider = self.provider.as_deref().ok_or_else(invalid)?;
        let fingerprint = self.fingerprint.as_deref().ok_or_else(invalid)?;
        if crate::catalog::ProviderId::parse(provider).is_none() || !is_opaque_id(fingerprint) {
            return Err(invalid());
        }
        Ok(())
    }
}

/// One stored reading of one window, as `quota_history` returns it.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct QuotaHistorySample {
    pub resets_at: String,
    pub observed_at: String,
    pub used_percent: f64,
}

/// This Mac's stored quota samples since `since`, plus the offset that places them in the
/// reader's day. The holder of the samples folds them (ADR 0042). Samples are keyed by the
/// local subscription selector, not by provider, so two accounts of one provider stay apart.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct QuotaHistoryResult {
    pub samples_by_subscription: BTreeMap<String, BTreeMap<String, Vec<QuotaHistorySample>>>,
    pub utc_offset_seconds: i32,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetUsageUploadPayload {
    pub enabled: bool,
}

/// The stored Account settings document as QuotaBar writes it: policy only, no envelope.
///
/// Relay assigns `revision` and `updated_at`. The helper adds `protocol_version` on the PUT.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AccountSettingsWriteDocument {
    pub alerts: AccountSettingsAlerts,
    pub budget: AccountSettingsBudget,
    /// Present only when this write names the switch. Absent means unchanged, not off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history: Option<AccountSettingsHistory>,
}

/// The Account history switch. Serialised only when a write names it.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AccountSettingsHistory {
    pub sync: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AccountSettingsAlerts {
    pub reset_reminders: bool,
    pub pace_alerts: bool,
    pub thresholds: BTreeMap<String, Vec<i64>>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AccountSettingsBudget {
    pub amount_usd: Option<String>,
    pub alerts: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetAccountSettingsPayload {
    pub document: AccountSettingsWriteDocument,
    pub if_match: String,
}

impl SetAccountSettingsPayload {
    pub fn validate(&self) -> Result<(), IpcError> {
        let invalid = || IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None);
        if self.if_match.is_empty()
            || self.if_match.len() > 64
            || self.if_match.trim() != self.if_match
            || self.if_match.chars().any(|ch| ch.is_control())
        {
            return Err(invalid());
        }
        self.document.validate()
    }
}

impl AccountSettingsWriteDocument {
    pub fn validate(&self) -> Result<(), IpcError> {
        let invalid = || IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None);
        if self.alerts.thresholds.len() > 256 {
            return Err(invalid());
        }
        for (selector, thresholds) in &self.alerts.thresholds {
            if !is_account_settings_selector(selector)
                || thresholds.is_empty()
                || thresholds.len() > 2
            {
                return Err(invalid());
            }
            let mut previous: Option<i64> = None;
            for value in thresholds {
                if !(1..=99).contains(value) || previous.is_some_and(|prior| *value >= prior) {
                    return Err(invalid());
                }
                previous = Some(*value);
            }
        }
        if let Some(amount) = &self.budget.amount_usd
            && !valid_budget_amount_usd(amount)
        {
            return Err(invalid());
        }
        Ok(())
    }
}

fn is_opaque_id(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.len() <= 128
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

fn is_account_settings_selector(value: &str) -> bool {
    value.len() == 12
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn valid_budget_amount_usd(value: &str) -> bool {
    let (whole, fraction) = match value.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (value, None),
    };
    if whole.is_empty() || whole.len() > 7 || !whole.bytes().all(|byte| byte.is_ascii_digit()) {
        return false;
    }
    if let Some(fraction) = fraction
        && (fraction.is_empty()
            || fraction.len() > 2
            || !fraction.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return false;
    }
    value
        .parse::<f64>()
        .ok()
        .is_some_and(|amount| amount > 0.0 && amount <= 1_000_000.0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountSettingsWriteOutcome {
    Written,
    Conflict,
}

/// What `set_account_settings` answers: the document Relay now holds, and whether this write
/// landed or must be re-applied onto it.
#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AccountSettingsMutationResult {
    pub outcome: AccountSettingsWriteOutcome,
    pub document: Value,
    pub revision: u64,
}

/// The Account settings document as `get_state` pushes it. Absent when signed out, and until
/// the first successful read for this Account.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AccountSettingsState {
    pub document: Value,
    pub revision: u64,
}

/// What Settings says under the history switch: whether it is on, and the last upload.
///
/// Present on `get_state` only while signed in. `last_error` is null, or one of
/// `history_sync_off`, `quota_history_full`, `network`, `invalid_response`,
/// `authentication_required`.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HistorySyncState {
    pub enabled: bool,
    pub last_upload_at: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetGroupUsageByProjectPayload {
    pub enabled: bool,
}

/// How this Mac paces provider collection (ADR 0063).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaRefreshMode {
    /// Each provider on its own tier, from local agent activity and remaining quota.
    Automatic,
    /// Every provider on `quota_refresh_interval_seconds`.
    Fixed,
}

impl QuotaRefreshMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Automatic => "automatic",
            Self::Fixed => "fixed",
        }
    }
}

/// `{"mode": "automatic"}`, or `{"mode": "fixed", "interval_seconds": <one of the intervals>}`.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetQuotaRefreshIntervalPayload {
    pub mode: QuotaRefreshMode,
    #[serde(default)]
    pub interval_seconds: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaRefreshTier {
    Active,
    Normal,
    Idle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaRefreshTierReason {
    /// The provider's local agent wrote its logs in the last five minutes.
    AgentActive,
    /// A window of the provider's last reading has less than 20 % left.
    LowRemaining,
}

/// What Automatic is doing now: the fastest tier among the providers this Mac collects.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaRefreshTierHint {
    pub tier: QuotaRefreshTier,
    pub interval_seconds: u64,
    pub provider: String,
    /// Present only for `active`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<QuotaRefreshTierReason>,
}

/// Pin Overview to one reporting source for a subscription, or clear the pin (Automatic).
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetOverviewSourcePinPayload {
    pub provider: String,
    pub fingerprint: String,
    pub scope: String,
    #[serde(default)]
    pub identity_source_id: Option<String>,
    /// `None` restores Automatic. A named id must already be a source on the current overview item.
    #[serde(default)]
    pub pin: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct OverviewSourcePinSetting {
    pub identity_key: String,
    pub pin: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RefreshResult {
    pub accepted: bool,
    pub pending: bool,
    pub revision: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EmptyResult {}

/// Liveness answer.  It carries no state, because the point is that the helper could answer.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PingResult {
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LoginResult {
    pub status: AuthStatus,
    pub account_id: Option<String>,
    pub device_id: Option<String>,
    pub device_generation: Option<u64>,
    /// Authorize URL the app opens. The service owns PKCE, the loopback listener, and the
    /// exchange; it never launches a browser. Absent on `cancel_login`.
    pub authorize_url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LogoutResult {
    pub status: AuthStatus,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct UsageUploadSetting {
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GroupUsageByProjectSetting {
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaRefreshIntervalSetting {
    pub mode: QuotaRefreshMode,
    pub interval_seconds: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderConfigView {
    pub provider: String,
    pub configured: bool,
    pub masked_api_key: Option<String>,
    pub base_url: Option<String>,
}

/// Last-good official status-page reading for one catalog provider.
///
/// This is a field of the `providers` component, not a sixth component: it is public JSON
/// about the provider, last-good on failure, and emitted on the same `providers` change
/// event configuration already uses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderStatusView {
    pub provider: String,
    pub indicator: String,
    pub description: String,
    pub checked_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderBrowserSessionView {
    pub provider: String,
    pub configured: bool,
    pub account_fingerprint: Option<String>,
    pub account_label: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderBrowserScanSetting {
    pub provider: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderBrowserSessionCandidate {
    pub provider: String,
    pub account_fingerprint: String,
    pub account_label: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ComponentState {
    pub status: ComponentStatus,
    pub value: Option<Value>,
    pub updated_at: Option<String>,
    pub last_error: Option<IpcError>,
    pub refreshing: bool,
}

/// What this device knows about the Account it is signed in to.
///
/// `display_label` is what the sign-in itself said the Account is called. It is separate from
/// `account_summary` because the summary is a whole Account read — devices, subscriptions, four
/// Usage periods, two catalog revisions — and none of that is known at the instant a session is
/// issued. Naming the account is, so it is stated on its own rather than as a summary with
/// invented fields.
#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AccountComponentValue {
    pub auth_status: AuthStatus,
    pub account_id: Option<String>,
    pub display_label: Option<String>,
    pub device_id: Option<String>,
    pub device_generation: Option<u64>,
    pub account_summary: Option<Value>,
}

/// OAuth, Device control, Account metadata, and the catalogs.
pub const CONTROL_PROTOCOL: i64 = 2;

/// The managed-data protocol this build uploads to and reads from Relay.
///
/// The private local Usage and quota collection reports name no version of their own: they only
/// ever travel nested inside a `StateSnapshot` that carries `ipc_version`, and both ends of that
/// pipe ship in the same build.
pub const MANAGED_DATA_PROTOCOL: i64 = 6;

#[derive(Debug, Clone, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaOverviewIdentity {
    pub provider: String,
    pub fingerprint: String,
    pub scope: String,
    pub source_id: Option<String>,
}

impl QuotaOverviewIdentity {
    /// The local opaque key both Apple clients already compute as `SubscriptionSelector`.
    ///
    /// First 12 lowercase hex characters of SHA-256 of
    /// `provider|fingerprint|scope|source_id`, with an empty source id when the subscription
    /// is global. It never leaves the device: quota samples stay in `cache.sqlite` (ADR 0042).
    pub fn selector(&self) -> String {
        Self::selector_for(
            &self.provider,
            &self.fingerprint,
            &self.scope,
            self.source_id.as_deref(),
        )
    }

    pub fn selector_for(
        provider: &str,
        fingerprint: &str,
        scope: &str,
        source_id: Option<&str>,
    ) -> String {
        use sha2::{Digest, Sha256};
        use std::fmt::Write;
        let preimage = format!(
            "{}|{}|{}|{}",
            provider,
            fingerprint,
            scope,
            source_id.unwrap_or("")
        );
        let digest = Sha256::digest(preimage.as_bytes());
        let mut hex = String::with_capacity(12);
        for byte in digest.iter().take(6) {
            let _ = write!(hex, "{byte:02x}");
        }
        hex
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaOverviewSource {
    pub source_id: String,
    pub kind: String,
    pub device_id: Option<String>,
    pub display_name: String,
    pub observed_at: String,
    pub is_stale: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaOverviewItem {
    pub identity: QuotaOverviewIdentity,
    pub snapshot: Value,
    pub sources: Vec<QuotaOverviewSource>,
    pub selected_source_id: String,
    pub selected_source_display_name: String,
    pub automatic_source_id: String,
    pub automatic_source_display_name: String,
    pub is_stale: bool,
    /// Set when this Mac pinned a source; absent means Automatic.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_pin: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct StateSnapshot {
    pub ipc_version: u32,
    pub revision: u64,
    pub usage_upload_enabled: bool,
    pub group_usage_by_project: bool,
    pub quota_refresh_mode: QuotaRefreshMode,
    pub quota_refresh_interval_seconds: u64,
    /// Present only in Automatic, once the scheduler has judged the providers it collects.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quota_refresh_tier: Option<QuotaRefreshTierHint>,
    pub usage_periods: UsagePeriodCache,
    pub quota: ComponentState,
    pub usage: ComponentState,
    pub account: ComponentState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_settings: Option<AccountSettingsState>,
    /// Absent when signed out. Not null.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history_sync: Option<HistorySyncState>,
    pub pricing: ComponentState,
    pub providers: Vec<ProviderConfigView>,
    pub provider_status: Vec<ProviderStatusView>,
    pub provider_browser_sessions: Vec<ProviderBrowserSessionView>,
    pub browser_scan_enabled: Vec<String>,
    pub overview: Vec<QuotaOverviewItem>,
    pub cache: CacheState,
}

/// What a reader is told about the disposable half of local state.
///
/// `rebuilding` means the cache was thrown away and this device has not yet completed one full
/// Usage scan, so local history is still filling in. `reset_at` is when that happened.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CacheState {
    pub rebuilding: bool,
    pub reset_at: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(deny_unknown_fields)]
pub struct UsagePeriodCache {
    pub local: UsagePeriodValues,
    pub account: UsagePeriodValues,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(deny_unknown_fields)]
pub struct UsagePeriodValues {
    pub today: Option<Value>,
    pub last_7_days: Option<Value>,
    pub last_30_days: Option<Value>,
    pub all: Option<Value>,
}

impl UsagePeriodValues {
    pub fn set(&mut self, period: UsagePeriod, value: Value) {
        match period {
            UsagePeriod::Today => self.today = Some(value),
            UsagePeriod::Last7Days => self.last_7_days = Some(value),
            UsagePeriod::Last30Days => self.last_30_days = Some(value),
            UsagePeriod::All => self.all = Some(value),
        }
    }
}

/// How well the product as a whole is working right now.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticOperation {
    Healthy,
    Degraded,
    Blocked,
}

/// Who, if anyone, has to do something.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticAttention {
    None,
    Automatic,
    Required,
}

/// One surface or one collection source, in the four states either can be in.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticStatus {
    Ok,
    Degraded,
    Blocked,
    Inactive,
}

/// What the retained data behind a surface is worth.  Nothing is ever "unknown": a surface the
/// service could not evaluate is `empty` and `blocked`.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticDataState {
    Current,
    Stale,
    Partial,
    Empty,
}

/// The machine-readable half of a message.  The sentence a person reads is `message`; this is
/// only for grouping and for deciding which affordance to offer.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticRecovery {
    None,
    Automatic,
    Retry,
    Login,
    ConfigureProvider,
    UpdateSource,
    CheckAccess,
    Reinstall,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticClient {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticSummary {
    pub operation: DiagnosticOperation,
    pub attention: DiagnosticAttention,
}

/// One of the four things the product promises to show.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticSurface {
    pub id: String,
    pub status: DiagnosticStatus,
    pub data: DiagnosticDataState,
    pub last_success_at: Option<String>,
    pub message: String,
    pub recovery: DiagnosticRecovery,
}

/// One place a surface's data comes from: a provider on this Mac, a Usage agent, the account,
/// the upload path, the pricing catalog, or this device's own local state.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticSourceState {
    pub subject: String,
    pub source_id: Option<String>,
    pub status: DiagnosticStatus,
    pub last_attempt_at: Option<String>,
    pub last_success_at: Option<String>,
    pub code: Option<String>,
    pub message: String,
    pub recovery: DiagnosticRecovery,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticAttemptKind {
    Refresh,
    QuotaCollection,
    UsageScan,
    UsageUpload,
    QuotaUpload,
    AccountSync,
    PricingRefresh,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticAttemptTrigger {
    Manual,
    Scheduled,
    Startup,
    Recheck,
    SettingsChange,
    AccountChange,
    /// Another signed-in client asked the Account for a fresh reading (ADR 0063).
    Demand,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticAttemptOutcome {
    Running,
    Success,
    Partial,
    NoWork,
    Failed,
    Interrupted,
    Cancelled,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticAttemptCode {
    ProcessInterrupted,
    Cancelled,
    NoWork,
    AuthenticationRequired,
    NetworkError,
    Unavailable,
    InvalidResponse,
    InvalidState,
    ProviderError,
    AccessDenied,
    ClientUpgradeRequired,
    PartialSource,
    MalformedData,
    TruncatedActiveSource,
    DeviceDeleted,
    /// The provider answered 429. The reading before it stands; this Mac waits it out.
    RateLimited,
}

/// One completed or still-running piece of work, as the copied report lists it.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticAttempt {
    pub kind: DiagnosticAttemptKind,
    pub subject: Option<String>,
    pub started_at: String,
    pub duration_ms: Option<u64>,
    pub outcome: DiagnosticAttemptOutcome,
    pub code: Option<DiagnosticAttemptCode>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticReport {
    pub schema_version: u32,
    pub generated_at: String,
    pub client: DiagnosticClient,
    pub summary: DiagnosticSummary,
    pub surfaces: Vec<DiagnosticSurface>,
    pub sources: Vec<DiagnosticSourceState>,
    pub recent: Vec<DiagnosticAttempt>,
}

pub const DIAGNOSTIC_SCHEMA_VERSION: u32 = 3;
pub const MAXIMUM_DIAGNOSTIC_SOURCES: usize = 64;
pub const MAXIMUM_DIAGNOSTIC_RECENT: usize = 100;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_wire_is_snake_case_and_strict() {
        let request: IpcRequest = serde_json::from_str(
            r#"{"type":"request","request_id":"r1","operation":"refresh","payload":{}}"#,
        )
        .expect("valid request");
        let _: EmptyPayload = request.decode_payload().expect("valid payload");

        let request_with_extra = serde_json::from_str::<IpcRequest>(
            r#"{"type":"request","request_id":"r1","operation":"refresh","payload":{"extra":true}}"#,
        )
        .expect("request envelope remains valid");
        assert!(request_with_extra.decode_payload::<EmptyPayload>().is_err());
        assert!(request.decode_payload::<EmptyPayload>().is_ok());

        let browser_session = serde_json::from_str::<IpcRequest>(
            r#"{"type":"request","request_id":"r2","operation":"validate_provider_browser_session","payload":{"provider":"cursor","cookie_header":"wos-session=secret","source_path":"/private"}}"#,
        )
        .expect("browser-session request envelope");
        assert!(
            browser_session
                .decode_payload::<ProviderBrowserSessionPayload>()
                .is_err()
        );

        let history: IpcRequest = serde_json::from_str(
            r#"{"type":"request","request_id":"r3","operation":"quota_history","payload":{"since":"2026-08-17T09:30:00Z"}}"#,
        )
        .expect("quota_history request");
        let payload: QuotaHistoryPayload = history.decode_payload().expect("since");
        assert_eq!(payload.since, "2026-08-17T09:30:00Z");
        assert_eq!(payload.source, QuotaHistorySource::Local);
        assert!(payload.validate().is_ok());
        let history_extra = serde_json::from_str::<IpcRequest>(
            r#"{"type":"request","request_id":"r3","operation":"quota_history","payload":{"since":"2026-08-17T09:30:00Z","extra":true}}"#,
        )
        .expect("quota_history envelope remains valid");
        assert!(
            history_extra
                .decode_payload::<QuotaHistoryPayload>()
                .is_err()
        );
    }

    fn usage_period_request(payload: &str) -> IpcRequest {
        serde_json::from_str(&format!(
            r#"{{"type":"request","request_id":"r4","operation":"usage_period","payload":{payload}}}"#
        ))
        .expect("usage_period envelope")
    }

    #[test]
    fn usage_period_payload_requires_source_and_refuses_the_old_shape() {
        let old = usage_period_request(r#"{"from":"2026-08-01","to":"2026-08-03"}"#);
        assert!(old.decode_payload::<UsagePeriodPayload>().is_err());

        let local: UsagePeriodPayload =
            usage_period_request(r#"{"from":"2026-08-01","to":"2026-08-03","source":"local"}"#)
                .decode_payload()
                .expect("local");
        assert_eq!(local.source, UsageSource::Local);
        assert!(local.validate().is_ok());

        let account: UsagePeriodPayload = usage_period_request(
            r#"{"from":"2026-08-01","to":"2026-08-03","source":"account","timezone":"Asia/Singapore"}"#,
        )
        .decode_payload()
        .expect("account");
        assert_eq!(account.source, UsageSource::Account);
        assert_eq!(account.timezone.as_deref(), Some("Asia/Singapore"));
        assert!(account.validate().is_ok());
    }

    #[test]
    fn usage_period_payload_refuses_inverted_overwide_and_bad_account_timezone() {
        let inverted: UsagePeriodPayload =
            usage_period_request(r#"{"from":"2026-08-03","to":"2026-08-01","source":"local"}"#)
                .decode_payload()
                .expect("inverted dates still decode");
        assert_eq!(
            inverted.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );

        let overwide: UsagePeriodPayload =
            usage_period_request(r#"{"from":"2025-08-01","to":"2026-08-03","source":"local"}"#)
                .decode_payload()
                .expect("overwide dates still decode");
        assert_eq!(
            overwide.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );

        let missing_tz: UsagePeriodPayload =
            usage_period_request(r#"{"from":"2026-08-01","to":"2026-08-03","source":"account"}"#)
                .decode_payload()
                .expect("account without timezone still decodes");
        assert_eq!(
            missing_tz.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );

        let bad_tz: UsagePeriodPayload = usage_period_request(
            r#"{"from":"2026-08-01","to":"2026-08-03","source":"account","timezone":"Not/A/Zone"}"#,
        )
        .decode_payload()
        .expect("unknown timezone still decodes");
        assert_eq!(
            bad_tz.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );
    }
    #[test]
    fn response_and_event_have_expected_shape() {
        let response = serde_json::to_value(IpcResponse::result(
            "r1",
            &RefreshResult {
                accepted: true,
                pending: false,
                revision: 3,
            },
        ))
        .expect("response serializes");
        assert_eq!(response["type"], "response");
        assert_eq!(response["result"]["accepted"], true);

        let event = serde_json::to_value(IpcEvent::state_changed(
            3,
            vec![ComponentName::Quota, ComponentName::Account],
        ))
        .expect("event serializes");
        assert_eq!(event["type"], "event");
        assert_eq!(event["event"], "state_changed");
        assert_eq!(event["changed_components"][0], "quota");

        // QuotaBar decodes the recovery action by its snake_case name.
        let error = serde_json::to_value(IpcResponse::error(
            "r2",
            IpcError::new(
                ErrorCode::ClientUpgradeRequired,
                RecoveryAction::ConfigureProvider,
            ),
        ))
        .expect("error serializes");
        assert_eq!(error["type"], "response");
        assert_eq!(error["error"]["code"], "client_upgrade_required");
        assert_eq!(error["error"]["recovery_action"], "configure_provider");
    }

    fn set_account_settings_request(payload: &str) -> IpcRequest {
        serde_json::from_str(&format!(
            r#"{{"type":"request","request_id":"r5","operation":"set_account_settings","payload":{payload}}}"#
        ))
        .expect("set_account_settings envelope")
    }

    #[test]
    fn set_account_settings_payload_is_strict_and_refuses_broken_documents() {
        let valid = set_account_settings_request(
            r#"{"document":{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{"a1b2c3d4e5f6":[20,10]}},"budget":{"amount_usd":"250.00","alerts":true}},"if_match":"\"0\""}"#,
        );
        let payload: SetAccountSettingsPayload = valid.decode_payload().expect("payload");
        assert!(payload.validate().is_ok());
        assert_eq!(payload.if_match, "\"0\"");

        let extra = set_account_settings_request(
            r#"{"document":{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}},"budget":{"amount_usd":null,"alerts":true}},"if_match":"\"0\"","extra":true}"#,
        );
        assert!(extra.decode_payload::<SetAccountSettingsPayload>().is_err());

        let revision_on_document = set_account_settings_request(
            r#"{"document":{"revision":1,"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}},"budget":{"amount_usd":null,"alerts":true}},"if_match":"\"0\""}"#,
        );
        assert!(
            revision_on_document
                .decode_payload::<SetAccountSettingsPayload>()
                .is_err()
        );

        let empty_match: SetAccountSettingsPayload = set_account_settings_request(
            r#"{"document":{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}},"budget":{"amount_usd":null,"alerts":true}},"if_match":""}"#,
        )
        .decode_payload()
        .expect("empty if_match still decodes");
        assert_eq!(
            empty_match.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );

        let unsorted: SetAccountSettingsPayload = set_account_settings_request(
            r#"{"document":{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{"a1b2c3d4e5f6":[10,20]}},"budget":{"amount_usd":null,"alerts":true}},"if_match":"\"0\""}"#,
        )
        .decode_payload()
        .expect("unsorted thresholds still decode");
        assert_eq!(
            unsorted.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );

        let amount_zero: SetAccountSettingsPayload = set_account_settings_request(
            r#"{"document":{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}},"budget":{"amount_usd":"0","alerts":true}},"if_match":"\"0\""}"#,
        )
        .decode_payload()
        .expect("zero amount still decodes");
        assert_eq!(
            amount_zero.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );
    }

    #[test]
    fn quota_history_account_source_names_one_subscription_and_history_serialises_only_when_set() {
        let account: IpcRequest = serde_json::from_str(
            r#"{"type":"request","request_id":"r3","operation":"quota_history","payload":{"since":"2026-08-22T00:00:00Z","source":"account","provider":"codex","fingerprint":"account_test"}}"#,
        )
        .expect("account history");
        let payload: QuotaHistoryPayload = account.decode_payload().expect("payload");
        assert!(payload.validate().is_ok());
        let missing: QuotaHistoryPayload = serde_json::from_str::<IpcRequest>(
            r#"{"type":"request","request_id":"r3","operation":"quota_history","payload":{"since":"2026-08-22T00:00:00Z","source":"account"}}"#,
        )
        .expect("envelope")
        .decode_payload()
        .expect("decodes");
        assert_eq!(
            missing.validate().unwrap_err().code,
            ErrorCode::InvalidRequest
        );

        let bare: AccountSettingsWriteDocument = serde_json::from_str(
            r#"{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}},"budget":{"amount_usd":null,"alerts":true}}"#,
        )
        .expect("write");
        let bare_json = serde_json::to_value(&bare).expect("json");
        assert!(bare_json.get("history").is_none());
        let mut named = bare;
        named.history = Some(AccountSettingsHistory { sync: true });
        assert_eq!(
            serde_json::to_value(&named).expect("json")["history"]["sync"],
            true
        );
    }

    /// The local sample key is the same 12-character selector Quota iOS and QuotaBar already
    /// compute, so a row written here is the row those surfaces look up.
    #[test]
    fn subscription_selector_matches_the_apple_clients() {
        assert_eq!(
            QuotaOverviewIdentity::selector_for("codex", "account_test", "global", None),
            "ccfc96629357"
        );
        assert_eq!(
            QuotaOverviewIdentity::selector_for("grok", "fp-source", "source", Some("local")),
            "bf475adb085d"
        );
        assert_eq!(
            QuotaOverviewIdentity {
                provider: "codex".into(),
                fingerprint: "account_test".into(),
                scope: "global".into(),
                source_id: None,
            }
            .selector(),
            QuotaOverviewIdentity::selector_for("codex", "account_test", "global", Some(""))
        );
    }
}
