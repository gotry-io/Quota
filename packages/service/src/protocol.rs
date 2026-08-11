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
    GetState,
    Refresh,
    Login,
    CancelLogin,
    Logout,
    SetProviderConfig,
    RemoveProviderConfig,
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
    StateChanged,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmptyPayload {}

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
pub struct ProviderConfigView {
    pub provider: String,
    pub configured: bool,
    pub masked_api_key: Option<String>,
    pub base_url: Option<String>,
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
    pub quota: ComponentState,
    pub usage: ComponentState,
    pub account: ComponentState,
    pub pricing: ComponentState,
    pub providers: Vec<ProviderConfigView>,
    pub overview: Vec<QuotaOverviewItem>,
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
}
