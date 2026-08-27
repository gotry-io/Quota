//! The private QuotaBar/service protocol.
//!
//! This is intentionally a small, versioned protocol.  Network protocol-v2 payloads are carried
//! as JSON values in component state; they remain owned by the provider/usage/pricing modules and
//! are validated before they cross this boundary.

use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;

pub const IPC_VERSION: u32 = 1;
pub const MAXIMUM_LINE_BYTES: usize = 1_048_576;
pub const MAXIMUM_REQUEST_ID_BYTES: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Ping,
    GetState,
    Diagnose,
    RecheckDiagnostics,
    Refresh,
    ResetCache,
    Login,
    CancelLogin,
    Logout,
    SetUsageUpload,
    SetProviderConfig,
    RemoveProviderConfig,
    ValidateProviderBrowserSession,
    CommitProviderBrowserSession,
    RemoveProviderBrowserSession,
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
    Unsupported,
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

impl BrowserAccessDenialReason {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::FullDiskAccess => "full_disk_access",
            Self::KeychainRefused => "keychain_refused",
            Self::StoreUnreadable => "store_unreadable",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "full_disk_access" => Some(Self::FullDiskAccess),
            "keychain_refused" => Some(Self::KeychainRefused),
            "store_unreadable" => Some(Self::StoreUnreadable),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderBrowserAccessDenial {
    /// The browser's display name. Never a profile name or a store path.
    pub browser: String,
    pub reason: BrowserAccessDenialReason,
}

/// What one browser sign-in attempt produced.
///
/// A commit either stores the session a browser released, or records that the browser released
/// nothing because macOS refused the store. Both are answers to the same question, and only
/// the second is one the reader has to act on, so the two must not arrive as the same silence.
/// Exactly one of the two fields is present.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommitProviderBrowserSessionPayload {
    pub provider: String,
    #[serde(default)]
    pub cookie_header: Option<String>,
    #[serde(default)]
    pub access_denied: Option<ProviderBrowserAccessDenial>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetUsageUploadPayload {
    pub enabled: bool,
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
pub struct ProviderConfigView {
    pub provider: String,
    pub configured: bool,
    pub masked_api_key: Option<String>,
    pub base_url: Option<String>,
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

impl ComponentState {
    pub fn empty(status: ComponentStatus) -> Self {
        Self {
            status,
            value: None,
            updated_at: None,
            last_error: None,
            refreshing: false,
        }
    }
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

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaOverviewSource {
    pub source_id: String,
    pub kind: String,
    pub device_id: Option<String>,
    pub display_name: String,
    pub observed_at: String,
    pub is_stale: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaOverviewItem {
    pub identity: QuotaOverviewIdentity,
    pub snapshot: Value,
    pub sources: Vec<QuotaOverviewSource>,
    pub selected_source_id: String,
    pub selected_source_display_name: String,
    pub is_stale: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct StateSnapshot {
    pub ipc_version: u32,
    pub revision: u64,
    pub usage_upload_enabled: bool,
    pub usage_periods: UsagePeriodCache,
    pub quota: ComponentState,
    pub usage: ComponentState,
    pub account: ComponentState,
    pub pricing: ComponentState,
    pub providers: Vec<ProviderConfigView>,
    pub provider_browser_sessions: Vec<ProviderBrowserSessionView>,
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
    Upgrade,
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
    UploadDisabled,
    SignedOut,
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
    }

    #[test]
    fn the_cache_state_says_whether_local_history_is_still_filling_in() {
        let value = serde_json::to_value(CacheState {
            rebuilding: true,
            reset_at: Some("2026-08-25T01:00:00Z".into()),
        })
        .expect("serializes");
        assert_eq!(value["rebuilding"], true);
        assert_eq!(value["reset_at"], "2026-08-25T01:00:00Z");
        assert_eq!(
            serde_json::from_value::<CacheState>(value).expect("round trip"),
            CacheState {
                rebuilding: true,
                reset_at: Some("2026-08-25T01:00:00Z".into()),
            }
        );
        // A cache this device has never had to throw away says so with an absent instant, not
        // with a made-up one.
        assert_eq!(
            CacheState::default(),
            CacheState {
                rebuilding: false,
                reset_at: None
            }
        );
        assert!(
            serde_json::from_value::<CacheState>(serde_json::json!({
                "rebuilding": false,
                "reset_at": null,
                "seq": 1
            }))
            .is_err()
        );
    }
}
