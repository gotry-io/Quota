use std::sync::Arc;

use quota_service::config::default_state_root;
use quota_service::ipc::{JsonLineWriter, run_stdio, run_stdio_startup_error};
use quota_service::protocol::{ErrorCode, IpcError, RecoveryAction};
use quota_service::relay::{RelayClient, RelayError};
use quota_service::service::{LocalService, backend::NativeBackend};
use quota_service::state::{StateError, StateStore};

const QUOTABAR_VERSION: &str = match option_env!("QUOTABAR_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};

fn main() {
    let writer = JsonLineWriter::stdout();
    match build_service(writer.clone()) {
        Ok(service) => {
            let _ = run_stdio(service, writer);
        }
        Err(error) => {
            let _ = run_stdio_startup_error(writer, error);
        }
    }
}

fn build_service(writer: Arc<JsonLineWriter>) -> Result<LocalService, IpcError> {
    // QuotaBar owns this process. There is intentionally no daemonization, launch agent, CLI
    // parser, socket listener, or PATH lookup here. Initialization failures use only this fixed
    // recovery pair; paths and source errors never cross the IPC boundary.
    let root = default_state_root().ok_or_else(unavailable_startup_error)?;
    let state = Arc::new(StateStore::open(root).map_err(state_startup_error)?);
    let relay = Arc::new(RelayClient::new().map_err(relay_startup_error)?);
    let backend = Arc::new(NativeBackend::new(
        state.clone(),
        relay,
        "QuotaBar",
        QUOTABAR_VERSION,
    ));
    Ok(LocalService::new(state, writer, backend))
}

const fn unavailable_startup_error() -> IpcError {
    IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)
}

const fn invalid_state_startup_error() -> IpcError {
    IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall)
}

fn state_startup_error(error: StateError) -> IpcError {
    match error {
        StateError::Unavailable => IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
        StateError::ClientUpgradeRequired => {
            IpcError::new(ErrorCode::ClientUpgradeRequired, RecoveryAction::Upgrade)
        }
        StateError::InvalidState => invalid_state_startup_error(),
        StateError::Io(_) | StateError::Sql(_) | StateError::Json(_) => unavailable_startup_error(),
    }
}

fn relay_startup_error(_error: RelayError) -> IpcError {
    IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_state_errors_have_stable_recovery_actions() {
        assert_eq!(
            state_startup_error(StateError::Unavailable),
            IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)
        );
        assert_eq!(
            state_startup_error(StateError::ClientUpgradeRequired),
            IpcError::new(ErrorCode::ClientUpgradeRequired, RecoveryAction::Upgrade)
        );
        assert_eq!(
            state_startup_error(StateError::InvalidState),
            IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall)
        );
    }
}
