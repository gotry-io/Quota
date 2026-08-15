//! Request handling, refresh scheduling, and parent-lifetime shutdown.

pub mod backend;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use crate::protocol::*;
use crate::state::{
    DiagnosticAttemptCompletion, DiagnosticAttemptHandle, StateError, StateStore, now_rfc3339,
};
use serde_json::Value;

pub trait EventSink: Send + Sync {
    fn event(&self, event: IpcEvent);
}

#[derive(Debug, Clone)]
pub struct BackendError {
    pub error: IpcError,
}

impl BackendError {
    pub const fn unavailable() -> Self {
        Self {
            error: IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
        }
    }

    pub const fn cancelled() -> Self {
        Self {
            error: IpcError::new(ErrorCode::Cancelled, RecoveryAction::None),
        }
    }
}

#[derive(Debug, Clone)]
pub struct LoginOutcome {
    pub session: Value,
    pub account: AccountComponentValue,
}

#[derive(Debug)]
pub struct RefreshOutcome {
    pub quota: Result<Value, BackendError>,
    pub usage: Result<Value, BackendError>,
    pub account: Result<Value, BackendError>,
    pub pricing: Result<Value, BackendError>,
    pub overview: Option<Vec<QuotaOverviewItem>>,
}

/// Catalog is generated from the language-neutral provider JSON.  Keeping this policy at the
/// service boundary prevents arbitrary providers, ambient credentials, and private URLs from
/// being created through IPC.
pub fn validate_provider_config(provider: &str, base_url: Option<&str>) -> Result<(), IpcError> {
    let config = provider_credential_config(provider)?;
    if config.requires_base_url && base_url.is_none() {
        return Err(IpcError::new(
            ErrorCode::InvalidRequest,
            RecoveryAction::ConfigureProvider,
        ));
    }
    if !config.supports_base_url && base_url.is_some() {
        return Err(IpcError::new(
            ErrorCode::InvalidRequest,
            RecoveryAction::None,
        ));
    }
    if let Some(value) = base_url {
        validate_catalog_base_url(value, config.allow_private_http)?;
    }
    Ok(())
}

fn provider_credential_config(provider: &str) -> Result<crate::catalog::ApiKeyConfig, IpcError> {
    crate::catalog::ProviderId::parse(provider)
        .ok_or_else(|| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))?
        .metadata()
        .credential_config
        .ok_or_else(|| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::ConfigureProvider))
}

fn provider_mask_label(provider: &str) -> &'static str {
    provider_credential_config(provider)
        .map(|config| config.mask_label)
        .unwrap_or("API")
}

/// Adapter boundary for the provider, usage, pricing, and Relay implementations.  It lives here
/// so those modules can be developed independently without making the IPC layer know their types.
pub trait LocalBackend: Send + Sync {
    /// One refresh transaction.  Implementations may collect quota/Usage in parallel, but must
    /// order pricing/control, upload/outbox, account summary, and overview merging explicitly.
    fn refresh(&self, cancel: Arc<AtomicBool>) -> RefreshOutcome;
    fn diagnose(&self) -> Result<DiagnosticReport, BackendError>;
    fn complete_diagnostics(&self) -> Result<DiagnosticReport, BackendError> {
        self.diagnose()
    }
    fn publish_device_health(&self, _: &DiagnosticReport) -> Result<(), BackendError> {
        Ok(())
    }
    fn login(
        &self,
        installation_id: &str,
        cancel: Arc<AtomicBool>,
    ) -> Result<LoginOutcome, BackendError>;
    fn logout(&self, pending_session: &Value) -> Result<(), BackendError>;
    fn validate_provider_browser_session(
        &self,
        provider: crate::catalog::ProviderId,
        cookie_header: &str,
    ) -> Result<crate::providers::ValidatedBrowserSession, BackendError>;
}

#[cfg(test)]
struct UnavailableBackend;

#[cfg(test)]
impl LocalBackend for UnavailableBackend {
    fn refresh(&self, _: Arc<AtomicBool>) -> RefreshOutcome {
        let unavailable = || Err(BackendError::unavailable());
        RefreshOutcome {
            quota: unavailable(),
            usage: unavailable(),
            account: unavailable(),
            pricing: unavailable(),
            overview: None,
        }
    }
    fn diagnose(&self) -> Result<DiagnosticReport, BackendError> {
        Err(BackendError::unavailable())
    }
    fn login(&self, _: &str, _: Arc<AtomicBool>) -> Result<LoginOutcome, BackendError> {
        Err(BackendError::unavailable())
    }
    fn logout(&self, _: &Value) -> Result<(), BackendError> {
        Err(BackendError::unavailable())
    }
    fn validate_provider_browser_session(
        &self,
        _: crate::catalog::ProviderId,
        _: &str,
    ) -> Result<crate::providers::ValidatedBrowserSession, BackendError> {
        Err(BackendError::unavailable())
    }
}

struct RefreshState {
    active: Option<ActiveRefresh>,
    pending: bool,
    pending_trigger: Option<DiagnosticAttemptTrigger>,
}

struct ActiveRefresh {
    cancel: Arc<AtomicBool>,
    started_at: String,
}

struct LoginState {
    active: Option<Arc<AtomicBool>>,
}

struct ServiceInner {
    state: Arc<StateStore>,
    backend: Arc<dyn LocalBackend>,
    sink: Arc<dyn EventSink>,
    shutdown: AtomicBool,
    refresh: Mutex<RefreshState>,
    login: Mutex<LoginState>,
    scheduler_wakeup: Condvar,
    scheduler_signal: Mutex<bool>,
    #[cfg(test)]
    fail_next_refresh_spawn: AtomicBool,
}

#[derive(Clone)]
pub struct LocalService {
    inner: Arc<ServiceInner>,
}

impl LocalService {
    pub fn new(
        state: Arc<StateStore>,
        sink: Arc<dyn EventSink>,
        backend: Arc<dyn LocalBackend>,
    ) -> Self {
        Self {
            inner: Arc::new(ServiceInner {
                state,
                backend,
                sink,
                shutdown: AtomicBool::new(false),
                refresh: Mutex::new(RefreshState {
                    active: None,
                    pending: false,
                    pending_trigger: None,
                }),
                login: Mutex::new(LoginState { active: None }),
                scheduler_wakeup: Condvar::new(),
                scheduler_signal: Mutex::new(false),
                #[cfg(test)]
                fail_next_refresh_spawn: AtomicBool::new(false),
            }),
        }
    }

    pub fn start_scheduler(&self) {
        let service = self.clone();
        service.request_refresh_with_trigger(DiagnosticAttemptTrigger::Startup);
        thread::Builder::new()
            .name("quota-refresh-scheduler".to_owned())
            .spawn(move || {
                let interval = Duration::from_secs(300);
                loop {
                    let signal = service.inner.scheduler_signal.lock();
                    let Ok(signal) = signal else { break };
                    let Ok((mut signal, timeout)) = service
                        .inner
                        .scheduler_wakeup
                        .wait_timeout_while(signal, interval, |value| !*value)
                    else {
                        break;
                    };
                    if service.is_shutdown() {
                        break;
                    }
                    let should_refresh = timeout.timed_out() || *signal;
                    if should_refresh {
                        *signal = false;
                        drop(signal);
                        service.request_refresh_with_trigger(DiagnosticAttemptTrigger::Scheduled);
                    }
                }
            })
            .ok();
    }

    pub fn handle(&self, request: IpcRequest) -> IpcResponse {
        if request.request_id.is_empty() || request.request_id.len() > MAXIMUM_REQUEST_ID_BYTES {
            return IpcResponse::error(
                "invalid",
                IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None),
            );
        }
        if self.is_shutdown() && !matches!(request.operation, Operation::Shutdown) {
            return IpcResponse::error(
                &request.request_id,
                IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
            );
        }
        let result: Result<Value, IpcError> = match request.operation {
            Operation::GetState => self.get_state(&request).map(as_json),
            Operation::Diagnose => self.diagnose(&request).map(as_json),
            Operation::RecheckDiagnostics => self.recheck_diagnostics(&request).map(as_json),
            Operation::Refresh => self.refresh(&request).map(as_json),
            Operation::Login => self.login(&request).map(as_json),
            Operation::CancelLogin => self.cancel_login(&request).map(as_json),
            Operation::Logout => self.logout(&request).map(as_json),
            Operation::SetUsageUpload => self.set_usage_upload(&request).map(as_json),
            Operation::SetProviderConfig => self.set_provider_config(&request).map(as_json),
            Operation::RemoveProviderConfig => self.remove_provider_config(&request).map(as_json),
            Operation::ValidateProviderBrowserSession => self
                .validate_provider_browser_session(&request)
                .map(as_json),
            Operation::CommitProviderBrowserSession => {
                self.commit_provider_browser_session(&request).map(as_json)
            }
            Operation::RemoveProviderBrowserSession => {
                self.remove_provider_browser_session(&request).map(as_json)
            }
            Operation::Shutdown => self.shutdown_response(&request).map(as_json),
        };
        match result {
            Ok(value) => IpcResponse::result(&request.request_id, &value),
            Err(error) => IpcResponse::error(&request.request_id, error),
        }
    }

    pub fn is_shutdown(&self) -> bool {
        self.inner.shutdown.load(Ordering::Acquire)
    }

    pub fn shutdown(&self) {
        if self.inner.shutdown.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Ok(refresh) = self.inner.refresh.lock()
            && let Some(active) = &refresh.active
        {
            active.cancel.store(true, Ordering::Release);
        }
        if let Ok(login) = self.inner.login.lock()
            && let Some(cancel) = &login.active
        {
            cancel.store(true, Ordering::Release);
        }
        if let Ok(mut signal) = self.inner.scheduler_signal.lock() {
            *signal = true;
            self.inner.scheduler_wakeup.notify_all();
        }
    }

    fn get_state(&self, request: &IpcRequest) -> Result<StateSnapshot, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        self.inner.state.snapshot().map_err(state_error)
    }

    fn refresh(&self, request: &IpcRequest) -> Result<RefreshResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        Ok(self.request_refresh())
    }

    fn diagnose(&self, request: &IpcRequest) -> Result<DiagnosticReport, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        let mut report = self.inner.backend.diagnose().map_err(|error| error.error)?;
        if let Ok(refresh) = self.inner.refresh.lock()
            && let Some(active) = &refresh.active
        {
            report.refresh.phase = DiagnosticRefreshPhase::Running;
            report.refresh.started_at = Some(active.started_at.clone());
            report.refresh.next_due_at = None;
        }
        Ok(report)
    }

    fn recheck_diagnostics(&self, request: &IpcRequest) -> Result<RefreshResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        Ok(self.request_refresh_with_trigger(DiagnosticAttemptTrigger::Recheck))
    }

    fn login(&self, request: &IpcRequest) -> Result<LoginResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        if let Some(session) = self.inner.state.session_json().map_err(state_error)? {
            match session.get("status").and_then(Value::as_str) {
                Some("active") | Some("logout_pending") => {
                    return Err(IpcError::new(ErrorCode::Busy, RecoveryAction::Retry));
                }
                _ => {
                    return Err(IpcError::new(
                        ErrorCode::InvalidState,
                        RecoveryAction::Reinstall,
                    ));
                }
            }
        }
        let mut login = self
            .inner
            .login
            .lock()
            .map_err(|_| IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry))?;
        if login.active.is_some() {
            return Err(IpcError::new(ErrorCode::Busy, RecoveryAction::Retry));
        }
        let cancel = Arc::new(AtomicBool::new(false));
        login.active = Some(cancel.clone());
        drop(login);

        let current = self
            .inner
            .state
            .component(ComponentName::Account)
            .map_err(state_error)?;
        let account = account_value_from(current.as_ref(), AuthStatus::LoggingIn);
        self.update_component(
            ComponentName::Account,
            ComponentStatus::AuthRequired,
            Some(account_value_json(&account)),
            None,
            None,
            true,
        )?;
        let service = self.clone();
        if thread::Builder::new()
            .name("quota-login".to_owned())
            .spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    service.inner.backend.login(
                        &service.inner.state.installation_id().unwrap_or_default(),
                        cancel.clone(),
                    )
                }))
                .unwrap_or_else(|_| Err(BackendError::unavailable()));
                service.finish_login(result, cancel);
            })
            .is_err()
        {
            if let Ok(mut login) = self.inner.login.lock() {
                login.active = None;
            }
            return Err(IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry));
        }
        Ok(LoginResult {
            status: AuthStatus::LoggingIn,
            account_id: None,
            device_id: None,
            device_generation: None,
        })
    }

    fn cancel_login(&self, request: &IpcRequest) -> Result<LoginResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        let login = self
            .inner
            .login
            .lock()
            .map_err(|_| IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry))?;
        let Some(cancel) = &login.active else {
            return Ok(LoginResult {
                status: AuthStatus::SignedOut,
                account_id: None,
                device_id: None,
                device_generation: None,
            });
        };
        cancel.store(true, Ordering::Release);
        Ok(LoginResult {
            status: AuthStatus::LoggingIn,
            account_id: None,
            device_id: None,
            device_generation: None,
        })
    }

    fn logout(&self, request: &IpcRequest) -> Result<LogoutResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        if self
            .inner
            .login
            .lock()
            .map_err(|_| IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry))?
            .active
            .is_some()
        {
            return Err(IpcError::new(ErrorCode::Busy, RecoveryAction::Retry));
        }
        // Stop the current refresh before changing the durable session epoch. Collectors observe
        // this flag directly; account operations also re-check the epoch around every request, so
        // no later upload stage can start from the signed-out session.
        if let Ok(refresh) = self.inner.refresh.lock()
            && let Some(active) = &refresh.active
        {
            active.cancel.store(true, Ordering::Release);
        }
        let Some(session) = self.inner.state.session_json().map_err(state_error)? else {
            self.set_signed_out()?;
            let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::AccountChange);
            return Ok(LogoutResult {
                status: AuthStatus::SignedOut,
            });
        };
        let pending = if session.get("status").and_then(Value::as_str) == Some("logout_pending") {
            session
        } else {
            make_logout_pending(&session)
                .ok_or_else(|| IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall))?
        };
        if pending.get("status").and_then(Value::as_str) != Some("logout_pending") {
            return Err(IpcError::new(
                ErrorCode::InvalidState,
                RecoveryAction::Reinstall,
            ));
        }
        self.inner
            .state
            .write_session_json(&pending)
            .map_err(state_error)?;
        let pending = self
            .inner
            .state
            .session_json()
            .map_err(state_error)?
            .ok_or_else(|| IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry))?;
        let current = self
            .inner
            .state
            .component(ComponentName::Account)
            .map_err(state_error)?;
        let value = account_value_from(current.as_ref(), AuthStatus::LogoutPending);
        self.update_component(
            ComponentName::Account,
            ComponentStatus::Ready,
            Some(account_value_json(&value)),
            None,
            None,
            true,
        )?;
        self.spawn_logout_retry(pending);
        Ok(LogoutResult {
            status: AuthStatus::LogoutPending,
        })
    }

    fn set_provider_config(&self, request: &IpcRequest) -> Result<ProviderConfigView, IpcError> {
        let payload: SetProviderConfigPayload = request.decode_payload()?;
        validate_provider_config(&payload.provider, payload.base_url.as_deref())?;
        self.inner
            .state
            .set_provider_config(
                &payload.provider,
                &payload.api_key,
                payload.base_url.as_deref(),
            )
            .map_err(state_error)?;
        self.emit(vec![ComponentName::Providers]);
        let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::SettingsChange);
        let config = self
            .inner
            .state
            .provider_config(&payload.provider)
            .map_err(state_error)?;
        Ok(config_view(
            &payload.provider,
            config.as_ref(),
            provider_mask_label(&payload.provider),
        ))
    }

    fn set_usage_upload(&self, request: &IpcRequest) -> Result<UsageUploadSetting, IpcError> {
        let payload: SetUsageUploadPayload = request.decode_payload()?;
        self.inner
            .state
            .set_usage_upload_enabled(payload.enabled)
            .map_err(state_error)?;
        self.emit(vec![ComponentName::Usage]);
        let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::SettingsChange);
        Ok(UsageUploadSetting {
            enabled: payload.enabled,
        })
    }

    fn remove_provider_config(&self, request: &IpcRequest) -> Result<ProviderConfigView, IpcError> {
        let payload: ProviderPayload = request.decode_payload()?;
        provider_credential_config(&payload.provider)?;
        self.inner
            .state
            .remove_provider_config(&payload.provider)
            .map_err(state_error)?;
        self.emit(vec![ComponentName::Providers]);
        let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::SettingsChange);
        Ok(config_view(
            &payload.provider,
            None,
            provider_mask_label(&payload.provider),
        ))
    }

    fn validate_provider_browser_session(
        &self,
        request: &IpcRequest,
    ) -> Result<ProviderBrowserSessionCandidate, IpcError> {
        let (provider, validated) = self.validated_provider_browser_session(request)?;
        Ok(ProviderBrowserSessionCandidate {
            provider: provider.as_str().to_owned(),
            account_fingerprint: validated.account_fingerprint,
            account_label: validated.account_label,
        })
    }

    fn commit_provider_browser_session(
        &self,
        request: &IpcRequest,
    ) -> Result<ProviderBrowserSessionView, IpcError> {
        let (provider, validated) = self.validated_provider_browser_session(request)?;
        self.inner
            .state
            .set_provider_browser_session(
                provider.as_str(),
                &crate::state::ProviderBrowserSession {
                    cookie_header: validated.cookie_header,
                    account_fingerprint: validated.account_fingerprint.clone(),
                    account_label: validated.account_label.clone(),
                },
            )
            .map_err(state_error)?;
        self.emit(vec![ComponentName::Providers]);
        let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::SettingsChange);
        Ok(ProviderBrowserSessionView {
            provider: provider.as_str().to_owned(),
            configured: true,
            account_fingerprint: Some(validated.account_fingerprint),
            account_label: validated.account_label,
        })
    }

    fn validated_provider_browser_session(
        &self,
        request: &IpcRequest,
    ) -> Result<
        (
            crate::catalog::ProviderId,
            crate::providers::ValidatedBrowserSession,
        ),
        IpcError,
    > {
        let payload: ProviderBrowserSessionPayload = request.decode_payload()?;
        let provider = crate::catalog::ProviderId::parse(&payload.provider)
            .filter(|provider| provider.metadata().browser_session.is_some())
            .ok_or_else(|| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))?;
        let cookie_header = crate::providers::common::normalize_browser_cookie_header(
            provider,
            &payload.cookie_header,
        )
        .map_err(|_| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))?;
        let validated = self
            .inner
            .backend
            .validate_provider_browser_session(provider, &cookie_header)
            .map_err(|error| error.error)?;
        Ok((provider, validated))
    }

    fn remove_provider_browser_session(
        &self,
        request: &IpcRequest,
    ) -> Result<ProviderBrowserSessionView, IpcError> {
        let payload: ProviderPayload = request.decode_payload()?;
        let provider = crate::catalog::ProviderId::parse(&payload.provider)
            .filter(|provider| provider.metadata().browser_session.is_some())
            .ok_or_else(|| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))?;
        self.inner
            .state
            .remove_provider_browser_session(provider.as_str())
            .map_err(state_error)?;
        self.emit(vec![ComponentName::Providers]);
        let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::SettingsChange);
        Ok(ProviderBrowserSessionView {
            provider: provider.as_str().to_owned(),
            configured: false,
            account_fingerprint: None,
            account_label: None,
        })
    }

    fn shutdown_response(&self, request: &IpcRequest) -> Result<EmptyResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        self.shutdown();
        Ok(EmptyResult {})
    }

    fn request_refresh(&self) -> RefreshResult {
        self.request_refresh_with_trigger(DiagnosticAttemptTrigger::Manual)
    }

    fn request_refresh_with_trigger(&self, trigger: DiagnosticAttemptTrigger) -> RefreshResult {
        let mut refresh = match self.inner.refresh.lock() {
            Ok(refresh) => refresh,
            Err(_) => {
                return RefreshResult {
                    accepted: false,
                    pending: false,
                    revision: 0,
                };
            }
        };
        if refresh.active.is_some() {
            refresh.pending = true;
            refresh.pending_trigger = Some(trigger);
            return RefreshResult {
                accepted: false,
                pending: true,
                revision: self.inner.state.current_revision().unwrap_or(0),
            };
        }
        if self
            .inner
            .state
            .diagnostic_snapshot()
            .ok()
            .flatten()
            .is_none()
        {
            let _ = self.inner.backend.complete_diagnostics();
        }
        let cancel = Arc::new(AtomicBool::new(false));
        let attempt = self
            .inner
            .state
            .begin_diagnostic_attempt(
                DiagnosticAttemptKind::Refresh,
                trigger,
                DiagnosticSource::System,
                None,
                DiagnosticMode::Required,
                None,
            )
            .ok();
        refresh.active = Some(ActiveRefresh {
            cancel: cancel.clone(),
            started_at: now_rfc3339(),
        });
        drop(refresh);

        let components = [
            ComponentName::Quota,
            ComponentName::Usage,
            ComponentName::Account,
            ComponentName::Pricing,
        ];
        for component in components {
            let _ = self.inner.state.set_refreshing(component, true);
        }
        self.emit(components.to_vec());

        let service = self.clone();
        #[cfg(test)]
        let force_spawn_failure = self
            .inner
            .fail_next_refresh_spawn
            .swap(false, Ordering::AcqRel);
        #[cfg(not(test))]
        let force_spawn_failure = false;
        let spawned = !force_spawn_failure
            && thread::Builder::new()
                .name("quota-refresh".to_owned())
                .spawn(move || {
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        service.run_refresh(cancel, attempt);
                    }));
                    if result.is_err() {
                        let unavailable = || Err(BackendError::unavailable());
                        for (component, error) in [
                            (ComponentName::Quota, unavailable()),
                            (ComponentName::Usage, unavailable()),
                            (ComponentName::Account, unavailable()),
                            (ComponentName::Pricing, unavailable()),
                        ] {
                            service.apply_component_result(component, error);
                        }
                        if let Some(attempt) = attempt {
                            let _ = service
                                .inner
                                .state
                                .finish_diagnostic_attempt_with_interrupted_children(
                                    attempt,
                                    &DiagnosticAttemptCompletion {
                                        outcome: DiagnosticAttemptOutcome::Failed,
                                        code: Some(DiagnosticAttemptCode::Unavailable),
                                        recovery: DiagnosticRecovery::Retry,
                                        metrics: [("failed_components".to_owned(), 4)].into(),
                                    },
                                );
                        }
                    }
                    if let Ok(report) = service.inner.backend.complete_diagnostics() {
                        let _ = service.inner.backend.publish_device_health(&report);
                    }
                    let rerun = service
                        .inner
                        .refresh
                        .lock()
                        .map(|mut refresh| {
                            refresh.active = None;
                            let rerun = refresh.pending.then_some(
                                refresh
                                    .pending_trigger
                                    .take()
                                    .unwrap_or(DiagnosticAttemptTrigger::Scheduled),
                            );
                            refresh.pending = false;
                            rerun
                        })
                        .unwrap_or(None);
                    service.emit(vec![
                        ComponentName::Quota,
                        ComponentName::Usage,
                        ComponentName::Account,
                        ComponentName::Pricing,
                    ]);
                    if let Some(trigger) = rerun
                        && !service.is_shutdown()
                    {
                        let _ = service.request_refresh_with_trigger(trigger);
                    }
                })
                .is_ok();
        if !spawned {
            if let Some(attempt) = attempt {
                let _ = self.inner.state.finish_diagnostic_attempt(
                    attempt,
                    &DiagnosticAttemptCompletion {
                        outcome: DiagnosticAttemptOutcome::Failed,
                        code: Some(DiagnosticAttemptCode::Unavailable),
                        recovery: DiagnosticRecovery::Retry,
                        metrics: Default::default(),
                    },
                );
            }
            if let Ok(mut refresh) = self.inner.refresh.lock() {
                refresh.active = None;
            }
            for component in components {
                let _ = self.inner.state.set_refreshing(component, false);
            }
            return RefreshResult {
                accepted: false,
                pending: false,
                revision: self.inner.state.current_revision().unwrap_or(0),
            };
        }
        RefreshResult {
            accepted: true,
            pending: false,
            revision: self.inner.state.current_revision().unwrap_or(0),
        }
    }

    fn run_refresh(&self, cancel: Arc<AtomicBool>, attempt: Option<DiagnosticAttemptHandle>) {
        let outcome = if cancel.load(Ordering::Acquire) || self.is_shutdown() {
            let cancelled = || Err(BackendError::cancelled());
            RefreshOutcome {
                quota: cancelled(),
                usage: cancelled(),
                account: cancelled(),
                pricing: cancelled(),
                overview: None,
            }
        } else {
            self.inner.backend.refresh(cancel.clone())
        };
        let session_required = self
            .inner
            .state
            .session_json()
            .ok()
            .flatten()
            .is_some_and(|value| value.get("status").and_then(Value::as_str) == Some("active"));
        let completion = refresh_attempt_completion(&outcome, session_required, cancel.as_ref());
        self.apply_component_result(ComponentName::Quota, outcome.quota);
        self.apply_component_result(ComponentName::Usage, outcome.usage);
        let account_result = match self.inner.state.session_json().ok().flatten() {
            Some(session)
                if session.get("status").and_then(Value::as_str) == Some("logout_pending") =>
            {
                Err(BackendError {
                    error: IpcError::new(ErrorCode::AuthenticationRequired, RecoveryAction::Retry),
                })
            }
            _ => outcome.account,
        };
        self.apply_component_result(ComponentName::Account, account_result);
        self.apply_component_result(ComponentName::Pricing, outcome.pricing);
        if let Some(overview) = outcome.overview {
            let _ = self.inner.state.set_overview(&overview);
        }
        if let Some(attempt) = attempt {
            let _ = self
                .inner
                .state
                .finish_diagnostic_attempt_with_interrupted_children(attempt, &completion);
        }
    }

    fn apply_component_result(
        &self,
        component: ComponentName,
        result: Result<Value, BackendError>,
    ) {
        let current = self.inner.state.component(component).ok().flatten();
        match result {
            Ok(value) => {
                // Pricing refresh commits the catalog and ETag in one SQLite transaction inside
                // the backend. Do not immediately write the identical component a second time.
                if component == ComponentName::Pricing
                    && current.as_ref().is_some_and(|record| {
                        record.status == ComponentStatus::Ready
                            && record.value.as_ref() == Some(&value)
                            && record.last_error.is_none()
                            && !record.refreshing
                    })
                {
                    return;
                }
                let _ = self.update_component(
                    component,
                    ComponentStatus::Ready,
                    Some(value),
                    Some(now_rfc3339()),
                    None,
                    false,
                );
            }
            Err(error) => {
                let no_session = self.inner.state.session_json().ok().flatten().is_none();
                let retained_auth_failure = error.error.code.requires_login()
                    && component == ComponentName::Account
                    && no_session
                    && current.as_ref().is_some_and(|record| {
                        record
                            .value
                            .as_ref()
                            .and_then(|value| value.get("auth_status"))
                            .and_then(Value::as_str)
                            == Some("signed_in")
                            || record.last_error.as_ref().is_some_and(|previous| {
                                previous.code.requires_login()
                                    && previous.recovery_action == RecoveryAction::Login
                            })
                    });
                let status = match error.error.code {
                    ErrorCode::Cancelled => current
                        .as_ref()
                        .map(|value| value.status)
                        .unwrap_or(ComponentStatus::Unavailable),
                    code if code.requires_login()
                        && component == ComponentName::Account
                        && no_session =>
                    {
                        ComponentStatus::SignedOut
                    }
                    code if code.requires_login() => ComponentStatus::AuthRequired,
                    ErrorCode::NetworkError | ErrorCode::Unavailable | ErrorCode::ProviderError => {
                        if current.as_ref().is_some_and(|value| value.value.is_some()) {
                            ComponentStatus::Stale
                        } else {
                            ComponentStatus::Unavailable
                        }
                    }
                    ErrorCode::Busy => ComponentStatus::AuthRequired,
                    ErrorCode::InvalidResponse | ErrorCode::InvalidState | ErrorCode::Internal => {
                        ComponentStatus::Error
                    }
                    _ => ComponentStatus::Error,
                };
                let (previous_value, previous_updated_at) = if status == ComponentStatus::SignedOut
                    && component == ComponentName::Account
                {
                    (
                        Some(account_value_json(&AccountComponentValue {
                            auth_status: AuthStatus::SignedOut,
                            account_id: None,
                            device_id: None,
                            device_generation: None,
                            account_summary: None,
                        })),
                        Some(now_rfc3339()),
                    )
                } else {
                    (
                        current.as_ref().and_then(|value| value.value.clone()),
                        current.as_ref().and_then(|value| value.updated_at.clone()),
                    )
                };
                let last_error = if status == ComponentStatus::SignedOut && !retained_auth_failure {
                    None
                } else {
                    let previous_disconnect = current
                        .as_ref()
                        .and_then(|record| record.last_error.clone())
                        .filter(|previous| {
                            matches!(
                                previous.code,
                                ErrorCode::DeviceDeleted | ErrorCode::StaleGeneration
                            )
                        });
                    Some(if error.error.code == ErrorCode::AuthenticationRequired {
                        previous_disconnect.unwrap_or(error.error)
                    } else {
                        error.error
                    })
                };
                let _ = self.update_component(
                    component,
                    status,
                    previous_value,
                    previous_updated_at,
                    last_error,
                    false,
                );
            }
        }
    }

    fn finish_login(&self, result: Result<LoginOutcome, BackendError>, cancel: Arc<AtomicBool>) {
        match result {
            Ok(outcome) => {
                if cancel.load(Ordering::Acquire) {
                    // The browser exchange may finish concurrently with CancelLogin.  Never drop
                    // newly issued refresh tokens: persist a durable revoke job and retry it via
                    // the same logout-pending path used after network failures.
                    if let Some(pending) = make_logout_pending(&outcome.session) {
                        let _ = self.inner.state.write_session_json(&pending);
                        let current = self
                            .inner
                            .state
                            .component(ComponentName::Account)
                            .ok()
                            .flatten();
                        let value = account_value_from(current.as_ref(), AuthStatus::LogoutPending);
                        let _ = self.update_component(
                            ComponentName::Account,
                            ComponentStatus::AuthRequired,
                            Some(account_value_json(&value)),
                            None,
                            Some(IpcError::new(ErrorCode::Cancelled, RecoveryAction::None)),
                            false,
                        );
                        self.spawn_logout_retry(pending);
                        self.emit(vec![ComponentName::Account]);
                    } else {
                        let _ = self.set_signed_out();
                    }
                    self.clear_login_active();
                    return;
                }
                if self
                    .inner
                    .state
                    .write_session_json(&outcome.session)
                    .is_err()
                {
                    if let Some(pending) = make_logout_pending(&outcome.session)
                        && self.inner.state.write_session_json(&pending).is_ok()
                    {
                        let pending = self
                            .inner
                            .state
                            .session_json()
                            .ok()
                            .flatten()
                            .unwrap_or(pending);
                        let current = self
                            .inner
                            .state
                            .component(ComponentName::Account)
                            .ok()
                            .flatten();
                        let value = account_value_from(current.as_ref(), AuthStatus::LogoutPending);
                        let _ = self.update_component(
                            ComponentName::Account,
                            ComponentStatus::AuthRequired,
                            Some(account_value_json(&value)),
                            None,
                            Some(IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)),
                            false,
                        );
                        self.spawn_logout_retry(pending);
                        self.emit(vec![ComponentName::Account]);
                        self.clear_login_active();
                        return;
                    }
                    let _ = self.update_component(
                        ComponentName::Account,
                        ComponentStatus::Error,
                        None,
                        None,
                        Some(IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)),
                        false,
                    );
                    self.emit(vec![ComponentName::Account]);
                    self.clear_login_active();
                    return;
                }
                if cancel.load(Ordering::Acquire) {
                    if let Some(pending) = make_logout_pending(&outcome.session) {
                        let _ = self.inner.state.write_session_json(&pending);
                        let current = self
                            .inner
                            .state
                            .component(ComponentName::Account)
                            .ok()
                            .flatten();
                        let value = account_value_from(current.as_ref(), AuthStatus::LogoutPending);
                        let _ = self.update_component(
                            ComponentName::Account,
                            ComponentStatus::AuthRequired,
                            Some(account_value_json(&value)),
                            None,
                            Some(IpcError::new(ErrorCode::Cancelled, RecoveryAction::None)),
                            false,
                        );
                        self.spawn_logout_retry(pending);
                        self.emit(vec![ComponentName::Account]);
                    } else {
                        let _ = self.set_signed_out();
                    }
                    self.clear_login_active();
                    return;
                }
                let _ = self.update_component(
                    ComponentName::Account,
                    ComponentStatus::Ready,
                    Some(account_value_json(&outcome.account)),
                    Some(now_rfc3339()),
                    None,
                    false,
                );
                self.emit(vec![ComponentName::Account]);
                let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::AccountChange);
            }
            Err(error) => {
                if let Some(pending) =
                    self.inner
                        .state
                        .session_json()
                        .ok()
                        .flatten()
                        .filter(|session| {
                            session.get("status").and_then(Value::as_str) == Some("logout_pending")
                        })
                {
                    let current = self
                        .inner
                        .state
                        .component(ComponentName::Account)
                        .ok()
                        .flatten();
                    let value = account_value_from(current.as_ref(), AuthStatus::LogoutPending);
                    let _ = self.update_component(
                        ComponentName::Account,
                        ComponentStatus::AuthRequired,
                        Some(account_value_json(&value)),
                        None,
                        Some(error.error),
                        false,
                    );
                    self.spawn_logout_retry(pending);
                    self.emit(vec![ComponentName::Account]);
                    self.clear_login_active();
                    return;
                }
                let _ = self.update_component(
                    ComponentName::Account,
                    if error.error.code == ErrorCode::Cancelled {
                        ComponentStatus::SignedOut
                    } else {
                        ComponentStatus::Error
                    },
                    Some(account_value_json(&AccountComponentValue {
                        auth_status: AuthStatus::SignedOut,
                        account_id: None,
                        device_id: None,
                        device_generation: None,
                        account_summary: None,
                    })),
                    None,
                    Some(error.error),
                    false,
                );
                self.emit(vec![ComponentName::Account]);
            }
        }
        self.clear_login_active();
    }

    fn clear_login_active(&self) {
        if let Ok(mut login) = self.inner.login.lock() {
            login.active = None;
        }
    }

    fn spawn_logout_retry(&self, pending: Value) {
        let service = self.clone();
        let _ = thread::Builder::new()
            .name("quota-logout-retry".to_owned())
            .spawn(move || {
                let expected_epoch = service
                    .inner
                    .state
                    .session_snapshot()
                    .ok()
                    .flatten()
                    .and_then(|(session, epoch)| {
                        (session.get("status").and_then(Value::as_str) == Some("logout_pending"))
                            .then_some(epoch)
                    });
                let result = service.inner.backend.logout(&pending);
                service.finish_logout(result, expected_epoch);
            });
    }

    fn finish_logout(&self, result: Result<(), BackendError>, expected_epoch: Option<u64>) {
        match result {
            Ok(()) => {
                if expected_epoch
                    .and_then(|epoch| self.inner.state.clear_session_if_epoch(epoch).ok())
                    .unwrap_or(false)
                {
                    let _ = self.set_signed_out();
                    let _ =
                        self.request_refresh_with_trigger(DiagnosticAttemptTrigger::AccountChange);
                }
            }
            Err(error) => {
                let _ = self.update_component(
                    ComponentName::Account,
                    ComponentStatus::Error,
                    self.inner
                        .state
                        .component(ComponentName::Account)
                        .ok()
                        .flatten()
                        .and_then(|v| v.value),
                    None,
                    Some(error.error),
                    false,
                );
            }
        }
    }

    fn set_signed_out(&self) -> Result<(), IpcError> {
        let value = AccountComponentValue {
            auth_status: AuthStatus::SignedOut,
            account_id: None,
            device_id: None,
            device_generation: None,
            account_summary: None,
        };
        self.update_component(
            ComponentName::Account,
            ComponentStatus::SignedOut,
            Some(account_value_json(&value)),
            Some(now_rfc3339()),
            None,
            false,
        )?;
        self.emit(vec![ComponentName::Account]);
        Ok(())
    }

    fn update_component(
        &self,
        component: ComponentName,
        status: ComponentStatus,
        value: Option<Value>,
        updated_at: Option<String>,
        error: Option<IpcError>,
        refreshing: bool,
    ) -> Result<u64, IpcError> {
        self.inner
            .state
            .set_component(component, status, value, updated_at, error, refreshing)
            .map_err(state_error)
    }

    fn emit(&self, components: Vec<ComponentName>) {
        let revision = self.inner.state.current_revision().unwrap_or(0);
        self.inner
            .sink
            .event(IpcEvent::state_changed(revision, components));
    }
}

fn refresh_attempt_completion(
    outcome: &RefreshOutcome,
    account_required: bool,
    cancel: &AtomicBool,
) -> DiagnosticAttemptCompletion {
    let mut errors = [&outcome.quota, &outcome.usage, &outcome.pricing]
        .into_iter()
        .filter_map(|result| result.as_ref().err())
        .collect::<Vec<_>>();
    if account_required && let Err(error) = &outcome.account {
        errors.push(error);
    }
    let cancelled = cancel.load(Ordering::Acquire)
        || errors
            .iter()
            .any(|error| error.error.code == ErrorCode::Cancelled);
    let (outcome, code, recovery) = if cancelled {
        (
            DiagnosticAttemptOutcome::Cancelled,
            Some(DiagnosticAttemptCode::Cancelled),
            DiagnosticRecovery::None,
        )
    } else if let Some(error) = errors.first() {
        (
            DiagnosticAttemptOutcome::Failed,
            Some(diagnostic_attempt_code(error.error.code)),
            diagnostic_recovery(error.error.recovery_action),
        )
    } else {
        (
            DiagnosticAttemptOutcome::Success,
            None,
            DiagnosticRecovery::None,
        )
    };
    DiagnosticAttemptCompletion {
        outcome,
        code,
        recovery,
        metrics: [("failed_components".to_owned(), errors.len() as i64)].into(),
    }
}

fn diagnostic_attempt_code(code: ErrorCode) -> DiagnosticAttemptCode {
    match code {
        ErrorCode::Cancelled => DiagnosticAttemptCode::Cancelled,
        ErrorCode::AuthenticationRequired | ErrorCode::StaleGeneration => {
            DiagnosticAttemptCode::AuthenticationRequired
        }
        ErrorCode::DeviceDeleted => DiagnosticAttemptCode::DeviceDeleted,
        ErrorCode::NetworkError => DiagnosticAttemptCode::NetworkError,
        ErrorCode::InvalidResponse => DiagnosticAttemptCode::InvalidResponse,
        ErrorCode::InvalidState | ErrorCode::ClientUpgradeRequired => {
            DiagnosticAttemptCode::InvalidState
        }
        ErrorCode::ProviderError => DiagnosticAttemptCode::ProviderError,
        ErrorCode::InvalidRequest
        | ErrorCode::UnsupportedOperation
        | ErrorCode::Busy
        | ErrorCode::Unavailable
        | ErrorCode::Internal => DiagnosticAttemptCode::Unavailable,
    }
}

fn diagnostic_recovery(recovery: RecoveryAction) -> DiagnosticRecovery {
    match recovery {
        RecoveryAction::None => DiagnosticRecovery::None,
        RecoveryAction::Retry => DiagnosticRecovery::Retry,
        RecoveryAction::Login => DiagnosticRecovery::Login,
        RecoveryAction::ConfigureProvider => DiagnosticRecovery::ConfigureProvider,
        RecoveryAction::Upgrade => DiagnosticRecovery::Upgrade,
        RecoveryAction::Reinstall => DiagnosticRecovery::Reinstall,
    }
}

fn as_json<T: serde::Serialize>(value: T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

fn state_error(error: StateError) -> IpcError {
    match error {
        StateError::ClientUpgradeRequired => {
            IpcError::new(ErrorCode::ClientUpgradeRequired, RecoveryAction::Upgrade)
        }
        StateError::InvalidState => {
            IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall)
        }
        StateError::Unavailable | StateError::Io(_) | StateError::Sql(_) | StateError::Json(_) => {
            IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)
        }
    }
}

fn account_value_from(
    current: Option<&crate::state::ComponentRecord>,
    status: AuthStatus,
) -> AccountComponentValue {
    let Some(value) = current.and_then(|record| record.value.as_ref()) else {
        return AccountComponentValue {
            auth_status: status,
            account_id: None,
            device_id: None,
            device_generation: None,
            account_summary: None,
        };
    };
    let Some(object) = value.as_object() else {
        return AccountComponentValue {
            auth_status: status,
            account_id: None,
            device_id: None,
            device_generation: None,
            account_summary: None,
        };
    };
    AccountComponentValue {
        auth_status: status,
        account_id: object
            .get("account_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        device_id: object
            .get("device_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        device_generation: object.get("device_generation").and_then(Value::as_u64),
        account_summary: object
            .get("account_summary")
            .cloned()
            .filter(|v| !v.is_null()),
    }
}

fn account_value_json(value: &AccountComponentValue) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

fn make_logout_pending(session: &Value) -> Option<Value> {
    let object = session.as_object()?;
    let account_id = object.get("account_id")?.as_str()?;
    let device_id = object.get("device_id")?.as_str()?;
    let account_refresh_token = object
        .get("account")
        .and_then(Value::as_object)
        .and_then(|v| v.get("refresh_token"))
        .and_then(Value::as_str)
        .or_else(|| object.get("account_refresh_token").and_then(Value::as_str))?;
    let device_refresh_token = object
        .get("device")
        .and_then(Value::as_object)
        .and_then(|v| v.get("refresh_token"))
        .and_then(Value::as_str)
        .or_else(|| object.get("device_refresh_token").and_then(Value::as_str))?;
    Some(serde_json::json!({
        "schema_version": 1,
        "status": "logout_pending",
        "account_id": account_id,
        "device_id": device_id,
        "account_refresh_token": account_refresh_token,
        "device_refresh_token": device_refresh_token
    }))
}

fn config_view(
    provider: &str,
    secret: Option<&crate::state::ProviderSecret>,
    mask_label: &str,
) -> ProviderConfigView {
    ProviderConfigView {
        provider: provider.to_owned(),
        configured: secret.is_some_and(|value| !value.api_key.is_empty()),
        masked_api_key: secret
            .filter(|value| !value.api_key.is_empty())
            .map(|value| mask_api_key(mask_label, &value.api_key)),
        base_url: secret.and_then(|value| value.base_url.clone()),
    }
}

fn mask_api_key(label: &str, value: &str) -> String {
    if value.len() <= 8 {
        return format!("{label} key");
    }
    let suffix: String = value
        .chars()
        .rev()
        .take(4)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    format!("{label} ···{suffix}")
}

fn validate_catalog_base_url(value: &str, allow_private_http: bool) -> Result<(), IpcError> {
    let parsed = reqwest::Url::parse(value.trim())
        .map_err(|_| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))?;
    if parsed.username() != "" || parsed.password().is_some() || parsed.fragment().is_some() {
        return Err(IpcError::new(
            ErrorCode::InvalidRequest,
            RecoveryAction::None,
        ));
    }
    if parsed.scheme() == "https" {
        return Ok(());
    }
    let host = parsed.host_str().unwrap_or_default().trim_end_matches('.');
    let private = host == "localhost"
        || host.ends_with(".local")
        || host.parse::<std::net::IpAddr>().is_ok_and(|ip| match ip {
            std::net::IpAddr::V4(ip) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
            std::net::IpAddr::V6(ip) => {
                ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local()
            }
        });
    if allow_private_http && parsed.scheme() == "http" && private {
        return Ok(());
    }
    Err(IpcError::new(
        ErrorCode::InvalidRequest,
        RecoveryAction::None,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::JsonLineWriter;
    use crate::state::StateStore;
    use std::fs;
    use uuid::Uuid;

    #[derive(Default)]
    struct RecordingSink(Mutex<Vec<IpcEvent>>);

    impl EventSink for RecordingSink {
        fn event(&self, event: IpcEvent) {
            self.0.lock().expect("events").push(event);
        }
    }

    struct BrowserSessionBackend {
        reject: bool,
    }

    impl LocalBackend for BrowserSessionBackend {
        fn refresh(&self, _: Arc<AtomicBool>) -> RefreshOutcome {
            let unavailable = || Err(BackendError::unavailable());
            RefreshOutcome {
                quota: unavailable(),
                usage: unavailable(),
                account: unavailable(),
                pricing: unavailable(),
                overview: None,
            }
        }

        fn diagnose(&self) -> Result<DiagnosticReport, BackendError> {
            Err(BackendError::unavailable())
        }

        fn login(&self, _: &str, _: Arc<AtomicBool>) -> Result<LoginOutcome, BackendError> {
            Err(BackendError::unavailable())
        }

        fn logout(&self, _: &Value) -> Result<(), BackendError> {
            Err(BackendError::unavailable())
        }

        fn validate_provider_browser_session(
            &self,
            _: crate::catalog::ProviderId,
            cookie_header: &str,
        ) -> Result<crate::providers::ValidatedBrowserSession, BackendError> {
            if self.reject {
                return Err(BackendError {
                    error: IpcError::new(
                        ErrorCode::AuthenticationRequired,
                        RecoveryAction::ConfigureProvider,
                    ),
                });
            }
            Ok(crate::providers::ValidatedBrowserSession {
                cookie_header: cookie_header.to_owned(),
                account_fingerprint: "b".repeat(64),
                account_label: Some("ne***@example.com".into()),
            })
        }
    }

    struct ChildLeakBackend {
        state: Arc<StateStore>,
        panic_after_child: bool,
    }

    impl LocalBackend for ChildLeakBackend {
        fn refresh(&self, _: Arc<AtomicBool>) -> RefreshOutcome {
            let (parent, _) = self
                .state
                .running_refresh_attempt()
                .expect("running refresh query")
                .expect("running refresh");
            self.state
                .begin_diagnostic_attempt(
                    DiagnosticAttemptKind::UsageScan,
                    DiagnosticAttemptTrigger::Recheck,
                    DiagnosticSource::ThisDevice,
                    Some("agent:codex"),
                    DiagnosticMode::Required,
                    Some(parent),
                )
                .expect("child attempt");
            if self.panic_after_child {
                panic!("synthetic child panic");
            }
            RefreshOutcome {
                quota: Ok(serde_json::json!({})),
                usage: Ok(serde_json::json!({})),
                account: Ok(serde_json::json!({})),
                pricing: Ok(serde_json::json!({})),
                overview: None,
            }
        }

        fn diagnose(&self) -> Result<DiagnosticReport, BackendError> {
            Err(BackendError::unavailable())
        }

        fn login(&self, _: &str, _: Arc<AtomicBool>) -> Result<LoginOutcome, BackendError> {
            Err(BackendError::unavailable())
        }

        fn logout(&self, _: &Value) -> Result<(), BackendError> {
            Err(BackendError::unavailable())
        }

        fn validate_provider_browser_session(
            &self,
            _: crate::catalog::ProviderId,
            _: &str,
        ) -> Result<crate::providers::ValidatedBrowserSession, BackendError> {
            Err(BackendError::unavailable())
        }
    }

    fn browser_session_request(operation: &str, cookie_header: &str) -> IpcRequest {
        serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": operation,
            "operation": operation,
            "payload": {"provider": "cursor", "cookie_header": cookie_header}
        }))
        .expect("browser-session request")
    }

    #[test]
    fn browser_session_validate_commit_and_failure_preserve_atomic_state() {
        let root = std::env::temp_dir().join(format!("quota-service-browser-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_provider_browser_session(
                "cursor",
                &crate::state::ProviderBrowserSession {
                    cookie_header: "wos-session=old-secret".into(),
                    account_fingerprint: "a".repeat(64),
                    account_label: Some("ol***@example.com".into()),
                },
            )
            .expect("old session");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(BrowserSessionBackend { reject: false }),
        );

        let validated = service.handle(browser_session_request(
            "validate_provider_browser_session",
            "wos-session=new-secret",
        ));
        assert!(validated.error.is_none());
        assert_eq!(
            state
                .provider_browser_session("cursor")
                .expect("read")
                .expect("old retained")
                .cookie_header,
            "wos-session=old-secret"
        );

        let committed = service.handle(browser_session_request(
            "commit_provider_browser_session",
            "wos-session=new-secret",
        ));
        assert!(committed.error.is_none());
        assert_eq!(
            state
                .provider_browser_session("cursor")
                .expect("read")
                .expect("new stored")
                .cookie_header,
            "wos-session=new-secret"
        );
        service.shutdown();

        let rejected = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(BrowserSessionBackend { reject: true }),
        );
        let response = rejected.handle(browser_session_request(
            "commit_provider_browser_session",
            "wos-session=rejected-secret",
        ));
        assert_eq!(
            response.error.map(|error| error.code),
            Some(ErrorCode::AuthenticationRequired)
        );
        assert_eq!(
            state
                .provider_browser_session("cursor")
                .expect("read")
                .expect("new retained")
                .cookie_header,
            "wos-session=new-secret"
        );
        rejected.shutdown();
        drop(rejected);
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn get_state_does_not_start_refresh() {
        let root = std::env::temp_dir().join(format!("quota-service-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let service = LocalService::new(
            state,
            JsonLineWriter::stdout(),
            Arc::new(UnavailableBackend),
        );
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "1",
            "operation": "get_state",
            "payload": {}
        }))
        .expect("request");
        let response = service.handle(request);
        assert!(response.error.is_none());
        assert!(service.inner.refresh.lock().expect("lock").active.is_none());
        service.shutdown();
        drop(service);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn refresh_spawn_failure_finalizes_the_started_attempt() {
        let root = std::env::temp_dir().join(format!("quota-refresh-spawn-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );
        service
            .inner
            .fail_next_refresh_spawn
            .store(true, Ordering::Release);

        let result = service.request_refresh_with_trigger(DiagnosticAttemptTrigger::Recheck);

        assert!(!result.accepted);
        assert!(!result.pending);
        assert!(
            service
                .inner
                .refresh
                .lock()
                .expect("refresh")
                .active
                .is_none()
        );
        let facts = state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::Refresh,
                DiagnosticSource::System,
                None,
            )
            .expect("refresh attempt facts");
        let attempt = facts.latest_completed.expect("completed attempt");
        assert_eq!(attempt.trigger, DiagnosticAttemptTrigger::Recheck);
        assert_eq!(attempt.outcome, DiagnosticAttemptOutcome::Failed);
        assert_eq!(attempt.code, Some(DiagnosticAttemptCode::Unavailable));
        assert_eq!(attempt.recovery, DiagnosticRecovery::Retry);
        assert!(facts.latest_success.is_none());

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn refresh_panic_interrupts_running_child_attempts() {
        let root = std::env::temp_dir().join(format!("quota-refresh-panic-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(ChildLeakBackend {
                state: state.clone(),
                panic_after_child: true,
            }),
        );

        let result = service.request_refresh_with_trigger(DiagnosticAttemptTrigger::Recheck);
        assert!(result.accepted);
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while service
            .inner
            .refresh
            .lock()
            .expect("refresh")
            .active
            .is_some()
            && std::time::Instant::now() < deadline
        {
            thread::yield_now();
        }
        assert!(
            service
                .inner
                .refresh
                .lock()
                .expect("refresh")
                .active
                .is_none()
        );

        let child = state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::UsageScan,
                DiagnosticSource::ThisDevice,
                Some("agent:codex"),
            )
            .expect("child facts")
            .latest_completed
            .expect("completed child");
        assert_eq!(child.outcome, DiagnosticAttemptOutcome::Interrupted);
        assert_eq!(child.code, Some(DiagnosticAttemptCode::ProcessInterrupted));
        assert_eq!(child.recovery, DiagnosticRecovery::Retry);

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn refresh_completion_interrupts_running_child_attempts() {
        let root = std::env::temp_dir().join(format!("quota-refresh-child-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(ChildLeakBackend {
                state: state.clone(),
                panic_after_child: false,
            }),
        );

        let result = service.request_refresh_with_trigger(DiagnosticAttemptTrigger::Recheck);
        assert!(result.accepted);
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while service
            .inner
            .refresh
            .lock()
            .expect("refresh")
            .active
            .is_some()
            && std::time::Instant::now() < deadline
        {
            thread::yield_now();
        }
        assert!(
            service
                .inner
                .refresh
                .lock()
                .expect("refresh")
                .active
                .is_none()
        );

        let refresh = state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::Refresh,
                DiagnosticSource::System,
                None,
            )
            .expect("refresh facts")
            .latest_completed
            .expect("completed refresh");
        assert_eq!(refresh.outcome, DiagnosticAttemptOutcome::Success);
        let child = state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::UsageScan,
                DiagnosticSource::ThisDevice,
                Some("agent:codex"),
            )
            .expect("child facts")
            .latest_completed
            .expect("completed child");
        assert_eq!(child.outcome, DiagnosticAttemptOutcome::Interrupted);
        assert_eq!(child.code, Some(DiagnosticAttemptCode::ProcessInterrupted));
        assert_eq!(child.recovery, DiagnosticRecovery::Retry);

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn diagnose_during_refresh_uses_the_last_completed_snapshot() {
        let root = std::env::temp_dir().join(format!("quota-service-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = Arc::new(crate::service::backend::NativeBackend::new(
            state.clone(),
            Arc::new(crate::relay::RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        ));
        let baseline = backend
            .complete_diagnostic_report()
            .expect("baseline diagnostics");
        state
            .set_component(
                ComponentName::Usage,
                ComponentStatus::Error,
                None,
                None,
                Some(IpcError::new(ErrorCode::Internal, RecoveryAction::Retry)),
                true,
            )
            .expect("intermediate state");
        let service = LocalService::new(state.clone(), Arc::new(RecordingSink::default()), backend);
        service.inner.refresh.lock().expect("refresh").active = Some(ActiveRefresh {
            cancel: Arc::new(AtomicBool::new(false)),
            started_at: "2026-08-15T08:00:00Z".into(),
        });
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "diagnose",
            "operation": "diagnose",
            "payload": {}
        }))
        .expect("request");

        let response = service.handle(request);
        let report: DiagnosticReport =
            serde_json::from_value(response.result.expect("result")).expect("report");

        assert_eq!(report.refresh.phase, DiagnosticRefreshPhase::Running);
        assert_eq!(report.refresh.revision, baseline.refresh.revision);
        assert_eq!(report.summary.operation, baseline.summary.operation);
        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn disabling_usage_upload_is_durable_and_emits_usage_state() {
        let root = std::env::temp_dir().join(format!("quota-usage-upload-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let sink = Arc::new(RecordingSink::default());
        let service = LocalService::new(state.clone(), sink.clone(), Arc::new(UnavailableBackend));
        assert!(
            state
                .snapshot()
                .expect("initial state")
                .usage_upload_enabled
        );
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "usage-upload",
            "operation": "set_usage_upload",
            "payload": {"enabled": false}
        }))
        .expect("request");

        let response = service.handle(request);

        assert!(response.error.is_none());
        assert_eq!(
            response
                .result
                .as_ref()
                .and_then(|value| value.get("enabled"))
                .and_then(Value::as_bool),
            Some(false)
        );
        assert!(
            !state
                .snapshot()
                .expect("updated state")
                .usage_upload_enabled
        );
        assert!(
            sink.0
                .lock()
                .expect("events")
                .iter()
                .any(|event| event.changed_components == [ComponentName::Usage])
        );
        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn failed_background_login_emits_account_state() {
        let root = std::env::temp_dir().join(format!("quota-login-event-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let sink = Arc::new(RecordingSink::default());
        let service = LocalService::new(state, sink.clone(), Arc::new(UnavailableBackend));
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "login",
            "operation": "login",
            "payload": {}
        }))
        .expect("request");

        let response = service.handle(request);
        assert!(response.error.is_none());
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while sink.0.lock().expect("events").is_empty() && std::time::Instant::now() < deadline {
            thread::yield_now();
        }
        assert!(
            sink.0
                .lock()
                .expect("events")
                .iter()
                .any(|event| event.changed_components == [ComponentName::Account])
        );

        service.shutdown();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while Arc::strong_count(&service.inner) > 1 && std::time::Instant::now() < deadline {
            thread::yield_now();
        }
        drop(service);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn signed_out_state_retains_a_lost_session_error() {
        let root = std::env::temp_dir().join(format!("quota-auth-lost-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_component(
                ComponentName::Account,
                ComponentStatus::Ready,
                Some(account_value_json(&AccountComponentValue {
                    auth_status: AuthStatus::SignedIn,
                    account_id: Some("account_test".into()),
                    device_id: Some("device_test".into()),
                    device_generation: Some(1),
                    account_summary: None,
                })),
                Some(now_rfc3339()),
                None,
                false,
            )
            .expect("signed in component");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );

        let cases = [
            ErrorCode::DeviceDeleted,
            ErrorCode::AuthenticationRequired,
            ErrorCode::StaleGeneration,
            ErrorCode::AuthenticationRequired,
        ];
        let expected = [
            ErrorCode::DeviceDeleted,
            ErrorCode::DeviceDeleted,
            ErrorCode::StaleGeneration,
            ErrorCode::StaleGeneration,
        ];
        for (error_code, expected_code) in cases.into_iter().zip(expected) {
            service.apply_component_result(
                ComponentName::Account,
                Err(BackendError {
                    error: IpcError::new(error_code, RecoveryAction::Login),
                }),
            );
            let account = state
                .component(ComponentName::Account)
                .expect("account")
                .expect("account component");
            assert_eq!(account.status, ComponentStatus::SignedOut);
            assert_eq!(
                account.last_error.map(|error| error.code),
                Some(expected_code)
            );
        }

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn logout_cancels_the_active_refresh_before_advancing_session_state() {
        let root = std::env::temp_dir().join(format!("quota-logout-cancel-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .write_session_json(&serde_json::json!({
                "schema_version": 1,
                "status": "active",
                "account_id": "account_test",
                "device_id": "device_test",
                "account": {"refresh_token": "account_refresh"},
                "device": {"refresh_token": "device_refresh"}
            }))
            .expect("session");
        let service = LocalService::new(
            state.clone(),
            JsonLineWriter::stdout(),
            Arc::new(UnavailableBackend),
        );
        let cancel = Arc::new(AtomicBool::new(false));
        service.inner.refresh.lock().expect("refresh").active = Some(ActiveRefresh {
            cancel: cancel.clone(),
            started_at: now_rfc3339(),
        });
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "logout",
            "operation": "logout",
            "payload": {}
        }))
        .expect("request");

        let response = service.handle(request);

        assert!(response.error.is_none());
        assert!(cancel.load(Ordering::Acquire));
        assert_eq!(
            state
                .session_json()
                .expect("session")
                .and_then(|value| value
                    .get("status")
                    .and_then(Value::as_str)
                    .map(str::to_owned)),
            Some("logout_pending".into())
        );
        service.shutdown();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while Arc::strong_count(&service.inner) > 1 && std::time::Instant::now() < deadline {
            thread::yield_now();
        }
        assert_eq!(Arc::strong_count(&service.inner), 1);
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }
}
