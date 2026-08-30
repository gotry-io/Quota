//! Request handling, refresh scheduling, and parent-lifetime shutdown.

pub mod backend;
pub mod schedule;

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::protocol::*;
use crate::state::{
    DiagnosticAttemptCompletion, DiagnosticAttemptHandle, StateError, StateStore, now_rfc3339,
    session_is_usable,
};
use chrono::Utc;
use serde_json::Value;

pub trait EventSink: Send + Sync {
    fn event(&self, event: IpcEvent);
}

/// Where a [`BackendError`] came from. Kept off the IPC surface so Swift does not have to
/// decode a new `ErrorCode`; a local epoch miss is retryable and never a sign-out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BackendErrorKind {
    Ordinary,
    SessionChanged,
    RelayRejection { observed_epoch: u64 },
}

#[derive(Debug, Clone)]
pub struct BackendError {
    pub error: IpcError,
    kind: BackendErrorKind,
}

impl BackendError {
    pub const fn new(error: IpcError) -> Self {
        Self {
            error,
            kind: BackendErrorKind::Ordinary,
        }
    }

    pub const fn unavailable() -> Self {
        Self::new(IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry))
    }

    pub const fn cancelled() -> Self {
        Self::new(IpcError::new(ErrorCode::Cancelled, RecoveryAction::None))
    }

    /// The local session moved under this caller. Distinct from a Relay 401: IPC is retryable
    /// and the installed session must not be cleared.
    pub const fn session_changed() -> Self {
        Self {
            error: IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
            kind: BackendErrorKind::SessionChanged,
        }
    }

    /// A Relay response that may end the session, pinned to the epoch observed when the
    /// rejected request was sent.
    pub(crate) const fn relay_rejection(error: IpcError, observed_epoch: u64) -> Self {
        let kind = if error.code.requires_login() {
            BackendErrorKind::RelayRejection { observed_epoch }
        } else {
            BackendErrorKind::Ordinary
        };
        Self { error, kind }
    }

    /// Epoch to compare-and-swap against when clearing a session after a Relay rejection.
    pub(crate) const fn sign_out_epoch(&self) -> Option<u64> {
        match self.kind {
            BackendErrorKind::RelayRejection { observed_epoch } => Some(observed_epoch),
            _ => None,
        }
    }

    #[cfg(test)]
    pub(crate) const fn is_session_changed(&self) -> bool {
        matches!(self.kind, BackendErrorKind::SessionChanged)
    }
}

fn unavailable_refresh_outcome() -> RefreshOutcome {
    let unavailable = || Err(BackendError::unavailable());
    RefreshOutcome {
        quota: unavailable(),
        usage: unavailable(),
        account: unavailable(),
        pricing: unavailable(),
        overview: None,
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

/// Where a refresh hands over a component the moment it has it, rather than at its end.
///
/// The Account read needs nothing but the session, so it lands in well under a second while
/// provider collection can take twenty seconds per provider. Publishing it here is what lets the
/// panel name the account and show its totals while the rest of the refresh is still running.
/// Whatever is published this way is also carried in the `RefreshOutcome`, so a caller that only
/// wants the end of the refresh discards these and loses nothing.
pub trait RefreshSink: Sync {
    fn account(&self, result: Result<Value, BackendError>);
    fn quota(&self, result: Result<Value, BackendError>) {
        let _ = result;
    }
}

/// A sink for a caller that wants only the finished `RefreshOutcome`.
pub struct DiscardedRefreshUpdates;

impl RefreshSink for DiscardedRefreshUpdates {
    fn account(&self, _: Result<Value, BackendError>) {}
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

/// A provider the catalog says has a browser session at all. Every other id is a request this
/// service will not answer, whatever the payload carries.
fn browser_session_provider(provider: &str) -> Result<crate::catalog::ProviderId, IpcError> {
    crate::catalog::ProviderId::parse(provider)
        .filter(|provider| provider.metadata().browser_session.is_some())
        .ok_or_else(|| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))
}

/// The browser's display name, kept short and free of control characters. It is the only part
/// of a refusal that came from outside this process, and it is rendered to a person.
fn bounded_browser_name(value: &str) -> Result<String, IpcError> {
    let value = value.trim();
    (!value.is_empty() && value.len() <= 64 && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
        .ok_or_else(|| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))
}

/// Adapter boundary for the provider, usage, pricing, and Relay implementations.  It lives here
/// so those modules can be developed independently without making the IPC layer know their types.
pub trait LocalBackend: Send + Sync {
    /// One refresh transaction.  Implementations may collect quota/Usage and read the Account in
    /// parallel, but must order pricing/control, upload/outbox, and overview merging explicitly.
    /// Anything handed to `updates` before this returns is still named in the outcome.
    ///
    /// `bypass_renewal_floor` is true only for a Recheck or a manual refresh: those may ask
    /// the owning CLI again immediately. Startup, settings, account changes, and the timer
    /// wait out the hour.
    fn refresh(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        bypass_renewal_floor: bool,
    ) -> RefreshOutcome;
    /// Account summary only. Used by the one-minute signed-in poll.
    fn refresh_account(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        trigger: DiagnosticAttemptTrigger,
    ) -> Result<Value, BackendError> {
        let _ = (cancel, updates, trigger);
        Err(BackendError::unavailable())
    }
    /// Quota collection, upload, and Overview, without Usage. Defaults do not run a full refresh.
    fn refresh_quota(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        trigger: DiagnosticAttemptTrigger,
    ) -> RefreshOutcome {
        let _ = (cancel, updates, trigger);
        unavailable_refresh_outcome()
    }
    /// Usage scan, report, and outbox, without provider collection.
    fn refresh_usage(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        trigger: DiagnosticAttemptTrigger,
    ) -> RefreshOutcome {
        let _ = (cancel, updates, trigger);
        unavailable_refresh_outcome()
    }
    fn diagnose(&self) -> Result<DiagnosticReport, BackendError>;
    fn complete_diagnostics(&self) -> Result<DiagnosticReport, BackendError> {
        self.diagnose()
    }
    fn login(
        &self,
        installation_id: &str,
        cancel: Arc<AtomicBool>,
    ) -> Result<LoginOutcome, BackendError>;
    /// Bind the loopback listener and return the authorize URL the app should open.
    ///
    /// Test backends skip the listener and return a placeholder. Production binds synchronously
    /// so `login` can answer with the URL before the callback thread waits.
    fn begin_login(&self) -> Result<String, BackendError> {
        Ok("http://127.0.0.1/quota-login".to_owned())
    }
    /// Drop a listener `begin_login` created if the login thread never starts.
    fn abort_login_preparation(&self) {}
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
    fn refresh(&self, _: Arc<AtomicBool>, _: &dyn RefreshSink, _: bool) -> RefreshOutcome {
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
    /// Coordinated refresh: startup, manual, Recheck, and settings. Occupies both lanes.
    active: Option<ActiveRefresh>,
    pending: bool,
    pending_trigger: Option<DiagnosticAttemptTrigger>,
    quota: Option<ActiveRefresh>,
    usage: Option<ActiveRefresh>,
    account: Option<ActiveRefresh>,
    pending_quota: bool,
    pending_usage: bool,
    pending_account: bool,
}

struct SchedulerPlan {
    next_quota: Option<Instant>,
    reset_at: Option<chrono::DateTime<chrono::Utc>>,
    attempted_resets: HashSet<i64>,
}

#[derive(Clone, Copy)]
enum RefreshLane {
    Quota,
    Usage,
    Account,
}

impl RefreshLane {
    /// Whether this lane should wait rather than start now.
    ///
    /// Quota and Usage may overlap: a local session-epoch miss is retryable and does not sign
    /// the device out, token refresh is process-wide and single-flight, and uploads refresh
    /// the access token before they send. Account waits for an in-flight Quota pass because
    /// that pass already reads the Account; a blocked poll is kept pending rather than dropped.
    fn blocked(self, refresh: &RefreshState) -> bool {
        match self {
            Self::Quota => refresh.active.is_some() || refresh.quota.is_some(),
            Self::Usage => refresh.active.is_some() || refresh.usage.is_some(),
            Self::Account => {
                refresh.active.is_some() || refresh.quota.is_some() || refresh.account.is_some()
            }
        }
    }

    fn components(self) -> &'static [ComponentName] {
        match self {
            Self::Quota => &[ComponentName::Quota],
            Self::Usage => &[ComponentName::Usage],
            Self::Account => &[ComponentName::Account],
        }
    }
}

fn coalesce_refresh_trigger(
    current: Option<DiagnosticAttemptTrigger>,
    incoming: DiagnosticAttemptTrigger,
) -> DiagnosticAttemptTrigger {
    let priority = |trigger| match trigger {
        DiagnosticAttemptTrigger::Scheduled | DiagnosticAttemptTrigger::Startup => 0,
        DiagnosticAttemptTrigger::SettingsChange | DiagnosticAttemptTrigger::AccountChange => 1,
        DiagnosticAttemptTrigger::Manual | DiagnosticAttemptTrigger::Recheck => 2,
    };
    current
        .filter(|current| priority(*current) >= priority(incoming))
        .unwrap_or(incoming)
}

/// How long a reset waits for the refresh it cancelled to let go of the cache.
///
/// A cancelled refresh unwinds at the next thing it checks, and the longest of those is one
/// provider request already in flight.
const REFRESH_HANDOVER_DEADLINE: Duration = Duration::from_secs(30);
const REFRESH_HANDOVER_POLL: Duration = Duration::from_millis(25);

struct ActiveRefresh {
    cancel: Arc<AtomicBool>,
}

struct LoginState {
    active: Option<Arc<AtomicBool>>,
}

/// Clears `login.active` unless the login thread was spawned.
struct LoginActiveGuard {
    inner: Arc<ServiceInner>,
    armed: bool,
}

impl LoginActiveGuard {
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for LoginActiveGuard {
    fn drop(&mut self) {
        if self.armed
            && let Ok(mut login) = self.inner.login.lock()
        {
            login.active = None;
        }
    }
}

struct ServiceInner {
    state: Arc<StateStore>,
    backend: Arc<dyn LocalBackend>,
    sink: Arc<dyn EventSink>,
    shutdown: AtomicBool,
    refresh: Mutex<RefreshState>,
    login: Mutex<LoginState>,
    scheduler: Mutex<SchedulerPlan>,
    scheduler_wakeup: Condvar,
    scheduler_signal: Mutex<schedule::SchedulerSignal>,
    #[cfg(test)]
    fail_next_refresh_spawn: AtomicBool,
    #[cfg(test)]
    fail_next_account_component_write: AtomicBool,
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
        let service = Self {
            inner: Arc::new(ServiceInner {
                state,
                backend,
                sink,
                shutdown: AtomicBool::new(false),
                refresh: Mutex::new(RefreshState {
                    active: None,
                    pending: false,
                    pending_trigger: None,
                    quota: None,
                    usage: None,
                    account: None,
                    pending_quota: false,
                    pending_usage: false,
                    pending_account: false,
                }),
                login: Mutex::new(LoginState { active: None }),
                scheduler: Mutex::new(SchedulerPlan {
                    next_quota: None,
                    reset_at: None,
                    attempted_resets: HashSet::new(),
                }),
                scheduler_wakeup: Condvar::new(),
                scheduler_signal: Mutex::new(schedule::SchedulerSignal::Idle),
                #[cfg(test)]
                fail_next_refresh_spawn: AtomicBool::new(false),
                #[cfg(test)]
                fail_next_account_component_write: AtomicBool::new(false),
            }),
        };
        service.reconcile_persisted_login();
        service
    }

    pub fn start_scheduler(&self) {
        let service = self.clone();
        service.request_refresh_with_trigger(DiagnosticAttemptTrigger::Startup);
        thread::Builder::new()
            .name("quota-refresh-scheduler".to_owned())
            .spawn(move || {
                let mut next_account = Instant::now() + schedule::account_sync_interval();
                let mut next_quota = Instant::now() + service.quota_refresh_interval();
                service.store_next_quota(next_quota);
                loop {
                    if service.is_shutdown() {
                        break;
                    }
                    let reset_at = service.reset_deadline_instant();
                    let (kind, wake_at) = schedule::next_wake(next_account, next_quota, reset_at);
                    let wait = wake_at.saturating_duration_since(Instant::now());
                    let signal = service.inner.scheduler_signal.lock();
                    let Ok(signal) = signal else { break };
                    let Ok((mut signal, timeout)) = service
                        .inner
                        .scheduler_wakeup
                        .wait_timeout_while(signal, wait, |value| {
                            matches!(value, schedule::SchedulerSignal::Idle)
                        })
                    else {
                        break;
                    };
                    if service.is_shutdown() {
                        break;
                    }
                    let posted = *signal;
                    *signal = schedule::SchedulerSignal::Idle;
                    drop(signal);
                    if posted != schedule::SchedulerSignal::Idle {
                        let now = Instant::now();
                        next_quota = schedule::next_quota_after_signal(
                            posted,
                            now,
                            service.quota_refresh_interval(),
                            next_quota,
                        );
                        service.store_next_quota(next_quota);
                        continue;
                    }
                    if !timeout.timed_out() {
                        continue;
                    }
                    let now = Instant::now();
                    match kind {
                        schedule::SchedulerWake::Account => {
                            next_account = now + schedule::account_sync_interval();
                            service.request_account_sync();
                        }
                        schedule::SchedulerWake::Quota => {
                            next_quota = now + service.quota_refresh_interval();
                            next_account = now + schedule::account_sync_interval();
                            service.store_next_quota(next_quota);
                            service.request_scheduled_lanes();
                        }
                        schedule::SchedulerWake::ResetBoundary => {
                            service.mark_reset_attempted();
                            service.request_lane(
                                RefreshLane::Quota,
                                DiagnosticAttemptTrigger::Scheduled,
                            );
                        }
                    }
                }
            })
            .ok();
    }

    fn quota_refresh_interval(&self) -> Duration {
        self.inner
            .state
            .quota_refresh_interval_seconds()
            .ok()
            .and_then(schedule::quota_refresh_interval)
            .unwrap_or_else(schedule::default_quota_refresh_interval)
    }

    fn store_next_quota(&self, next_quota: Instant) {
        if let Ok(mut plan) = self.inner.scheduler.lock() {
            plan.next_quota = Some(next_quota);
        }
    }

    fn reset_deadline_instant(&self) -> Option<Instant> {
        let reset_at = self.inner.scheduler.lock().ok()?.reset_at?;
        let now = Instant::now();
        schedule::instant_from_utc(reset_at, chrono::Utc::now(), now)
    }

    fn mark_reset_attempted(&self) {
        if let Ok(mut plan) = self.inner.scheduler.lock() {
            if let Some(at) = plan.reset_at.take() {
                plan.attempted_resets.insert(at.timestamp());
            }
            if plan.attempted_resets.len() > 64
                && let Some(oldest) = plan.attempted_resets.iter().copied().min()
            {
                plan.attempted_resets.remove(&oldest);
            }
        }
    }

    fn wake_scheduler(&self, signal: schedule::SchedulerSignal) {
        if matches!(signal, schedule::SchedulerSignal::Idle) {
            return;
        }
        if let Ok(mut slot) = self.inner.scheduler_signal.lock() {
            if matches!(*slot, schedule::SchedulerSignal::CadenceChanged)
                && matches!(signal, schedule::SchedulerSignal::Recalculate)
            {
                // A cadence change already restarts the collection clock; a reset wake must
                // not downgrade it.
            } else {
                *slot = signal;
            }
            self.inner.scheduler_wakeup.notify_all();
        }
    }

    pub fn handle(&self, request: IpcRequest) -> IpcResponse {
        if request.request_id.is_empty() || request.request_id.len() > MAXIMUM_REQUEST_ID_BYTES {
            return IpcResponse::error(
                "invalid",
                IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None),
            );
        }
        // `ping` is answered while shutting down too: it reports that this process is still
        // there to answer, which stays true until the loop leaves.
        if self.is_shutdown() && !matches!(request.operation, Operation::Shutdown | Operation::Ping)
        {
            return IpcResponse::error(
                &request.request_id,
                IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
            );
        }
        let result: Result<Value, IpcError> = match request.operation {
            Operation::Ping => Self::ping(&request).map(as_json),
            Operation::GetState => self.get_state(&request).map(as_json),
            Operation::Diagnose => self.diagnose(&request).map(as_json),
            Operation::RecheckDiagnostics => self.recheck_diagnostics(&request).map(as_json),
            Operation::Refresh => self.refresh(&request).map(as_json),
            Operation::ResetCache => self.reset_cache(&request).map(as_json),
            Operation::Login => self.login(&request).map(as_json),
            Operation::CancelLogin => self.cancel_login(&request).map(as_json),
            Operation::Logout => self.logout(&request).map(as_json),
            Operation::SetUsageUpload => self.set_usage_upload(&request).map(as_json),
            Operation::SetQuotaRefreshInterval => {
                self.set_quota_refresh_interval(&request).map(as_json)
            }
            Operation::SetOverviewSourcePin => self.set_overview_source_pin(&request).map(as_json),
            Operation::SetProviderConfig => self.set_provider_config(&request).map(as_json),
            Operation::RemoveProviderConfig => self.remove_provider_config(&request).map(as_json),
            Operation::ValidateProviderBrowserSession => self
                .validate_provider_browser_session(&request)
                .map(as_json),
            Operation::SetProviderBrowserScan => {
                self.set_provider_browser_scan(&request).map(as_json)
            }
            Operation::ReplaceProviderBrowserSessions => self
                .replace_provider_browser_sessions(&request)
                .map(as_json),
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
        if let Ok(refresh) = self.inner.refresh.lock() {
            for lane in [
                &refresh.active,
                &refresh.quota,
                &refresh.usage,
                &refresh.account,
            ] {
                if let Some(active) = lane {
                    active.cancel.store(true, Ordering::Release);
                }
            }
        }
        if let Ok(login) = self.inner.login.lock()
            && let Some(cancel) = &login.active
        {
            cancel.store(true, Ordering::Release);
        }
        if let Ok(mut signal) = self.inner.scheduler_signal.lock() {
            *signal = schedule::SchedulerSignal::Recalculate;
            self.inner.scheduler_wakeup.notify_all();
        }
    }

    /// Takes no lock and touches no state, so the stdin thread can answer it while a long
    /// operation holds the worker.
    fn ping(request: &IpcRequest) -> Result<PingResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        Ok(PingResult { ok: true })
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
        self.inner.backend.diagnose().map_err(|error| error.error)
    }

    /// Throws this device's cache away and starts filling it in again.
    ///
    /// Identity — the session, the upload queue, saved browser sessions — is a different file and
    /// is untouched.
    fn reset_cache(&self, request: &IpcRequest) -> Result<EmptyResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        self.reset_cache_within(REFRESH_HANDOVER_DEADLINE)
    }

    /// Deletes the cache once the refresh in flight has let go of it.
    ///
    /// A refresh reads the cache to decide what this device owes its Account, so a reset that
    /// landed in the middle of one would delete the rows it was about to hand over. The refresh
    /// is cancelled first and this call waits for it, and a refresh still holding on when the
    /// wait runs out is answered `Busy` rather than raced.
    fn reset_cache_within(&self, deadline: Duration) -> Result<EmptyResult, IpcError> {
        if !self.cancel_refresh_and_wait(deadline) {
            return Err(IpcError::new(ErrorCode::Busy, RecoveryAction::Retry));
        }
        self.inner.state.reset_cache();
        let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::Manual);
        Ok(EmptyResult {})
    }

    /// Stops the refresh in flight and answers whether it let go before the deadline.
    fn cancel_refresh_and_wait(&self, deadline: Duration) -> bool {
        {
            let Ok(refresh) = self.inner.refresh.lock() else {
                return false;
            };
            if refresh.active.is_none()
                && refresh.quota.is_none()
                && refresh.usage.is_none()
                && refresh.account.is_none()
            {
                return true;
            }
            for lane in [
                &refresh.active,
                &refresh.quota,
                &refresh.usage,
                &refresh.account,
            ] {
                if let Some(active) = lane {
                    active.cancel.store(true, Ordering::Release);
                }
            }
        }
        let deadline = Instant::now() + deadline;
        loop {
            thread::sleep(REFRESH_HANDOVER_POLL);
            match self.inner.refresh.lock() {
                Ok(refresh)
                    if refresh.active.is_none()
                        && refresh.quota.is_none()
                        && refresh.usage.is_none()
                        && refresh.account.is_none() =>
                {
                    return true;
                }
                Ok(_) => {}
                Err(_) => return false,
            }
            if Instant::now() >= deadline {
                return false;
            }
        }
    }

    fn recheck_diagnostics(&self, request: &IpcRequest) -> Result<RefreshResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        Ok(self.request_refresh_with_trigger(DiagnosticAttemptTrigger::Recheck))
    }

    fn login(&self, request: &IpcRequest) -> Result<LoginResult, IpcError> {
        request.decode_payload::<EmptyPayload>()?;
        if let Some((session, epoch)) = self.inner.state.session_snapshot().map_err(state_error)? {
            // A live or signing-out session owns the device; anything else, including an
            // `active` row without its tokens, is cleared so signing in again can replace it.
            if session_is_usable(&session) {
                return Err(IpcError::new(ErrorCode::Busy, RecoveryAction::Retry));
            }
            if !self
                .inner
                .state
                .clear_session_if_epoch(epoch)
                .map_err(state_error)?
            {
                return Err(IpcError::new(ErrorCode::Busy, RecoveryAction::Retry));
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
        let authorize_url = match self.inner.backend.begin_login() {
            Ok(url) => url,
            Err(error) => return Err(error.error),
        };
        let cancel = Arc::new(AtomicBool::new(false));
        login.active = Some(cancel.clone());
        drop(login);

        let mut guard = LoginActiveGuard {
            inner: Arc::clone(&self.inner),
            armed: true,
        };
        let _ = self.mark_account_logging_in();
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
            self.inner.backend.abort_login_preparation();
            return Err(IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry));
        }
        guard.disarm();
        Ok(LoginResult {
            status: AuthStatus::LoggingIn,
            account_id: None,
            device_id: None,
            device_generation: None,
            authorize_url: Some(authorize_url),
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
                authorize_url: None,
            });
        };
        cancel.store(true, Ordering::Release);
        Ok(LoginResult {
            status: AuthStatus::LoggingIn,
            account_id: None,
            device_id: None,
            device_generation: None,
            authorize_url: None,
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
        if let Ok(refresh) = self.inner.refresh.lock() {
            for lane in [
                &refresh.active,
                &refresh.quota,
                &refresh.usage,
                &refresh.account,
            ] {
                if let Some(active) = lane {
                    active.cancel.store(true, Ordering::Release);
                }
            }
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

    fn set_quota_refresh_interval(
        &self,
        request: &IpcRequest,
    ) -> Result<QuotaRefreshIntervalSetting, IpcError> {
        let payload: SetQuotaRefreshIntervalPayload = request.decode_payload()?;
        if schedule::quota_refresh_interval(payload.interval_seconds).is_none() {
            return Err(IpcError::new(
                ErrorCode::InvalidRequest,
                RecoveryAction::None,
            ));
        }
        self.inner
            .state
            .set_quota_refresh_interval_seconds(payload.interval_seconds)
            .map_err(state_error)?;
        self.wake_scheduler(schedule::SchedulerSignal::CadenceChanged);
        Ok(QuotaRefreshIntervalSetting {
            interval_seconds: payload.interval_seconds,
        })
    }

    fn set_overview_source_pin(
        &self,
        request: &IpcRequest,
    ) -> Result<OverviewSourcePinSetting, IpcError> {
        let payload: SetOverviewSourcePinPayload = request.decode_payload()?;
        if payload.provider.is_empty()
            || payload.fingerprint.is_empty()
            || payload.pin.as_ref().is_some_and(|pin| pin.is_empty())
            || crate::catalog::ProviderId::parse(&payload.provider).is_none()
        {
            return Err(IpcError::new(
                ErrorCode::InvalidRequest,
                RecoveryAction::None,
            ));
        }
        let identity = match payload.scope.as_str() {
            "global" if payload.identity_source_id.is_none() => QuotaOverviewIdentity {
                provider: payload.provider,
                fingerprint: payload.fingerprint,
                scope: payload.scope,
                source_id: None,
            },
            "source" => match payload.identity_source_id {
                Some(source_id) if !source_id.is_empty() => QuotaOverviewIdentity {
                    provider: payload.provider,
                    fingerprint: payload.fingerprint,
                    scope: payload.scope,
                    source_id: Some(source_id),
                },
                _ => {
                    return Err(IpcError::new(
                        ErrorCode::InvalidRequest,
                        RecoveryAction::None,
                    ));
                }
            },
            _ => {
                return Err(IpcError::new(
                    ErrorCode::InvalidRequest,
                    RecoveryAction::None,
                ));
            }
        };
        let overview = self.inner.state.overview().map_err(state_error)?;
        let Some(item) = overview.iter().find(|item| item.identity == identity) else {
            return Err(IpcError::new(
                ErrorCode::InvalidRequest,
                RecoveryAction::None,
            ));
        };
        // A source without its reading can be seen but not shown: pinning it would put the
        // automatic reading under that source's name.
        if let Some(pin) = payload.pin.as_deref()
            && !item
                .sources
                .iter()
                .any(|source| source.source_id == pin && source.snapshot.is_some())
        {
            return Err(IpcError::new(
                ErrorCode::InvalidRequest,
                RecoveryAction::None,
            ));
        }
        let identity_key = backend::overview_identity_key(&identity);
        self.inner
            .state
            .set_overview_source_pin(&identity_key, payload.pin.as_deref())
            .map_err(state_error)?;
        self.rebuild_overview()?;
        self.emit(vec![ComponentName::Quota]);
        Ok(OverviewSourcePinSetting {
            identity_key,
            pin: payload.pin,
        })
    }

    fn rebuild_overview(&self) -> Result<(), IpcError> {
        let snapshot = self.inner.state.snapshot().map_err(state_error)?;
        let Some(quota) = snapshot.quota.value else {
            return Ok(());
        };
        let previous = self.inner.state.overview().map_err(state_error)?;
        let pins = self
            .inner
            .state
            .overview_source_pins()
            .map_err(state_error)?;
        let (items, kept) = backend::overview_items_and_pins(
            &quota,
            snapshot.account.value.as_ref(),
            &previous,
            &pins,
            Utc::now(),
        );
        if kept != pins {
            self.inner
                .state
                .replace_overview_source_pins(&kept)
                .map_err(state_error)?;
        }
        self.inner.state.set_overview(&items).map_err(state_error)?;
        Ok(())
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

    fn set_provider_browser_scan(
        &self,
        request: &IpcRequest,
    ) -> Result<ProviderBrowserScanSetting, IpcError> {
        let payload: SetProviderBrowserScanPayload = request.decode_payload()?;
        let provider = browser_session_provider(&payload.provider)?;
        self.inner
            .state
            .set_browser_scan_enabled(provider.as_str(), payload.enabled)
            .map_err(state_error)?;
        if !payload.enabled {
            let _ = self
                .inner
                .state
                .clear_browser_access_denial(provider.as_str());
        }
        self.emit(vec![ComponentName::Providers]);
        let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::SettingsChange);
        Ok(ProviderBrowserScanSetting {
            provider: provider.as_str().to_owned(),
            enabled: payload.enabled,
        })
    }

    fn replace_provider_browser_sessions(
        &self,
        request: &IpcRequest,
    ) -> Result<EmptyResult, IpcError> {
        let payload: ReplaceProviderBrowserSessionsPayload = request.decode_payload()?;
        let provider = browser_session_provider(&payload.provider)?;
        let mut stored = Vec::new();
        let mut seen = HashSet::new();
        let mut last_error = None;
        for header in &payload.cookie_headers {
            match self.validate_browser_session(provider, header) {
                Ok(validated) => {
                    if !seen.insert(validated.account_fingerprint.clone()) {
                        continue;
                    }
                    stored.push(crate::state::ProviderBrowserSession {
                        cookie_header: validated.cookie_header,
                        account_fingerprint: validated.account_fingerprint,
                        account_label: validated.account_label,
                    });
                }
                Err(error) => last_error = Some(error),
            }
        }
        if !payload.cookie_headers.is_empty() && stored.is_empty() {
            return Err(last_error.unwrap_or_else(|| {
                IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None)
            }));
        }
        let existing_denial = self
            .inner
            .state
            .browser_access_denials()
            .unwrap_or_default()
            .get(provider.as_str())
            .cloned();
        let before = self.inner.state.current_revision().map_err(state_error)?;
        let after = self
            .inner
            .state
            .replace_provider_browser_sessions(provider.as_str(), &stored)
            .map_err(state_error)?;
        let sessions_changed = after != before;
        let denial_changed = if let Some(denial) = payload.access_denials.first() {
            let browser = bounded_browser_name(&denial.browser)?;
            let same = existing_denial.as_ref().is_some_and(|current| {
                current.browser == browser && current.reason == denial.reason
            });
            if same {
                false
            } else {
                let _ = self.inner.state.set_browser_access_denial(
                    provider.as_str(),
                    &crate::state::BrowserAccessDenial {
                        browser,
                        reason: denial.reason,
                        denied_at: crate::state::now_rfc3339(),
                    },
                );
                true
            }
        } else if existing_denial.is_some() {
            let _ = self
                .inner
                .state
                .clear_browser_access_denial(provider.as_str());
            true
        } else {
            false
        };
        if sessions_changed || denial_changed {
            self.emit(vec![ComponentName::Providers]);
            let _ = self.request_refresh_with_trigger(DiagnosticAttemptTrigger::SettingsChange);
        }
        Ok(EmptyResult {})
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
        let provider = browser_session_provider(&payload.provider)?;
        let validated = self.validate_browser_session(provider, &payload.cookie_header)?;
        Ok((provider, validated))
    }

    fn validate_browser_session(
        &self,
        provider: crate::catalog::ProviderId,
        cookie_header: &str,
    ) -> Result<crate::providers::ValidatedBrowserSession, IpcError> {
        let cookie_header =
            crate::providers::common::normalize_browser_cookie_header(provider, cookie_header)
                .map_err(|_| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None))?;
        self.inner
            .backend
            .validate_provider_browser_session(provider, &cookie_header)
            .map_err(|error| error.error)
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
        match trigger {
            DiagnosticAttemptTrigger::Scheduled => self.request_scheduled_lanes(),
            _ => self.request_full(trigger),
        }
    }

    fn request_scheduled_lanes(&self) -> RefreshResult {
        let quota = self.request_lane(RefreshLane::Quota, DiagnosticAttemptTrigger::Scheduled);
        let usage = self.request_lane(RefreshLane::Usage, DiagnosticAttemptTrigger::Scheduled);
        RefreshResult {
            accepted: quota.accepted || usage.accepted,
            pending: quota.pending || usage.pending,
            revision: self.inner.state.current_revision().unwrap_or(0),
        }
    }

    fn request_account_sync(&self) {
        let _ = self.request_lane(RefreshLane::Account, DiagnosticAttemptTrigger::Scheduled);
    }

    fn request_lane(&self, lane: RefreshLane, trigger: DiagnosticAttemptTrigger) -> RefreshResult {
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
        if lane.blocked(&refresh) {
            match lane {
                RefreshLane::Quota => refresh.pending_quota = true,
                RefreshLane::Usage => refresh.pending_usage = true,
                RefreshLane::Account => refresh.pending_account = true,
            }
            return RefreshResult {
                accepted: false,
                pending: true,
                revision: self.inner.state.current_revision().unwrap_or(0),
            };
        }
        let cancel = Arc::new(AtomicBool::new(false));
        match lane {
            RefreshLane::Quota => {
                refresh.pending_quota = false;
                refresh.quota = Some(ActiveRefresh {
                    cancel: cancel.clone(),
                })
            }
            RefreshLane::Usage => {
                refresh.pending_usage = false;
                refresh.usage = Some(ActiveRefresh {
                    cancel: cancel.clone(),
                })
            }
            RefreshLane::Account => {
                refresh.pending_account = false;
                refresh.account = Some(ActiveRefresh {
                    cancel: cancel.clone(),
                })
            }
        }
        drop(refresh);
        for component in lane.components() {
            let _ = self.inner.state.set_refreshing(*component, true);
        }
        self.emit(lane.components().to_vec());
        let service = self.clone();
        let spawned = thread::Builder::new()
            .name(
                match lane {
                    RefreshLane::Quota => "quota-quota-lane",
                    RefreshLane::Usage => "quota-usage-lane",
                    RefreshLane::Account => "quota-account-sync",
                }
                .to_owned(),
            )
            .spawn(move || service.run_lane(lane, cancel, trigger))
            .is_ok();
        if !spawned {
            self.clear_lane(lane);
            for component in lane.components() {
                let _ = self.inner.state.set_refreshing(*component, false);
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

    fn clear_lane(&self, lane: RefreshLane) {
        if let Ok(mut refresh) = self.inner.refresh.lock() {
            match lane {
                RefreshLane::Quota => refresh.quota = None,
                RefreshLane::Usage => refresh.usage = None,
                RefreshLane::Account => refresh.account = None,
            }
        }
    }

    fn request_full(&self, trigger: DiagnosticAttemptTrigger) -> RefreshResult {
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
        if refresh.active.is_some() || refresh.quota.is_some() || refresh.usage.is_some() {
            refresh.pending = true;
            refresh.pending_trigger =
                Some(coalesce_refresh_trigger(refresh.pending_trigger, trigger));
            return RefreshResult {
                accepted: false,
                pending: true,
                revision: self.inner.state.current_revision().unwrap_or(0),
            };
        }
        let cancel = Arc::new(AtomicBool::new(false));
        let attempt = self.begin_refresh_attempt(trigger);
        refresh.active = Some(ActiveRefresh {
            cancel: cancel.clone(),
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
                        service.run_refresh(cancel, attempt, trigger)
                    }));
                    // A panicking refresh still has an outcome worth reporting: the
                    // recovery below marks every component unavailable.
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
                        service
                            .inner
                            .state
                            .finish_diagnostic_attempt_with_interrupted_children(
                                attempt,
                                &DiagnosticAttemptCompletion::new(
                                    DiagnosticAttemptOutcome::Failed,
                                    Some(DiagnosticAttemptCode::Unavailable),
                                ),
                            );
                    }
                    // Building a report is work a service that is tearing down skips. Folding
                    // the cache's log back in is local, so it runs either way, and after the
                    // report so it covers it.
                    if !service.is_shutdown() {
                        let _ = service.inner.backend.complete_diagnostics();
                    }
                    service.inner.state.checkpoint_cache();
                    if let Ok(mut refresh) = service.inner.refresh.lock() {
                        refresh.active = None;
                    }
                    service.emit(vec![
                        ComponentName::Quota,
                        ComponentName::Usage,
                        ComponentName::Account,
                        ComponentName::Pricing,
                    ]);
                    service.maybe_start_pending();
                })
                .is_ok();
        if !spawned {
            self.inner.state.finish_diagnostic_attempt(
                attempt,
                &DiagnosticAttemptCompletion::new(
                    DiagnosticAttemptOutcome::Failed,
                    Some(DiagnosticAttemptCode::Unavailable),
                ),
            );
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

    fn begin_refresh_attempt(
        &self,
        trigger: DiagnosticAttemptTrigger,
    ) -> Option<DiagnosticAttemptHandle> {
        self.inner.state.begin_diagnostic_attempt(
            DiagnosticAttemptKind::Refresh,
            trigger,
            None,
            None,
        )
    }

    fn run_refresh(
        &self,
        cancel: Arc<AtomicBool>,
        attempt: Option<DiagnosticAttemptHandle>,
        trigger: DiagnosticAttemptTrigger,
    ) {
        let updates = RefreshUpdates {
            service: self.clone(),
            account: Mutex::new(None),
            quota: Mutex::new(None),
        };
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
            self.inner.backend.refresh(
                cancel.clone(),
                &updates,
                matches!(
                    trigger,
                    DiagnosticAttemptTrigger::Manual | DiagnosticAttemptTrigger::Recheck
                ),
            )
        };
        let session_required = self
            .inner
            .state
            .session_json()
            .ok()
            .flatten()
            .is_some_and(|value| value.get("status").and_then(Value::as_str) == Some("active"));
        let completion = refresh_attempt_completion(&outcome, session_required, cancel.as_ref());
        if !updates.already_applied_quota(&outcome.quota) {
            self.apply_component_result(ComponentName::Quota, outcome.quota.clone());
        }
        if let Ok(quota) = &outcome.quota {
            self.note_reset_boundary(quota);
        }
        self.apply_component_result(ComponentName::Usage, outcome.usage);
        // The Account is usually already applied, from the read that finished long before this
        // refresh did. Writing the identical value again would only restate it, so the end of a
        // refresh applies the Account exactly when it differs from what was published.
        let account_result = self.account_result_for_session(outcome.account);
        if !updates.already_applied_account(&account_result) {
            self.apply_component_result(ComponentName::Account, account_result);
        }
        self.apply_component_result(ComponentName::Pricing, outcome.pricing);
        if let Some(overview) = outcome.overview {
            let _ = self.inner.state.set_overview(&overview);
        }
        self.inner
            .state
            .finish_diagnostic_attempt_with_interrupted_children(attempt, &completion);
    }

    fn maybe_start_pending(&self) {
        if self.is_shutdown() {
            return;
        }
        let mut refresh = match self.inner.refresh.lock() {
            Ok(refresh) => refresh,
            Err(_) => return,
        };
        if refresh.active.is_some() {
            return;
        }
        if refresh.pending {
            let trigger = refresh
                .pending_trigger
                .take()
                .unwrap_or(DiagnosticAttemptTrigger::Scheduled);
            refresh.pending = false;
            drop(refresh);
            let _ = self.request_full(trigger);
            return;
        }
        let start_account = refresh.pending_account && !RefreshLane::Account.blocked(&refresh);
        let lanes_idle = refresh.quota.is_none() && refresh.usage.is_none();
        let quota = lanes_idle && refresh.pending_quota;
        let usage = lanes_idle && refresh.pending_usage;
        drop(refresh);
        if quota {
            let _ = self.request_lane(RefreshLane::Quota, DiagnosticAttemptTrigger::Scheduled);
        }
        if usage {
            let _ = self.request_lane(RefreshLane::Usage, DiagnosticAttemptTrigger::Scheduled);
        }
        if start_account {
            let _ = self.request_lane(RefreshLane::Account, DiagnosticAttemptTrigger::Scheduled);
        }
    }

    fn run_lane(
        &self,
        lane: RefreshLane,
        cancel: Arc<AtomicBool>,
        trigger: DiagnosticAttemptTrigger,
    ) {
        match lane {
            RefreshLane::Account => self.run_account_lane(cancel, trigger),
            RefreshLane::Quota => self.run_quota_lane(cancel, trigger),
            RefreshLane::Usage => self.run_usage_lane(cancel, trigger),
        }
        self.clear_lane(lane);
        for component in lane.components() {
            let _ = self.inner.state.set_refreshing(*component, false);
        }
        if matches!(lane, RefreshLane::Usage) {
            let _ = self
                .inner
                .state
                .set_refreshing(ComponentName::Pricing, false);
        }
        if !self.is_shutdown() && !matches!(lane, RefreshLane::Account) {
            let _ = self.inner.backend.complete_diagnostics();
        }
        if !matches!(lane, RefreshLane::Account) {
            self.inner.state.checkpoint_cache();
        }
        self.emit(match lane {
            RefreshLane::Quota => vec![ComponentName::Quota, ComponentName::Account],
            RefreshLane::Usage => vec![
                ComponentName::Usage,
                ComponentName::Pricing,
                ComponentName::Account,
            ],
            RefreshLane::Account => vec![ComponentName::Account],
        });
        self.maybe_start_pending();
    }

    fn run_account_lane(&self, cancel: Arc<AtomicBool>, trigger: DiagnosticAttemptTrigger) {
        let updates = RefreshUpdates {
            service: self.clone(),
            account: Mutex::new(None),
            quota: Mutex::new(None),
        };
        if !cancel.load(Ordering::Acquire) && !self.is_shutdown() {
            let _ = self
                .inner
                .backend
                .refresh_account(cancel, &updates, trigger);
        }
    }

    fn run_quota_lane(&self, cancel: Arc<AtomicBool>, trigger: DiagnosticAttemptTrigger) {
        let updates = RefreshUpdates {
            service: self.clone(),
            account: Mutex::new(None),
            quota: Mutex::new(None),
        };
        let outcome = if cancel.load(Ordering::Acquire) || self.is_shutdown() {
            return;
        } else {
            self.inner.backend.refresh_quota(cancel, &updates, trigger)
        };
        if !updates.already_applied_quota(&outcome.quota) {
            self.apply_component_result(ComponentName::Quota, outcome.quota.clone());
        }
        if let Ok(quota) = &outcome.quota {
            self.note_reset_boundary(quota);
        }
        let account_result = self.account_result_for_session(outcome.account);
        if !updates.already_applied_account(&account_result) {
            self.apply_component_result(ComponentName::Account, account_result);
        }
        if let Some(overview) = outcome.overview {
            let _ = self.inner.state.set_overview(&overview);
        }
    }

    fn run_usage_lane(&self, cancel: Arc<AtomicBool>, trigger: DiagnosticAttemptTrigger) {
        let updates = RefreshUpdates {
            service: self.clone(),
            account: Mutex::new(None),
            quota: Mutex::new(None),
        };
        let outcome = if cancel.load(Ordering::Acquire) || self.is_shutdown() {
            return;
        } else {
            self.inner.backend.refresh_usage(cancel, &updates, trigger)
        };
        self.apply_component_result(ComponentName::Usage, outcome.usage);
        self.apply_component_result(ComponentName::Pricing, outcome.pricing);
        let account_result = self.account_result_for_session(outcome.account);
        let account_is_news = matches!(&account_result, Ok(_))
            || account_result
                .as_ref()
                .err()
                .is_some_and(|error| error.error.code.requires_login());
        if account_is_news && !updates.already_applied_account(&account_result) {
            self.apply_component_result(ComponentName::Account, account_result);
        }
    }

    fn note_reset_boundary(&self, quota: &Value) {
        let now_utc = chrono::Utc::now();
        let now = Instant::now();
        let (next_quota_at, attempted) = {
            let Ok(plan) = self.inner.scheduler.lock() else {
                return;
            };
            let next_quota_at = plan
                .next_quota
                .and_then(|at| schedule::utc_from_instant(at, now, now_utc))
                .unwrap_or_else(|| {
                    now_utc
                        + chrono::Duration::from_std(self.quota_refresh_interval())
                            .unwrap_or(chrono::Duration::minutes(5))
                });
            (next_quota_at, plan.attempted_resets.clone())
        };
        let wake = schedule::next_reset_boundary(quota, now_utc, next_quota_at, &attempted);
        if let Ok(mut plan) = self.inner.scheduler.lock() {
            plan.reset_at = wake;
        }
        self.wake_scheduler(schedule::SchedulerSignal::Recalculate);
    }

    /// A session being signed out never has its Account overwritten by a read taken before it.
    fn account_result_for_session(
        &self,
        result: Result<Value, BackendError>,
    ) -> Result<Value, BackendError> {
        match self.inner.state.session_json().ok().flatten() {
            Some(session)
                if session.get("status").and_then(Value::as_str) == Some("logout_pending") =>
            {
                Err(BackendError::new(IpcError::new(
                    ErrorCode::AuthenticationRequired,
                    RecoveryAction::Retry,
                )))
            }
            _ => result,
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
                            display_label: None,
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
                        display_label: None,
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

    /// Best-effort UI hint. A cache lock miss must not abort the login the thread is about to
    /// run: `login.active` is the real gate.
    fn mark_account_logging_in(&self) -> Result<(), IpcError> {
        #[cfg(test)]
        if self
            .inner
            .fail_next_account_component_write
            .swap(false, Ordering::AcqRel)
        {
            return Err(IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry));
        }
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
        Ok(())
    }

    /// A persisted `logging_in` row cannot be finished after restart: no login thread exists.
    fn reconcile_persisted_login(&self) {
        let Ok(Some(record)) = self.inner.state.component(ComponentName::Account) else {
            return;
        };
        let logging_in = record
            .value
            .as_ref()
            .and_then(|value| value.get("auth_status"))
            .and_then(Value::as_str)
            == Some("logging_in");
        if !logging_in {
            return;
        }
        let session = self.inner.state.session_json().ok().flatten();
        let restored = crate::state::account_record_from_session(session.as_ref());
        let _ = self.inner.state.set_component(
            ComponentName::Account,
            restored.status,
            restored.value,
            Some(now_rfc3339()),
            None,
            false,
        );
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
            display_label: None,
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

/// The running refresh's half of [`RefreshSink`].
///
/// It applies and announces what it is handed, and remembers it: a refresh can read the Account
/// twice — once before it uploads and once after, when the upload changed it — and the end of
/// the refresh restates it again. Only a value that differs from the one standing is applied, so
/// a conditional read answered 304 costs nothing and announces nothing.
struct RefreshUpdates {
    service: LocalService,
    account: Mutex<Option<Result<Value, BackendError>>>,
    quota: Mutex<Option<Result<Value, BackendError>>>,
}

impl RefreshUpdates {
    fn already_applied_account(&self, result: &Result<Value, BackendError>) -> bool {
        self.account
            .lock()
            .ok()
            .and_then(|applied| {
                applied
                    .as_ref()
                    .map(|previous| same_component_result(previous, result))
            })
            .unwrap_or(false)
    }

    fn already_applied_quota(&self, result: &Result<Value, BackendError>) -> bool {
        self.quota
            .lock()
            .ok()
            .and_then(|applied| {
                applied
                    .as_ref()
                    .map(|previous| same_component_result(previous, result))
            })
            .unwrap_or(false)
    }
}

impl RefreshSink for RefreshUpdates {
    fn account(&self, result: Result<Value, BackendError>) {
        let result = self.service.account_result_for_session(result);
        if self.already_applied_account(&result) {
            return;
        }
        if let Ok(mut applied) = self.account.lock() {
            *applied = Some(result.clone());
        }
        self.service
            .apply_component_result(ComponentName::Account, result);
        self.service.emit(vec![ComponentName::Account]);
    }

    fn quota(&self, result: Result<Value, BackendError>) {
        if self.already_applied_quota(&result) {
            return;
        }
        if let Ok(mut applied) = self.quota.lock() {
            *applied = Some(result.clone());
        }
        self.service
            .apply_component_result(ComponentName::Quota, result);
        self.service.emit(vec![ComponentName::Quota]);
    }
}

fn same_component_result(
    left: &Result<Value, BackendError>,
    right: &Result<Value, BackendError>,
) -> bool {
    match (left, right) {
        (Ok(left), Ok(right)) => left == right,
        (Err(left), Err(right)) => left.error == right.error,
        _ => false,
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
    let (outcome, code) = if cancelled {
        (
            DiagnosticAttemptOutcome::Cancelled,
            Some(DiagnosticAttemptCode::Cancelled),
        )
    } else if let Some(error) = errors.first() {
        (
            DiagnosticAttemptOutcome::Failed,
            Some(diagnostic_attempt_code(error.error.code)),
        )
    } else {
        (DiagnosticAttemptOutcome::Success, None)
    };
    DiagnosticAttemptCompletion::new(outcome, code)
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
            display_label: None,
            device_id: None,
            device_generation: None,
            account_summary: None,
        };
    };
    let Some(object) = value.as_object() else {
        return AccountComponentValue {
            auth_status: status,
            account_id: None,
            display_label: None,
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
        display_label: object
            .get("display_label")
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

/// The revoke record for a session being signed out, from an active one or from itself.
fn make_logout_pending(session: &Value) -> Option<Value> {
    let object = session.as_object()?;
    let account_id = object.get("account_id")?.as_str()?;
    let device_id = object.get("device_id")?.as_str()?;
    let refresh_token = object
        .get("session")
        .and_then(Value::as_object)
        .and_then(|value| value.get("refresh_token"))
        .and_then(Value::as_str)
        .or_else(|| object.get("refresh_token").and_then(Value::as_str))?;
    Some(serde_json::json!({
        "schema_version": 1,
        "status": "logout_pending",
        "account_id": account_id,
        "device_id": device_id,
        "refresh_token": refresh_token
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
    use std::sync::atomic::AtomicUsize;
    use uuid::Uuid;

    #[test]
    fn pending_refresh_keeps_the_highest_intent_trigger() {
        assert_eq!(
            coalesce_refresh_trigger(None, DiagnosticAttemptTrigger::Scheduled),
            DiagnosticAttemptTrigger::Scheduled
        );
        assert_eq!(
            coalesce_refresh_trigger(
                Some(DiagnosticAttemptTrigger::Scheduled),
                DiagnosticAttemptTrigger::SettingsChange,
            ),
            DiagnosticAttemptTrigger::SettingsChange
        );
        assert_eq!(
            coalesce_refresh_trigger(
                Some(DiagnosticAttemptTrigger::Manual),
                DiagnosticAttemptTrigger::Scheduled,
            ),
            DiagnosticAttemptTrigger::Manual
        );
        assert_eq!(
            coalesce_refresh_trigger(
                Some(DiagnosticAttemptTrigger::Recheck),
                DiagnosticAttemptTrigger::Manual,
            ),
            DiagnosticAttemptTrigger::Recheck
        );
    }

    #[derive(Default)]
    struct RecordingSink(Mutex<Vec<IpcEvent>>);

    impl EventSink for RecordingSink {
        fn event(&self, event: IpcEvent) {
            self.0.lock().expect("events").push(event);
        }
    }

    struct BrowserSessionBackend {
        reject: bool,
        refresh_calls: AtomicUsize,
    }

    impl BrowserSessionBackend {
        fn new(reject: bool) -> Self {
            Self {
                reject,
                refresh_calls: AtomicUsize::new(0),
            }
        }
    }

    impl LocalBackend for BrowserSessionBackend {
        fn refresh(&self, _: Arc<AtomicBool>, _: &dyn RefreshSink, _: bool) -> RefreshOutcome {
            self.refresh_calls.fetch_add(1, Ordering::SeqCst);
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
                return Err(BackendError::new(IpcError::new(
                    ErrorCode::AuthenticationRequired,
                    RecoveryAction::ConfigureProvider,
                )));
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
        fn refresh(&self, _: Arc<AtomicBool>, _: &dyn RefreshSink, _: bool) -> RefreshOutcome {
            let (parent, _) = self
                .state
                .running_refresh_attempt()
                .expect("running refresh query")
                .expect("running refresh");
            self.state
                .begin_diagnostic_attempt(
                    DiagnosticAttemptKind::UsageScan,
                    DiagnosticAttemptTrigger::Recheck,
                    Some("agent:codex"),
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
        provider_browser_session_request("cursor", operation, cookie_header)
    }

    fn provider_browser_session_request(
        provider: &str,
        operation: &str,
        cookie_header: &str,
    ) -> IpcRequest {
        let payload = if operation == "replace_provider_browser_sessions" {
            serde_json::json!({
                "provider": provider,
                "cookie_headers": [cookie_header],
                "access_denials": []
            })
        } else {
            serde_json::json!({"provider": provider, "cookie_header": cookie_header})
        };
        serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": operation,
            "operation": operation,
            "payload": payload
        }))
        .expect("browser-session request")
    }

    /// Every provider the catalog declares a session for can have one stored and cleared.
    #[test]
    fn every_catalog_browser_session_provider_commits_and_disconnects() {
        let root = std::env::temp_dir().join(format!("quota-service-sessions-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(BrowserSessionBackend::new(false)),
        );
        let declared = crate::catalog::ProviderId::ALL
            .iter()
            .filter(|provider| provider.metadata().browser_session.is_some())
            .map(|provider| provider.as_str())
            .collect::<Vec<_>>();
        assert_eq!(declared, ["codex", "claude", "grok", "kimi", "cursor"]);
        // One real session cookie per provider, from that provider's own catalog allowlist.
        let headers = [
            ("codex", "__Secure-next-auth.session-token=secret"),
            ("claude", "sessionKey=secret"),
            ("grok", "sso=secret"),
            ("kimi", "kimi-auth=secret"),
            ("cursor", "wos-session=secret"),
        ];
        assert_eq!(
            headers.map(|(provider, _)| provider).as_slice(),
            declared.as_slice()
        );
        for (provider, header) in headers {
            let committed = service.handle(provider_browser_session_request(
                provider,
                "replace_provider_browser_sessions",
                header,
            ));
            assert!(committed.error.is_none(), "{provider} replace");
            let stored = state
                .provider_browser_session(provider)
                .expect("read")
                .expect("stored");
            assert_eq!(stored.cookie_header, header);
            assert_eq!(stored.account_fingerprint, "b".repeat(64));
            assert_eq!(stored.account_label.as_deref(), Some("ne***@example.com"));

            // A cookie name from another provider's list is not this provider's session.
            let foreign = service.handle(provider_browser_session_request(
                provider,
                "replace_provider_browser_sessions",
                "someone-elses-session=secret",
            ));
            assert!(
                foreign.error.is_some(),
                "{provider} accepted a foreign name"
            );

            let removed = service.handle(
                serde_json::from_value(serde_json::json!({
                    "type": "request",
                    "request_id": "set_provider_browser_scan",
                    "operation": "set_provider_browser_scan",
                    "payload": {"provider": provider, "enabled": false}
                }))
                .expect("disable scan"),
            );
            assert!(removed.error.is_none(), "{provider} disable scan");
            assert!(
                state
                    .provider_browser_session(provider)
                    .expect("read")
                    .is_none(),
                "{provider} still stored"
            );
        }
        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
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
            Arc::new(BrowserSessionBackend::new(false)),
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

        // A refusal recorded before this attempt is answered by the session it stored.
        state
            .set_browser_access_denial(
                "cursor",
                &crate::state::BrowserAccessDenial {
                    browser: "Safari".into(),
                    reason: BrowserAccessDenialReason::FullDiskAccess,
                    denied_at: crate::state::now_rfc3339(),
                },
            )
            .expect("denial");
        let committed = service.handle(browser_session_request(
            "replace_provider_browser_sessions",
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
        assert!(state.browser_access_denials().expect("denials").is_empty());

        service.shutdown();

        let rejected = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(BrowserSessionBackend::new(true)),
        );
        let response = rejected.handle(browser_session_request(
            "replace_provider_browser_sessions",
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
    fn replacing_identical_browser_sessions_does_not_refresh() {
        let root =
            std::env::temp_dir().join(format!("quota-service-browser-noop-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let sink = Arc::new(RecordingSink::default());
        let backend = Arc::new(BrowserSessionBackend::new(false));
        let service = LocalService::new(state.clone(), sink.clone(), backend.clone());

        let first = service.handle(browser_session_request(
            "replace_provider_browser_sessions",
            "wos-session=same-secret",
        ));
        assert!(first.error.is_none());
        wait_lanes_idle(&service);
        let revision = state.current_revision().expect("revision");
        let providers = sink
            .0
            .lock()
            .expect("events")
            .iter()
            .filter(|event| event.changed_components.contains(&ComponentName::Providers))
            .count();
        let refreshes = backend.refresh_calls.load(Ordering::SeqCst);

        let second = service.handle(browser_session_request(
            "replace_provider_browser_sessions",
            "wos-session=same-secret",
        ));
        assert!(second.error.is_none());
        wait_lanes_idle(&service);
        assert_eq!(state.current_revision().expect("revision"), revision);
        assert_eq!(
            sink.0
                .lock()
                .expect("events")
                .iter()
                .filter(|event| event.changed_components.contains(&ComponentName::Providers))
                .count(),
            providers
        );
        assert_eq!(backend.refresh_calls.load(Ordering::SeqCst), refreshes);

        service.shutdown();
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
        let cache = response
            .result
            .as_ref()
            .and_then(|value| value.get("cache"))
            .expect("cache object");
        assert_eq!(cache["rebuilding"], false);
        assert!(cache["reset_at"].is_null());
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
            .diagnostic_attempt_facts(DiagnosticAttemptKind::Refresh, None)
            .expect("refresh attempt facts");
        assert_eq!(facts.last_outcome, Some(DiagnosticAttemptOutcome::Failed));
        assert_eq!(
            facts.unresolved_code,
            Some(DiagnosticAttemptCode::Unavailable)
        );
        assert!(facts.last_success_at.is_none());
        assert!(
            state
                .diagnostic_recent_attempts()
                .expect("recent")
                .iter()
                .any(|attempt| attempt.kind == DiagnosticAttemptKind::Refresh)
        );

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
            .diagnostic_attempt_facts(DiagnosticAttemptKind::UsageScan, Some("agent:codex"))
            .expect("child facts");
        assert_eq!(
            child.last_outcome,
            Some(DiagnosticAttemptOutcome::Interrupted)
        );
        assert_eq!(
            child.unresolved_code,
            Some(DiagnosticAttemptCode::ProcessInterrupted)
        );

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
            .diagnostic_attempt_facts(DiagnosticAttemptKind::Refresh, None)
            .expect("refresh facts");
        assert_eq!(
            refresh.last_outcome,
            Some(DiagnosticAttemptOutcome::Success)
        );
        let child = state
            .diagnostic_attempt_facts(DiagnosticAttemptKind::UsageScan, Some("agent:codex"))
            .expect("child facts");
        assert_eq!(
            child.last_outcome,
            Some(DiagnosticAttemptOutcome::Interrupted)
        );
        assert_eq!(
            child.unresolved_code,
            Some(DiagnosticAttemptCode::ProcessInterrupted)
        );

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A reset deletes the file the refresh in flight is reading, so it cancels that refresh
    /// and waits for it to let go. Staging reads an hour's rows after it reads the list of
    /// dirty hours; a reset in between would have staged that hour empty under the scan
    /// version that produced it, and an hour is replaced by version.
    #[test]
    fn reset_cache_waits_for_the_refresh_it_cancelled() {
        let root = std::env::temp_dir().join(format!("quota-reset-wait-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_component(
                ComponentName::Usage,
                ComponentStatus::Ready,
                Some(serde_json::json!({"kept": true})),
                None,
                None,
                false,
            )
            .expect("something to lose");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );
        let cancel = Arc::new(AtomicBool::new(false));
        service.inner.refresh.lock().expect("refresh").active = Some(ActiveRefresh {
            cancel: cancel.clone(),
        });

        // A refresh that will not let go is answered rather than raced.
        assert_eq!(
            service
                .reset_cache_within(Duration::from_millis(50))
                .expect_err("busy")
                .code,
            ErrorCode::Busy
        );
        assert!(cancel.load(Ordering::Acquire));
        assert!(state.snapshot().expect("snapshot").cache.reset_at.is_none());

        // One that does is waited for, and only then is the cache thrown away.
        let releasing = {
            let service = service.clone();
            let cancel = cancel.clone();
            thread::spawn(move || {
                while !cancel.load(Ordering::Acquire) {
                    thread::sleep(Duration::from_millis(5));
                }
                thread::sleep(Duration::from_millis(20));
                service.inner.refresh.lock().expect("refresh").active = None;
            })
        };
        cancel.store(false, Ordering::Release);
        service
            .reset_cache_within(Duration::from_secs(5))
            .expect("reset");
        releasing.join().expect("releasing thread");
        assert!(state.snapshot().expect("snapshot").cache.reset_at.is_some());
        assert_ne!(
            state
                .component(ComponentName::Usage)
                .expect("component")
                .and_then(|record| record.value),
            Some(serde_json::json!({"kept": true}))
        );

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A recheck asks for a newer report; a running refresh has none to give yet, so it hands
    /// back the last completed one unchanged rather than an intermediate state.
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

        assert_eq!(report.generated_at, baseline.generated_at);
        assert_eq!(report.summary.operation, baseline.summary.operation);
        assert_eq!(
            report
                .surfaces
                .iter()
                .find(|surface| surface.id == "usage_this_device")
                .map(|surface| surface.status),
            Some(DiagnosticStatus::Ok)
        );
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
    fn setting_quota_refresh_interval_is_durable_and_rejects_unknown_values() {
        let root = std::env::temp_dir().join(format!("quota-refresh-interval-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let sink = Arc::new(RecordingSink::default());
        let service = LocalService::new(state.clone(), sink, Arc::new(UnavailableBackend));
        assert_eq!(
            state
                .snapshot()
                .expect("initial state")
                .quota_refresh_interval_seconds,
            300
        );
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "cadence",
            "operation": "set_quota_refresh_interval",
            "payload": {"interval_seconds": 60}
        }))
        .expect("request");
        let response = service.handle(request);
        assert!(response.error.is_none());
        assert_eq!(
            response
                .result
                .as_ref()
                .and_then(|value| value.get("interval_seconds"))
                .and_then(Value::as_u64),
            Some(60)
        );
        assert_eq!(
            state
                .snapshot()
                .expect("updated state")
                .quota_refresh_interval_seconds,
            60
        );
        let rejected: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "bad-cadence",
            "operation": "set_quota_refresh_interval",
            "payload": {"interval_seconds": 7}
        }))
        .expect("request");
        let response = service.handle(rejected);
        assert_eq!(
            response.error.as_ref().map(|error| error.code),
            Some(ErrorCode::InvalidRequest)
        );
        assert_eq!(
            state
                .snapshot()
                .expect("unchanged cadence")
                .quota_refresh_interval_seconds,
            60
        );
        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    fn seed_codex_overview(state: &StateStore, now: chrono::DateTime<Utc>) -> Value {
        let local_at = (now - chrono::Duration::minutes(30))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let remote_at =
            (now - chrono::Duration::minutes(5)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let local = serde_json::json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 10.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": local_at
        });
        let remote = serde_json::json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 20.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": remote_at
        });
        let quota = serde_json::json!({
            "results": [{"provider": "codex", "outcome": "success", "snapshots": [local]}]
        });
        let account = serde_json::json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [{"id": "device_remote", "display_name": "Studio", "platform": "macos", "last_seen_at": null, "last_observed_at": null}],
                "subscriptions": [{
                    "key": "codex|fp|global|",
                    "provider": "codex",
                    "snapshot": remote.clone(),
                    "sources": [{
                        "device_id": "device_remote",
                        "observed_at": remote_at,
                        "snapshot": remote
                    }]
                }]
            }
        });
        state
            .set_component(
                ComponentName::Quota,
                ComponentStatus::Ready,
                Some(quota.clone()),
                Some(now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
                None,
                false,
            )
            .expect("quota");
        state
            .set_component(
                ComponentName::Account,
                ComponentStatus::Ready,
                Some(account.clone()),
                Some(now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
                None,
                false,
            )
            .expect("account");
        let items = backend::overview_items_with_pins(
            &quota,
            Some(&account),
            &[],
            &std::collections::HashMap::new(),
            now,
        );
        state.set_overview(&items).expect("overview");
        quota
    }

    #[test]
    fn setting_an_overview_source_pin_is_validated_and_emits_quota_state() {
        let root = std::env::temp_dir().join(format!("quota-overview-pin-ipc-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let sink = Arc::new(RecordingSink::default());
        let service = LocalService::new(state.clone(), sink.clone(), Arc::new(UnavailableBackend));
        let now = Utc::now();
        seed_codex_overview(&state, now);

        let pinned: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "pin",
            "operation": "set_overview_source_pin",
            "payload": {
                "provider": "codex",
                "fingerprint": "fp",
                "scope": "global",
                "pin": "local"
            }
        }))
        .expect("request");
        let response = service.handle(pinned);
        assert!(response.error.is_none(), "{response:?}");
        assert_eq!(
            response
                .result
                .as_ref()
                .and_then(|value| value.get("pin"))
                .and_then(Value::as_str),
            Some("local")
        );
        let overview = state.overview().expect("overview");
        assert_eq!(overview[0].selected_source_id, "local");
        assert_eq!(overview[0].automatic_source_id, "device:device_remote");
        assert_eq!(overview[0].source_pin.as_deref(), Some("local"));
        assert!(
            sink.0
                .lock()
                .expect("events")
                .iter()
                .any(|event| event.changed_components == [ComponentName::Quota])
        );

        // A source Relay named without its reading is listed but cannot be pinned.
        let mut without_reading = state.overview().expect("overview");
        without_reading[0].sources.push(QuotaOverviewSource {
            source_id: "device:device_laptop".into(),
            kind: "device".into(),
            device_id: Some("device_laptop".into()),
            display_name: "Laptop".into(),
            observed_at: "2026-08-24T08:00:00Z".into(),
            is_stale: true,
            snapshot: None,
        });
        state.set_overview(&without_reading).expect("overview");
        let unreadable_source: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "unreadable-source",
            "operation": "set_overview_source_pin",
            "payload": {
                "provider": "codex",
                "fingerprint": "fp",
                "scope": "global",
                "pin": "device:device_laptop"
            }
        }))
        .expect("request");
        assert_eq!(
            service
                .handle(unreadable_source)
                .error
                .as_ref()
                .map(|error| error.code),
            Some(ErrorCode::InvalidRequest)
        );

        let unknown_source: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "missing-source",
            "operation": "set_overview_source_pin",
            "payload": {
                "provider": "codex",
                "fingerprint": "fp",
                "scope": "global",
                "pin": "device:nobody"
            }
        }))
        .expect("request");
        assert_eq!(
            service
                .handle(unknown_source)
                .error
                .as_ref()
                .map(|error| error.code),
            Some(ErrorCode::InvalidRequest)
        );

        let global_with_source: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "bad-scope",
            "operation": "set_overview_source_pin",
            "payload": {
                "provider": "codex",
                "fingerprint": "fp",
                "scope": "global",
                "identity_source_id": "local",
                "pin": "local"
            }
        }))
        .expect("request");
        assert_eq!(
            service
                .handle(global_with_source)
                .error
                .as_ref()
                .map(|error| error.code),
            Some(ErrorCode::InvalidRequest)
        );

        let missing_subscription: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "missing-item",
            "operation": "set_overview_source_pin",
            "payload": {
                "provider": "codex",
                "fingerprint": "other",
                "scope": "global",
                "pin": "local"
            }
        }))
        .expect("request");
        assert_eq!(
            service
                .handle(missing_subscription)
                .error
                .as_ref()
                .map(|error| error.code),
            Some(ErrorCode::InvalidRequest)
        );

        let unknown_provider: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "bad-provider",
            "operation": "set_overview_source_pin",
            "payload": {
                "provider": "not-a-provider",
                "fingerprint": "fp",
                "scope": "global",
                "pin": "local"
            }
        }))
        .expect("request");
        assert_eq!(
            service
                .handle(unknown_provider)
                .error
                .as_ref()
                .map(|error| error.code),
            Some(ErrorCode::InvalidRequest)
        );

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_pin_whose_source_has_gone_is_dropped_from_identity() {
        let root =
            std::env::temp_dir().join(format!("quota-overview-pin-prune-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let now = Utc::now();
        let quota = seed_codex_overview(&state, now);
        state
            .set_overview_source_pin("codex|fp|global|", Some("local"))
            .expect("pin");
        let account = serde_json::json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [{"id": "device_remote", "display_name": "Studio", "platform": "macos", "last_seen_at": null, "last_observed_at": null}],
                "subscriptions": [{
                    "key": "codex|fp|global|",
                    "provider": "codex",
                    "snapshot": quota["results"][0]["snapshots"][0].clone(),
                    "sources": [{
                        "device_id": "device_remote",
                        "observed_at": quota["results"][0]["snapshots"][0]["observed_at"].clone(),
                        "snapshot": quota["results"][0]["snapshots"][0].clone()
                    }]
                }]
            }
        });
        let empty_local = serde_json::json!({"results": []});
        let (items, kept) = backend::overview_items_and_pins(
            &empty_local,
            Some(&account),
            &[],
            &state.overview_source_pins().expect("pins"),
            now,
        );
        assert!(kept.get("codex|fp|global|").is_none());
        assert_eq!(items[0].selected_source_id, "device:device_remote");
        assert!(items[0].source_pin.is_none());
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A gate a test closes in front of a backend, so it can read the state a person would see
    /// while that backend is provably still working.
    struct Latch {
        state: Mutex<(bool, bool)>,
        changed: std::sync::Condvar,
    }

    impl Latch {
        fn new() -> Self {
            Self {
                state: Mutex::new((false, false)),
                changed: std::sync::Condvar::new(),
            }
        }

        /// Reports arrival and waits to be released; answers whether it was, rather than timing
        /// out silently.
        fn hold(&self) -> bool {
            let mut state = self.state.lock().expect("latch");
            state.0 = true;
            self.changed.notify_all();
            let deadline = Instant::now() + Duration::from_secs(5);
            while !state.1 {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return false;
                }
                let (guard, _) = self
                    .changed
                    .wait_timeout(state, remaining)
                    .expect("latch wait");
                state = guard;
            }
            true
        }

        fn wait_arrived(&self) {
            let mut state = self.state.lock().expect("latch");
            let deadline = Instant::now() + Duration::from_secs(5);
            while !state.0 {
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "the latch was never reached");
                let (guard, _) = self
                    .changed
                    .wait_timeout(state, remaining)
                    .expect("latch wait");
                state = guard;
            }
        }

        fn release(&self) {
            self.state.lock().expect("latch").1 = true;
            self.changed.notify_all();
        }
    }

    fn named_session() -> Value {
        serde_json::json!({
            "schema_version": 1,
            "status": "active",
            "account_id": "account_1",
            "display_label": "octocat",
            "device_id": "device_1",
            "device_generation": 1,
            "session": {
                "access_token": "qb_access_token_synthetic",
                "access_expires_at": "2099-01-01T00:00:00Z",
                "refresh_token": "qbr_refresh_token_synthetic",
                "refresh_expires_at": "2099-01-01T00:00:00Z"
            }
        })
    }

    fn named_account(summary: Option<Value>) -> AccountComponentValue {
        AccountComponentValue {
            auth_status: AuthStatus::SignedIn,
            account_id: Some("account_1".into()),
            display_label: Some("octocat".into()),
            device_id: Some("device_1".into()),
            device_generation: Some(1),
            account_summary: summary,
        }
    }

    /// Signs in with an Account that has a name, and holds the refresh that follows.
    struct NamedLoginBackend {
        refreshing: Arc<Latch>,
    }

    impl LocalBackend for NamedLoginBackend {
        fn refresh(&self, _: Arc<AtomicBool>, _: &dyn RefreshSink, _: bool) -> RefreshOutcome {
            self.refreshing.hold();
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
            Ok(LoginOutcome {
                session: named_session(),
                account: named_account(None),
            })
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

    /// Hands the Account over the moment it has one, then keeps working.
    struct EarlyAccountBackend {
        collecting: Arc<Latch>,
    }

    impl EarlyAccountBackend {
        fn account(&self) -> Value {
            serde_json::to_value(named_account(Some(serde_json::json!({"devices": []}))))
                .expect("account value")
        }
    }

    impl LocalBackend for EarlyAccountBackend {
        fn refresh(
            &self,
            _: Arc<AtomicBool>,
            updates: &dyn RefreshSink,
            _: bool,
        ) -> RefreshOutcome {
            updates.account(Ok(self.account()));
            self.collecting.hold();
            // A conditional read answered 304 hands back the Account it already had. Restating
            // it is not a change, and a window that is already showing it is not told again.
            updates.account(Ok(self.account()));
            RefreshOutcome {
                quota: Ok(serde_json::json!({"results": []})),
                usage: Err(BackendError::unavailable()),
                account: Ok(self.account()),
                pricing: Err(BackendError::unavailable()),
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

    struct EarlyQuotaBackend {
        collecting: Arc<Latch>,
    }

    impl EarlyQuotaBackend {
        fn quota(&self) -> Value {
            serde_json::json!({"captured_at": "2026-08-28T00:00:00Z", "results": []})
        }
    }

    impl LocalBackend for EarlyQuotaBackend {
        fn refresh(
            &self,
            _: Arc<AtomicBool>,
            updates: &dyn RefreshSink,
            _: bool,
        ) -> RefreshOutcome {
            updates.quota(Ok(self.quota()));
            self.collecting.hold();
            RefreshOutcome {
                quota: Ok(self.quota()),
                usage: Err(BackendError::unavailable()),
                account: Err(BackendError::unavailable()),
                pricing: Err(BackendError::unavailable()),
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

    fn account_component(service: &LocalService) -> Value {
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "state",
            "operation": "get_state",
            "payload": {}
        }))
        .expect("request");
        let response = service.handle(request);
        assert!(response.error.is_none());
        response
            .result
            .and_then(|state| state.get("account").cloned())
            .expect("account component")
    }

    fn wait_for_account_event(sink: &RecordingSink, after: usize) -> usize {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let seen = sink.0.lock().expect("events").len();
            if sink
                .0
                .lock()
                .expect("events")
                .iter()
                .skip(after)
                .any(|event| event.changed_components == [ComponentName::Account])
            {
                return seen;
            }
            assert!(Instant::now() < deadline, "no account event was emitted");
            thread::yield_now();
        }
    }

    /// The panel names the account as soon as the sign-in answers, which is long before the
    /// refresh it triggers can read one.
    #[test]
    fn signing_in_names_the_account_before_the_refresh_it_triggers() {
        let root = std::env::temp_dir().join(format!("quota-login-name-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let sink = Arc::new(RecordingSink::default());
        let refreshing = Arc::new(Latch::new());
        let service = LocalService::new(
            state.clone(),
            sink.clone(),
            Arc::new(NamedLoginBackend {
                refreshing: refreshing.clone(),
            }),
        );

        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "login",
            "operation": "login",
            "payload": {}
        }))
        .expect("request");
        assert!(service.handle(request).error.is_none());
        wait_for_account_event(&sink, 0);

        // The next read a person's window makes already carries the name, with no Account
        // summary yet: the sign-in named the account, it did not invent a read of it.
        let account = account_component(&service);
        assert_eq!(account["status"], "ready");
        assert_eq!(account["value"]["auth_status"], "signed_in");
        assert_eq!(account["value"]["display_label"], "octocat");
        assert!(account["value"]["account_summary"].is_null());

        // The account was announced on its own, before the refresh announced anything.
        let events = sink.0.lock().expect("events").clone();
        let account_first = events
            .iter()
            .position(|event| event.changed_components == [ComponentName::Account])
            .expect("account event");
        let refresh_first = events
            .iter()
            .position(|event| event.changed_components.len() == 4)
            .expect("refresh event");
        assert!(account_first < refresh_first, "{events:?}");

        refreshing.release();
        service.shutdown();
        wait_refresh_idle(&service);
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A refresh applies the Account when it has it, not when it is finished, and the end of the
    /// refresh restates nothing.
    #[test]
    fn the_account_is_applied_while_the_rest_of_the_refresh_is_still_running() {
        let root = std::env::temp_dir().join(format!("quota-early-account-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state.write_session_json(&named_session()).expect("session");
        let sink = Arc::new(RecordingSink::default());
        let collecting = Arc::new(Latch::new());
        let backend = Arc::new(EarlyAccountBackend {
            collecting: collecting.clone(),
        });
        let service = LocalService::new(state.clone(), sink.clone(), backend.clone());

        assert!(
            service
                .request_refresh_with_trigger(DiagnosticAttemptTrigger::Manual)
                .accepted
        );
        // The refresh is provably still inside the backend here, and the Account is already
        // applied and announced.
        collecting.wait_arrived();
        wait_for_account_event(&sink, 1);
        let mid_refresh = account_component(&service);
        assert_eq!(mid_refresh["status"], "ready");
        assert_eq!(mid_refresh["value"], backend.account());
        assert!(mid_refresh["last_error"].is_null());

        collecting.release();
        wait_refresh_idle(&service);

        // The unchanged second reading announced nothing: one account event stands for the one
        // value the window is showing.
        assert_eq!(
            sink.0
                .lock()
                .expect("events")
                .iter()
                .filter(|event| event.changed_components == [ComponentName::Account])
                .count(),
            1
        );

        // Ending the refresh neither restated the Account nor took it back.
        let settled = account_component(&service);
        assert_eq!(settled["value"], backend.account());
        assert_eq!(settled["status"], "ready");
        assert_eq!(settled["updated_at"], mid_refresh["updated_at"]);
        assert!(settled["last_error"].is_null());
        assert_eq!(settled["refreshing"], false);

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn the_quota_is_applied_while_the_rest_of_the_refresh_is_still_running() {
        let root = std::env::temp_dir().join(format!("quota-early-quota-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let sink = Arc::new(RecordingSink::default());
        let collecting = Arc::new(Latch::new());
        let backend = Arc::new(EarlyQuotaBackend {
            collecting: collecting.clone(),
        });
        let service = LocalService::new(state.clone(), sink.clone(), backend.clone());

        assert!(
            service
                .request_refresh_with_trigger(DiagnosticAttemptTrigger::Manual)
                .accepted
        );
        collecting.wait_arrived();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let seen = sink.0.lock().expect("events").len();
            if sink
                .0
                .lock()
                .expect("events")
                .iter()
                .any(|event| event.changed_components == [ComponentName::Quota])
            {
                let _ = seen;
                break;
            }
            assert!(Instant::now() < deadline, "no quota event was emitted");
            thread::yield_now();
        }
        let request: IpcRequest = serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "state",
            "operation": "get_state",
            "payload": {}
        }))
        .expect("request");
        let mid = service.handle(request);
        let quota = mid
            .result
            .and_then(|state| state.get("quota").cloned())
            .expect("quota");
        assert_eq!(quota["status"], "ready");
        assert_eq!(quota["value"], backend.quota());

        collecting.release();
        wait_refresh_idle(&service);
        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A sign-out that started while a read was in flight is not undone by that read.
    #[test]
    fn an_account_read_never_overwrites_a_session_that_is_signing_out() {
        let root = std::env::temp_dir().join(format!("quota-account-guard-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .write_session_json(&serde_json::json!({
                "schema_version": 1,
                "status": "logout_pending",
                "account_id": "account_1",
                "device_id": "device_1",
                "refresh_token": "qbr_refresh_token_synthetic"
            }))
            .expect("session");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );

        let guarded = service.account_result_for_session(Ok(serde_json::json!({
            "auth_status": "signed_in",
            "display_label": "octocat"
        })));

        assert_eq!(
            guarded
                .expect_err("a signing-out session refuses the read")
                .error,
            IpcError::new(ErrorCode::AuthenticationRequired, RecoveryAction::Retry)
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

    fn login_request() -> IpcRequest {
        serde_json::from_value(serde_json::json!({
            "type": "request",
            "request_id": "login",
            "operation": "login",
            "payload": {}
        }))
        .expect("request")
    }

    fn wait_login_idle(service: &LocalService) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while service.inner.login.lock().expect("login").active.is_some()
            && Instant::now() < deadline
        {
            thread::yield_now();
        }
        assert!(service.inner.login.lock().expect("login").active.is_none());
    }

    #[test]
    fn a_failing_account_component_write_does_not_leak_login_active() {
        let root = std::env::temp_dir().join(format!("quota-login-write-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let service = LocalService::new(
            state,
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );
        service
            .inner
            .fail_next_account_component_write
            .store(true, Ordering::Release);

        let first = service.handle(login_request());
        assert!(first.error.is_none(), "{first:?}");
        assert_eq!(
            first
                .result
                .as_ref()
                .and_then(|value| value.get("authorize_url")),
            Some(&serde_json::json!("http://127.0.0.1/quota-login"))
        );
        wait_login_idle(&service);

        let second = service.handle(login_request());
        assert!(second.error.is_none(), "{second:?}");

        service.shutdown();
        wait_login_idle(&service);
        drop(service);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn an_unusable_session_row_is_cleared_and_login_proceeds() {
        let root = std::env::temp_dir().join(format!("quota-login-unusable-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .write_session_json(&serde_json::json!({
                "status": "expired",
                "account_id": "account_1"
            }))
            .expect("session");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );

        let response = service.handle(login_request());
        assert!(response.error.is_none(), "{response:?}");
        assert!(state.session_json().expect("session").is_none());
        wait_login_idle(&service);

        let second = service.handle(login_request());
        assert!(second.error.is_none(), "{second:?}");

        service.shutdown();
        wait_login_idle(&service);
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// The row an upgrade can leave behind: `active`, but without the tokens this build reads
    /// with. Busy would mean nobody can ever sign in again on this device.
    #[test]
    fn an_active_session_without_tokens_does_not_refuse_login() {
        let root = std::env::temp_dir().join(format!("quota-login-tokenless-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let mut session = named_session();
        session["session"] = serde_json::json!({ "expires_at": "2099-01-01T00:00:00Z" });
        state.write_session_json(&session).expect("session");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );

        let response = service.handle(login_request());
        assert!(response.error.is_none(), "{response:?}");
        assert_eq!(
            response
                .result
                .as_ref()
                .and_then(|value| value.get("authorize_url")),
            Some(&serde_json::json!("http://127.0.0.1/quota-login"))
        );
        assert!(state.session_json().expect("session").is_none());
        wait_login_idle(&service);

        service.shutdown();
        wait_login_idle(&service);
        drop(service);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn an_active_session_still_refuses_login() {
        let root = std::env::temp_dir().join(format!("quota-login-active-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state.write_session_json(&named_session()).expect("session");
        let service = LocalService::new(
            state,
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );

        let response = service.handle(login_request());
        assert_eq!(
            response.error.map(|error| error.code),
            Some(ErrorCode::Busy)
        );

        service.shutdown();
        drop(service);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_persisted_logging_in_component_resets_when_the_service_starts() {
        let root = std::env::temp_dir().join(format!("quota-login-stale-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_component(
                ComponentName::Account,
                ComponentStatus::AuthRequired,
                Some(account_value_json(&AccountComponentValue {
                    auth_status: AuthStatus::LoggingIn,
                    account_id: None,
                    display_label: None,
                    device_id: None,
                    device_generation: None,
                    account_summary: None,
                })),
                Some(now_rfc3339()),
                None,
                false,
            )
            .expect("logging_in");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );

        let account = account_component(&service);
        assert_eq!(account["value"]["auth_status"], "signed_out");
        assert_eq!(account["status"], "signed_out");

        service.shutdown();
        drop(service);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_persisted_logging_in_component_with_an_active_session_resets_to_signed_in() {
        let root = std::env::temp_dir().join(format!("quota-login-stale-in-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state.write_session_json(&named_session()).expect("session");
        state
            .set_component(
                ComponentName::Account,
                ComponentStatus::AuthRequired,
                Some(account_value_json(&AccountComponentValue {
                    auth_status: AuthStatus::LoggingIn,
                    account_id: None,
                    display_label: None,
                    device_id: None,
                    device_generation: None,
                    account_summary: None,
                })),
                Some(now_rfc3339()),
                None,
                false,
            )
            .expect("logging_in");
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            Arc::new(UnavailableBackend),
        );

        let account = account_component(&service);
        assert_eq!(account["value"]["auth_status"], "signed_in");
        assert_eq!(account["value"]["account_id"], "account_1");
        assert_eq!(account["value"]["display_label"], "octocat");
        assert_eq!(account["status"], "stale");
        assert!(account["value"]["account_summary"].is_null());

        service.shutdown();
        drop(service);
        drop(state);
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
                    display_label: Some("octocat".into()),
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
                Err(BackendError::new(IpcError::new(
                    error_code,
                    RecoveryAction::Login,
                ))),
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
                "session": {"refresh_token": "session_refresh"}
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

    /// A backend that reports itself started and then waits, so a test can act on a refresh
    /// that is provably still in flight.
    struct GatedBackend {
        complete_calls: Arc<std::sync::atomic::AtomicUsize>,
        started: Arc<(Mutex<bool>, std::sync::Condvar)>,
        gate: Arc<(Mutex<bool>, std::sync::Condvar)>,
    }

    impl GatedBackend {
        fn new() -> Self {
            Self {
                complete_calls: Arc::new(AtomicUsize::new(0)),
                started: Arc::new((Mutex::new(false), std::sync::Condvar::new())),
                gate: Arc::new((Mutex::new(false), std::sync::Condvar::new())),
            }
        }

        fn release(&self) {
            *self.gate.0.lock().expect("gate") = true;
            self.gate.1.notify_all();
        }

        fn wait_started(&self) {
            let (lock, cond) = &*self.started;
            let mut started = lock.lock().expect("started");
            let deadline = Instant::now() + Duration::from_secs(2);
            while !*started {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break;
                }
                let (guard, _) = cond.wait_timeout(started, remaining).expect("wait");
                started = guard;
            }
            assert!(*started, "refresh never started");
        }
    }

    impl LocalBackend for GatedBackend {
        fn refresh(&self, _: Arc<AtomicBool>, _: &dyn RefreshSink, _: bool) -> RefreshOutcome {
            *self.started.0.lock().expect("started") = true;
            self.started.1.notify_all();
            let (lock, cond) = &*self.gate;
            let mut open = lock.lock().expect("gate");
            let deadline = Instant::now() + Duration::from_secs(2);
            while !*open {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break;
                }
                let (guard, _) = cond.wait_timeout(open, remaining).expect("wait");
                open = guard;
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

        fn complete_diagnostics(&self) -> Result<DiagnosticReport, BackendError> {
            self.complete_calls.fetch_add(1, Ordering::SeqCst);
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

    fn wait_refresh_idle(service: &LocalService) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while service
            .inner
            .refresh
            .lock()
            .expect("refresh")
            .active
            .is_some()
            && Instant::now() < deadline
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
    }

    #[test]
    fn shutdown_during_a_refresh_skips_the_report() {
        // A tearing-down service must not build or publish a report, even though the refresh it
        // caught mid-flight runs to its end.
        let root = std::env::temp_dir().join(format!("quota-shutdown-mid-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = Arc::new(GatedBackend::new());
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            backend.clone(),
        );

        assert!(
            service
                .request_refresh_with_trigger(DiagnosticAttemptTrigger::Recheck)
                .accepted
        );
        // The refresh is provably inside `backend.refresh` here, so the shutdown lands
        // mid-flight rather than racing the worker's completion check.
        backend.wait_started();
        service.shutdown();
        backend.release();
        wait_refresh_idle(&service);

        assert_eq!(backend.complete_calls.load(Ordering::SeqCst), 0);

        drop(service);
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    struct RecordingLaneBackend {
        quota_trigger: Mutex<Option<DiagnosticAttemptTrigger>>,
        account_trigger: Mutex<Option<DiagnosticAttemptTrigger>>,
        account_calls: AtomicUsize,
        quota_started: Arc<(Mutex<bool>, std::sync::Condvar)>,
        quota_gate: Arc<(Mutex<bool>, std::sync::Condvar)>,
    }

    impl RecordingLaneBackend {
        fn new() -> Self {
            Self {
                quota_trigger: Mutex::new(None),
                account_trigger: Mutex::new(None),
                account_calls: AtomicUsize::new(0),
                quota_started: Arc::new((Mutex::new(false), std::sync::Condvar::new())),
                quota_gate: Arc::new((Mutex::new(false), std::sync::Condvar::new())),
            }
        }

        fn wait_quota_started(&self) {
            let (lock, cond) = &*self.quota_started;
            let mut started = lock.lock().expect("started");
            let deadline = Instant::now() + Duration::from_secs(2);
            while !*started {
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "quota lane never started");
                let (guard, _) = cond.wait_timeout(started, remaining).expect("wait");
                started = guard;
            }
        }

        fn release_quota(&self) {
            *self.quota_gate.0.lock().expect("gate") = true;
            self.quota_gate.1.notify_all();
        }
    }

    impl LocalBackend for RecordingLaneBackend {
        fn refresh(&self, _: Arc<AtomicBool>, _: &dyn RefreshSink, _: bool) -> RefreshOutcome {
            unavailable_refresh_outcome()
        }

        fn refresh_quota(
            &self,
            _: Arc<AtomicBool>,
            _: &dyn RefreshSink,
            trigger: DiagnosticAttemptTrigger,
        ) -> RefreshOutcome {
            *self.quota_trigger.lock().expect("quota trigger") = Some(trigger);
            *self.quota_started.0.lock().expect("started") = true;
            self.quota_started.1.notify_all();
            let (lock, cond) = &*self.quota_gate;
            let mut open = lock.lock().expect("gate");
            let deadline = Instant::now() + Duration::from_secs(2);
            while !*open {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break;
                }
                let (guard, _) = cond.wait_timeout(open, remaining).expect("wait");
                open = guard;
            }
            RefreshOutcome {
                quota: Ok(serde_json::json!({})),
                usage: Err(BackendError::cancelled()),
                account: Err(BackendError::cancelled()),
                pricing: Err(BackendError::cancelled()),
                overview: None,
            }
        }

        fn refresh_account(
            &self,
            _: Arc<AtomicBool>,
            _: &dyn RefreshSink,
            trigger: DiagnosticAttemptTrigger,
        ) -> Result<Value, BackendError> {
            *self.account_trigger.lock().expect("account trigger") = Some(trigger);
            self.account_calls.fetch_add(1, Ordering::SeqCst);
            Ok(serde_json::json!({"auth_status": "signed_in"}))
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

    fn wait_lanes_idle(service: &LocalService) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let refresh = service.inner.refresh.lock().expect("refresh");
            let idle = refresh.active.is_none()
                && refresh.quota.is_none()
                && refresh.usage.is_none()
                && refresh.account.is_none()
                && !refresh.pending
                && !refresh.pending_quota
                && !refresh.pending_usage
                && !refresh.pending_account;
            drop(refresh);
            if idle {
                return;
            }
            assert!(Instant::now() < deadline, "lanes still running");
            thread::yield_now();
        }
    }

    #[test]
    fn scheduled_lanes_record_a_scheduled_trigger() {
        let root = std::env::temp_dir().join(format!("quota-lane-trigger-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = Arc::new(RecordingLaneBackend::new());
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            backend.clone(),
        );

        assert!(service.request_scheduled_lanes().accepted);
        backend.wait_quota_started();
        backend.release_quota();
        wait_lanes_idle(&service);
        assert_eq!(
            *backend.quota_trigger.lock().expect("quota trigger"),
            Some(DiagnosticAttemptTrigger::Scheduled)
        );

        service.request_account_sync();
        wait_lanes_idle(&service);
        assert_eq!(
            *backend.account_trigger.lock().expect("account trigger"),
            Some(DiagnosticAttemptTrigger::Scheduled)
        );

        service.shutdown();
        drop(service);
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_blocked_account_poll_is_kept_pending() {
        let root = std::env::temp_dir().join(format!("quota-account-pending-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = Arc::new(RecordingLaneBackend::new());
        let service = LocalService::new(
            state.clone(),
            Arc::new(RecordingSink::default()),
            backend.clone(),
        );

        assert!(
            service
                .request_lane(RefreshLane::Quota, DiagnosticAttemptTrigger::Scheduled)
                .accepted
        );
        backend.wait_quota_started();
        let blocked =
            service.request_lane(RefreshLane::Account, DiagnosticAttemptTrigger::Scheduled);
        assert!(!blocked.accepted);
        assert!(blocked.pending);
        {
            let refresh = service.inner.refresh.lock().expect("refresh");
            assert!(refresh.pending_account);
            assert!(refresh.account.is_none());
        }
        assert_eq!(backend.account_calls.load(Ordering::SeqCst), 0);
        backend.release_quota();
        wait_lanes_idle(&service);
        assert!(backend.account_calls.load(Ordering::SeqCst) >= 1);
        assert_eq!(
            *backend.account_trigger.lock().expect("account trigger"),
            Some(DiagnosticAttemptTrigger::Scheduled)
        );

        service.shutdown();
        drop(service);
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }
}
