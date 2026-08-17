//! The private QuotaBar/service protocol.
//!
//! This is intentionally a small, versioned protocol.  Network protocol-v2 payloads are carried
//! as JSON values in component state; they remain owned by the provider/usage/pricing modules and
//! are validated before they cross this boundary.

use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::collections::BTreeMap;

pub const IPC_VERSION: u32 = 1;
pub const MAXIMUM_LINE_BYTES: usize = 1_048_576;
pub const MAXIMUM_REQUEST_ID_BYTES: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    GetState,
    Diagnose,
    RecheckDiagnostics,
    Refresh,
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
    Repair,
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
    StateChanged,
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

#[derive(Debug, Clone, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AccountComponentValue {
    pub auth_status: AuthStatus,
    pub account_id: Option<String>,
    pub device_id: Option<String>,
    pub device_generation: Option<u64>,
    pub account_summary: Option<Value>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
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
    pub repair: RepairSession,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RepairStatus {
    Idle,
    Checking,
    Repairing,
    Stuck,
    Failed,
    Completed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RepairSeverity {
    None,
    Derived,
    Durable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RepairPhase {
    PreservingAccount,
    RebuildingStorage,
    ReindexingUsage,
    Verifying,
    RestoringLastGood,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RepairRecoveryAction {
    Retry,
    Reinstall,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RepairSession {
    pub status: RepairStatus,
    pub severity: RepairSeverity,
    pub phase: Option<RepairPhase>,
    pub title: Option<String>,
    pub guidance: Option<String>,
    pub activity: Option<String>,
    pub started_at: Option<String>,
    pub heartbeat_at: Option<String>,
    pub progress_current: Option<i64>,
    pub progress_total: Option<i64>,
    pub stuck: bool,
    pub blocks_quit: bool,
    pub recovery_action: Option<RepairRecoveryAction>,
}

impl RepairSession {
    pub const TITLE_MAX_CHARS: usize = 64;
    pub const GUIDANCE_MAX_CHARS: usize = 160;
    pub const ACTIVITY_MAX_CHARS: usize = 64;
    pub const PROGRESS_TOTAL_MAX: i64 = 1_000_000;

    pub fn idle() -> Self {
        Self {
            status: RepairStatus::Idle,
            severity: RepairSeverity::None,
            phase: None,
            title: None,
            guidance: None,
            activity: None,
            started_at: None,
            heartbeat_at: None,
            progress_current: None,
            progress_total: None,
            stuck: false,
            blocks_quit: false,
            recovery_action: None,
        }
    }

    pub fn is_valid(&self) -> bool {
        self.validation_error().is_none()
    }

    pub fn validation_error(&self) -> Option<&'static str> {
        if !text_field_ok(self.title.as_deref(), Self::TITLE_MAX_CHARS) {
            return Some("invalid repair title");
        }
        if !text_field_ok(self.guidance.as_deref(), Self::GUIDANCE_MAX_CHARS) {
            return Some("invalid repair guidance");
        }
        if !text_field_ok(self.activity.as_deref(), Self::ACTIVITY_MAX_CHARS) {
            return Some("invalid repair activity");
        }
        match (self.progress_current, self.progress_total) {
            (None, None) => {}
            (Some(current), Some(total))
                if (1..=Self::PROGRESS_TOTAL_MAX).contains(&total)
                    && current >= 0
                    && current <= total => {}
            _ => return Some("invalid repair progress"),
        }
        if self.blocks_quit
            && !(self.severity == RepairSeverity::Durable && self.status == RepairStatus::Repairing)
        {
            return Some("blocks_quit is only valid while durable repairing");
        }
        if self.status == RepairStatus::Idle {
            if self.severity != RepairSeverity::None
                || self.phase.is_some()
                || self.title.is_some()
                || self.guidance.is_some()
                || self.activity.is_some()
                || self.started_at.is_some()
                || self.heartbeat_at.is_some()
                || self.progress_current.is_some()
                || self.progress_total.is_some()
                || self.stuck
                || self.blocks_quit
                || self.recovery_action.is_some()
            {
                return Some("idle repair session must be empty");
            }
            return None;
        }
        if self.started_at.is_none() || self.heartbeat_at.is_none() {
            return Some("started_at and heartbeat_at are required while not idle");
        }
        if self.recovery_action.is_some()
            && !matches!(self.status, RepairStatus::Stuck | RepairStatus::Failed)
        {
            return Some("recovery_action is only valid when stuck or failed");
        }
        if self.stuck && !matches!(self.status, RepairStatus::Stuck | RepairStatus::Failed) {
            return Some("stuck is only valid when status is stuck or failed");
        }
        None
    }
}

fn text_field_ok(value: Option<&str>, max_chars: usize) -> bool {
    value.is_none_or(|text| {
        text.chars().count() <= max_chars && !text.chars().any(|ch| ch.is_control())
    })
}

impl<'de> Deserialize<'de> for RepairSession {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct RawRepairSession {
            status: RepairStatus,
            severity: RepairSeverity,
            phase: Option<RepairPhase>,
            title: Option<String>,
            guidance: Option<String>,
            activity: Option<String>,
            started_at: Option<String>,
            heartbeat_at: Option<String>,
            progress_current: Option<i64>,
            progress_total: Option<i64>,
            stuck: bool,
            blocks_quit: bool,
            recovery_action: Option<RepairRecoveryAction>,
        }

        let raw = RawRepairSession::deserialize(deserializer)?;
        let session = Self {
            status: raw.status,
            severity: raw.severity,
            phase: raw.phase,
            title: raw.title,
            guidance: raw.guidance,
            activity: raw.activity,
            started_at: raw.started_at,
            heartbeat_at: raw.heartbeat_at,
            progress_current: raw.progress_current,
            progress_total: raw.progress_total,
            stuck: raw.stuck,
            blocks_quit: raw.blocks_quit,
            recovery_action: raw.recovery_action,
        };
        if let Some(error) = session.validation_error() {
            return Err(serde::de::Error::custom(error));
        }
        Ok(session)
    }
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

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticOperation {
    Healthy,
    Degraded,
    Blocked,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticDataState {
    Current,
    Stale,
    Partial,
    Empty,
    Unknown,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticAttention {
    None,
    Automatic,
    Optional,
    Required,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticSummary {
    pub operation: DiagnosticOperation,
    pub data: DiagnosticDataState,
    pub attention: DiagnosticAttention,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticRefreshPhase {
    Idle,
    Running,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticRefresh {
    pub phase: DiagnosticRefreshPhase,
    pub revision: u64,
    pub as_of: String,
    pub started_at: Option<String>,
    pub next_due_at: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSource {
    ThisDevice,
    Account,
    System,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticMode {
    Inactive,
    Opportunistic,
    Required,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticImpact {
    None,
    Source,
    Surface,
    System,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticRecovery {
    None,
    Automatic,
    Login,
    ConfigureProvider,
    Retry,
    UpdateSource,
    CheckAccess,
    Upgrade,
    Reinstall,
    Feedback,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticClient {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticSurface {
    pub name: String,
    pub operation: DiagnosticOperation,
    pub data: DiagnosticDataState,
    pub source: Option<DiagnosticSource>,
    pub metrics: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticCheck {
    pub name: String,
    pub source: DiagnosticSource,
    pub subject: Option<String>,
    pub mode: DiagnosticMode,
    pub operation: DiagnosticOperation,
    pub data: DiagnosticDataState,
    pub last_attempt_at: Option<String>,
    pub last_success_at: Option<String>,
    pub metrics: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSeverity {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticFinding {
    pub component: String,
    pub source: DiagnosticSource,
    pub subject: Option<String>,
    pub code: String,
    pub severity: DiagnosticSeverity,
    pub impact: DiagnosticImpact,
    pub recovery: DiagnosticRecovery,
    pub count: i64,
    pub observed_at: String,
    pub message: String,
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
    DeviceHealthUpload,
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
    PartialSource,
    MalformedData,
    TruncatedActiveSource,
    InvalidUsageBatch,
    UnrepresentableHour,
    DeviceDeleted,
    UploadDisabled,
    SignedOut,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticAttempt {
    pub kind: DiagnosticAttemptKind,
    pub trigger: DiagnosticAttemptTrigger,
    pub source: DiagnosticSource,
    pub subject: Option<String>,
    pub mode: DiagnosticMode,
    pub started_at: String,
    pub completed_at: Option<String>,
    pub duration_ms: Option<u64>,
    pub outcome: DiagnosticAttemptOutcome,
    pub code: Option<DiagnosticAttemptCode>,
    pub recovery: DiagnosticRecovery,
    pub metrics: BTreeMap<String, i64>,
    pub start_revision: u64,
    pub end_revision: Option<u64>,
    pub parent_refresh_started_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticRecentActivity {
    pub attempts: Vec<DiagnosticAttempt>,
    pub history_truncated: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticReport {
    pub schema_version: u32,
    pub summary: DiagnosticSummary,
    pub refresh: DiagnosticRefresh,
    pub generated_at: String,
    pub client: DiagnosticClient,
    pub surfaces: Vec<DiagnosticSurface>,
    pub checks: Vec<DiagnosticCheck>,
    pub findings: Vec<DiagnosticFinding>,
    pub recent_activity: DiagnosticRecentActivity,
}

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
    fn repair_session_idle_and_repairing_round_trip() {
        let idle = serde_json::from_value::<RepairSession>(serde_json::json!({
            "status": "idle",
            "severity": "none",
            "phase": null,
            "title": null,
            "guidance": null,
            "activity": null,
            "started_at": null,
            "heartbeat_at": null,
            "progress_current": null,
            "progress_total": null,
            "stuck": false,
            "blocks_quit": false,
            "recovery_action": null
        }))
        .expect("idle session");
        assert_eq!(idle, RepairSession::idle());

        let repairing = serde_json::from_value::<RepairSession>(serde_json::json!({
            "status": "repairing",
            "severity": "derived",
            "phase": "reindexing_usage",
            "title": "Rebuilding Usage history",
            "guidance": "Quota and Account stay available. Usage history is catching up.",
            "activity": "Scanning local logs",
            "started_at": "2026-08-17T01:00:00Z",
            "heartbeat_at": "2026-08-17T01:00:14Z",
            "progress_current": 12,
            "progress_total": 40,
            "stuck": false,
            "blocks_quit": false,
            "recovery_action": null
        }))
        .expect("repairing session");
        assert_eq!(repairing.status, RepairStatus::Repairing);
        assert_eq!(repairing.severity, RepairSeverity::Derived);
        assert_eq!(repairing.progress_current, Some(12));
        assert_eq!(repairing.progress_total, Some(40));
        assert!(!repairing.blocks_quit);
    }

    #[test]
    fn repair_session_rejects_invalid_progress_and_unknown_fields() {
        assert!(
            serde_json::from_value::<RepairSession>(serde_json::json!({
                "status": "repairing",
                "severity": "durable",
                "phase": "preserving_account",
                "title": "Repairing local data",
                "guidance": "Keep QuotaBar open. You can close this menu.",
                "activity": "Copying account",
                "started_at": "2026-08-17T01:00:00Z",
                "heartbeat_at": "2026-08-17T01:00:14Z",
                "progress_current": 8,
                "progress_total": 4,
                "stuck": false,
                "blocks_quit": true,
                "recovery_action": null
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<RepairSession>(serde_json::json!({
                "status": "idle",
                "severity": "none",
                "phase": null,
                "title": null,
                "guidance": null,
                "activity": null,
                "started_at": null,
                "heartbeat_at": null,
                "progress_current": 0,
                "progress_total": null,
                "stuck": false,
                "blocks_quit": false,
                "recovery_action": null
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<RepairSession>(serde_json::json!({
                "status": "idle",
                "severity": "none",
                "phase": null,
                "title": null,
                "guidance": null,
                "activity": null,
                "started_at": null,
                "heartbeat_at": null,
                "progress_current": null,
                "progress_total": null,
                "stuck": false,
                "blocks_quit": false,
                "recovery_action": null,
                "seq": 1
            }))
            .is_err()
        );
    }
}
