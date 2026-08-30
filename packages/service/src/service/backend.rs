//! Production backend adapter.  The service owns orchestration; this adapter owns the concrete
//! provider, Usage, pricing, and Relay calls and returns only protocol-shaped values.

use std::cell::Cell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use chrono::{
    DateTime, Days, Duration, LocalResult, NaiveDate, SecondsFormat, TimeZone, Timelike, Utc,
};
use chrono_tz::Tz;
use serde_json::{Value, json};

use crate::catalog::ProviderId;
use crate::observation::snapshot_is_current;
use crate::pricing;
use crate::protocol::{
    BrowserAccessDenialReason, DIAGNOSTIC_SCHEMA_VERSION, DiagnosticAttemptCode,
    DiagnosticAttemptKind, DiagnosticAttemptOutcome, DiagnosticAttemptTrigger, DiagnosticAttention,
    DiagnosticClient, DiagnosticDataState, DiagnosticOperation, DiagnosticRecovery,
    DiagnosticReport, DiagnosticSourceState, DiagnosticStatus, DiagnosticSummary,
    DiagnosticSurface, ErrorCode, IpcError, MANAGED_DATA_PROTOCOL, MAXIMUM_DIAGNOSTIC_SOURCES,
    QuotaOverviewIdentity, QuotaOverviewItem, QuotaOverviewSource, RecoveryAction, UsagePeriod,
    UsageSource,
};
use crate::providers::claude;
use crate::providers::codex;
use crate::providers::common::{
    CliTool, ErrorCategory, ProbeCache, ProbeEnvironment, ProviderError, ProviderSession,
    RenewalAttempts, resolve_cli_versions,
};
use crate::providers::grok;
use crate::providers::{self, CollectionContext};
use crate::relay::{AccountManager, RelayClient};
use crate::service::{BackendError, LocalBackend, LoginOutcome, RefreshOutcome, RefreshSink};
use crate::state::{
    DiagnosticAttemptCompletion, DiagnosticAttemptHandle, StateStore, UsageOutboxEntry, now_rfc3339,
};
use crate::usage::{
    self, CoverageReasonCode, CoverageStatus, DatedUsageRow, UsageAgent, UsageScanOptions,
};

/// How many recomputed hours one refresh hands to the outbox. Four requests' worth: enough to
/// keep a steady device empty, small enough that a first sign-in does not stage a year at once.
const MAX_STAGED_HOURS_PER_REFRESH: usize = usage::MAX_USAGE_HOURS_PER_UPLOAD * 4;
/// The widest lower bound there is, for a count that could not read a narrower one.
const EPOCH_HOUR: &str = "1970-01-01T00:00:00Z";

fn plural(value: i64, singular: &str) -> String {
    format!("{value} {singular}{}", if value == 1 { "" } else { "s" })
}

/// The reason a scan gives that a person can act on, out of the bounded reason counts.
///
/// Access and malformed input are worth naming; a file that grew while it was being read is
/// ordinary and is only mentioned when nothing worse happened.
fn worst_usage_scan_reason(value: &Value) -> Option<&'static str> {
    const ORDER: [&str; 12] = [
        "permission_denied",
        "source_unreadable",
        "malformed_json",
        "unknown_record",
        "invalid_timestamp",
        "invalid_model",
        "invalid_usage",
        "line_too_large",
        "record_limit",
        "discovery_limit",
        "truncated_tail",
        "source_changed",
    ];
    let counts = value.get("reason_counts").and_then(Value::as_object)?;
    ORDER
        .into_iter()
        .chain(["scan_cancelled"])
        .find(|code| counts.get(*code).and_then(Value::as_i64).unwrap_or(0) > 0)
}

const fn operation_for(status: DiagnosticStatus) -> DiagnosticOperation {
    match status {
        DiagnosticStatus::Ok | DiagnosticStatus::Inactive => DiagnosticOperation::Healthy,
        DiagnosticStatus::Degraded => DiagnosticOperation::Degraded,
        DiagnosticStatus::Blocked => DiagnosticOperation::Blocked,
    }
}

/// Who has to act. Work QuotaBar will redo on its own is `automatic`; anything whose fix is in
/// someone's hands is `required`.
const fn attention_for(recovery: DiagnosticRecovery) -> DiagnosticAttention {
    match recovery {
        DiagnosticRecovery::None => DiagnosticAttention::None,
        DiagnosticRecovery::Automatic | DiagnosticRecovery::Retry => DiagnosticAttention::Automatic,
        _ => DiagnosticAttention::Required,
    }
}

const fn worst_attention(
    left: DiagnosticAttention,
    right: DiagnosticAttention,
) -> DiagnosticAttention {
    match (left, right) {
        (DiagnosticAttention::Required, _) | (_, DiagnosticAttention::Required) => {
            DiagnosticAttention::Required
        }
        (DiagnosticAttention::Automatic, _) | (_, DiagnosticAttention::Automatic) => {
            DiagnosticAttention::Automatic
        }
        _ => DiagnosticAttention::None,
    }
}

fn array_len(value: Option<&Value>, key: &str) -> i64 {
    value
        .and_then(Value::as_object)
        .and_then(|object| object.get(key))
        .and_then(Value::as_array)
        .map(|items| items.len() as i64)
        .unwrap_or(0)
}

fn error_code_wire(code: ErrorCode) -> String {
    serde_json::to_value(code)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "unknown_error".to_owned())
}

fn failed_sign_in_message(error: &IpcError) -> String {
    let code = error_code_wire(error.code);
    if error.code == ErrorCode::Unavailable {
        format!("{code}: browser could not be opened")
    } else {
        format!("The last sign-in did not finish ({code}).")
    }
}

fn backend_attempt_error(error: &IpcError) -> (DiagnosticAttemptOutcome, DiagnosticAttemptCode) {
    if error.code == ErrorCode::Cancelled {
        return (
            DiagnosticAttemptOutcome::Cancelled,
            DiagnosticAttemptCode::Cancelled,
        );
    }
    let code = match error.code {
        ErrorCode::AuthenticationRequired | ErrorCode::StaleGeneration => {
            DiagnosticAttemptCode::AuthenticationRequired
        }
        ErrorCode::DeviceDeleted => DiagnosticAttemptCode::DeviceDeleted,
        ErrorCode::NetworkError => DiagnosticAttemptCode::NetworkError,
        ErrorCode::InvalidResponse => DiagnosticAttemptCode::InvalidResponse,
        ErrorCode::InvalidState => DiagnosticAttemptCode::InvalidState,
        ErrorCode::ClientUpgradeRequired => DiagnosticAttemptCode::ClientUpgradeRequired,
        ErrorCode::ProviderError => DiagnosticAttemptCode::ProviderError,
        ErrorCode::Cancelled => DiagnosticAttemptCode::Cancelled,
        ErrorCode::InvalidRequest
        | ErrorCode::UnsupportedOperation
        | ErrorCode::Busy
        | ErrorCode::Unavailable
        | ErrorCode::Internal => DiagnosticAttemptCode::Unavailable,
    };
    (DiagnosticAttemptOutcome::Failed, code)
}

fn diagnostic_attempt_code_wire(value: DiagnosticAttemptCode) -> &'static str {
    match value {
        DiagnosticAttemptCode::ProcessInterrupted => "process_interrupted",
        DiagnosticAttemptCode::Cancelled => "cancelled",
        DiagnosticAttemptCode::NoWork => "no_work",
        DiagnosticAttemptCode::AuthenticationRequired => "authentication_required",
        DiagnosticAttemptCode::NetworkError => "network_error",
        DiagnosticAttemptCode::Unavailable => "unavailable",
        DiagnosticAttemptCode::InvalidResponse => "invalid_response",
        DiagnosticAttemptCode::InvalidState => "invalid_state",
        DiagnosticAttemptCode::ProviderError => "provider_error",
        DiagnosticAttemptCode::AccessDenied => "access_denied",
        DiagnosticAttemptCode::ClientUpgradeRequired => "client_upgrade_required",
        DiagnosticAttemptCode::PartialSource => "partial_source",
        DiagnosticAttemptCode::MalformedData => "malformed_data",
        DiagnosticAttemptCode::TruncatedActiveSource => "truncated_active_source",
        DiagnosticAttemptCode::DeviceDeleted => "device_deleted",
    }
}

thread_local! {
    static LANE_ATTEMPT_TRIGGER: Cell<Option<DiagnosticAttemptTrigger>> =
        const { Cell::new(None) };
}

struct LaneAttemptTriggerGuard;

impl Drop for LaneAttemptTriggerGuard {
    fn drop(&mut self) {
        LANE_ATTEMPT_TRIGGER.with(|slot| slot.set(None));
    }
}

fn enter_lane_attempt_trigger(trigger: DiagnosticAttemptTrigger) -> LaneAttemptTriggerGuard {
    LANE_ATTEMPT_TRIGGER.with(|slot| slot.set(Some(trigger)));
    LaneAttemptTriggerGuard
}

pub struct NativeBackend {
    state: Arc<StateStore>,
    relay: Arc<RelayClient>,
    account: AccountManager,
    home: PathBuf,
    environment: HashMap<String, String>,
    client_name: String,
    client_version: String,
    /// Held closed by a test in front of provider collection, so a refresh can be observed
    /// while collection is provably still running.
    #[cfg(test)]
    collection_gate: Option<Arc<RefreshGate>>,
    /// Held closed by a test just after the refresh's own Account read has decided, so a test
    /// can act on what that read found before anything else in the refresh moves.
    #[cfg(test)]
    account_read_gate: Option<Arc<RefreshGate>>,
}

/// A latch a test closes inside a refresh.
///
/// It reports when the refresh reached it, waits to be opened, and remembers whether it timed
/// out rather than blocking forever — so ordering is proven by what actually released it rather
/// than by how long a test slept.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct RefreshGate {
    state: std::sync::Mutex<RefreshGateState>,
    changed: std::sync::Condvar,
}

#[cfg(test)]
#[derive(Default)]
struct RefreshGateState {
    arrived: bool,
    open: bool,
    timed_out: bool,
}

#[cfg(test)]
impl RefreshGate {
    fn hold(&self) {
        let mut state = self.state.lock().expect("refresh gate");
        state.arrived = true;
        self.changed.notify_all();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !state.open {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                state.timed_out = true;
                return;
            }
            let (guard, _) = self
                .changed
                .wait_timeout(state, remaining)
                .expect("refresh gate wait");
            state = guard;
        }
    }

    pub(crate) fn wait_arrived(&self) {
        let mut state = self.state.lock().expect("refresh gate");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !state.arrived {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!remaining.is_zero(), "the refresh never reached the gate");
            let (guard, _) = self
                .changed
                .wait_timeout(state, remaining)
                .expect("refresh gate wait");
            state = guard;
        }
    }

    pub(crate) fn open(&self) {
        self.state.lock().expect("refresh gate").open = true;
        self.changed.notify_all();
    }

    pub(crate) fn timed_out(&self) -> bool {
        self.state.lock().expect("refresh gate").timed_out
    }
}

impl NativeBackend {
    pub fn new(
        state: Arc<StateStore>,
        relay: Arc<RelayClient>,
        client_name: &str,
        client_version: &str,
    ) -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"));
        let device_name = crate::relay::local_device_display_name(client_name);
        let account = AccountManager::new(relay.clone(), state.clone(), device_name);
        Self {
            state,
            relay,
            account,
            home,
            environment: std::env::vars().collect(),
            client_name: client_name.to_owned(),
            client_version: client_version.to_owned(),
            #[cfg(test)]
            collection_gate: None,
            #[cfg(test)]
            account_read_gate: None,
        }
    }

    /// Opens a journal row for work that is about to run.
    ///
    /// A cache that cannot take the row answers `None`, and the work runs anyway: the journal is
    /// evidence about collection, not a permit to collect. Lane work inherits the trigger the
    /// scheduler (or a person) started it with; a coordinated refresh's children inherit theirs.
    fn begin_attempt(
        &self,
        kind: DiagnosticAttemptKind,
        subject: Option<&str>,
    ) -> Option<DiagnosticAttemptHandle> {
        let parent = self.state.running_refresh_attempt().ok().flatten();
        let trigger = parent
            .map(|(_, trigger)| trigger)
            .or_else(|| LANE_ATTEMPT_TRIGGER.with(|slot| slot.get()))
            .unwrap_or(DiagnosticAttemptTrigger::Manual);
        self.state.begin_diagnostic_attempt(
            kind,
            trigger,
            subject,
            parent.map(|(handle, _)| handle),
        )
    }

    fn finish_attempt(
        &self,
        handle: Option<DiagnosticAttemptHandle>,
        outcome: DiagnosticAttemptOutcome,
        code: Option<DiagnosticAttemptCode>,
    ) {
        self.state
            .finish_diagnostic_attempt(handle, &DiagnosticAttemptCompletion::new(outcome, code));
    }

    fn finish_backend_result_attempt<T>(
        &self,
        handle: Option<DiagnosticAttemptHandle>,
        result: &Result<T, BackendError>,
    ) {
        match result {
            Ok(_) => self.finish_attempt(handle, DiagnosticAttemptOutcome::Success, None),
            Err(error) => {
                let (outcome, code) = backend_attempt_error(&error.error);
                self.finish_attempt(handle, outcome, Some(code));
            }
        }
    }

    /// Collect provider quota without Usage, pricing, account synchronization, or uploads.
    ///
    /// This is the local-only path used by diagnostic/status callers.  Full refresh remains the
    /// only path that performs account synchronization and outbox work.
    pub fn collect_quota(&self, cancel: Arc<AtomicBool>) -> Result<Value, BackendError> {
        self.collect_quota_for(ProviderId::ALL, cancel, false)
    }

    /// Discover providers through the same provider-owned credential paths used for collection.
    /// No account or Relay state is read or changed.
    #[cfg(test)]
    pub fn configured_providers(&self) -> Result<Vec<ProviderId>, BackendError> {
        let context = self.collection_context(Arc::new(AtomicBool::new(false)))?;
        Ok(ProviderId::ALL
            .iter()
            .copied()
            .filter(|provider| !providers::discover(*provider, &context).is_empty())
            .collect())
    }

    /// The last completed report, or a fresh one if this device has never finished a refresh.
    ///
    /// `generated_at` is when the evaluation happened, not when it was asked for, so a caller
    /// waiting on a recheck can tell a new report from the one it already has.
    pub fn diagnostic_report(&self) -> Result<DiagnosticReport, BackendError> {
        let Some(mut report) = self
            .state
            .diagnostic_snapshot()
            .map_err(|_| BackendError::unavailable())?
        else {
            return self.evaluate_diagnostic_report(false);
        };
        report.client = self.diagnostic_client();
        report.recent = self
            .state
            .diagnostic_recent_attempts()
            .map_err(|_| BackendError::unavailable())?;
        Ok(report)
    }

    pub fn complete_diagnostic_report(&self) -> Result<DiagnosticReport, BackendError> {
        let report = self.evaluate_diagnostic_report(true)?;
        let _ = self.state.write_diagnostic_snapshot(&report);
        Ok(report)
    }

    fn diagnostic_client(&self) -> DiagnosticClient {
        DiagnosticClient {
            name: self.client_name.clone(),
            version: self.client_version.clone(),
        }
    }

    fn evaluate_diagnostic_report(
        &self,
        allow_usage_index_reads: bool,
    ) -> Result<DiagnosticReport, BackendError> {
        let now = now_rfc3339();
        let snapshot = self
            .state
            .snapshot_for_diagnostics()
            .map_err(|_| BackendError::unavailable())?;
        let recent = self
            .state
            .diagnostic_recent_attempts()
            .map_err(|_| BackendError::unavailable())?;
        let quota = self
            .state
            .component(crate::protocol::ComponentName::Quota)
            .map_err(|_| BackendError::unavailable())?;
        let usage = self
            .state
            .component(crate::protocol::ComponentName::Usage)
            .map_err(|_| BackendError::unavailable())?;
        let pricing = self
            .state
            .component(crate::protocol::ComponentName::Pricing)
            .map_err(|_| BackendError::unavailable())?;
        let account = self
            .state
            .component(crate::protocol::ComponentName::Account)
            .map_err(|_| BackendError::unavailable())?;
        let session = self
            .state
            .session_json()
            .map_err(|_| BackendError::unavailable())?;
        let usage_upload_enabled = snapshot.usage_upload_enabled;
        let account_active = session
            .as_ref()
            .is_some_and(|value| value.get("status").and_then(Value::as_str) == Some("active"));
        let account_signed_in = account.as_ref().is_some_and(|record| {
            record
                .value
                .as_ref()
                .and_then(|value| value.get("auth_status"))
                .and_then(Value::as_str)
                == Some("signed_in")
        });

        let explicit_providers = snapshot
            .providers
            .iter()
            .filter(|value| value.configured)
            .map(|value| value.provider.as_str())
            .chain(
                snapshot
                    .provider_browser_sessions
                    .iter()
                    .filter(|value| value.configured)
                    .map(|value| value.provider.as_str()),
            )
            .collect::<HashSet<_>>();
        let mut sources = Vec::new();

        // Quota Overview.
        let mut current_quota = 0i64;
        for item in &snapshot.overview {
            if !item.is_stale {
                current_quota = current_quota.saturating_add(1);
            }
        }
        let quota_data = if snapshot.overview.is_empty() {
            DiagnosticDataState::Empty
        } else if current_quota > 0 {
            DiagnosticDataState::Current
        } else {
            DiagnosticDataState::Stale
        };

        let mut configured_quota_source_failed = false;
        if let Some(results) = quota
            .as_ref()
            .and_then(|record| record.value.as_ref())
            .and_then(|value| value.get("results"))
            .and_then(Value::as_array)
        {
            for result in results {
                let Some(provider) = result.get("provider").and_then(Value::as_str) else {
                    continue;
                };
                let explicit = explicit_providers.contains(provider);
                let subject = format!("provider:{provider}");
                // The journal answers when the collection ran; the report in hand answers what
                // it found.
                let facts = self
                    .state
                    .diagnostic_attempt_facts(
                        DiagnosticAttemptKind::QuotaCollection,
                        Some(&subject),
                    )
                    .map_err(|_| BackendError::unavailable())?;
                let report_sources = result
                    .get("sources")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_default();
                if !explicit && report_sources.is_empty() {
                    continue;
                }
                let outcome = result
                    .get("outcome")
                    .and_then(Value::as_str)
                    .unwrap_or("error");
                let snapshots = array_len(Some(result), "snapshots");
                if outcome == "success" && snapshots > 0 {
                    sources.push(DiagnosticSourceState {
                        subject,
                        source_id: report_sources
                            .iter()
                            .rev()
                            .find(|source| {
                                source.get("outcome").and_then(Value::as_str) == Some("success")
                            })
                            .and_then(|source| source.get("source_id"))
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                        status: DiagnosticStatus::Ok,
                        last_attempt_at: facts.last_attempt_at,
                        last_success_at: facts.last_success_at,
                        code: None,
                        message: "Quota was read on this Mac.".into(),
                        recovery: DiagnosticRecovery::None,
                    });
                    continue;
                }
                // The row names the rung that failed, because "Claude could not be read" and
                // "the browser session saved for Claude went stale" are different problems with
                // different fixes.
                let failing_source = report_sources
                    .iter()
                    .rev()
                    .find(|source| source.get("outcome").and_then(Value::as_str) != Some("success"))
                    .and_then(|source| source.get("source_id"))
                    .and_then(Value::as_str);
                let access_denied =
                    result.get("access_denied").and_then(Value::as_bool) == Some(true);
                let code = match outcome {
                    _ if access_denied => "access_denied",
                    "auth_required" => "auth_required",
                    "unsupported" => "unsupported",
                    "unavailable" => "unavailable",
                    _ => "provider_error",
                };
                let recovery = match code {
                    "auth_required" => DiagnosticRecovery::ConfigureProvider,
                    // Signing in again rewrites a secret this Mac still would not be handed, and
                    // retrying asks for it once more every five minutes.
                    "access_denied" => DiagnosticRecovery::CheckAccess,
                    "unsupported" => DiagnosticRecovery::None,
                    _ => DiagnosticRecovery::Retry,
                };
                let status = match code {
                    "unsupported" => DiagnosticStatus::Inactive,
                    _ => DiagnosticStatus::Degraded,
                };
                configured_quota_source_failed |= explicit && status != DiagnosticStatus::Inactive;
                let message = match code {
                    "auth_required" => ProviderId::parse(provider)
                        .map(|id| auth_required_message(id, failing_source.unwrap_or("")))
                        .unwrap_or("The saved sign-in expired or was rejected. Sign in again."),
                    "access_denied" if provider == "claude" => {
                        "QuotaBar could not read Claude Code's Keychain item. Open Claude Code \
                         to refresh the sign-in."
                    }
                    "access_denied" => {
                        "macOS did not release the saved sign-in for this source. Allow QuotaBar \
                         access in System Settings, then recheck."
                    }
                    "unsupported" => "This source cannot be read on this Mac.",
                    "unavailable" => {
                        "This source could not be reached. QuotaBar will try again at the next \
                         refresh."
                    }
                    _ if explicit => {
                        "Configured collection on this Mac returned no quota. QuotaBar will try \
                         again at the next refresh."
                    }
                    _ => {
                        "A source this Mac found could not be read. QuotaBar will try again at \
                         the next refresh."
                    }
                };
                sources.push(DiagnosticSourceState {
                    subject,
                    source_id: failing_source.map(str::to_owned),
                    status,
                    last_attempt_at: facts.last_attempt_at,
                    last_success_at: facts.last_success_at,
                    code: Some(code.to_owned()),
                    message: message.into(),
                    recovery,
                });
            }
        }

        // A browser cookie store macOS refused this Mac. It is not a provider failure and no
        // refresh will clear it: it stands until a permission is granted, so it gets its own
        // row rather than being folded into the provider's collection outcome.
        for (provider, denial) in self
            .state
            .browser_access_denials()
            .map_err(|_| BackendError::unavailable())?
        {
            sources.push(DiagnosticSourceState {
                subject: format!("provider:{provider}"),
                source_id: Some(providers::BROWSER_SESSION_SOURCE.to_owned()),
                status: DiagnosticStatus::Blocked,
                last_attempt_at: Some(denial.denied_at.clone()),
                last_success_at: None,
                code: Some("browser_access_denied".into()),
                message: browser_access_denied_message(&denial),
                recovery: DiagnosticRecovery::CheckAccess,
            });
        }

        let (config_present, config_readable) = self.state.provider_config_status();
        if config_present && !config_readable {
            sources.push(DiagnosticSourceState {
                subject: "provider_configuration".into(),
                source_id: None,
                status: DiagnosticStatus::Blocked,
                last_attempt_at: Some(now.clone()),
                last_success_at: None,
                code: Some("config_unreadable".into()),
                message: "Saved provider settings cannot be read safely. Open Agents and set the \
                          provider up again, then recheck."
                    .into(),
                recovery: DiagnosticRecovery::ConfigureProvider,
            });
        }

        // Usage on this device. A cache that was thrown away has no local history yet, so every
        // Usage answer it can give is partial until one complete scan has run.
        let force_usage_partial = snapshot.cache.rebuilding;
        let last_good_local_usage = [
            &snapshot.usage_periods.local.today,
            &snapshot.usage_periods.local.last_7_days,
            &snapshot.usage_periods.local.last_30_days,
            &snapshot.usage_periods.local.all,
        ]
        .into_iter()
        .any(Option::is_some)
            || usage.as_ref().is_some_and(|record| record.value.is_some());
        let (record_count, partial_hours, scan_diagnostics) = if allow_usage_index_reads {
            (
                self.state
                    .usage_event_count()
                    .map_err(|_| BackendError::unavailable())?
                    .min(i64::MAX as u64) as i64,
                self.state
                    .partial_usage_hours()
                    .map_err(|_| BackendError::unavailable())?,
                self.state
                    .usage_scan_diagnostics()
                    .map_err(|_| BackendError::unavailable())?,
            )
        } else {
            (0, HashSet::new(), Vec::new())
        };
        let mut usage_partial = force_usage_partial || !partial_hours.is_empty();
        let mut usage_scan_blocked = false;
        for (agent, value, observed_at) in &scan_diagnostics {
            let subject = format!("agent:{}", agent.as_str());
            let facts = self
                .state
                .diagnostic_attempt_facts(DiagnosticAttemptKind::UsageScan, Some(&subject))
                .map_err(|_| BackendError::unavailable())?;
            let status = value.get("status").and_then(Value::as_str);
            let partial = status == Some("partial") || status == Some("blocked");
            usage_partial |= partial;
            let reason = worst_usage_scan_reason(value);
            let blocked = status == Some("blocked");
            usage_scan_blocked |= blocked;
            let (status, code, message, recovery) = match (blocked, reason) {
                (true, _) => (
                    DiagnosticStatus::Blocked,
                    Some("scan_unavailable"),
                    "This Usage source could not be read. Check that QuotaBar can reach this \
                     agent's data, then recheck.",
                    DiagnosticRecovery::CheckAccess,
                ),
                (false, Some(reason @ ("permission_denied" | "source_unreadable"))) => (
                    DiagnosticStatus::Degraded,
                    Some(reason),
                    "Part of this Usage source could not be read. Check that QuotaBar can reach \
                     this agent's data, then recheck.",
                    DiagnosticRecovery::CheckAccess,
                ),
                (
                    false,
                    Some(reason @ ("truncated_tail" | "source_changed" | "scan_cancelled")),
                ) => (
                    DiagnosticStatus::Ok,
                    Some(reason),
                    "The source changed while it was being scanned. The next refresh picks up \
                     the rest.",
                    DiagnosticRecovery::Automatic,
                ),
                (false, Some(reason @ ("discovery_limit" | "record_limit"))) => (
                    DiagnosticStatus::Degraded,
                    Some(reason),
                    "This Usage source is larger than one scan reads, so the part past that \
                     bound was not read.",
                    DiagnosticRecovery::None,
                ),
                (false, Some(reason)) => (
                    DiagnosticStatus::Degraded,
                    Some(reason),
                    "Invalid Usage records were skipped and the valid ones were kept. Update the \
                     app or CLI that wrote them, then recheck.",
                    DiagnosticRecovery::UpdateSource,
                ),
                (false, None) => (
                    DiagnosticStatus::Ok,
                    None,
                    "Usage records were read on this Mac.",
                    DiagnosticRecovery::None,
                ),
            };
            sources.push(DiagnosticSourceState {
                subject,
                source_id: None,
                status,
                last_attempt_at: facts
                    .last_attempt_at
                    .clone()
                    .or_else(|| Some(observed_at.clone())),
                last_success_at: facts.last_success_at,
                code: code.map(str::to_owned),
                message: message.into(),
                recovery,
            });
        }

        // Account.
        let account_facts = self
            .state
            .diagnostic_attempt_facts(DiagnosticAttemptKind::AccountSync, None)
            .map_err(|_| BackendError::unavailable())?;
        let account_attempt_failed = account_active
            && matches!(
                account_facts.last_outcome,
                Some(DiagnosticAttemptOutcome::Failed | DiagnosticAttemptOutcome::Interrupted)
            );
        let account_degraded = match account.as_ref().map(|value| value.status) {
            Some(
                crate::protocol::ComponentStatus::Stale
                | crate::protocol::ComponentStatus::AuthRequired
                | crate::protocol::ComponentStatus::Error,
            ) if account_signed_in || account_active => true,
            _ => account_attempt_failed,
        };
        let account_error = account.as_ref().and_then(|value| value.last_error.as_ref());
        let account_needs_login = account_error.is_some_and(|value| value.code.requires_login());
        let failed_sign_in = !account_signed_in
            && !account_active
            && account_error.is_some_and(|error| {
                !error.code.requires_login() && error.code != ErrorCode::Cancelled
            });
        if account_active || account_signed_in {
            sources.push(DiagnosticSourceState {
                subject: "account".into(),
                source_id: None,
                status: if account_degraded {
                    DiagnosticStatus::Degraded
                } else {
                    DiagnosticStatus::Ok
                },
                last_attempt_at: account_facts.last_attempt_at.clone(),
                last_success_at: account_facts.last_success_at.clone(),
                code: account_degraded
                    .then(|| {
                        account_error
                            .map(|value| error_code_wire(value.code))
                            .unwrap_or_else(|| "account_unavailable".into())
                    })
                    .clone(),
                message: match (account_degraded, account_needs_login) {
                    (false, _) => "Account data is up to date.",
                    (true, true) => {
                        "This Mac is no longer signed in to the account. Reconnect Account in \
                         Settings, then recheck."
                    }
                    (true, false) => {
                        "Account data could not be refreshed. QuotaBar will try again at the next \
                         refresh."
                    }
                }
                .into(),
                recovery: match (account_degraded, account_needs_login) {
                    (false, _) => DiagnosticRecovery::None,
                    (true, true) => DiagnosticRecovery::Login,
                    (true, false) => DiagnosticRecovery::Retry,
                },
            });
        } else if failed_sign_in {
            let error = account_error.expect("failed sign-in last_error");
            sources.push(DiagnosticSourceState {
                subject: "account".into(),
                source_id: None,
                status: DiagnosticStatus::Degraded,
                last_attempt_at: account_facts.last_attempt_at.clone(),
                last_success_at: account_facts.last_success_at.clone(),
                code: Some(error_code_wire(error.code)),
                message: failed_sign_in_message(error),
                recovery: DiagnosticRecovery::Login,
            });
        }

        // Usage upload.
        let outbox_count = self
            .state
            .outbox_len()
            .map_err(|_| BackendError::unavailable())?;
        let uploadable_dirty_count = self.uploadable_dirty_hour_count()?;
        let upload_facts = self
            .state
            .diagnostic_attempt_facts(DiagnosticAttemptKind::UsageUpload, None)
            .map_err(|_| BackendError::unavailable())?;
        let upload_waiting = outbox_count + uploadable_dirty_count > 0;
        // A closed range waiting for the next scheduler pass is normal automatic work. Only a
        // completed attempt that did not make progress is a problem, and while work remains a
        // later `no_work` does not retire it.
        let upload_problem = match upload_facts.last_outcome {
            Some(
                DiagnosticAttemptOutcome::Failed
                | DiagnosticAttemptOutcome::Interrupted
                | DiagnosticAttemptOutcome::Partial,
            ) => upload_facts
                .unresolved_code
                .or(Some(crate::protocol::DiagnosticAttemptCode::Unavailable)),
            _ if upload_waiting => upload_facts.unresolved_code,
            _ => None,
        };
        let upload_active = account_active && usage_upload_enabled;
        let upload_failed = upload_active && upload_problem.is_some();
        let upload_blocked =
            upload_failed && upload_problem == Some(DiagnosticAttemptCode::InvalidState);
        if upload_active {
            sources.push(DiagnosticSourceState {
                subject: "usage_upload".into(),
                source_id: None,
                status: match (upload_blocked, upload_failed) {
                    (true, _) => DiagnosticStatus::Blocked,
                    (false, true) => DiagnosticStatus::Degraded,
                    _ => DiagnosticStatus::Ok,
                },
                last_attempt_at: upload_facts.last_attempt_at.clone(),
                last_success_at: upload_facts.last_success_at.clone(),
                code: upload_problem.map(|code| diagnostic_attempt_code_wire(code).to_owned()),
                message: match (upload_blocked, upload_failed, upload_waiting) {
                    (true, _, _) => {
                        "Usage upload cannot continue with the local state as it is. Reset local \
                         data from Support, then recheck."
                    }
                    (false, true, _) => {
                        "The last Usage upload did not go through. QuotaBar will try again at the \
                         next refresh."
                    }
                    (false, false, true) => {
                        "Usage is waiting for the next upload. QuotaBar sends it at the next \
                         refresh."
                    }
                    _ => "Usage is uploaded to the account.",
                }
                .into(),
                recovery: match (upload_blocked, upload_failed, upload_waiting) {
                    (true, _, _) => DiagnosticRecovery::Reinstall,
                    (false, true, _) => DiagnosticRecovery::Retry,
                    (false, false, true) => DiagnosticRecovery::Automatic,
                    _ => DiagnosticRecovery::None,
                },
            });
        }

        // Pricing catalog.
        let pricing_value = pricing.as_ref().and_then(|value| value.value.as_ref());
        let pricing_valid =
            pricing_value.is_some_and(|value| pricing::validate_pricing_catalog(value).valid);
        let pricing_required = record_count > 0;
        let pricing_facts = self
            .state
            .diagnostic_attempt_facts(DiagnosticAttemptKind::PricingRefresh, None)
            .map_err(|_| BackendError::unavailable())?;
        let pricing_failed = pricing_required
            && ((pricing_value.is_some() && !pricing_valid)
                || matches!(
                    pricing_facts.last_outcome,
                    Some(DiagnosticAttemptOutcome::Failed | DiagnosticAttemptOutcome::Interrupted)
                ));
        sources.push(DiagnosticSourceState {
            subject: "pricing_catalog".into(),
            source_id: None,
            status: match (pricing_required, pricing_failed) {
                (false, _) => DiagnosticStatus::Inactive,
                (true, true) => DiagnosticStatus::Degraded,
                (true, false) => DiagnosticStatus::Ok,
            },
            last_attempt_at: pricing_facts.last_attempt_at.clone(),
            last_success_at: pricing_facts.last_success_at.clone(),
            code: pricing_failed.then(|| "invalid_catalog".to_owned()),
            message: match (pricing_required, pricing_failed) {
                (false, _) => "No Usage records need prices yet.",
                (true, true) => {
                    "Prices could not be loaded, so costs may be missing. Token totals are still \
                     exact."
                }
                (true, false) => "Prices are loaded.",
            }
            .into(),
            recovery: if pricing_failed {
                DiagnosticRecovery::Retry
            } else {
                DiagnosticRecovery::None
            },
        });

        // An identity this device could not read is the one loss a refresh cannot undo, so the
        // person in front of the app is told what happened and what to do about it.
        let identity_reset = self
            .state
            .identity_reset_at()
            .map_err(|_| BackendError::unavailable())?
            .filter(|value| {
                DateTime::parse_from_rfc3339(value)
                    .is_ok_and(|value| Utc::now() - value.with_timezone(&Utc) < Duration::hours(24))
            });
        if let Some(reset_at) = identity_reset {
            sources.push(DiagnosticSourceState {
                subject: "local_state".into(),
                source_id: None,
                status: DiagnosticStatus::Degraded,
                last_attempt_at: Some(reset_at.clone()),
                last_success_at: None,
                code: Some("local_identity_reset".into()),
                message: "Local identity could not be read and was reset. Sign in again.".into(),
                recovery: DiagnosticRecovery::Login,
            });
        }

        // Surfaces.
        let quota_status = if configured_quota_source_failed {
            DiagnosticStatus::Degraded
        } else {
            DiagnosticStatus::Ok
        };
        let surfaces = vec![
            DiagnosticSurface {
                id: "quota_overview".into(),
                status: quota_status,
                data: quota_data,
                last_success_at: quota.as_ref().and_then(|value| value.updated_at.clone()),
                // What a person needs here is whether the numbers on Overview still describe
                // their account, not how many machines each one came from.
                message: match (snapshot.overview.len(), quota_data) {
                    (0, _) => "No quota has been read yet.".to_owned(),
                    (total, DiagnosticDataState::Stale) => format!(
                        "{} shown, none of them current.",
                        plural(total as i64, "subscription")
                    ),
                    (total, _) if current_quota == total as i64 => {
                        format!(
                            "{} shown, all current.",
                            plural(total as i64, "subscription")
                        )
                    }
                    (total, _) => format!(
                        "{} shown, {} not current.",
                        plural(total as i64, "subscription"),
                        total as i64 - current_quota
                    ),
                },
                recovery: if configured_quota_source_failed {
                    DiagnosticRecovery::ConfigureProvider
                } else {
                    DiagnosticRecovery::None
                },
            },
            DiagnosticSurface {
                id: "usage_this_device".into(),
                status: match (usage_scan_blocked, usage.as_ref().map(|value| value.status)) {
                    (true, _) => DiagnosticStatus::Blocked,
                    (false, Some(crate::protocol::ComponentStatus::Error)) => {
                        DiagnosticStatus::Degraded
                    }
                    _ => DiagnosticStatus::Ok,
                },
                data: if usage_partial {
                    DiagnosticDataState::Partial
                } else if record_count > 0 || (!allow_usage_index_reads && last_good_local_usage) {
                    DiagnosticDataState::Current
                } else {
                    DiagnosticDataState::Empty
                },
                last_success_at: usage.as_ref().and_then(|value| value.updated_at.clone()),
                message: if force_usage_partial {
                    "Local Usage history is being rebuilt and is incomplete until the next full \
                     scan finishes."
                        .to_owned()
                } else if record_count > 0 {
                    format!(
                        "{} read from {}.",
                        plural(record_count, "record"),
                        plural(scan_diagnostics.len() as i64, "agent")
                    )
                } else {
                    "No Usage records have been found on this Mac yet.".to_owned()
                },
                recovery: if usage_scan_blocked {
                    DiagnosticRecovery::CheckAccess
                } else if force_usage_partial {
                    DiagnosticRecovery::Automatic
                } else {
                    DiagnosticRecovery::None
                },
            },
            DiagnosticSurface {
                id: "usage_account".into(),
                status: match (usage_upload_enabled && account_signed_in, upload_blocked) {
                    (false, _) => DiagnosticStatus::Inactive,
                    (true, true) => DiagnosticStatus::Blocked,
                    (true, false) if upload_failed => DiagnosticStatus::Degraded,
                    _ => DiagnosticStatus::Ok,
                },
                data: if !usage_upload_enabled || !account_signed_in {
                    DiagnosticDataState::Empty
                } else if [
                    &snapshot.usage_periods.account.today,
                    &snapshot.usage_periods.account.last_7_days,
                    &snapshot.usage_periods.account.last_30_days,
                    &snapshot.usage_periods.account.all,
                ]
                .into_iter()
                .any(Option::is_some)
                {
                    DiagnosticDataState::Current
                } else {
                    DiagnosticDataState::Empty
                },
                last_success_at: upload_facts.last_success_at.clone(),
                message: match (usage_upload_enabled, account_signed_in) {
                    (false, _) => "Usage sync is off, so nothing leaves this Mac.".to_owned(),
                    (true, false) => "Sign in to send Usage to your account.".to_owned(),
                    (true, true) => {
                        "Usage from this Mac is part of your account totals.".to_owned()
                    }
                },
                recovery: DiagnosticRecovery::None,
            },
            DiagnosticSurface {
                id: "account".into(),
                status: if failed_sign_in {
                    DiagnosticStatus::Degraded
                } else {
                    match (account_signed_in || account_active, account_degraded) {
                        (false, _) => DiagnosticStatus::Inactive,
                        (true, true) => DiagnosticStatus::Degraded,
                        (true, false) => DiagnosticStatus::Ok,
                    }
                },
                data: if failed_sign_in || (!account_signed_in && !account_active) {
                    DiagnosticDataState::Empty
                } else if account_degraded {
                    DiagnosticDataState::Stale
                } else {
                    DiagnosticDataState::Current
                },
                last_success_at: account_facts.last_success_at.clone(),
                message: if failed_sign_in {
                    failed_sign_in_message(account_error.expect("failed sign-in last_error"))
                } else {
                    match (account_signed_in || account_active, account_degraded) {
                        (false, _) => "This Mac is not signed in to a Quota account.".to_owned(),
                        (true, true) => {
                            "Account data on screen is the last copy this Mac read.".to_owned()
                        }
                        (true, false) => format!(
                            "Signed in · {}.",
                            plural(
                                array_len(
                                    account
                                        .as_ref()
                                        .and_then(|value| value.value.as_ref())
                                        .and_then(|value| value.get("account_summary")),
                                    "devices",
                                ),
                                "device",
                            )
                        ),
                    }
                },
                recovery: if failed_sign_in || (account_needs_login && account_degraded) {
                    DiagnosticRecovery::Login
                } else if account_degraded {
                    DiagnosticRecovery::Retry
                } else {
                    DiagnosticRecovery::None
                },
            },
        ];

        let operation = surfaces
            .iter()
            .map(|surface| surface.status)
            .fold(DiagnosticOperation::Healthy, |worst, status| {
                worst_operation(worst, operation_for(status))
            });
        let attention = surfaces
            .iter()
            .map(|surface| surface.recovery)
            .chain(sources.iter().map(|source| source.recovery))
            .fold(DiagnosticAttention::None, |worst, recovery| {
                worst_attention(worst, attention_for(recovery))
            });
        // Folded before the cap, so a report never says everything is fine because the row
        // that needed acting on fell off the end of a long list.
        sources.truncate(MAXIMUM_DIAGNOSTIC_SOURCES);

        Ok(DiagnosticReport {
            schema_version: DIAGNOSTIC_SCHEMA_VERSION,
            generated_at: now,
            client: self.diagnostic_client(),
            summary: DiagnosticSummary {
                operation,
                attention,
            },
            surfaces,
            sources,
            recent,
        })
    }

    /// Collect only the selected providers through the local-only path.  This keeps CLI status
    /// provider selection separate from the full refresh that may upload account data.
    pub fn collect_quota_for(
        &self,
        provider_ids: &[ProviderId],
        cancel: Arc<AtomicBool>,
        bypass_renewal_floor: bool,
    ) -> Result<Value, BackendError> {
        #[cfg(test)]
        if let Some(gate) = &self.collection_gate {
            gate.hold();
        }
        let mut context = self.collection_context(cancel.clone())?;
        let captured_at = context.observed_at();
        let diagnostic_snapshot = self
            .state
            .snapshot_for_diagnostics()
            .map_err(|_| BackendError::unavailable())?;
        let configured = diagnostic_snapshot
            .providers
            .into_iter()
            .filter(|value| value.configured)
            .map(|value| value.provider)
            .chain(
                diagnostic_snapshot
                    .provider_browser_sessions
                    .into_iter()
                    .filter(|value| value.configured)
                    .map(|value| value.provider),
            )
            .collect::<HashSet<_>>();
        // Discovery first, then the CLI version probe, then collection: a collector must be
        // handed the version it presents rather than reach for it, so that nothing running on
        // the five-minute timer can start a process of its own.
        let discovered = provider_ids
            .iter()
            .copied()
            .map(|provider| {
                let sessions = providers::discover(provider, &context);
                (provider, sessions)
            })
            .collect::<Vec<_>>();
        context.cli_versions = self.provider_cli_versions(&discovered, &context, &cancel);
        let attempted = self.renew_provider_sign_ins(
            &discovered,
            &mut context,
            bypass_renewal_floor,
            &HashSet::new(),
        );
        let mut attempts = collect_discovered_jobs(&discovered, &configured, &context, |subject| {
            self.begin_attempt(DiagnosticAttemptKind::QuotaCollection, Some(subject))
        });
        if !cancel.load(Ordering::Acquire) {
            let retry = providers_needing_forced_renewal(&attempts);
            let force_for = forced_renewal_targets(&retry, &attempted);
            if !force_for.is_empty() {
                let retry_discovered = discovered
                    .iter()
                    .filter(|(provider, _)| force_for.contains(provider))
                    .cloned()
                    .collect::<Vec<_>>();
                let forced_attempted = self.renew_provider_sign_ins(
                    &retry_discovered,
                    &mut context,
                    bypass_renewal_floor,
                    &force_for,
                );
                if !forced_attempted.is_empty() {
                    let retried_discovered = retry_discovered
                        .iter()
                        .filter(|(provider, _)| forced_attempted.contains(provider))
                        .cloned()
                        .collect::<Vec<_>>();
                    let retried =
                        collect_discovered_jobs(&retried_discovered, &configured, &context, |_| {
                            None
                        });
                    merge_collected_jobs(&mut attempts, retried);
                }
            }
        }
        let cancelled = cancel.load(Ordering::Acquire);
        let mut results = Vec::with_capacity(attempts.len());
        for (_provider, explicit, handle, mut result, panicked) in attempts {
            let result_outcome = result
                .get("outcome")
                .and_then(Value::as_str)
                .unwrap_or("error");
            let (outcome, code) = if cancelled {
                (
                    DiagnosticAttemptOutcome::Cancelled,
                    Some(DiagnosticAttemptCode::Cancelled),
                )
            } else if panicked {
                (
                    DiagnosticAttemptOutcome::Failed,
                    Some(DiagnosticAttemptCode::Unavailable),
                )
            } else {
                let access_denied =
                    result.get("access_denied").and_then(Value::as_bool) == Some(true);
                match result_outcome {
                    // A refusal reads as unavailable to every other device, and names itself
                    // here, because only this Mac can act on it.
                    _ if access_denied => (
                        DiagnosticAttemptOutcome::Failed,
                        Some(DiagnosticAttemptCode::AccessDenied),
                    ),
                    "success" => (DiagnosticAttemptOutcome::Success, None),
                    "auth_required" if !explicit => (
                        DiagnosticAttemptOutcome::NoWork,
                        Some(DiagnosticAttemptCode::AuthenticationRequired),
                    ),
                    "auth_required" => (
                        DiagnosticAttemptOutcome::Failed,
                        Some(DiagnosticAttemptCode::AuthenticationRequired),
                    ),
                    _ => (
                        DiagnosticAttemptOutcome::Failed,
                        Some(DiagnosticAttemptCode::ProviderError),
                    ),
                }
            };
            self.finish_attempt(handle, outcome, code);
            // A collector that panicked reported nothing at all, so the sources it was
            // handed are stated here rather than lost with it.
            if !result["sources"].is_array() {
                result["sources"] = json!([]);
            }
            results.push(result);
        }
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        self.record_proven_credentials(&results, &context);
        Ok(json!({
            "captured_at": captured_at,
            "results": results
        }))
    }

    /// The installed version of every provider CLI this refresh will identify as.
    ///
    /// Only CLIs whose provider actually holds a sign-in here are asked, so a Mac without
    /// Codex never runs `codex --version`.  The answer is a property of the binary, kept in
    /// the cache against its real path, size, and mtime: an unchanged install costs a `stat`,
    /// and `--version` runs at most once per installed binary and at most once an hour.  A
    /// probe that fails or is absent leaves the collector on its own fallback constant, and
    /// nothing about collection waits on it.
    fn provider_cli_versions(
        &self,
        discovered: &[(ProviderId, Vec<ProviderSession>)],
        context: &CollectionContext,
        cancel: &Arc<AtomicBool>,
    ) -> BTreeMap<CliTool, String> {
        let wanted = discovered
            .iter()
            .filter(|(_, sessions)| !sessions.is_empty())
            .filter_map(|(provider, _)| match provider {
                ProviderId::Claude => Some(CliTool::Claude),
                ProviderId::Codex => Some(CliTool::Codex),
                _ => None,
            })
            .collect::<Vec<_>>();
        if wanted.is_empty() {
            return BTreeMap::new();
        }
        let cached = self
            .state
            .provider_cli_versions()
            .ok()
            .flatten()
            .and_then(|raw| serde_json::from_str::<ProbeCache>(&raw).ok())
            .unwrap_or_default();
        let resolution = resolve_cli_versions(
            &wanted,
            &cached,
            &ProbeEnvironment::new(
                context.home_directory.clone(),
                context.env("PATH").map(str::to_owned),
            ),
            crate::providers::common::unix_now(),
            Some(cancel),
        );
        if resolution.changed
            && let Ok(encoded) = serde_json::to_string(&resolution.cache)
        {
            let _ = self.state.write_provider_cli_versions(&encoded);
        }
        resolution.versions
    }

    /// Asks the CLI that owns a provider's sign-in to renew it, when that sign-in is the only
    /// thing standing between the refresh and a reading.
    ///
    /// Three providers hold a token only their own program can renew. Grok's lives about six
    /// hours, Claude Code's about eight, Codex's about ten days, so a Mac that has not opened
    /// one of them lately would otherwise report an expired sign-in until someone does. An
    /// expired grant — and, for Claude Code, a Keychain item this process was refused when
    /// the file holds no usable grant — earns one bounded run of that CLI. A scheduled
    /// refresh asks at most once an hour whatever the last attempt produced. A Recheck or
    /// a manual refresh skips that hour. Each provider states which program and which
    /// conversation; [`crate::providers::common`] owns every bound the three share.
    ///
    /// `force_for` is the second chance: an official collection that came back
    /// `auth_required` even though the file still looks in date. The local clock is not the
    /// account. Those providers are asked even when their expiry predicate is false.
    ///
    /// Runs here, beside the version probe and before collection, so no collector gains the
    /// ability to start a process. Collection reads the credential afterwards and neither
    /// knows nor waits for any of this beyond the renewals' own deadlines.
    fn renew_provider_sign_ins(
        &self,
        discovered: &[(ProviderId, Vec<ProviderSession>)],
        context: &mut CollectionContext,
        bypass_renewal_floor: bool,
        force_for: &HashSet<ProviderId>,
    ) -> HashSet<ProviderId> {
        let signed_in = |wanted: ProviderId| {
            discovered
                .iter()
                .any(|(provider, sessions)| *provider == wanted && !sessions.is_empty())
        };
        let wanted = [ProviderId::Claude, ProviderId::Codex, ProviderId::Grok]
            .into_iter()
            .filter(|provider| signed_in(*provider))
            .collect::<Vec<_>>();
        if wanted.is_empty() {
            return HashSet::new();
        }
        // One read and one write for every provider that asks: the record only exists to hold
        // the hour, and splitting it per provider would split those too.
        let mut attempts = self
            .state
            .provider_refresh_attempts()
            .ok()
            .flatten()
            .and_then(|raw| serde_json::from_str::<RenewalAttempts>(&raw).ok())
            .unwrap_or_default();
        let now = crate::providers::common::unix_now();
        let home = context.home_directory.clone();
        let path = context.env("PATH").map(str::to_owned);
        let mut recorded = false;
        let mut started = HashSet::new();
        for provider in wanted {
            // Omitting the last attempt is how a Recheck or a manual refresh skips that hour;
            // the spawn is still recorded, so the next scheduled refresh waits it out.
            let attempted = if bypass_renewal_floor {
                None
            } else {
                attempts.get(provider.as_str()).cloned()
            };
            let mut environment = ProbeEnvironment::new(home.clone(), path.clone());
            // A renewal waits on the provider's own network round trip, so it is not bounded
            // like a `--version` read; each CLI states how long its own takes.
            let force = force_for.contains(&provider);
            let attempt = match provider {
                ProviderId::Claude => {
                    environment.timeout = claude::refresh::RENEWAL_TIMEOUT;
                    claude::refresh::renew_expired_sign_in_for(
                        context,
                        &environment,
                        attempted.as_ref(),
                        now,
                        force,
                    )
                }
                ProviderId::Codex => {
                    environment.timeout = codex::refresh::RENEWAL_TIMEOUT;
                    codex::refresh::renew_expired_sign_in_for(
                        context,
                        &environment,
                        attempted.as_ref(),
                        now,
                        force,
                    )
                }
                _ => {
                    environment.timeout = grok::refresh::RENEWAL_TIMEOUT;
                    grok::refresh::renew_expired_sign_in_for(
                        context,
                        &environment,
                        attempted.as_ref(),
                        now,
                        force,
                    )
                }
            };
            if let Some(attempt) = attempt {
                attempts.insert(provider.as_str().to_owned(), attempt);
                recorded = true;
                started.insert(provider);
            }
        }
        // An attempt that cannot be recorded must not become an attempt every five minutes,
        // but a cache that cannot be written is already reporting itself elsewhere.
        if recorded && let Ok(encoded) = serde_json::to_string(&attempts) {
            let _ = self.state.write_provider_refresh_attempts(&encoded);
        }
        started
    }

    fn collection_context(
        &self,
        cancel: Arc<AtomicBool>,
    ) -> Result<CollectionContext, BackendError> {
        let browser_sessions = self
            .state
            .provider_browser_sessions()
            .map_err(|_| BackendError::unavailable())?
            .into_iter()
            .fold(
                std::collections::HashMap::<ProviderId, Vec<String>>::new(),
                |mut sessions, (provider, session)| {
                    sessions
                        .entry(provider)
                        .or_default()
                        .push(session.cookie_header);
                    sessions
                },
            );
        Ok(CollectionContext {
            home_directory: self.home.clone(),
            environment: self.environment.clone(),
            config_path: Some(self.state.root().join("providers.json")),
            browser_sessions,
            client_name: self.client_name.clone(),
            client_version: self.client_version.clone(),
            now: Some(now_rfc3339()),
            cancel: Some(cancel),
            keychain: Default::default(),
            cli_versions: BTreeMap::new(),
            proven_credentials: self
                .state
                .proven_provider_credentials()
                .ok()
                .flatten()
                .and_then(|raw| serde_json::from_str(&raw).ok())
                .unwrap_or_default(),
        })
    }

    /// Remembers the credential a provider was just read with.
    ///
    /// Only a rung that spends this device's own credential counts, and only when it answered:
    /// that is the one thing that says an access token this build cannot date is a token that
    /// works. Everything else — a browser session, a rung that failed — leaves the record
    /// alone, so a sign-in that stops working goes back to earning a renewal.
    fn record_proven_credentials(&self, results: &[Value], context: &CollectionContext) {
        let succeeded = |provider: ProviderId, source_id: &str| {
            results.iter().any(|result| {
                result.get("provider").and_then(Value::as_str) == Some(provider.as_str())
                    && result
                        .get("sources")
                        .and_then(Value::as_array)
                        .is_some_and(|sources| {
                            sources.iter().any(|source| {
                                source.get("source_id").and_then(Value::as_str) == Some(source_id)
                                    && source.get("outcome").and_then(Value::as_str)
                                        == Some("success")
                            })
                        })
            })
        };
        let mut proven = context.proven_credentials.clone();
        let before = proven.clone();
        match codex::proven_credential(context)
            .filter(|_| succeeded(ProviderId::Codex, codex::SOURCE))
        {
            Some(fingerprint) => {
                proven.insert(ProviderId::Codex.as_str().to_owned(), fingerprint);
            }
            None => {
                proven.remove(ProviderId::Codex.as_str());
            }
        }
        if proven != before
            && let Ok(encoded) = serde_json::to_string(&proven)
        {
            let _ = self.state.write_proven_provider_credentials(&encoded);
        }
    }

    fn collect_usage(&self, cancel: Arc<AtomicBool>) -> Result<UsageCollection, BackendError> {
        let timezone = self.timezone();
        let completed_hour = floor_utc_hour(&Utc::now());
        let end_at = DateTime::parse_from_rfc3339(&completed_hour)
            .map(|value| {
                (value + chrono::Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Secs, true)
            })
            .unwrap_or(completed_hour);
        let mut agents = Vec::new();
        // One revision for the whole pass: every hour this scan recomputes is stamped with it,
        // and Relay replaces a stored hour only for a strictly newer one.
        let scan_version = self
            .state
            .next_usage_scan_version()
            .map_err(|_| BackendError::unavailable())?;
        for agent in UsageAgent::ALL {
            if cancel.load(Ordering::Acquire) {
                return Err(BackendError::cancelled());
            }
            let file_index = self
                .state
                .usage_file_index(agent)
                .map_err(|_| BackendError::unavailable())?;
            let subject = format!("agent:{}", agent.as_str());
            let attempt = self.begin_attempt(DiagnosticAttemptKind::UsageScan, Some(&subject));
            let options = UsageScanOptions {
                home_directory: Some(self.home.clone()),
                environment: self.environment.clone(),
                // The scanner uses the full retained timeline only to qualify changed files.  It
                // skips unchanged files from the SQLite file index; precise upload ranges come
                // from old/new normalized records in `apply_usage_scan` below.
                start_at: "1970-01-01T00:00:00Z".to_owned(),
                end_at: end_at.clone(),
                cancelled: Some(cancel.clone()),
                parser_revision: usage::DEFAULT_PARSER_REVISION.to_owned(),
                file_index,
                ..UsageScanOptions::default()
            };
            let scan = match usage::scan_local_usage(agent, &options) {
                Ok(scan) => scan,
                Err(_) => {
                    let _ = self.state.write_usage_scan_diagnostics(
                        agent,
                        &json!({"status": "blocked", "reason_counts": {"scan_failed": 1}}),
                    );
                    self.finish_attempt(
                        attempt,
                        DiagnosticAttemptOutcome::Failed,
                        Some(DiagnosticAttemptCode::Unavailable),
                    );
                    return Err(BackendError::new(IpcError::new(
                        ErrorCode::Unavailable,
                        RecoveryAction::Retry,
                    )));
                }
            };
            let _ = self
                .state
                .write_usage_scan_diagnostics(agent, &usage_scan_diagnostic(&scan));
            // Apply complete source files even when another file for the same agent is partial.
            // The state layer keeps the last-good rows for partial sources, so one malformed or
            // unreadable file cannot roll back unrelated complete sources.
            if self
                .state
                .apply_usage_scan(agent, &scan, scan_version)
                .is_err()
            {
                let _ = self.state.write_usage_scan_diagnostics(
                    agent,
                    &json!({"status": "blocked", "reason_counts": {"state_apply_failed": 1}}),
                );
                self.finish_attempt(
                    attempt,
                    DiagnosticAttemptOutcome::Failed,
                    Some(DiagnosticAttemptCode::InvalidState),
                );
                return Err(BackendError::unavailable());
            }
            let (outcome, code) = if scan.scanned_source_count == 0
                && scan.skipped_source_count == 0
                && scan.deleted_source_file_ids.is_empty()
            {
                (
                    DiagnosticAttemptOutcome::NoWork,
                    Some(DiagnosticAttemptCode::NoWork),
                )
            } else if scan.coverage.status == CoverageStatus::Partial {
                let transient = scan.coverage.reasons.iter().all(|reason| {
                    matches!(
                        reason.code,
                        CoverageReasonCode::TruncatedTail | CoverageReasonCode::SourceChanged
                    )
                });
                let malformed = scan.coverage.reasons.iter().any(|reason| {
                    matches!(
                        reason.code,
                        CoverageReasonCode::MalformedJson
                            | CoverageReasonCode::UnknownRecord
                            | CoverageReasonCode::InvalidTimestamp
                            | CoverageReasonCode::InvalidModel
                            | CoverageReasonCode::InvalidUsage
                    )
                });
                (
                    DiagnosticAttemptOutcome::Partial,
                    Some(if transient {
                        DiagnosticAttemptCode::TruncatedActiveSource
                    } else if malformed {
                        DiagnosticAttemptCode::MalformedData
                    } else {
                        DiagnosticAttemptCode::PartialSource
                    }),
                )
            } else {
                (DiagnosticAttemptOutcome::Success, None)
            };
            self.finish_attempt(attempt, outcome, code);
            agents.push(AgentUsage {
                coverage: scan.coverage.clone(),
            });
        }
        Ok(UsageCollection {
            timezone,
            generated_at: now_rfc3339(),
            agents,
        })
    }

    fn usage_report(
        &self,
        usage: &UsageCollection,
        catalog: Option<&pricing::PricingCatalog>,
        model_catalog: Option<&crate::model_catalog::ModelCatalog>,
    ) -> Result<Value, BackendError> {
        let coverage: Vec<Value> = usage
            .agents
            .iter()
            .map(|agent| {
                let status = match agent.coverage.status {
                    CoverageStatus::Complete => "complete",
                    CoverageStatus::Partial => "partial",
                };
                json!({
                    "agent": agent.coverage.agent,
                    "start_at": agent.coverage.start_at,
                    "end_at": agent.coverage.end_at,
                    "status": status
                })
            })
            .collect();
        let status = if coverage
            .iter()
            .all(|item| item.get("status").and_then(Value::as_str) == Some("complete"))
        {
            "complete"
        } else {
            "partial"
        };
        let generated_at = usage::parse_instant(&usage.generated_at).ok_or_else(|| {
            BackendError::new(IpcError::new(
                ErrorCode::InvalidState,
                RecoveryAction::Retry,
            ))
        })?;
        let periods = [
            UsagePeriod::Today,
            UsagePeriod::Last7Days,
            UsagePeriod::Last30Days,
            UsagePeriod::All,
        ]
        .into_iter()
        .map(|period| {
            Ok((
                period,
                self.local_usage_detail(
                    period,
                    &usage.timezone,
                    generated_at,
                    catalog,
                    model_catalog,
                    status == "partial",
                )?,
            ))
        })
        .collect::<Result<Vec<_>, BackendError>>()?;
        self.state
            .replace_usage_periods(UsageSource::Local, &periods)
            .map_err(|_| BackendError::unavailable())?;
        let today = usage_period_window(UsagePeriod::Today, &usage.timezone, generated_at)?.0;
        let (from, to) = periods
            .last()
            .and_then(|(_, detail)| detail.get("range"))
            .and_then(|range| {
                Some((
                    range.get("from")?.as_str()?.to_owned(),
                    range.get("to")?.as_str()?.to_owned(),
                ))
            })
            .unwrap_or_else(|| (today.clone(), today.clone()));
        Ok(json!({
            "generated_at": usage.generated_at,
            "aggregation_timezone": usage.timezone,
            "range": {"from": from, "to": to},
            "status": status,
            "model_catalog_revision": model_catalog.map(|value| value.revision.clone()),
            "coverage": coverage
        }))
    }

    /// One period, folded from the hours this device has stored.
    ///
    /// A local day begins at local midnight, so a period bounds the hours it folds by instant
    /// rather than by UTC date — the same rule the Account read follows, so the two sides of the
    /// panel agree for a Mac keeping the calendar the caller asked about.
    fn local_usage_detail(
        &self,
        period: UsagePeriod,
        timezone: &str,
        generated_at: DateTime<Utc>,
        pricing_catalog: Option<&pricing::PricingCatalog>,
        model_catalog: Option<&crate::model_catalog::ModelCatalog>,
        incomplete: bool,
    ) -> Result<Value, BackendError> {
        let (today, span) = usage_period_window(period, timezone, generated_at)?;
        let (rows, partial) = self
            .state
            .usage_period_rows(
                span.as_ref()
                    .map(|span| (span.start.as_str(), span.end.as_str())),
            )
            .map_err(|_| BackendError::unavailable())?;
        let summary = usage::build_local_usage_summary(&rows, pricing_catalog, model_catalog)
            .map_err(|_| BackendError::unavailable())?;
        let details_truncated = summary.models_truncated || summary.cost.unpriced_truncated;
        let (from, to) = span
            .map(|span| span.dates)
            .unwrap_or_else(|| usage_date_range(&rows, &today));
        Ok(json!({
            "range": {"from": from, "to": to},
            "usage": summary,
            "incomplete": incomplete || partial,
            "details_truncated": details_truncated
        }))
    }

    fn refresh_pricing(&self) -> Result<Value, BackendError> {
        let attempt = self.begin_attempt(DiagnosticAttemptKind::PricingRefresh, None);
        let result = self.refresh_pricing_inner();
        self.finish_backend_result_attempt(attempt, &result);
        result
    }

    fn refresh_pricing_inner(&self) -> Result<Value, BackendError> {
        let old = self
            .state
            .component(crate::protocol::ComponentName::Pricing)
            .ok()
            .flatten()
            .and_then(|component| component.value);
        let local = old;
        let etag = self
            .state
            .pricing_etag()
            .map_err(|_| BackendError::unavailable())?;
        match self.relay.pricing_catalog(etag.as_deref()) {
            Ok((next_etag, Some(value))) if pricing::validate_pricing_catalog(&value).valid => {
                // A new body under the validator that described the old one would answer the
                // next conditional request with a 304 for a document this device no longer
                // holds. A response with no ETag is stored with none.
                self.state
                    .commit_pricing_catalog(&value, next_etag.as_deref())
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((next_etag, None)) => {
                let Some(value) = local else {
                    return Err(BackendError::new(IpcError::new(
                        ErrorCode::InvalidState,
                        RecoveryAction::Retry,
                    )));
                };
                if !pricing::validate_pricing_catalog(&value).valid {
                    return Err(BackendError::new(IpcError::new(
                        ErrorCode::InvalidState,
                        RecoveryAction::Retry,
                    )));
                }
                self.state
                    .commit_pricing_catalog(&value, next_etag.as_deref().or(etag.as_deref()))
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((_, Some(_))) => Err(BackendError::new(IpcError::new(
                ErrorCode::InvalidResponse,
                RecoveryAction::Retry,
            ))),
            Err(error) => Err(BackendError::new(crate::relay::relay_error_for_backend(
                error,
            ))),
        }
    }

    fn refresh_model_catalog(&self) -> Result<Value, BackendError> {
        let local = self.state.model_catalog().ok().flatten();
        let etag = self
            .state
            .model_catalog_etag()
            .map_err(|_| BackendError::unavailable())?;
        match self.relay.model_catalog(etag.as_deref()) {
            Ok((next_etag, Some(value)))
                if crate::model_catalog::validate_model_catalog_value(&value).valid =>
            {
                // As above: a body this device just received is not described by the validator
                // for the one it replaced.
                self.state
                    .commit_model_catalog(&value, next_etag.as_deref())
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((next_etag, None)) => {
                let Some(value) = local else {
                    return Err(BackendError::new(IpcError::new(
                        ErrorCode::InvalidState,
                        RecoveryAction::Retry,
                    )));
                };
                if !crate::model_catalog::validate_model_catalog_value(&value).valid {
                    return Err(BackendError::new(IpcError::new(
                        ErrorCode::InvalidState,
                        RecoveryAction::Retry,
                    )));
                }
                self.state
                    .commit_model_catalog(&value, next_etag.as_deref().or(etag.as_deref()))
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((_, Some(_))) => Err(BackendError::new(IpcError::new(
                ErrorCode::InvalidResponse,
                RecoveryAction::Retry,
            ))),
            Err(error) => Err(BackendError::new(crate::relay::relay_error_for_backend(
                error,
            ))),
        }
    }

    /// How many recomputed hours are ready to leave, under the same two bounds staging
    /// applies: at or after this device's privacy watermark, and before the hour still being
    /// written to.
    ///
    /// A session this build cannot read a watermark out of is counted from the epoch. This is
    /// a number for one diagnostic line, and refusing to produce it would take the whole
    /// report with it.
    fn uploadable_dirty_hour_count(&self) -> Result<i64, BackendError> {
        let lower_bound = self
            .state
            .session_json()
            .ok()
            .flatten()
            .and_then(|session| effective_usage_lower_bound(&session).ok())
            .and_then(|value| ceil_utc_hour(&value).ok())
            .unwrap_or_else(|| EPOCH_HOUR.to_owned());
        self.state
            .uploadable_dirty_hour_count(&lower_bound, &floor_utc_hour(&Utc::now()))
            .map_err(|_| BackendError::unavailable())
    }

    /// Hands every hour this device has recomputed to the outbox, newest scan wins.
    ///
    /// An hour is the unit and its version decides, so staging is a copy rather than a
    /// reservation: there is no sequence to allocate, no submission id to remember, and a
    /// re-staged hour replaces the entry that was already there.
    fn stage_outbox(&self) -> Result<bool, BackendError> {
        if !self
            .state
            .usage_upload_enabled()
            .map_err(|_| BackendError::unavailable())?
        {
            return Ok(false);
        }
        let Some((session, session_epoch)) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
        else {
            return Ok(false);
        };
        if session.get("status").and_then(Value::as_str) != Some("active") {
            return Ok(false);
        }
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let device_id = session
            .get("device_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let generation = session
            .get("device_generation")
            .and_then(Value::as_u64)
            .ok_or_else(BackendError::unavailable)?;
        let lower_bound = ceil_utc_hour(&effective_usage_lower_bound(&session)?)?;
        // The hour in progress is still being written to, so it is left for the next refresh.
        let complete_until = floor_utc_hour(&Utc::now());
        // An hour before the watermark will never be staged, so its mark is not work owed.
        let _ = self.state.forget_dirty_usage_hours_before(&lower_bound);
        // Identity is the file this device cannot rebuild, so it holds a bounded queue rather
        // than a year of history at once. What is left over stays dirty and is staged by the
        // next refresh, oldest hour first.
        let entries = self
            .state
            .dirty_usage_hour_batch(&lower_bound, &complete_until, MAX_STAGED_HOURS_PER_REFRESH)
            .map_err(|_| BackendError::unavailable())?;
        if entries.is_empty() {
            return Ok(false);
        }
        if !self
            .state
            .active_session_at_epoch(session_epoch)
            .map_err(|_| BackendError::unavailable())?
        {
            return Err(BackendError::session_changed());
        }
        if !self
            .state
            .usage_upload_enabled()
            .map_err(|_| BackendError::unavailable())?
        {
            return Ok(false);
        }
        self.state
            .stage_outbox_entries(account_id, device_id, generation, &entries)
            .map_err(|_| BackendError::unavailable())
    }

    /// Sends the staged hours, at most one agent and one request's worth at a time.
    /// Sends the hours this device still owes its Account.
    ///
    /// Answers whether Relay took an hour it did not already have. An ignored hour left the
    /// Account exactly as it was, so it is not a reason to read the Account again.
    fn drain_outbox(&self) -> Result<bool, BackendError> {
        let mut accepted_any = false;
        if !self
            .state
            .usage_upload_enabled()
            .map_err(|_| BackendError::unavailable())?
        {
            return Ok(accepted_any);
        }
        let Some((session, session_epoch)) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
        else {
            return Ok(accepted_any);
        };
        if session.get("status").and_then(Value::as_str) != Some("active")
            || !self
                .state
                .active_session_at_epoch(session_epoch)
                .map_err(|_| BackendError::unavailable())?
        {
            return Ok(accepted_any);
        }
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let device_id = session
            .get("device_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let generation = session
            .get("device_generation")
            .and_then(Value::as_u64)
            .ok_or_else(BackendError::unavailable)?;
        let entries = self
            .state
            .outbox_entries_for(account_id, device_id, generation)
            .map_err(|_| BackendError::unavailable())?;
        let mut by_agent: BTreeMap<UsageAgent, Vec<UsageOutboxEntry>> = BTreeMap::new();
        for entry in entries {
            by_agent.entry(entry.agent).or_default().push(entry);
        }
        for (agent, entries) in by_agent {
            let mut remaining = entries.as_slice();
            while !remaining.is_empty() {
                if !self
                    .state
                    .usage_upload_enabled()
                    .map_err(|_| BackendError::unavailable())?
                {
                    return Ok(accepted_any);
                }
                let taken = usage_upload_batch_size(agent, generation, remaining);
                if taken == 0 {
                    // One hour that cannot be represented at all would block every hour behind
                    // it, so it is dropped from the queue and the drain carries on.
                    self.state
                        .forget_outbox_hours(agent, &[remaining[0].bucket_start_utc.clone()])
                        .map_err(|_| BackendError::unavailable())?;
                    remaining = &remaining[1..];
                    continue;
                }
                let batch = &remaining[..taken];
                let upload =
                    usage_upload(agent, generation, batch).ok_or_else(BackendError::unavailable)?;
                let response = self.account.upload_usage(&upload)?;
                if response.get("device_id").and_then(Value::as_str) != Some(device_id)
                    || response.get("device_generation").and_then(Value::as_u64) != Some(generation)
                {
                    return Err(BackendError::new(IpcError::new(
                        ErrorCode::InvalidResponse,
                        RecoveryAction::Retry,
                    )));
                }
                // Accepted and ignored are the same move for this device: an ignored hour is one
                // a newer scan already replaced or one before this device's deletion watermark,
                // and either way it never needs sending again.
                let answered = ["accepted", "ignored"]
                    .into_iter()
                    .filter_map(|key| response.get(key)?.as_array())
                    .flatten()
                    .filter_map(|value| value.as_str().map(str::to_owned))
                    .collect::<Vec<_>>();
                accepted_any |= response
                    .get("accepted")
                    .and_then(Value::as_array)
                    .is_some_and(|hours| !hours.is_empty());
                self.state
                    .forget_outbox_hours(agent, &answered)
                    .map_err(|_| BackendError::unavailable())?;
                remaining = &remaining[taken..];
            }
        }
        Ok(accepted_any)
    }

    fn timezone(&self) -> String {
        crate::providers::common::resolve_timezone(&self.environment)
            .name()
            .to_owned()
    }

    /// Files the four periods the Account read already answered.
    ///
    /// A managed read folds days once, on the server, so there is nothing left for this device
    /// to ask for period by period.
    fn refresh_account_usage_periods(&self, account_value: &Value) -> Result<(), BackendError> {
        let usage = account_value
            .get("account_summary")
            .and_then(|summary| summary.get("usage"))
            .and_then(Value::as_object)
            .ok_or_else(BackendError::unavailable)?;
        let timezone = self.timezone();
        let now = Utc::now();
        let mut periods = Vec::new();
        for (period, key) in [
            (UsagePeriod::Today, "today"),
            (UsagePeriod::Last7Days, "last_7_days"),
            (UsagePeriod::Last30Days, "last_30_days"),
            (UsagePeriod::All, "all"),
        ] {
            let Some(value) = usage.get(key) else {
                continue;
            };
            let (today, span) = usage_period_window(period, &timezone, now)?;
            let range = span
                .map(|span| span.dates)
                .unwrap_or_else(|| (today.clone(), today.clone()));
            if let Ok(detail) = account_usage_detail(value, &range) {
                periods.push((period, detail));
            }
        }
        if periods.is_empty() {
            return Err(BackendError::unavailable());
        }
        self.state
            .replace_usage_periods(UsageSource::Account, &periods)
            .map_err(|_| BackendError::unavailable())?;
        Ok(())
    }

    /// Reads the whole Account, and publishes it before the rest of the refresh is done.
    ///
    /// `None` means there was no active session to read with, and the refresh's own session
    /// handling decides what the Account is then — a signed-out or signed-out-pending device is
    /// never given an Account read taken with a session it no longer has.
    fn read_account(
        &self,
        cancel: &AtomicBool,
        updates: &dyn RefreshSink,
    ) -> Option<Result<Value, BackendError>> {
        let read = self.account_read(cancel);
        // A test latch that opens only once this read has decided, so what it decided — and in
        // particular that it found no session — is a fact rather than a race.
        #[cfg(test)]
        if let Some(gate) = &self.account_read_gate {
            gate.hold();
        }
        let value = read?;
        updates.account(value.clone());
        Some(value)
    }

    /// Reads the Account once more, because this device's own upload just changed it.
    ///
    /// Without this, what a Mac uploaded would not appear in its own Account view until the
    /// next refresh five minutes later. The read is conditional, so an Account that did not
    /// actually move answers 304 and publishes nothing. A read that fails is not news — this
    /// refresh already has an Account — so only a fresh answer, or one that says the session
    /// has ended, replaces what was published.
    fn reread_account(
        &self,
        cancel: &AtomicBool,
        updates: &dyn RefreshSink,
    ) -> Option<Result<Value, BackendError>> {
        let value = self.account_read(cancel)?;
        if value
            .as_ref()
            .err()
            .is_some_and(|error| !error.error.code.requires_login())
        {
            return None;
        }
        updates.account(value.clone());
        Some(value)
    }

    /// One Account read, with the periods it derives and the journal row it earns.
    fn account_read(&self, cancel: &AtomicBool) -> Option<Result<Value, BackendError>> {
        if cancel.load(Ordering::Acquire) {
            return None;
        }
        let session = self.state.session_json().ok().flatten()?;
        if session.get("status").and_then(Value::as_str) != Some("active") {
            return None;
        }
        let attempt = self.begin_attempt(DiagnosticAttemptKind::AccountSync, None);
        let mut value = self.account.refresh_account_state(&self.timezone(), cancel);
        // Account periods are this account's Usage as Relay folded it, so they are kept only by
        // a device that contributes to it.
        if self.state.usage_upload_enabled().unwrap_or(false)
            && let Ok(summary) = &value
            && let Err(error) = self.refresh_account_usage_periods(summary)
            && error.error.code.requires_login()
        {
            value = Err(error);
        }
        if let Err(error) = &value {
            self.clear_session_if_rejected(error);
        }
        self.finish_backend_result_attempt(attempt, &value);
        Some(value)
    }

    /// Two readings of one subscription: this device's, and the one Relay resolved.
    ///
    /// Relay resolves the account's observations once, on the read, so there is no N-way merge
    /// left here. What stays is the one comparison Relay cannot make: local collection is the
    /// only authority for the machine in front of you, so the newer of the two wins and a tie
    /// goes to the local reading.
    fn build_overview(&self, quota: &Value, account: Option<&Value>) -> Vec<QuotaOverviewItem> {
        let previous = self.state.overview().unwrap_or_default();
        let pins = self.state.overview_source_pins().unwrap_or_default();
        let (items, kept) = overview_items_and_pins(quota, account, &previous, &pins, Utc::now());
        if kept != pins {
            let _ = self.state.replace_overview_source_pins(&kept);
        }
        items
    }
}

/// See [`NativeBackend::build_overview`]; the instant is an argument so the rule can be tested
/// against the shared cases at the instant they name.
#[cfg(test)]
fn overview_items(
    quota: &Value,
    account: Option<&Value>,
    previous: &[QuotaOverviewItem],
    now: DateTime<Utc>,
) -> Vec<QuotaOverviewItem> {
    overview_items_with_pins(quota, account, previous, &HashMap::new(), now)
}

#[cfg(test)]
pub(crate) fn overview_items_with_pins(
    quota: &Value,
    account: Option<&Value>,
    previous: &[QuotaOverviewItem],
    pins: &HashMap<String, String>,
    now: DateTime<Utc>,
) -> Vec<QuotaOverviewItem> {
    overview_items_and_pins(quota, account, previous, pins, now).0
}

pub(crate) fn overview_items_and_pins(
    quota: &Value,
    account: Option<&Value>,
    previous: &[QuotaOverviewItem],
    pins: &HashMap<String, String>,
    now: DateTime<Utc>,
) -> (Vec<QuotaOverviewItem>, HashMap<String, String>) {
    let mut items = Vec::new();
    if let Some(results) = quota.get("results").and_then(Value::as_array) {
        for result in results {
            if keep_previous_local_overview(result) {
                if let Some(provider) = result.get("provider").and_then(Value::as_str) {
                    retain_previous_local_overview(&mut items, previous, provider, now);
                }
                continue;
            }
            for snapshot in result
                .get("snapshots")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(item) =
                    overview_item(snapshot, "local", LOCAL_SOURCE_DISPLAY_NAME, None, now)
                {
                    merge_overview_item(&mut items, item);
                }
            }
        }
    }
    if let Some(account) = account {
        let this_device_id = account.get("device_id").and_then(Value::as_str);
        if let Some(summary) = account.get("account_summary").and_then(Value::as_object) {
            let display_names = summary
                .get("devices")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|device| {
                    Some((
                        device.get("id")?.as_str()?.to_owned(),
                        device.get("display_name")?.as_str()?.to_owned(),
                    ))
                })
                .collect::<HashMap<_, _>>();
            for subscription in summary
                .get("subscriptions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(snapshot) = subscription.get("snapshot") else {
                    continue;
                };
                if !snapshot
                    .get("provider")
                    .and_then(Value::as_str)
                    .and_then(ProviderId::parse)
                    .is_some_and(ProviderId::syncs_to_account)
                {
                    continue;
                }
                let winner_observed = snapshot.get("observed_at").and_then(Value::as_str);
                let mut handled = false;
                for source in subscription
                    .get("sources")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    let Some(device_id) = source.get("device_id").and_then(Value::as_str) else {
                        continue;
                    };
                    let observed = source.get("observed_at").and_then(Value::as_str);
                    let (source_snapshot, has_reading) = match source.get("snapshot").cloned() {
                        Some(reading) => (reading, true),
                        None if observed == winner_observed => (snapshot.clone(), true),
                        None => {
                            // Relay named the device and when it read, but not what it read —
                            // an older Relay, or a reading it no longer holds. The row still
                            // stands so the device is not lost: its freshness is its own
                            // instant against the subscription's windows, and no quota is
                            // invented for it.
                            let Some(observed) = observed else { continue };
                            let mut approximate = snapshot.clone();
                            approximate["observed_at"] = Value::String(observed.to_owned());
                            (approximate, false)
                        }
                    };
                    let display_name = display_names
                        .get(device_id)
                        .map(String::as_str)
                        .unwrap_or("Other device");
                    let Some(mut item) = overview_item(
                        &source_snapshot,
                        &format!("device:{device_id}"),
                        display_name,
                        Some(device_id),
                        now,
                    ) else {
                        continue;
                    };
                    if !has_reading {
                        for entry in &mut item.sources {
                            entry.snapshot = None;
                        }
                    }
                    if local_already_covers_this_device(&items, &item, this_device_id, device_id) {
                        handled = true;
                        continue;
                    }
                    merge_overview_item(&mut items, item);
                    handled = true;
                }
                if handled {
                    continue;
                }
                let device_id = subscription
                    .get("sources")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|source| {
                        Some((
                            source.get("device_id")?.as_str()?,
                            source.get("observed_at")?.as_str()?,
                        ))
                    })
                    .filter(|(_, observed_at)| Some(*observed_at) == winner_observed)
                    .map(|(device_id, _)| device_id)
                    .min();
                let Some(device_id) = device_id else {
                    continue;
                };
                let display_name = display_names
                    .get(device_id)
                    .map(String::as_str)
                    .unwrap_or("Other device");
                let Some(item) = overview_item(
                    snapshot,
                    &format!("device:{device_id}"),
                    display_name,
                    Some(device_id),
                    now,
                ) else {
                    continue;
                };
                if local_already_covers_this_device(&items, &item, this_device_id, device_id) {
                    continue;
                }
                merge_overview_item(&mut items, item);
            }
        }
    }
    let mut kept = pins.clone();
    prune_overview_pins(&items, &mut kept);
    apply_overview_pins(&mut items, &kept);
    sort_overview_items(&mut items);
    (items, kept)
}

fn prune_overview_pins(items: &[QuotaOverviewItem], pins: &mut HashMap<String, String>) {
    pins.retain(|key, pin| {
        items.iter().any(|item| {
            overview_identity_key(&item.identity) == *key
                && item.sources.iter().any(|source| source.source_id == *pin)
        })
    });
}

fn collect_discovered_jobs(
    discovered: &[(ProviderId, Vec<ProviderSession>)],
    configured: &HashSet<String>,
    context: &CollectionContext,
    mut begin: impl FnMut(&str) -> Option<DiagnosticAttemptHandle>,
) -> Vec<(
    ProviderId,
    bool,
    Option<DiagnosticAttemptHandle>,
    Value,
    bool,
)> {
    thread::scope(|scope| {
        let mut jobs = Vec::with_capacity(discovered.len());
        for (provider, sessions) in discovered {
            let provider = *provider;
            let sessions = sessions.clone();
            let context = context.clone();
            let explicit = configured.contains(provider.as_str());
            if sessions.is_empty() && !explicit {
                jobs.push((provider, explicit, None, None));
                continue;
            }
            let subject = format!("provider:{}", provider.as_str());
            let handle = begin(&subject);
            jobs.push((
                provider,
                explicit,
                handle,
                Some(
                    scope.spawn(move || collect_discovered_provider(provider, sessions, &context)),
                ),
            ));
        }
        jobs.into_iter()
            .map(|(provider, explicit, handle, job)| match job {
                Some(job) => match job.join() {
                    Ok(result) => (provider, explicit, handle, result, false),
                    Err(_) => (
                        provider,
                        explicit,
                        handle,
                        json!({
                            "provider": provider,
                            "outcome": "error",
                            "snapshots": [],
                            "sources": []
                        }),
                        true,
                    ),
                },
                None => (
                    provider,
                    explicit,
                    None,
                    json!({
                        "provider": provider,
                        "outcome": "auth_required",
                        "snapshots": [],
                        "sources": []
                    }),
                    false,
                ),
            })
            .collect()
    })
}

fn merge_collected_jobs(
    collected: &mut [(
        ProviderId,
        bool,
        Option<DiagnosticAttemptHandle>,
        Value,
        bool,
    )],
    retried: Vec<(
        ProviderId,
        bool,
        Option<DiagnosticAttemptHandle>,
        Value,
        bool,
    )>,
) {
    for (provider, explicit, _, result, panicked) in retried {
        if let Some(slot) = collected
            .iter_mut()
            .find(|(existing, _, _, _, _)| *existing == provider)
        {
            slot.1 = explicit;
            slot.3 = result;
            slot.4 = panicked;
        }
    }
}

fn providers_needing_forced_renewal(
    collected: &[(
        ProviderId,
        bool,
        Option<DiagnosticAttemptHandle>,
        Value,
        bool,
    )],
) -> HashSet<ProviderId> {
    collected
        .iter()
        .filter(|(provider, _, _, result, panicked)| {
            if *panicked
                || !matches!(
                    provider,
                    ProviderId::Claude | ProviderId::Codex | ProviderId::Grok
                )
            {
                return false;
            }
            if result.get("access_denied").and_then(Value::as_bool) == Some(true) {
                return false;
            }
            result.get("outcome").and_then(Value::as_str) == Some("auth_required")
                && result
                    .get("sources")
                    .and_then(Value::as_array)
                    .is_some_and(|sources| !sources.is_empty())
        })
        .map(|(provider, _, _, _, _)| *provider)
        .collect()
}

/// Rejected readings that still need a CLI ask, minus any this refresh already started.
///
/// A Recheck that renewed an expired grant in the first pass is not spawned a second time
/// just because collection still came back `auth_required`. A scheduled refresh that hit
/// the hourly floor, found no binary, or declined the force gate is not asked again only
/// to re-collect the same reading.
fn forced_renewal_targets(
    retry: &HashSet<ProviderId>,
    already_attempted: &HashSet<ProviderId>,
) -> HashSet<ProviderId> {
    retry.difference(already_attempted).copied().collect()
}

/// A failed local collection keeps the last local Overview row for that provider, so one
/// timeout does not blank the panel. The report itself stays empty-snapshot: that is the
/// IPC contract, and [`failure_status_snapshots`] restates the last good reading for the
/// Account. A provider that is no longer discovered or configured is not resurrected.
fn keep_previous_local_overview(result: &Value) -> bool {
    let outcome = result.get("outcome").and_then(Value::as_str).unwrap_or("");
    if !matches!(
        outcome,
        "auth_required" | "unavailable" | "unsupported" | "error"
    ) {
        return false;
    }
    result
        .get("sources")
        .and_then(Value::as_array)
        .is_some_and(|sources| !sources.is_empty())
        || outcome != "auth_required"
}

fn retain_previous_local_overview(
    items: &mut Vec<QuotaOverviewItem>,
    previous: &[QuotaOverviewItem],
    provider: &str,
    now: DateTime<Utc>,
) {
    for item in previous {
        if item.identity.provider != provider {
            continue;
        }
        let Some(local) = item.sources.iter().find(|source| source.kind == "local") else {
            continue;
        };
        if item.selected_source_id != local.source_id {
            continue;
        }
        if let Some(kept) = overview_item(
            &item.snapshot,
            "local",
            LOCAL_SOURCE_DISPLAY_NAME,
            None,
            now,
        ) {
            merge_overview_item(items, kept);
        }
    }
}

/// This device's own readings, restated with the status its latest collection found.
///
/// A failed collection produces no snapshot, so without this the account keeps serving the
/// last good reading and no other device can tell that the source behind it stopped
/// working. Every reader already treats a status other than `available` as not current, so
/// restating is what turns a local detection into a cross-device fact instead of one that
/// other devices have to wait out. The reading itself is untouched, `observed_at`
/// included: the numbers really are as old as they were.
///
/// What is restated is what this device last collected, not what it reads back from the
/// account: an account read answers one resolved row per subscription, which may belong to
/// another Mac. That is also what makes this terminate — the previous report is overwritten
/// by this one, which carries no snapshot for the source that failed, so there is nothing
/// left to restate on the next refresh.
fn failure_status_snapshots(
    report: &Value,
    previous: Option<&Value>,
    now: DateTime<Utc>,
) -> Vec<Value> {
    let failed = report
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|result| {
            let provider = result.get("provider")?.as_str()?;
            // A failed outcome names the same word a snapshot status uses.
            let status = result.get("outcome")?.as_str()?;
            matches!(
                status,
                "auth_required" | "unavailable" | "unsupported" | "error"
            )
            .then_some((provider, status))
        })
        .collect::<Vec<_>>();
    if failed.is_empty() {
        return Vec::new();
    }
    previous
        .and_then(|value| value.get("results"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|result| result.get("snapshots")?.as_array())
        .flatten()
        .filter_map(|snapshot| {
            let provider = snapshot.get("provider")?.as_str()?;
            let (_, status) = failed.iter().find(|(failed, _)| *failed == provider)?;
            (snapshot_is_current(snapshot, now)
                && snapshot.get("status").and_then(Value::as_str) != Some(status))
            .then(|| {
                let mut restated = snapshot.clone();
                restated["status"] = Value::String((*status).to_owned());
                restated
            })
        })
        .collect()
}

fn collect_discovered_provider(
    provider: ProviderId,
    sessions: Vec<ProviderSession>,
    context: &CollectionContext,
) -> Value {
    if sessions.is_empty() {
        return json!({
            "provider": provider,
            "outcome": "auth_required",
            "snapshots": [],
            "sources": []
        });
    }
    let browser_already = sessions
        .iter()
        .any(|session| session.credential_source == providers::BROWSER_SESSION_SOURCE);
    let mut snapshots = Vec::new();
    let mut sources = Vec::new();
    let mut failure: Option<ProviderError> = None;
    for session in &sessions {
        match providers::collect(provider, session, context) {
            // Expiry is derived from the reading itself by whoever reads it, so this
            // uploads the observation and nothing about how long it stays current.
            Ok(snapshot) => {
                sources.push(json!({
                    "source_id": providers::session_source_id(provider, &session),
                    "outcome": "success",
                    "category": "success"
                }));
                snapshots.push(serde_json::to_value(&snapshot).unwrap_or(Value::Null));
            }
            // The rung that reached the verdict names itself, so a report distinguishes an
            // OAuth endpoint that is unreachable from a stored browser session that went
            // stale.  Losing that left every failure looking like the provider's.
            Err(error) => {
                sources.push(json!({
                    "source_id": error.source_id,
                    "outcome": error.category.as_str(),
                    "category": error.category.name()
                }));
                failure = Some(error);
            }
        }
    }
    if snapshots.is_empty()
        && !browser_already
        && failure
            .as_ref()
            .is_some_and(|error| error.category == ErrorCategory::AuthRequired)
    {
        // The ladder already spent browser_sessions_for(provider)[0] when the
        // official rung answered auth_required; sending it again would
        // double-request the same account.
        for cookie in context.browser_sessions_for(provider).iter().skip(1) {
            let session = ProviderSession {
                provider,
                credential_source: providers::BROWSER_SESSION_SOURCE.to_owned(),
                cookie_header: Some(cookie.clone()),
            };
            match providers::collect(provider, &session, context) {
                Ok(snapshot) => {
                    sources.push(json!({
                        "source_id": providers::session_source_id(provider, &session),
                        "outcome": "success",
                        "category": "success"
                    }));
                    snapshots.push(serde_json::to_value(&snapshot).unwrap_or(Value::Null));
                }
                Err(error) => {
                    sources.push(json!({
                        "source_id": error.source_id,
                        "outcome": error.category.as_str(),
                        "category": error.category.name()
                    }));
                    failure = Some(error);
                }
            }
        }
    }
    if snapshots.is_empty() {
        let failure =
            failure.unwrap_or_else(|| ProviderError::new(ErrorCategory::Unavailable, "provider"));
        let mut result = json!({
            "provider": provider,
            "outcome": failure.category.as_str(),
            "snapshots": [],
            "sources": sources
        });
        // A discovered source that answers `auth_required` is a sign-in this machine still
        // holds and the provider no longer accepts. That is a different recovery from a
        // provider that was never set up here, so it is reported as its own message.
        if failure.category == ErrorCategory::AuthRequired {
            result["message"] = json!(auth_required_message(provider, failure.source_id));
        }
        if failure.category == ErrorCategory::AccessDenied {
            result["access_denied"] = json!(true);
            result["message"] = json!(access_denied_message(provider));
        }
        result
    } else {
        json!({
            "provider": provider,
            "outcome": "success",
            "snapshots": snapshots,
            "sources": sources
        })
    }
}

/// What a refused cookie store means, and what releases it.
///
/// Naming the browser matters: the reader has several, and the grant is per browser, not per
/// provider. The store's path is never part of this, only the browser's name.
fn browser_access_denied_message(denial: &crate::state::BrowserAccessDenial) -> String {
    let browser = &denial.browser;
    match denial.reason {
        BrowserAccessDenialReason::FullDiskAccess => format!(
            "QuotaBar could not read {browser}'s cookies. Grant Full Disk Access in System \
             Settings › Privacy & Security, then try again."
        ),
        BrowserAccessDenialReason::KeychainRefused => format!(
            "QuotaBar could not read {browser}'s cookies. macOS did not release the \"Chrome \
             Safe Storage\" Keychain item, so allow it when asked, then try again."
        ),
        BrowserAccessDenialReason::StoreUnreadable => format!(
            "QuotaBar could not read {browser}'s cookies. Its cookie store could not be opened. \
             Quit {browser} and try again, or choose another browser."
        ),
    }
}

/// What restores collection after a sign-in stops being accepted.
///
/// The source that failed decides it.  A stored browser session is re-added in this app,
/// while a provider's own grant is renewed by the program that owns it — telling the reader
/// to "sign in again" left them nowhere to do it.
fn access_denied_message(provider: ProviderId) -> &'static str {
    match provider {
        ProviderId::Claude => {
            "QuotaBar could not read Claude Code's Keychain item. Open Claude Code to refresh \
             the sign-in."
        }
        _ => "A saved sign-in is stored here but this Mac was refused it. Check access.",
    }
}

fn auth_required_message(provider: ProviderId, source_id: &str) -> &'static str {
    if providers::is_browser_session_source(source_id) {
        return "The saved browser session expired or was rejected. Add it again in Settings.";
    }
    // Claude Code empties its own credential when the refresh token it holds is rejected.
    // Opening it would open onto that same emptied entry, so this is the one sign-in the
    // reader has to restore at a terminal.
    if source_id == claude::SIGNED_OUT_SOURCE {
        return "Claude Code is signed out. Run `claude` and sign in again.";
    }
    match provider {
        ProviderId::Claude => {
            "The saved sign-in expired or was rejected. Open Claude Code to refresh the sign-in."
        }
        ProviderId::Codex => {
            "The saved sign-in expired or was rejected. Open Codex to refresh the sign-in."
        }
        ProviderId::Grok => {
            "The saved sign-in expired or was rejected. Open Grok to refresh the sign-in."
        }
        ProviderId::Cursor => {
            "The saved sign-in expired or was rejected. Open Cursor to refresh the sign-in."
        }
        _ => "The saved sign-in expired or was rejected. Sign in again.",
    }
}

fn worst_operation(left: DiagnosticOperation, right: DiagnosticOperation) -> DiagnosticOperation {
    match (left, right) {
        (DiagnosticOperation::Blocked, _) | (_, DiagnosticOperation::Blocked) => {
            DiagnosticOperation::Blocked
        }
        (DiagnosticOperation::Degraded, _) | (_, DiagnosticOperation::Degraded) => {
            DiagnosticOperation::Degraded
        }
        _ => DiagnosticOperation::Healthy,
    }
}

impl LocalBackend for NativeBackend {
    fn diagnose(&self) -> Result<DiagnosticReport, BackendError> {
        self.diagnostic_report()
    }

    fn complete_diagnostics(&self) -> Result<DiagnosticReport, BackendError> {
        self.complete_diagnostic_report()
    }

    fn validate_provider_browser_session(
        &self,
        provider: ProviderId,
        cookie_header: &str,
    ) -> Result<crate::providers::ValidatedBrowserSession, BackendError> {
        let context = self.collection_context(Arc::new(AtomicBool::new(false)))?;
        providers::validate_browser_session(provider, cookie_header, &context).map_err(|error| {
            BackendError::new(match error.category {
                ErrorCategory::AuthRequired => IpcError::new(
                    ErrorCode::AuthenticationRequired,
                    RecoveryAction::ConfigureProvider,
                ),
                ErrorCategory::Unavailable => {
                    IpcError::new(ErrorCode::NetworkError, RecoveryAction::Retry)
                }
                // A browser session is pasted in, never read from a credential store, so
                // this cannot arise here and is answered as the unavailability it is.
                ErrorCategory::AccessDenied => {
                    IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)
                }
                ErrorCategory::Unsupported => {
                    IpcError::new(ErrorCode::UnsupportedOperation, RecoveryAction::None)
                }
                ErrorCategory::Error => {
                    IpcError::new(ErrorCode::ProviderError, RecoveryAction::Retry)
                }
            })
        })
    }

    fn refresh(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        bypass_renewal_floor: bool,
    ) -> RefreshOutcome {
        let quota_cancel = cancel.clone();
        let usage_cancel = cancel.clone();
        // Reading the Account needs the session and nothing else, so it does not queue behind a
        // provider that answers in twenty seconds or a scan of every Usage file. It is published
        // the moment it lands, which is what names the account and fills its totals while the
        // rest of this refresh is still running.
        let previous_quota = self
            .state
            .component(crate::protocol::ComponentName::Quota)
            .ok()
            .flatten()
            .and_then(|component| component.value);
        let had_active_session = self
            .state
            .session_json()
            .ok()
            .flatten()
            .is_some_and(|session| session.get("status").and_then(Value::as_str) == Some("active"));
        let (quota, usage, read_account, quota_put, quota_accepted, quota_signed_out) =
            thread::scope(|scope| {
                let quota_job = scope.spawn(|| {
                    self.collect_quota_for(ProviderId::ALL, quota_cancel, bypass_renewal_floor)
                });
                let usage_job = scope.spawn(|| self.collect_usage(usage_cancel));
                let account_job = scope.spawn(|| self.read_account(cancel.as_ref(), updates));
                let quota_result = quota_job
                    .join()
                    .unwrap_or_else(|_| Err(BackendError::unavailable()));
                updates.quota(match &quota_result {
                    Ok(value) => Ok(value.clone()),
                    Err(error) => Err(error.clone()),
                });
                let account_result = account_job.join().unwrap_or(None);
                let (quota_put, quota_accepted, quota_signed_out) = if had_active_session {
                    self.upload_quota_after_collection(
                        &quota_result,
                        previous_quota.as_ref(),
                        cancel.as_ref(),
                        updates,
                    )
                } else {
                    (false, false, None)
                };
                let usage_result = usage_job
                    .join()
                    .unwrap_or_else(|_| Err(BackendError::unavailable()));
                (
                    quota_result,
                    usage_result,
                    account_result,
                    quota_put,
                    quota_accepted,
                    quota_signed_out,
                )
            });
        let cached_catalog = self
            .state
            .component(crate::protocol::ComponentName::Pricing)
            .ok()
            .flatten()
            .and_then(|component| component.value)
            .and_then(|value| serde_json::from_value(value).ok());
        // Relay's catalog is the published one; the build's own copy stands in until a device
        // has read it, so vendor grouping does not wait on a first successful fetch.
        let cached_model_catalog = self
            .state
            .model_catalog()
            .ok()
            .flatten()
            .and_then(|value| {
                crate::model_catalog::validate_model_catalog_value(&value)
                    .valid
                    .then(|| serde_json::from_value(value).ok())
                    .flatten()
            })
            .or_else(|| Some(crate::model_catalog::bundled_model_catalog()));
        let (pricing, model_catalog_refresh) = thread::scope(|scope| {
            let pricing_job = scope.spawn(|| self.refresh_pricing());
            let model_catalog_job = scope.spawn(|| self.refresh_model_catalog());
            (
                pricing_job
                    .join()
                    .unwrap_or_else(|_| Err(BackendError::unavailable())),
                model_catalog_job
                    .join()
                    .unwrap_or_else(|_| Err(BackendError::unavailable())),
            )
        });
        let catalog = pricing
            .as_ref()
            .ok()
            .and_then(|value| serde_json::from_value(value.clone()).ok())
            .or(cached_catalog);
        let model_catalog = model_catalog_refresh
            .as_ref()
            .ok()
            .and_then(|value| serde_json::from_value(value.clone()).ok())
            .or(cached_model_catalog);
        let usage_collection = usage.ok();
        let usage_value = match usage_collection.as_ref() {
            Some(value) => self.usage_report(value, catalog.as_ref(), model_catalog.as_ref()),
            None => Err(BackendError::unavailable()),
        };
        let quota_value = quota;
        // Last refresh's account fills the Overview when this one cannot be read, and last
        // refresh's own collection is what a failed source is restated from.
        let stored_account = quota_value
            .is_ok()
            .then(|| {
                self.state
                    .component(crate::protocol::ComponentName::Account)
                    .ok()
                    .flatten()
                    .and_then(|component| component.value)
            })
            .flatten();
        // What the Account read already answered, or nothing when there was no session to read
        // with at the time. A Relay rejection on the quota upload may already have ended it.
        let mut account_value: Option<Result<Value, BackendError>> = match quota_signed_out {
            Some(error) => Some(Err(error)),
            None => read_account,
        };
        let mut overview = None;
        match self.state.session_json() {
            _ if cancel.load(Ordering::Acquire) => {
                if !matches!(account_value, Some(Ok(_))) {
                    account_value = Some(Err(BackendError::cancelled()));
                }
            }
            Ok(Some(session))
                if session.get("status").and_then(Value::as_str) == Some("active") =>
            {
                // The Account has answered for itself already. What is left here is the writing
                // half of a sync, and only a failure that ends the session speaks for the
                // Account: an upload this refresh could not deliver is not news about who is
                // signed in.
                match self.account.sync_control_and_update() {
                    Ok(_) if cancel.load(Ordering::Acquire) => {
                        if !matches!(account_value, Some(Ok(_))) {
                            account_value = Some(Err(BackendError::cancelled()));
                        }
                    }
                    Ok(_) => {
                        let current_session =
                            self.state.session_json().ok().flatten().unwrap_or(session);
                        let mut account_sync_error = None;
                        // Whether this refresh put something in the Account that was not there
                        // when it read one.
                        let mut uploaded = false;
                        if !quota_put && let Ok(quota_payload) = &quota_value {
                            let restated = failure_status_snapshots(
                                quota_payload,
                                previous_quota.as_ref(),
                                Utc::now(),
                            );
                            match self.account.upload_quota_report(quota_payload, &restated) {
                                Ok(response) => {
                                    uploaded |= response
                                        .get("accepted")
                                        .and_then(Value::as_array)
                                        .is_some_and(|providers| !providers.is_empty());
                                }
                                Err(error) => {
                                    record_account_sync_error(&mut account_sync_error, error);
                                }
                            }
                        }
                        uploaded |= quota_accepted;
                        let usage_upload_enabled = match self.state.usage_upload_enabled() {
                            Ok(enabled) => enabled,
                            Err(_) => {
                                record_account_sync_error(
                                    &mut account_sync_error,
                                    BackendError::unavailable(),
                                );
                                false
                            }
                        };
                        if usage_upload_enabled && usage_collection.is_some() {
                            let context_result = effective_usage_lower_bound(&current_session)
                                .and_then(|lower_bound| {
                                    self.state
                                        .ensure_usage_context(
                                            current_session
                                                .get("account_id")
                                                .and_then(Value::as_str)
                                                .unwrap_or_default(),
                                            current_session
                                                .get("device_id")
                                                .and_then(Value::as_str)
                                                .unwrap_or_default(),
                                            current_session
                                                .get("device_generation")
                                                .and_then(Value::as_u64)
                                                .unwrap_or_default(),
                                            current_session
                                                .get("usage_sync_revision")
                                                .and_then(Value::as_u64)
                                                .unwrap_or_default(),
                                            &lower_bound,
                                        )
                                        .map_err(|_| BackendError::unavailable())
                                });
                            if let Err(error) = context_result {
                                record_account_sync_error(&mut account_sync_error, error);
                            } else if let Err(error) = self.stage_outbox() {
                                record_account_sync_error(&mut account_sync_error, error);
                            }
                        }
                        if usage_upload_enabled && account_sync_error.is_none() {
                            match self.drain_outbox_recorded() {
                                Ok(accepted) => uploaded |= accepted,
                                Err(error) => {
                                    record_account_sync_error(&mut account_sync_error, error)
                                }
                            }
                        }
                        if let Some(error) =
                            account_sync_error.filter(|error| error.sign_out_epoch().is_some())
                        {
                            self.clear_session_if_rejected(&error);
                            account_value = Some(Err(error));
                        } else if uploaded
                            && let Some(reread) = self.reread_account(cancel.as_ref(), updates)
                        {
                            account_value = Some(reread);
                        }
                    }
                    Err(error) => {
                        if error.sign_out_epoch().is_some() {
                            self.clear_session_if_rejected(&error);
                            account_value = Some(Err(error));
                        }
                    }
                }
            }
            Ok(Some(session))
                if session.get("status").and_then(Value::as_str) == Some("logout_pending") =>
            {
                match self.account.logout(&session) {
                    Ok(()) => {
                        self.clear_pending_session();
                        account_value = Some(Err(BackendError::new(IpcError::new(
                            ErrorCode::AuthenticationRequired,
                            RecoveryAction::Login,
                        ))));
                    }
                    Err(error) => account_value = Some(Err(error)),
                }
            }
            Ok(None) => {}
            Ok(Some(_)) => {
                account_value = Some(Err(BackendError::new(IpcError::new(
                    ErrorCode::InvalidState,
                    RecoveryAction::Reinstall,
                ))));
            }
            Err(_) => account_value = Some(Err(BackendError::unavailable())),
        }
        // A sign-in that landed after this refresh began leaves it holding no Account read at
        // all. Reading one now is what keeps a device that has just signed in from being
        // reported as signed out until the next refresh.
        if account_value.is_none() {
            account_value = self.read_account(cancel.as_ref(), updates);
        }
        let account_value = account_value.unwrap_or_else(|| {
            Err(BackendError::new(IpcError::new(
                ErrorCode::AuthenticationRequired,
                RecoveryAction::Login,
            )))
        });
        if let Ok(ref quota_payload) = quota_value {
            let account_for_overview = account_value.as_ref().ok().cloned().or(stored_account);
            overview = Some(self.build_overview(quota_payload, account_for_overview.as_ref()));
        }
        RefreshOutcome {
            quota: quota_value,
            usage: usage_value,
            account: account_value,
            pricing,
            overview,
        }
    }

    fn refresh_account(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        trigger: DiagnosticAttemptTrigger,
    ) -> Result<Value, BackendError> {
        let _guard = enter_lane_attempt_trigger(trigger);
        self.read_account(cancel.as_ref(), updates)
            .unwrap_or_else(|| {
                Err(BackendError::new(IpcError::new(
                    ErrorCode::AuthenticationRequired,
                    RecoveryAction::Login,
                )))
            })
    }

    fn refresh_quota(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        trigger: DiagnosticAttemptTrigger,
    ) -> RefreshOutcome {
        let _guard = enter_lane_attempt_trigger(trigger);
        let previous_quota = self
            .state
            .component(crate::protocol::ComponentName::Quota)
            .ok()
            .flatten()
            .and_then(|component| component.value);
        let quota = self.collect_quota(cancel.clone());
        updates.quota(match &quota {
            Ok(value) => Ok(value.clone()),
            Err(error) => Err(error.clone()),
        });
        // Read first so the Account poll is not skipped for a whole interval, and so a token
        // inside the refresh margin is rotated before the upload spends it.
        let mut account = self
            .read_account(cancel.as_ref(), updates)
            .unwrap_or_else(|| {
                Err(BackendError::new(IpcError::new(
                    ErrorCode::AuthenticationRequired,
                    RecoveryAction::Login,
                )))
            });
        let (_put, accepted, signed_out) = self.upload_quota_after_collection(
            &quota,
            previous_quota.as_ref(),
            cancel.as_ref(),
            updates,
        );
        if let Some(error) = signed_out {
            account = Err(error);
        } else if accepted && let Some(reread) = self.reread_account(cancel.as_ref(), updates) {
            account = reread;
        }
        let stored_account = self
            .state
            .component(crate::protocol::ComponentName::Account)
            .ok()
            .flatten()
            .and_then(|component| component.value);
        let overview = quota.as_ref().ok().map(|payload| {
            self.build_overview(
                payload,
                account.as_ref().ok().cloned().or(stored_account).as_ref(),
            )
        });
        RefreshOutcome {
            quota,
            usage: Err(BackendError::cancelled()),
            account,
            pricing: Err(BackendError::cancelled()),
            overview,
        }
    }

    fn refresh_usage(
        &self,
        cancel: Arc<AtomicBool>,
        updates: &dyn RefreshSink,
        trigger: DiagnosticAttemptTrigger,
    ) -> RefreshOutcome {
        let _guard = enter_lane_attempt_trigger(trigger);
        let usage = self.collect_usage(cancel.clone());
        let cached_catalog = self
            .state
            .component(crate::protocol::ComponentName::Pricing)
            .ok()
            .flatten()
            .and_then(|component| component.value)
            .and_then(|value| serde_json::from_value(value).ok());
        let cached_model_catalog = self
            .state
            .model_catalog()
            .ok()
            .flatten()
            .and_then(|value| {
                crate::model_catalog::validate_model_catalog_value(&value)
                    .valid
                    .then(|| serde_json::from_value(value).ok())
                    .flatten()
            })
            .or_else(|| Some(crate::model_catalog::bundled_model_catalog()));
        let (pricing, model_catalog_refresh) = thread::scope(|scope| {
            let pricing_job = scope.spawn(|| self.refresh_pricing());
            let model_catalog_job = scope.spawn(|| self.refresh_model_catalog());
            (
                pricing_job
                    .join()
                    .unwrap_or_else(|_| Err(BackendError::unavailable())),
                model_catalog_job
                    .join()
                    .unwrap_or_else(|_| Err(BackendError::unavailable())),
            )
        });
        let catalog = pricing
            .as_ref()
            .ok()
            .and_then(|value| serde_json::from_value(value.clone()).ok())
            .or(cached_catalog);
        let model_catalog = model_catalog_refresh
            .as_ref()
            .ok()
            .and_then(|value| serde_json::from_value(value.clone()).ok())
            .or(cached_model_catalog);
        let usage_collection = usage.ok();
        let usage_value = match usage_collection.as_ref() {
            Some(value) => self.usage_report(value, catalog.as_ref(), model_catalog.as_ref()),
            None => Err(BackendError::unavailable()),
        };
        let mut account_value = None;
        if let Ok(Some(session)) = self.state.session_json()
            && session.get("status").and_then(Value::as_str) == Some("active")
            && self.state.usage_upload_enabled().unwrap_or(false)
            && usage_collection.is_some()
        {
            let mut account_sync_error = None;
            let context_result = effective_usage_lower_bound(&session).and_then(|lower_bound| {
                self.state
                    .ensure_usage_context(
                        session
                            .get("account_id")
                            .and_then(Value::as_str)
                            .unwrap_or_default(),
                        session
                            .get("device_id")
                            .and_then(Value::as_str)
                            .unwrap_or_default(),
                        session
                            .get("device_generation")
                            .and_then(Value::as_u64)
                            .unwrap_or_default(),
                        session
                            .get("usage_sync_revision")
                            .and_then(Value::as_u64)
                            .unwrap_or_default(),
                        &lower_bound,
                    )
                    .map_err(|_| BackendError::unavailable())
            });
            if let Err(error) = context_result {
                record_account_sync_error(&mut account_sync_error, error);
            } else if let Err(error) = self.stage_outbox() {
                record_account_sync_error(&mut account_sync_error, error);
            } else {
                match self.drain_outbox_recorded() {
                    Ok(accepted) => {
                        if accepted {
                            account_value = self.reread_account(cancel.as_ref(), updates);
                        }
                    }
                    Err(error) => record_account_sync_error(&mut account_sync_error, error),
                }
            }
            if let Some(error) = account_sync_error.filter(|error| error.sign_out_epoch().is_some())
            {
                self.clear_session_if_rejected(&error);
                account_value = Some(Err(error));
            }
        }
        RefreshOutcome {
            quota: Ok(Value::Null),
            usage: usage_value,
            account: account_value.unwrap_or_else(|| Err(BackendError::cancelled())),
            pricing,
            overview: None,
        }
    }

    fn begin_login(&self) -> Result<String, BackendError> {
        self.account.begin_login()
    }

    fn abort_login_preparation(&self) {
        self.account.abort_pending_login();
    }

    fn login(&self, _: &str, cancel: Arc<AtomicBool>) -> Result<LoginOutcome, BackendError> {
        self.account.login(cancel.as_ref())
    }

    fn logout(&self, pending_session: &Value) -> Result<(), BackendError> {
        self.account.logout(pending_session)
    }
}

impl NativeBackend {
    /// Uploads this collection's quota as soon as it exists, without waiting for Usage.
    ///
    /// Device control and the Account re-read stay in the writing half of the refresh.
    /// The third value is a Relay-originated rejection that ended the session.
    fn upload_quota_after_collection(
        &self,
        quota_value: &Result<Value, BackendError>,
        previous_quota: Option<&Value>,
        cancel: &AtomicBool,
        updates: &dyn RefreshSink,
    ) -> (bool, bool, Option<BackendError>) {
        if cancel.load(Ordering::Acquire) {
            return (false, false, None);
        }
        let Ok(Some(session)) = self.state.session_json() else {
            return (false, false, None);
        };
        if session.get("status").and_then(Value::as_str) != Some("active") {
            return (false, false, None);
        }
        let Ok(quota_payload) = quota_value else {
            return (false, false, None);
        };
        let restated = failure_status_snapshots(quota_payload, previous_quota, Utc::now());
        match self.account.upload_quota_report(quota_payload, &restated) {
            Ok(response) => (
                true,
                response
                    .get("accepted")
                    .and_then(Value::as_array)
                    .is_some_and(|providers| !providers.is_empty()),
                None,
            ),
            Err(error) if error.sign_out_epoch().is_some() => {
                self.clear_session_if_rejected(&error);
                updates.account(Err(error.clone()));
                (false, false, Some(error))
            }
            Err(_) => (false, false, None),
        }
    }

    /// Sends staged hours and records the `usage_upload` journal row the drain earns.
    fn drain_outbox_recorded(&self) -> Result<bool, BackendError> {
        let before = self.state.outbox_len().unwrap_or(0);
        let upload_attempt = self.begin_attempt(DiagnosticAttemptKind::UsageUpload, None);
        match self.drain_outbox() {
            Ok(accepted) => {
                let pending = self.state.outbox_len().unwrap_or(0);
                let (outcome, code) = if before == 0 {
                    (
                        DiagnosticAttemptOutcome::NoWork,
                        Some(DiagnosticAttemptCode::NoWork),
                    )
                } else if pending > 0 {
                    (
                        DiagnosticAttemptOutcome::Partial,
                        Some(DiagnosticAttemptCode::Unavailable),
                    )
                } else {
                    (DiagnosticAttemptOutcome::Success, None)
                };
                self.finish_attempt(upload_attempt, outcome, code);
                Ok(accepted)
            }
            Err(error) => {
                let (outcome, code) = backend_attempt_error(&error.error);
                self.finish_attempt(upload_attempt, outcome, Some(code));
                Err(error)
            }
        }
    }

    fn clear_session_if_rejected(&self, error: &BackendError) {
        if let Some(epoch) = error.sign_out_epoch() {
            let _ = self.state.clear_session_if_epoch(epoch);
        }
    }

    fn clear_pending_session(&self) {
        if let Ok(Some((session, epoch))) = self.state.session_snapshot()
            && session.get("status").and_then(Value::as_str) == Some("logout_pending")
        {
            let _ = self.state.clear_session_if_epoch(epoch);
        }
    }
}

struct UsageCollection {
    timezone: String,
    generated_at: String,
    agents: Vec<AgentUsage>,
}

struct AgentUsage {
    coverage: usage::ScanCoverage,
}

/// One period as this device's own calendar draws it.
///
/// A local day begins at local midnight, so a period is a half-open range of instants rather
/// than a run of UTC dates: `start` is when its first local day begins and `end` is when the day
/// after its last one does. An hour is the finest fact stored, so a zone offset by less than an
/// hour reports the hour its midnight falls in with the day before — comparing a stored hour
/// against these instants rounds the edge up, which is the rule the Account read follows too.
pub(crate) struct LocalPeriodSpan {
    dates: (String, String),
    pub(crate) start: String,
    pub(crate) end: String,
}

pub(crate) fn usage_period_window(
    period: UsagePeriod,
    timezone: &str,
    now: DateTime<Utc>,
) -> Result<(String, Option<LocalPeriodSpan>), BackendError> {
    let timezone = Tz::from_str(timezone).map_err(|_| BackendError::unavailable())?;
    let today = now.with_timezone(&timezone).date_naive();
    let today_text = today.format("%Y-%m-%d").to_string();
    let previous_days = match period {
        UsagePeriod::Today => 0,
        UsagePeriod::Last7Days => 6,
        UsagePeriod::Last30Days => 29,
        UsagePeriod::All => return Ok((today_text, None)),
    };
    let first = today
        .checked_sub_days(Days::new(previous_days))
        .ok_or_else(BackendError::unavailable)?;
    let after = today
        .checked_add_days(Days::new(1))
        .ok_or_else(BackendError::unavailable)?;
    Ok((
        today_text.clone(),
        Some(LocalPeriodSpan {
            dates: (first.format("%Y-%m-%d").to_string(), today_text),
            start: local_day_start(&timezone, first)?,
            end: local_day_start(&timezone, after)?,
        }),
    ))
}

/// The instant a local date begins, as the hour comparison in `usage_period_rows` reads it.
///
/// A date whose midnight a daylight change repeated begins at the earlier of the two; one whose
/// midnight a change skipped begins when the clocks land after it.
fn local_day_start(timezone: &Tz, date: NaiveDate) -> Result<String, BackendError> {
    let midnight = date
        .and_hms_opt(0, 0, 0)
        .ok_or_else(BackendError::unavailable)?;
    for minutes in [0, 30, 60, 90, 120, 150, 180] {
        let candidate = midnight + Duration::minutes(minutes);
        let resolved = match timezone.from_local_datetime(&candidate) {
            LocalResult::Single(value) => value,
            LocalResult::Ambiguous(earliest, _) => earliest,
            LocalResult::None => continue,
        };
        return Ok(resolved
            .with_timezone(&Utc)
            .to_rfc3339_opts(SecondsFormat::Secs, true));
    }
    Err(BackendError::unavailable())
}

/// One managed period as the panel reads it.
///
/// The managed tree carries totals and cost only at the model leaf, because that is the only
/// place the rollup has to keep them. The panel shows a total per agent and per provider, so
/// those are folded here rather than asked for on the wire.
fn account_usage_detail(value: &Value, range: &(String, String)) -> Result<Value, BackendError> {
    let object = value.as_object().ok_or_else(invalid_usage_detail)?;
    let totals = object
        .get("totals")
        .cloned()
        .ok_or_else(invalid_usage_detail)?;
    let cost = object
        .get("cost")
        .cloned()
        .ok_or_else(invalid_usage_detail)?;
    let incomplete = object.get("partial").and_then(Value::as_bool) == Some(true);
    let unpriced_truncated = cost.get("unpriced_truncated").and_then(Value::as_bool) == Some(true);
    let agents = object
        .get("agents")
        .and_then(Value::as_array)
        .ok_or_else(invalid_usage_detail)?
        .iter()
        .map(account_usage_agent)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({
        "range": {"from": range.0, "to": range.1},
        "usage": {
            "totals": totals,
            "cost": cost,
            "agents": agents
        },
        "incomplete": incomplete,
        "details_truncated": unpriced_truncated
    }))
}

fn account_usage_agent(value: &Value) -> Result<Value, BackendError> {
    let object = value.as_object().ok_or_else(invalid_usage_detail)?;
    let providers = object
        .get("providers")
        .and_then(Value::as_array)
        .ok_or_else(invalid_usage_detail)?
        .iter()
        .map(account_usage_provider)
        .collect::<Result<Vec<_>, _>>()?;
    let (totals, cost) = fold_leaf_totals(&providers)?;
    Ok(json!({
        "agent": object.get("agent").cloned().ok_or_else(invalid_usage_detail)?,
        "totals": totals,
        "cost": cost,
        "providers": providers
    }))
}

fn account_usage_provider(value: &Value) -> Result<Value, BackendError> {
    let object = value.as_object().ok_or_else(invalid_usage_detail)?;
    let models = object
        .get("models")
        .and_then(Value::as_array)
        .cloned()
        .ok_or_else(invalid_usage_detail)?;
    let (totals, cost) = fold_leaves(&models)?;
    Ok(json!({
        "provider": object.get("provider").cloned().ok_or_else(invalid_usage_detail)?,
        "totals": totals,
        "cost": cost,
        "models": models
    }))
}

fn fold_leaf_totals(providers: &[Value]) -> Result<(Value, Value), BackendError> {
    let leaves = providers
        .iter()
        .filter_map(|provider| provider.get("models")?.as_array())
        .flatten()
        .cloned()
        .collect::<Vec<_>>();
    fold_leaves(&leaves)
}

fn fold_leaves(leaves: &[Value]) -> Result<(Value, Value), BackendError> {
    let mut totals = usage::UsageSummaryTotals::default();
    let mut costs = Vec::with_capacity(leaves.len());
    for leaf in leaves {
        let leaf_totals: usage::UsageSummaryTotals = serde_json::from_value(
            leaf.get("totals")
                .cloned()
                .ok_or_else(invalid_usage_detail)?,
        )
        .map_err(|_| invalid_usage_detail())?;
        totals =
            usage::add_summary_totals(&totals, &leaf_totals).map_err(|_| invalid_usage_detail())?;
        costs.push(
            serde_json::from_value::<pricing::UsageCostOutcome>(
                leaf.get("cost").cloned().ok_or_else(invalid_usage_detail)?,
            )
            .map_err(|_| invalid_usage_detail())?,
        );
    }
    let cost = pricing::fold_usage_cost_outcomes(&costs).map_err(|_| invalid_usage_detail())?;
    Ok((
        serde_json::to_value(totals).map_err(|_| invalid_usage_detail())?,
        serde_json::to_value(cost).map_err(|_| invalid_usage_detail())?,
    ))
}

fn invalid_usage_detail() -> BackendError {
    BackendError::new(IpcError::new(
        ErrorCode::InvalidResponse,
        RecoveryAction::Retry,
    ))
}

fn usage_date_range(rows: &[DatedUsageRow], fallback_date: &str) -> (String, String) {
    let from = rows
        .iter()
        .map(|row| row.date.clone())
        .min()
        .unwrap_or_else(|| fallback_date.to_owned());
    let to = rows
        .iter()
        .map(|row| row.date.clone())
        .max()
        .unwrap_or_else(|| fallback_date.to_owned());
    (from, to)
}

/// What the last scan of one agent left behind, in the two facts the report reads: whether the
/// scan covered everything it found, and the bounded count per reason it did not.
fn usage_scan_diagnostic(scan: &usage::UsageScanResult) -> Value {
    let mut reason_counts = BTreeMap::<String, i64>::new();
    for reason in &scan.coverage.reasons {
        let key = serde_json::to_string(&reason.code)
            .unwrap_or_else(|_| "\"unknown\"".into())
            .trim_matches('"')
            .to_owned();
        let entry = reason_counts.entry(key).or_default();
        *entry = entry.saturating_add(reason.count.min(i64::MAX as u64) as i64);
    }
    json!({
        "status": match scan.coverage.status {
            CoverageStatus::Complete => "complete",
            CoverageStatus::Partial => "partial",
        },
        "reason_counts": reason_counts,
    })
}

/// The instant before which this device uploads nothing.
///
/// Every account signed in on this Mac is owed every hour it still holds, so the only bound is
/// the one Relay states: the watermark Delete Device set for this device, before which deleted
/// data must not be restored. A device that was never deleted starts at the epoch.
fn effective_usage_lower_bound(session: &Value) -> Result<String, BackendError> {
    let bound = match session.get("usage_deleted_before") {
        Some(Value::Null) => DateTime::parse_from_rfc3339("1970-01-01T00:00:00Z")
            .map_err(|_| invalid_local_state())?,
        Some(Value::String(value)) => {
            DateTime::parse_from_rfc3339(value).map_err(|_| invalid_local_state())?
        }
        _ => return Err(invalid_local_state()),
    };
    Ok(bound.to_rfc3339_opts(SecondsFormat::AutoSi, true))
}

fn invalid_local_state() -> BackendError {
    BackendError::new(IpcError::new(
        ErrorCode::InvalidState,
        RecoveryAction::Reinstall,
    ))
}

/// Prefer the first session-authority failure over later non-auth sync diagnostics.
///
/// A later Unavailable from usage preference/state must not erase an earlier
/// AuthenticationRequired/DeviceDeleted/StaleGeneration from quota upload or outbox drain.
fn record_account_sync_error(slot: &mut Option<BackendError>, error: BackendError) {
    if slot
        .as_ref()
        .is_some_and(|existing| existing.error.code.requires_login())
    {
        return;
    }
    *slot = Some(error);
}

/// One agent's rescanned hours, in the shape Relay accepts.
fn usage_upload(agent: UsageAgent, generation: u64, hours: &[UsageOutboxEntry]) -> Option<Value> {
    let mut values = Vec::with_capacity(hours.len());
    for hour in hours {
        let mut rows = serde_json::to_value(&hour.rows).ok()?;
        if let Some(row_values) = rows.as_array_mut() {
            for row in row_values {
                if row.get("source_cost_microusd").is_some_and(Value::is_null)
                    && let Some(object) = row.as_object_mut()
                {
                    object.remove("source_cost_microusd");
                }
            }
        }
        values.push(json!({
            "bucket_start_utc": hour.bucket_start_utc,
            "scan_version": hour.scan_version,
            "partial": hour.partial,
            "rows": rows
        }));
    }
    Some(json!({
        "protocol_version": MANAGED_DATA_PROTOCOL,
        "generation": generation,
        "agent": agent,
        "hours": values
    }))
}

/// How many of the staged hours fit one request, by hour count and by bytes.
///
/// Zero means the first hour alone does not fit, which is the only case the caller cannot
/// make progress on.
fn usage_upload_batch_size(
    agent: UsageAgent,
    generation: u64,
    hours: &[UsageOutboxEntry],
) -> usize {
    let fits = |count: usize| {
        usage_upload(agent, generation, &hours[..count])
            .filter(|upload| crate::relay::validate_usage_submission(upload).is_ok())
            .is_some()
    };
    let mut high = hours.len().min(usage::MAX_USAGE_HOURS_PER_UPLOAD);
    if high == 0 || !fits(1) {
        return 0;
    }
    // Byte fit is monotonic over a prefix, so the largest count that fits is a binary search
    // rather than a serialization per candidate.
    let mut low = 1usize;
    while low < high {
        let middle = low + (high - low).div_ceil(2);
        if fits(middle) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    low
}

/// The first whole hour at or after an instant, in the canonical form `bucket_start_utc`
/// holds.
///
/// An hour that starts before the watermark is not one this device may upload. Rounding the
/// watermark up is what turns that into a comparison the stored column can answer directly,
/// without re-parsing every row.
fn ceil_utc_hour(value: &str) -> Result<String, BackendError> {
    let instant = DateTime::parse_from_rfc3339(value)
        .map_err(|_| invalid_local_state())?
        .with_timezone(&Utc);
    let floored = instant
        .with_minute(0)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .ok_or_else(invalid_local_state)?;
    let hour = if floored == instant {
        floored
    } else {
        floored + Duration::hours(1)
    };
    Ok(hour.to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn floor_utc_hour(value: &DateTime<Utc>) -> String {
    value
        .with_minute(0)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .unwrap_or(*value)
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

const LOCAL_SOURCE_DISPLAY_NAME: &str = "This Mac";

fn overview_item(
    snapshot: &Value,
    source_id: &str,
    display_name: &str,
    device_id: Option<&str>,
    now: DateTime<Utc>,
) -> Option<QuotaOverviewItem> {
    let provider = snapshot.get("provider")?.as_str()?.to_owned();
    let account = snapshot.get("account")?.as_object()?;
    let fingerprint = account.get("fingerprint")?.as_str()?.to_owned();
    let scope = account.get("fingerprint_scope")?.as_str()?.to_owned();
    let observed_at = snapshot.get("observed_at")?.as_str()?.to_owned();
    let stale = !snapshot_is_current(snapshot, now);
    Some(QuotaOverviewItem {
        identity: QuotaOverviewIdentity {
            provider,
            fingerprint,
            scope: scope.clone(),
            source_id: (scope == "source").then(|| source_id.to_owned()),
        },
        snapshot: snapshot.clone(),
        sources: vec![QuotaOverviewSource {
            source_id: source_id.to_owned(),
            kind: if device_id.is_some() {
                "device"
            } else {
                "local"
            }
            .to_owned(),
            device_id: device_id.map(str::to_owned),
            display_name: display_name.to_owned(),
            observed_at,
            is_stale: stale,
            snapshot: Some(snapshot.clone()),
        }],
        selected_source_id: source_id.to_owned(),
        selected_source_display_name: display_name.to_owned(),
        automatic_source_id: source_id.to_owned(),
        automatic_source_display_name: display_name.to_owned(),
        is_stale: stale,
        source_pin: None,
    })
}

pub(crate) fn overview_identity_key(identity: &QuotaOverviewIdentity) -> String {
    format!(
        "{}|{}|{}|{}",
        identity.provider,
        identity.fingerprint,
        identity.scope,
        identity.source_id.as_deref().unwrap_or("")
    )
}

fn local_already_covers_this_device(
    items: &[QuotaOverviewItem],
    incoming: &QuotaOverviewItem,
    this_device_id: Option<&str>,
    source_device_id: &str,
) -> bool {
    this_device_id == Some(source_device_id)
        && items.iter().any(|item| {
            item.identity.provider == incoming.identity.provider
                && item.identity.fingerprint == incoming.identity.fingerprint
                && item.sources.iter().any(|source| source.kind == "local")
        })
}

fn apply_overview_pins(items: &mut [QuotaOverviewItem], pins: &HashMap<String, String>) {
    for item in items {
        item.source_pin = None;
        let Some(pin) = pins.get(&overview_identity_key(&item.identity)) else {
            continue;
        };
        let Some(source) = item.sources.iter().find(|source| source.source_id == *pin) else {
            continue;
        };
        let Some(snapshot) = source.snapshot.clone() else {
            continue;
        };
        item.snapshot = snapshot;
        item.selected_source_id = source.source_id.clone();
        item.selected_source_display_name = source.display_name.clone();
        item.is_stale = source.is_stale;
        item.source_pin = Some(pin.clone());
    }
}

fn sort_overview_items(items: &mut [QuotaOverviewItem]) {
    items.sort_by(|left, right| left.identity.cmp(&right.identity));
}

fn merge_overview_item(items: &mut Vec<QuotaOverviewItem>, mut incoming: QuotaOverviewItem) {
    let Some(existing) = items
        .iter_mut()
        .find(|item| item.identity == incoming.identity)
    else {
        items.push(incoming);
        return;
    };
    let incoming_better = overview_choice_is_better(&incoming, existing);
    for source in incoming.sources.drain(..) {
        existing
            .sources
            .retain(|value| value.source_id != source.source_id);
        existing.sources.push(source);
    }
    existing
        .sources
        .sort_by(|left, right| left.source_id.cmp(&right.source_id));
    if incoming_better {
        existing.snapshot = incoming.snapshot;
        existing.selected_source_id = incoming.selected_source_id.clone();
        existing.selected_source_display_name = incoming.selected_source_display_name.clone();
        existing.automatic_source_id = incoming.automatic_source_id;
        existing.automatic_source_display_name = incoming.automatic_source_display_name;
        existing.is_stale = incoming.is_stale;
    }
}

fn overview_choice_is_better(incoming: &QuotaOverviewItem, existing: &QuotaOverviewItem) -> bool {
    if incoming.is_stale != existing.is_stale {
        return !incoming.is_stale;
    }
    let incoming_observed = snapshot_observed_at(&incoming.snapshot);
    let existing_observed = snapshot_observed_at(&existing.snapshot);
    if incoming_observed != existing_observed {
        return incoming_observed > existing_observed;
    }
    let incoming_local = incoming
        .sources
        .iter()
        .find(|source| source.source_id == incoming.selected_source_id)
        .is_some_and(|source| source.kind == "local");
    let existing_local = existing
        .sources
        .iter()
        .find(|source| source.source_id == existing.selected_source_id)
        .is_some_and(|source| source.kind == "local");
    if incoming_local != existing_local {
        return incoming_local;
    }
    incoming.selected_source_id < existing.selected_source_id
}

fn snapshot_observed_at(snapshot: &Value) -> DateTime<Utc> {
    crate::observation::instant(snapshot.get("observed_at")).unwrap_or(DateTime::<Utc>::MIN_UTC)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// A Relay that answers the given responses in order.
    ///
    /// It keeps listening until the test stops it, and a request the test did not plan for is
    /// recorded and answered with a closed connection rather than ignored — so "this refresh
    /// called the Account read twice" is something a test can see, not something it has to
    /// infer from a call that hung.
    struct MockRelay {
        origin: String,
        stop: Arc<AtomicBool>,
        server: std::thread::JoinHandle<Vec<String>>,
    }

    impl MockRelay {
        /// Stops listening and answers with every request head it saw, in order.
        fn finish(self) -> Vec<String> {
            self.stop.store(true, Ordering::Release);
            self.server.join().expect("relay server")
        }
    }

    fn spawn_relay(responses: Vec<String>) -> MockRelay {
        use std::io::{Read as _, Write as _};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("relay listener");
        listener.set_nonblocking(true).expect("relay nonblocking");
        let address = listener.local_addr().expect("relay address");
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let server = std::thread::spawn(move || {
            let mut recorded = Vec::new();
            let mut responses = responses.into_iter();
            while !stopping.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).expect("relay stream");
                        stream
                            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                            .expect("relay timeout");
                        let mut request = [0_u8; 8_192];
                        let read = stream.read(&mut request).unwrap_or(0);
                        recorded.push(String::from_utf8_lossy(&request[..read]).into_owned());
                        let _ = stream.write_all(responses.next().unwrap_or_default().as_bytes());
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(2))
                    }
                    Err(_) => break,
                }
            }
            recorded
        });
        MockRelay {
            origin: format!("http://{address}"),
            stop,
            server,
        }
    }

    fn spawn_gated_relay(
        responses: Vec<String>,
        delay: std::time::Duration,
        arrived: Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>,
    ) -> MockRelay {
        use std::io::{Read as _, Write as _};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("relay listener");
        listener.set_nonblocking(true).expect("relay nonblocking");
        let address = listener.local_addr().expect("relay address");
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let server = std::thread::spawn(move || {
            let mut recorded = Vec::new();
            let mut responses = responses.into_iter();
            while !stopping.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).expect("relay stream");
                        stream
                            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                            .expect("relay timeout");
                        let mut request = [0_u8; 8_192];
                        let read = stream.read(&mut request).unwrap_or(0);
                        recorded.push(String::from_utf8_lossy(&request[..read]).into_owned());
                        {
                            let (lock, cond) = arrived.as_ref();
                            *lock.lock().expect("gate") = true;
                            cond.notify_all();
                        }
                        std::thread::sleep(delay);
                        let _ = stream.write_all(responses.next().unwrap_or_default().as_bytes());
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(2))
                    }
                    Err(_) => break,
                }
            }
            recorded
        });
        MockRelay {
            origin: format!("http://{address}"),
            stop,
            server,
        }
    }

    fn wait_arrived_gate(arrived: &Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>) {
        let (lock, cond) = arrived.as_ref();
        let mut ready = lock.lock().expect("gate");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !*ready {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!remaining.is_zero(), "relay never received a request");
            let (guard, _) = cond.wait_timeout(ready, remaining).expect("wait");
            ready = guard;
        }
    }

    fn http_unauthorized() -> String {
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_owned()
    }

    fn token_refresh_response() -> String {
        relay_json(&json!({
            "protocol_version": crate::protocol::CONTROL_PROTOCOL,
            "token_type": "Bearer",
            "account_id": "account_1",
            "device_id": "device_1",
            "device_generation": 1,
            "session": {
                "access_token": "qb_access_token_rotatedxx",
                "access_expires_at": "2099-01-01T00:00:00Z",
                "refresh_token": "qbr_refresh_token_rotatedx",
                "refresh_expires_at": "2099-01-01T00:00:00Z"
            }
        }))
    }

    fn near_expiry_session() -> Value {
        let mut session = active_session();
        session["session"]["access_expires_at"] = json!(
            Utc::now()
                .checked_add_signed(Duration::seconds(30))
                .expect("expiry")
                .to_rfc3339_opts(SecondsFormat::Secs, true)
        );
        session
    }

    fn summary_requests(sent: &[String]) -> usize {
        sent.iter()
            .filter(|head| head.starts_with("GET /api/v6/account/summary"))
            .count()
    }

    fn http_json_with_etag(value: &Value, etag: &str) -> String {
        let body = serde_json::to_vec(value).expect("json");
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nETag: {etag}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            String::from_utf8(body).expect("utf8")
        )
    }

    fn relay_json(value: &Value) -> String {
        let body = serde_json::to_vec(value).expect("json");
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            String::from_utf8(body).expect("utf8")
        )
    }

    fn account_summary(label: &str) -> Value {
        let totals = json!({
            "total_tokens": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_input_tokens": 0,
            "cache_write_input_tokens": 0,
            "reasoning_tokens": 0,
            "messages": 0
        });
        let period = json!({
            "totals": totals,
            "cost": {
                "mode": "calculate",
                "basis": "none",
                "status": "complete",
                "amount_microusd": null,
                "catalog_revision": null,
                "calculated_rows": 0,
                "reported_rows": 0,
                "unpriced_rows": 0,
                "assumptions": [],
                "unpriced": []
            },
            "partial": false,
            "agents": []
        });
        json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "account": {
                "account_id": "account_1",
                "display_label": label,
                "created_at": "2026-08-09T00:00:00Z"
            },
            "devices": [],
            "subscriptions": [],
            "usage": {
                "today": period.clone(),
                "last_7_days": period.clone(),
                "last_30_days": period.clone(),
                "all": period
            },
            "pricing_revision": "2026-08-01",
            "model_catalog_revision": "2026-08-01"
        })
    }

    /// Records what a refresh publishes, and lets provider collection go the moment the Account
    /// arrives — so the ordering is proven by what released collection, not by a clock.
    struct GateOpeningUpdates {
        gate: Arc<RefreshGate>,
        account: std::sync::Mutex<Option<Value>>,
    }

    impl RefreshSink for GateOpeningUpdates {
        fn account(&self, result: Result<Value, BackendError>) {
            *self.account.lock().expect("published account") = result.ok();
            self.gate.open();
        }
    }

    /// The Account read waits on nothing but the session, so it lands and is published while
    /// provider collection is still blocked.
    #[test]
    fn the_account_read_does_not_queue_behind_provider_collection() {
        let summary = account_summary("octocat");
        let relay_server = spawn_relay(vec![relay_json(&summary)]);
        let origin = relay_server.origin.clone();
        let root =
            std::env::temp_dir().join(format!("quota-account-first-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        fs::create_dir_all(&home).expect("home");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .write_session_json(&json!({
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
            }))
            .expect("session");
        // A signed-in device, as the refresh before this one left it.
        state
            .set_component(
                crate::protocol::ComponentName::Account,
                crate::protocol::ComponentStatus::Ready,
                Some(json!({
                    "auth_status": "signed_in",
                    "account_id": "account_1",
                    "display_label": "octocat",
                    "device_id": "device_1",
                    "device_generation": 1,
                    "account_summary": null
                })),
                Some(now_rfc3339()),
                None,
                false,
            )
            .expect("account component");
        let gate = Arc::new(RefreshGate::default());
        let relay = Arc::new(crate::relay::RelayClient::for_test(&origin).expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = home;
        backend.environment.clear();
        backend.collection_gate = Some(gate.clone());
        let updates = GateOpeningUpdates {
            gate: gate.clone(),
            account: std::sync::Mutex::new(None),
        };

        let outcome = backend.refresh(Arc::new(AtomicBool::new(false)), &updates, false);

        // Collection was still waiting when the Account was published: opening the gate is what
        // let it run at all.
        assert!(!gate.timed_out(), "the account read waited for collection");
        let published = updates
            .account
            .lock()
            .expect("published account")
            .clone()
            .expect("the account was published during the refresh");
        assert_eq!(published["auth_status"], "signed_in");
        assert_eq!(published["account_summary"], summary);
        assert_eq!(outcome.account.expect("account outcome"), published);
        // The Account periods Relay folded are stored with it, not after the whole refresh.
        assert!(
            state
                .snapshot()
                .expect("state snapshot")
                .usage_periods
                .account
                .today
                .is_some()
        );

        let sent = relay_server.finish();
        // The Account was the first thing this refresh asked Relay for, before pricing, before
        // the control check, before anything collection could have needed.
        assert!(
            sent[0].starts_with("GET /api/v6/account/summary"),
            "{sent:?}"
        );
        assert_eq!(summary_requests(&sent), 1, "{sent:?}");
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// Signing in during a refresh is a race the refresh has to lose gracefully: it began with
    /// no session to read, and it must not report the device signed out because of that.
    #[test]
    fn a_sign_in_that_lands_mid_refresh_is_still_read_before_the_refresh_ends() {
        let summary = account_summary("octocat");
        // Pricing, the model catalog and the control call are all answered by a closed
        // connection — a network failure, not a session ending. The read that follows is the
        // one under test.
        let relay_server = spawn_relay(vec![
            String::new(),
            String::new(),
            String::new(),
            relay_json(&summary),
        ]);
        let origin = relay_server.origin.clone();
        let root =
            std::env::temp_dir().join(format!("quota-account-late-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        fs::create_dir_all(&home).expect("home");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let reading = Arc::new(RefreshGate::default());
        let collecting = Arc::new(RefreshGate::default());
        let relay = Arc::new(crate::relay::RelayClient::for_test(&origin).expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = home;
        backend.environment.clear();
        backend.account_read_gate = Some(reading.clone());
        backend.collection_gate = Some(collecting.clone());
        let updates = RecordingUpdates::default();

        let outcome = std::thread::scope(|scope| {
            let refreshing =
                scope.spawn(|| backend.refresh(Arc::new(AtomicBool::new(false)), &updates, false));
            // Both halves of the refresh are parked. The Account read has already decided — it
            // found no session — and collection has not finished. The sign-in lands between the
            // two, with nothing about the ordering left to a clock.
            reading.wait_arrived();
            collecting.wait_arrived();
            state
                .write_session_json(&active_session())
                .expect("session");
            reading.open();
            collecting.open();
            refreshing.join().expect("refresh")
        });
        assert!(!reading.timed_out(), "the account read was never released");
        assert!(!collecting.timed_out(), "collection was never released");

        let account = outcome
            .account
            .expect("the account this refresh signed in to");
        assert_eq!(account["auth_status"], "signed_in");
        assert_eq!(account["account_summary"], summary);
        // One read, published once: the refresh began with nothing to read.
        assert_eq!(updates.published(), vec![account.clone()]);

        let sent = relay_server.finish();
        assert_eq!(sent.len(), 4, "{sent:?}");
        assert!(
            sent[3].starts_with("GET /api/v6/account/summary"),
            "{}",
            sent[3]
        );
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// Records everything a refresh publishes, in order.
    #[derive(Default)]
    struct RecordingUpdates {
        account: std::sync::Mutex<Vec<Result<Value, BackendError>>>,
    }

    impl RecordingUpdates {
        fn published(&self) -> Vec<Value> {
            self.account
                .lock()
                .expect("published accounts")
                .iter()
                .filter_map(|result| result.as_ref().ok().cloned())
                .collect()
        }
    }

    impl RefreshSink for RecordingUpdates {
        fn account(&self, result: Result<Value, BackendError>) {
            self.account
                .lock()
                .expect("published accounts")
                .push(result);
        }
    }

    fn active_session() -> Value {
        json!({
            "schema_version": 1,
            "status": "active",
            "account_id": "account_1",
            "display_label": "octocat",
            "device_id": "device_1",
            "device_generation": 1,
            "usage_sync_revision": 0,
            "usage_deleted_before": null,
            "session": {
                "access_token": "qb_access_token_synthetic",
                "access_expires_at": "2099-01-01T00:00:00Z",
                "refresh_token": "qbr_refresh_token_synthetic",
                "refresh_expires_at": "2099-01-01T00:00:00Z"
            }
        })
    }

    fn device_control() -> String {
        relay_json(&json!({
            "protocol_version": crate::protocol::CONTROL_PROTOCOL,
            "account_id": "account_1",
            "device_id": "device_1",
            "device_generation": 1,
            "usage_deleted_before": null,
            "usage_sync_revision": 0
        }))
    }

    fn device_profile() -> String {
        relay_json(&json!({
            "protocol_version": crate::protocol::CONTROL_PROTOCOL,
            "status": "updated",
            "device_id": "device_1"
        }))
    }

    fn snapshot_upload(accepted: Value, ignored: Value) -> String {
        relay_json(&json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "device_id": "device_1",
            "device_generation": 1,
            "accepted": accepted,
            "ignored": ignored
        }))
    }

    /// A reading this device took a moment ago, still current, for a provider this refresh will
    /// find no sign-in for — which is what makes the refresh restate and upload it.
    fn previous_quota_report() -> Value {
        json!({
            "captured_at": Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
            "results": [{
                "provider": "codex",
                "outcome": "success",
                "snapshots": [{
                    "provider": "codex",
                    "account": {"fingerprint": "account_test", "fingerprint_scope": "global"},
                    "windows": [{"id": "five_hour", "title": "5 hour", "used_percent": 40.0}],
                    "status": "available",
                    "observed_at": Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
                }],
                "sources": []
            }]
        })
    }

    fn signed_in_backend(root: &std::path::Path, origin: &str) -> (Arc<StateStore>, NativeBackend) {
        let home = root.join("home");
        fs::create_dir_all(&home).expect("home");
        let state = Arc::new(StateStore::open(root).expect("state"));
        state
            .write_session_json(&active_session())
            .expect("session");
        state
            .set_component(
                crate::protocol::ComponentName::Account,
                crate::protocol::ComponentStatus::Ready,
                Some(json!({
                    "auth_status": "signed_in",
                    "account_id": "account_1",
                    "display_label": "octocat",
                    "device_id": "device_1",
                    "device_generation": 1,
                    "account_summary": null
                })),
                Some(now_rfc3339()),
                None,
                false,
            )
            .expect("account component");
        let relay = Arc::new(crate::relay::RelayClient::for_test(origin).expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = home;
        backend.environment.clear();
        (state, backend)
    }

    #[test]
    fn account_read_session_changed_leaves_the_session_installed() {
        let arrived = Arc::new((std::sync::Mutex::new(false), std::sync::Condvar::new()));
        let relay_server = spawn_gated_relay(
            vec![token_refresh_response()],
            std::time::Duration::from_millis(150),
            arrived.clone(),
        );
        let root =
            std::env::temp_dir().join(format!("quota-session-changed-{}", uuid::Uuid::new_v4()));
        let (state, backend) = signed_in_backend(&root, &relay_server.origin);
        state
            .write_session_json(&near_expiry_session())
            .expect("near-expiry session");
        let reader = std::thread::spawn(move || backend.account_read(&AtomicBool::new(false)));
        wait_arrived_gate(&arrived);
        state
            .write_session_json(&active_session())
            .expect("rotated session");
        let result = reader.join().expect("account_read");
        let error = result
            .expect("an active session was present")
            .expect_err("session-changed");
        assert!(error.is_session_changed(), "{error:?}");
        assert!(!error.error.code.requires_login());
        let session = state.session_json().expect("session").expect("installed");
        assert_eq!(
            session.get("status").and_then(Value::as_str),
            Some("active")
        );
        drop(relay_server.finish());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_relay_401_at_epoch_n_does_not_clear_epoch_n_plus_one() {
        let arrived = Arc::new((std::sync::Mutex::new(false), std::sync::Condvar::new()));
        let relay_server = spawn_gated_relay(
            vec![http_unauthorized()],
            std::time::Duration::from_millis(150),
            arrived.clone(),
        );
        let root = std::env::temp_dir().join(format!("quota-401-epoch-{}", uuid::Uuid::new_v4()));
        let (state, backend) = signed_in_backend(&root, &relay_server.origin);
        let (_, epoch) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session");
        let reader = std::thread::spawn(move || backend.account_read(&AtomicBool::new(false)));
        wait_arrived_gate(&arrived);
        state
            .write_session_json(&active_session())
            .expect("newer session");
        let result = reader.join().expect("account_read");
        let error = result
            .expect("an active session was present")
            .expect_err("relay 401");
        assert_eq!(error.error.code, ErrorCode::AuthenticationRequired);
        assert_eq!(error.sign_out_epoch(), Some(epoch));
        let (session, after) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session still installed");
        assert_ne!(after, epoch);
        assert_eq!(
            session.get("status").and_then(Value::as_str),
            Some("active")
        );
        drop(relay_server.finish());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn upload_quota_after_collection_refreshes_a_near_expiry_token_first() {
        let relay_server = spawn_relay(vec![
            token_refresh_response(),
            snapshot_upload(json!(["codex"]), json!([])),
        ]);
        let root =
            std::env::temp_dir().join(format!("quota-upload-refresh-{}", uuid::Uuid::new_v4()));
        let (state, backend) = signed_in_backend(&root, &relay_server.origin);
        state
            .write_session_json(&near_expiry_session())
            .expect("near-expiry session");
        let updates = RecordingUpdates::default();
        let (put, accepted, signed_out) = backend.upload_quota_after_collection(
            &Ok(previous_quota_report()),
            None,
            &AtomicBool::new(false),
            &updates,
        );
        assert!(put);
        assert!(accepted);
        assert!(signed_out.is_none());
        let sent = relay_server.finish();
        assert!(sent[0].starts_with("POST /oauth/v2/token"), "{sent:?}");
        assert!(
            sent.iter()
                .any(|head| head.starts_with("PUT /api/v6/device/snapshots")),
            "{sent:?}"
        );
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// What this Mac just uploaded belongs in its own Account view now, not in five minutes.
    ///
    /// The refresh reads the Account first — that is what makes it feel instant — and reads it
    /// once more after an upload Relay actually took, so the panel ends the refresh holding the
    /// Account that includes this device's own reading.
    #[test]
    fn an_upload_the_account_took_is_read_back_in_the_same_refresh() {
        let before = account_summary("octocat");
        let mut after = account_summary("octocat");
        after["devices"] = json!([{
            "id": "device_1",
            "display_name": "Test Mac",
            "platform": "macos",
            "last_seen_at": "2026-08-27T00:00:00Z",
            "last_observed_at": "2026-08-27T00:00:00Z"
        }]);
        let relay_server = spawn_relay(vec![
            http_json_with_etag(&before, "\"before\""),
            snapshot_upload(json!(["codex"]), json!([])),
            String::new(),
            String::new(),
            device_control(),
            device_profile(),
            http_json_with_etag(&after, "\"after\""),
        ]);
        let root =
            std::env::temp_dir().join(format!("quota-account-reread-{}", uuid::Uuid::new_v4()));
        let (state, backend) = signed_in_backend(&root, &relay_server.origin);
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(previous_quota_report()),
                Some(now_rfc3339()),
                None,
                false,
            )
            .expect("previous quota");
        let updates = RecordingUpdates::default();

        let outcome = backend.refresh(Arc::new(AtomicBool::new(false)), &updates, false);

        let account = outcome.account.expect("account outcome");
        assert_eq!(account["account_summary"], after);
        // Both reads were published, in the order they happened: the fast one, then the one that
        // includes this device.
        let published = updates.published();
        assert_eq!(published.len(), 2, "{published:?}");
        assert_eq!(published[0]["account_summary"], before);
        assert_eq!(published[1]["account_summary"], after);

        let sent = relay_server.finish();
        assert!(
            sent.iter()
                .any(|head| head.starts_with("PUT /api/v6/device/snapshots")),
            "{sent:?}"
        );
        assert_eq!(summary_requests(&sent), 2, "{sent:?}");
        let reread = sent
            .iter()
            .filter(|head| head.starts_with("GET /api/v6/account/summary"))
            .nth(1)
            .expect("second account read");
        // The second read is conditional on what the first one returned, so an Account that did
        // not move costs a 304 and nothing else.
        assert!(
            reread
                .to_ascii_lowercase()
                .contains("if-none-match: \"before\""),
            "{reread}"
        );
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// An upload Relay took nothing new from left the Account exactly as this refresh read it,
    /// so there is nothing to read again.
    #[test]
    fn an_upload_the_account_ignored_does_not_read_it_again() {
        let summary = account_summary("octocat");
        let relay_server = spawn_relay(vec![
            http_json_with_etag(&summary, "\"only\""),
            snapshot_upload(json!([]), json!(["codex"])),
            String::new(),
            String::new(),
            device_control(),
            device_profile(),
        ]);
        let root =
            std::env::temp_dir().join(format!("quota-account-once-{}", uuid::Uuid::new_v4()));
        let (state, backend) = signed_in_backend(&root, &relay_server.origin);
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(previous_quota_report()),
                Some(now_rfc3339()),
                None,
                false,
            )
            .expect("previous quota");
        let updates = RecordingUpdates::default();

        let outcome = backend.refresh(Arc::new(AtomicBool::new(false)), &updates, false);

        assert_eq!(
            outcome.account.expect("account outcome")["account_summary"],
            summary
        );
        assert_eq!(updates.published().len(), 1);
        let sent = relay_server.finish();
        // The upload happened; Relay simply had nothing new to take from it.
        assert!(
            sent.iter()
                .any(|head| head.starts_with("PUT /api/v6/device/snapshots")),
            "{sent:?}"
        );
        assert_eq!(summary_requests(&sent), 1, "{sent:?}");
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn requires_login_sync_error_is_not_overwritten_by_later_non_auth() {
        for code in [
            ErrorCode::AuthenticationRequired,
            ErrorCode::DeviceDeleted,
            ErrorCode::StaleGeneration,
        ] {
            let mut slot = None;
            record_account_sync_error(
                &mut slot,
                BackendError::new(IpcError::new(code, RecoveryAction::Login)),
            );
            record_account_sync_error(&mut slot, BackendError::unavailable());
            let error = slot.expect("retained requires-login error");
            assert_eq!(error.error.code, code);
            assert!(error.error.code.requires_login());
        }

        let mut slot = None;
        record_account_sync_error(&mut slot, BackendError::unavailable());
        record_account_sync_error(
            &mut slot,
            BackendError::new(IpcError::new(
                ErrorCode::AuthenticationRequired,
                RecoveryAction::Login,
            )),
        );
        assert_eq!(
            slot.expect("promoted requires-login error").error.code,
            ErrorCode::AuthenticationRequired
        );
    }

    #[test]
    fn usage_periods_begin_at_local_midnight_in_the_service_timezone() {
        let now = DateTime::parse_from_rfc3339("2026-08-12T18:00:00Z")
            .expect("instant")
            .with_timezone(&Utc);
        let span = usage_period_window(UsagePeriod::Last7Days, "Asia/Singapore", now)
            .expect("window")
            .1
            .expect("span");
        // 18:00 UTC is already the 13th in Singapore, and its days begin at 16:00 UTC.
        assert_eq!(span.dates, ("2026-08-07".into(), "2026-08-13".into()));
        assert_eq!(span.start, "2026-08-06T16:00:00Z");
        assert_eq!(span.end, "2026-08-13T16:00:00Z");
        assert!(
            usage_period_window(UsagePeriod::All, "Asia/Singapore", now)
                .expect("window")
                .1
                .is_none()
        );
    }

    /// A change that skips or repeats midnight still leaves the day one instant to begin at.
    #[test]
    fn a_local_day_begins_once_across_a_daylight_change() {
        let santiago = Tz::from_str("America/Santiago").expect("zone");
        let skipped = NaiveDate::from_ymd_opt(2026, 9, 6).expect("date");
        assert_eq!(
            local_day_start(&santiago, skipped).expect("start"),
            "2026-09-06T04:00:00Z"
        );

        let havana = Tz::from_str("America/Havana").expect("zone");
        let repeated = NaiveDate::from_ymd_opt(2026, 11, 1).expect("date");
        assert_eq!(
            local_day_start(&havana, repeated).expect("start"),
            "2026-11-01T04:00:00Z"
        );
    }

    /// One statement per contract: the account read always carries its per-agent breakdown, so
    /// a summary without it is refused rather than rebuilt from the display breakdowns.
    /// A managed period states cost at the leaf. What the panel shows above it — a total per
    /// agent and per provider — is folded here, and folding must not invent or lose anything.
    #[test]
    fn a_managed_period_folds_its_leaves_into_the_totals_the_panel_shows() {
        let cost = |amount: &str, calculated: u64| {
            json!({
                "mode": "auto",
                "basis": "calculated",
                "status": "complete",
                "amount_microusd": amount,
                "catalog_revision": "official-2026-08-10-4",
                "calculated_rows": calculated,
                "reported_rows": 0,
                "unpriced_rows": 0,
                "assumptions": ["wildcard_speed"],
                "unpriced": []
            })
        };
        let totals = |input: u64, output: u64, messages: u64| {
            json!({
                "total_tokens": input + output,
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": 0,
                "cache_write_input_tokens": 0,
                "reasoning_tokens": 0,
                "messages": messages
            })
        };
        let period = json!({
            "totals": totals(30, 6, 3),
            "cost": cost("300", 3),
            "partial": true,
            "agents": [{
                "agent": "codex",
                "providers": [{
                    "provider": "openai",
                    "models": [
                        {"model": "gpt-5.4", "totals": totals(10, 2, 1), "cost": cost("100", 1)},
                        {"model": "gpt-5.6", "totals": totals(20, 4, 2), "cost": cost("200", 2)}
                    ]
                }]
            }]
        });
        let detail =
            account_usage_detail(&period, &("2026-08-13".to_owned(), "2026-08-13".to_owned()))
                .expect("detail");

        assert_eq!(
            detail["range"],
            json!({"from": "2026-08-13", "to": "2026-08-13"})
        );
        assert_eq!(detail["incomplete"], json!(true));
        assert_eq!(detail["usage"]["totals"]["messages"], json!(3));
        let agent = &detail["usage"]["agents"][0];
        assert_eq!(agent["agent"], "codex");
        assert_eq!(agent["totals"]["input_tokens"], json!(30));
        assert_eq!(agent["totals"]["messages"], json!(3));
        assert_eq!(agent["cost"]["amount_microusd"], json!("300"));
        assert_eq!(agent["cost"]["calculated_rows"], json!(3));
        assert_eq!(agent["cost"]["status"], json!("complete"));
        assert_eq!(agent["providers"][0]["totals"]["output_tokens"], json!(6));
        assert_eq!(
            agent["providers"][0]["models"]
                .as_array()
                .expect("models")
                .len(),
            2
        );
    }

    /// A period with no agents in it still answers, and its fold says there was no cost.
    #[test]
    fn a_managed_period_with_nothing_in_it_folds_to_no_cost() {
        let detail = account_usage_detail(
            &json!({
                "totals": {
                    "total_tokens": 0,
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "cache_write_input_tokens": 0,
                    "reasoning_tokens": 0,
                    "messages": 0
                },
                "cost": {
                    "mode": "auto",
                    "basis": "none",
                    "status": "complete",
                    "amount_microusd": null,
                    "catalog_revision": null,
                    "calculated_rows": 0,
                    "reported_rows": 0,
                    "unpriced_rows": 0,
                    "assumptions": [],
                    "unpriced": []
                },
                "partial": false,
                "agents": []
            }),
            &("2026-08-13".to_owned(), "2026-08-13".to_owned()),
        )
        .expect("detail");
        assert_eq!(detail["usage"]["agents"], json!([]));
        assert_eq!(detail["incomplete"], json!(false));
    }

    /// A period that does not carry the tree is not a period this build can read.
    #[test]
    fn a_managed_period_without_its_agent_tree_is_refused() {
        assert!(
            account_usage_detail(
                &json!({"totals": {}, "cost": {}, "partial": false}),
                &("2026-08-13".to_owned(), "2026-08-13".to_owned()),
            )
            .is_err()
        );
    }

    /// The probe belongs to the binary, not to the refresh: it is stored in the cache and
    /// re-read from it, so the second refresh presents the same version without starting
    /// anything.  A CLI whose provider holds no sign-in here is never asked at all.
    #[test]
    fn a_second_refresh_reads_the_cli_version_from_the_cache_without_spawning() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let root =
                std::env::temp_dir().join(format!("quota-cli-version-{}", uuid::Uuid::new_v4()));
            let home = root.join("home");
            let bin = root.join("bin");
            fs::create_dir_all(&home).expect("home");
            fs::create_dir_all(&bin).expect("bin");
            let log = root.join("spawns.log");
            fs::write(
                bin.join("claude"),
                format!(
                    "#!/bin/sh\necho ran >> {}\necho '2.4.7 (Claude Code)'\n",
                    log.display()
                ),
            )
            .expect("fake claude");
            fs::set_permissions(bin.join("claude"), fs::Permissions::from_mode(0o755))
                .expect("mode");

            let state = Arc::new(StateStore::open(&root).expect("state"));
            let relay = Arc::new(RelayClient::new().expect("relay"));
            let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
            backend.home = home.clone();
            backend.environment.clear();
            backend
                .environment
                .insert("PATH".to_owned(), bin.to_string_lossy().into_owned());
            let cancel = Arc::new(AtomicBool::new(false));
            let context = backend.collection_context(cancel.clone()).expect("context");
            let signed_in = vec![(
                ProviderId::Claude,
                vec![ProviderSession {
                    provider: ProviderId::Claude,
                    credential_source: "fixture".to_owned(),
                    cookie_header: None,
                }],
            )];

            let first = backend.provider_cli_versions(&signed_in, &context, &cancel);
            assert_eq!(
                first.get(&CliTool::Claude).map(String::as_str),
                Some("2.4.7")
            );
            let spawns = |log: &std::path::Path| {
                fs::read_to_string(log)
                    .map(|text| text.lines().count())
                    .unwrap_or(0)
            };
            assert_eq!(spawns(&log), 1);

            let second = backend.provider_cli_versions(&signed_in, &context, &cancel);
            assert_eq!(second, first);
            assert_eq!(spawns(&log), 1);

            // Codex is not signed in here, so its binary is never looked for or run.
            let none = backend.provider_cli_versions(
                &[(ProviderId::Codex, Vec::new())],
                &context,
                &cancel,
            );
            assert!(none.is_empty());
            assert_eq!(spawns(&log), 1);

            drop(backend);
            drop(state);
            fs::remove_dir_all(root).expect("cleanup");
        }
    }

    /// The renewal rung end to end: an expired Grok token, an expired Claude Code credential,
    /// and an expired Codex token each buy exactly one run of the CLI that owns them, on the
    /// refresh worker; all three attempts land in one cache record; and that record is what
    /// stops the next five-minute refresh from starting any of them again.  The rest of the
    /// refresh — here, the Claude version probe — is untouched by any of it.
    #[test]
    fn expired_sign_ins_are_renewed_once_each_and_one_record_outlives_the_refresh() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let root = std::env::temp_dir().join(format!("quota-renew-{}", uuid::Uuid::new_v4()));
            let home = root.join("home");
            let bin = root.join("bin");
            let grok_home = home.join(".grok");
            let claude_home = home.join(".claude");
            let codex_home = home.join(".codex");
            fs::create_dir_all(&grok_home).expect("grok home");
            fs::create_dir_all(&claude_home).expect("claude home");
            fs::create_dir_all(&codex_home).expect("codex home");
            fs::create_dir_all(&bin).expect("bin");
            let log = root.join("spawns.log");
            let auth = grok_home.join("auth.json");
            let credential = claude_home.join(".credentials.json");
            let codex_auth = codex_home.join("auth.json");
            let grok_credentials = |expires_at: &str, token: &str| {
                format!(
                    "{{\"https://auth.x.ai::fixture\": {{\"key\": \"{token}\", \
                     \"expires_at\": \"{expires_at}\"}}}}"
                )
            };
            // Milliseconds, as Claude Code writes them: 2020, then 2099.
            let claude_credentials = |expires_at_ms: i64, token: &str| {
                format!(
                    "{{\"claudeAiOauth\": {{\"accessToken\": \"{token}\", \
                     \"refreshToken\": \"refresh\", \"expiresAt\": {expires_at_ms}}}}}"
                )
            };
            // Codex writes the expiry inside the access token, so the fixture writes one too:
            // a base64url payload carrying nothing but `exp`, in 2020 and then in 2099.
            let codex_access_token = |expires_at: i64| {
                use base64::Engine as _;
                let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
                    .encode(format!("{{\"exp\":{expires_at}}}"));
                format!("header.{payload}.signature")
            };
            let codex_credentials = |expires_at: i64| {
                format!(
                    "{{\"tokens\": {{\"access_token\": \"{token}\", \
                     \"refresh_token\": \"refresh\"}}, \
                     \"last_refresh\": \"2020-01-01T00:00:00Z\"}}",
                    token = codex_access_token(expires_at),
                )
            };
            fs::write(&auth, grok_credentials("2020-01-01T00:00:00Z", "stale")).expect("auth");
            fs::write(&credential, claude_credentials(1_577_836_800_000, "stale"))
                .expect("credential");
            fs::write(&codex_auth, codex_credentials(1_577_836_800)).expect("codex auth");
            fs::write(
                bin.join("grok"),
                format!(
                    "#!/bin/sh\n\
                     echo \"ran grok\" >> {log}\n\
                     read -r first || exit 1\n\
                     printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{}}}}'\n\
                     read -r second || exit 1\n\
                     case \"$second\" in *cached_token*) ;; *) exit 3 ;; esac\n\
                     printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{{}}}}'\n\
                     cat > {auth} <<'AUTHJSON'\n\
                     {renewed}\n\
                     AUTHJSON\n",
                    log = log.display(),
                    auth = auth.display(),
                    renewed = grok_credentials("2099-01-01T00:00:00Z", "fresh"),
                ),
            )
            .expect("fake grok");
            // One binary answering both things this build ever asks a CLI for: the version
            // the request headers claim, and the renewal an expired credential earns.
            fs::write(
                bin.join("claude"),
                format!(
                    "#!/bin/sh\n\
                     case \"$1\" in\n\
                       --version) echo '2.4.7 (Claude Code)'; exit 0 ;;\n\
                     esac\n\
                     echo \"ran claude $*\" >> {log}\n\
                     cat > {credential} <<'CREDENTIAL'\n\
                     {renewed}\n\
                     CREDENTIAL\n",
                    log = log.display(),
                    credential = credential.display(),
                    renewed = claude_credentials(4_070_908_800_000, "fresh"),
                ),
            )
            .expect("fake claude");
            // The Codex CLI renews on its own startup path, so the stand-in rewrites
            // `auth.json` on the way out rather than in answer to a request.
            fs::write(
                bin.join("codex"),
                format!(
                    "#!/bin/sh\n\
                     echo \"ran codex $*\" >> {log}\n\
                     read -r first || exit 1\n\
                     printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{}}}}'\n\
                     read -r rest\n\
                     cat > {auth} <<'AUTHJSON'\n\
                     {renewed}\n\
                     AUTHJSON\n",
                    log = log.display(),
                    auth = codex_auth.display(),
                    renewed = codex_credentials(4_070_908_800),
                ),
            )
            .expect("fake codex");
            for program in ["grok", "claude", "codex"] {
                fs::set_permissions(bin.join(program), fs::Permissions::from_mode(0o755))
                    .expect("mode");
            }

            let state = Arc::new(StateStore::open(&root).expect("state"));
            let relay = Arc::new(RelayClient::new().expect("relay"));
            let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
            backend.home = home.clone();
            backend.environment.clear();
            backend.environment.insert(
                "PATH".to_owned(),
                format!("{}:/usr/bin:/bin", bin.display()),
            );
            let cancel = Arc::new(AtomicBool::new(false));
            let mut context = backend.collection_context(cancel.clone()).expect("context");
            let session = |provider: ProviderId| {
                (
                    provider,
                    vec![ProviderSession {
                        provider,
                        credential_source: "fixture".to_owned(),
                        cookie_header: None,
                    }],
                )
            };
            let discovered = vec![
                session(ProviderId::Grok),
                session(ProviderId::Claude),
                session(ProviderId::Codex),
            ];
            let spawns = |program: &str| {
                fs::read_to_string(&log)
                    .map(|text| {
                        text.lines()
                            .filter(|line| line.starts_with(&format!("ran {program}")))
                            .count()
                    })
                    .unwrap_or(0)
            };

            let first =
                backend.renew_provider_sign_ins(&discovered, &mut context, false, &HashSet::new());
            assert_eq!(
                first,
                HashSet::from([ProviderId::Claude, ProviderId::Codex, ProviderId::Grok])
            );
            assert_eq!(
                (spawns("grok"), spawns("claude"), spawns("codex")),
                (1, 1, 1)
            );
            assert!(
                fs::read_to_string(&auth).expect("auth").contains("fresh"),
                "collection reads the file the CLI wrote"
            );
            assert!(
                fs::read_to_string(&codex_auth)
                    .expect("codex auth")
                    .contains(&codex_access_token(4_070_908_800)),
                "collection reads the token the CLI wrote"
            );
            assert!(
                fs::read_to_string(&credential)
                    .expect("credential")
                    .contains("fresh"),
                "collection reads the credential the CLI wrote"
            );
            assert!(
                fs::read_to_string(&log).expect("log").contains("mcp list"),
                "the renewal is the one invocation that reaches Claude Code's refresh path"
            );
            // One record for both providers, so the refresh reads and writes it once.
            let recorded = state
                .provider_refresh_attempts()
                .expect("attempts")
                .expect("recorded");
            let attempts =
                serde_json::from_str::<RenewalAttempts>(&recorded).expect("decodes as a map");
            assert_eq!(attempts.len(), 3, "{recorded}");
            for provider in [ProviderId::Claude, ProviderId::Codex, ProviderId::Grok] {
                assert_eq!(
                    attempts
                        .get(provider.as_str())
                        .map(|attempt| attempt.outcome),
                    Some(crate::providers::common::RenewalOutcome::Renewed),
                    "{recorded}"
                );
            }

            // Tokens with time left are not sign-in problems, so nothing is started.
            assert!(
                backend
                    .renew_provider_sign_ins(&discovered, &mut context, false, &HashSet::new())
                    .is_empty()
            );
            assert_eq!(
                (spawns("grok"), spawns("claude"), spawns("codex")),
                (1, 1, 1)
            );

            // Expired again inside the hour: the record from the first attempt is what keeps
            // the five-minute timer from turning into a spawn schedule.
            fs::write(&auth, grok_credentials("2020-01-01T00:00:00Z", "stale")).expect("auth");
            fs::write(&credential, claude_credentials(1_577_836_800_000, "stale"))
                .expect("credential");
            fs::write(&codex_auth, codex_credentials(1_577_836_800)).expect("codex auth");
            assert!(
                backend
                    .renew_provider_sign_ins(&discovered, &mut context, false, &HashSet::new())
                    .is_empty()
            );
            assert_eq!(
                (spawns("grok"), spawns("claude"), spawns("codex")),
                (1, 1, 1)
            );

            // A Recheck or a manual refresh skips that hour, so it can ask again immediately.
            let recheck =
                backend.renew_provider_sign_ins(&discovered, &mut context, true, &HashSet::new());
            assert_eq!(
                recheck,
                HashSet::from([ProviderId::Claude, ProviderId::Codex, ProviderId::Grok])
            );
            assert_eq!(
                (spawns("grok"), spawns("claude"), spawns("codex")),
                (2, 2, 2)
            );

            // A Mac that never signed into any of them never looks for a binary at all.
            assert!(
                backend
                    .renew_provider_sign_ins(
                        &[
                            (ProviderId::Grok, Vec::new()),
                            (ProviderId::Claude, Vec::new()),
                            (ProviderId::Codex, Vec::new()),
                        ],
                        &mut context,
                        false,
                        &HashSet::new(),
                    )
                    .is_empty()
            );
            assert_eq!(
                (spawns("grok"), spawns("claude"), spawns("codex")),
                (2, 2, 2)
            );

            // And the rest of the refresh is exactly where it was.
            let versions =
                backend.provider_cli_versions(&[session(ProviderId::Claude)], &context, &cancel);
            assert_eq!(
                versions.get(&CliTool::Claude).map(String::as_str),
                Some("2.4.7")
            );

            drop(backend);
            drop(state);
            fs::remove_dir_all(root).expect("cleanup");
        }
    }

    #[test]
    fn native_backend_collects_empty_home_without_unavailable_fallback() {
        let root = std::env::temp_dir().join(format!("quota-backend-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        fs::create_dir_all(&home).expect("home");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let mut backend = NativeBackend::new(state, relay, "QuotaTest", "test");
        backend.home = home;
        backend.environment.clear();
        let collection = backend
            .collect_usage(Arc::new(AtomicBool::new(false)))
            .expect("empty usage collection");
        assert_eq!(collection.agents.len(), UsageAgent::ALL.len());
        assert!(!collection.timezone.is_empty());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn usage_index_read_failure_does_not_leave_a_running_scan_attempt() {
        let root = std::env::temp_dir().join(format!("quota-usage-index-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        fs::create_dir_all(&home).expect("home");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .make_usage_file_index_unreadable_for_test()
            .expect("break index read");
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = home;
        backend.environment.clear();

        let error = match backend.collect_usage(Arc::new(AtomicBool::new(false))) {
            Ok(_) => panic!("index read must fail before scanning"),
            Err(error) => error,
        };

        assert_eq!(error.error.code, ErrorCode::Unavailable);
        assert!(
            state
                .diagnostic_recent_attempts()
                .expect("activity")
                .iter()
                .all(|attempt| attempt.kind != DiagnosticAttemptKind::UsageScan)
        );
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// The journal is evidence about collection, not a permit to collect.
    #[test]
    fn a_journal_that_cannot_be_written_does_not_stop_a_refresh() {
        let root = std::env::temp_dir().join(format!("quota-journal-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        fs::create_dir_all(&home).expect("home");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .make_diagnostic_journal_unwritable_for_test()
            .expect("break the journal");
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = home;
        backend.environment.clear();

        let quota = backend
            .collect_quota(Arc::new(AtomicBool::new(false)))
            .expect("quota still collects");
        assert_eq!(
            quota.get("results").and_then(Value::as_array).map(Vec::len),
            Some(ProviderId::ALL.len())
        );
        let usage = backend
            .collect_usage(Arc::new(AtomicBool::new(false)))
            .expect("usage still scans");
        assert_eq!(usage.agents.len(), UsageAgent::ALL.len());
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn local_quota_collection_does_not_require_or_modify_account_state() {
        let root =
            std::env::temp_dir().join(format!("quota-local-status-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        fs::create_dir_all(&home).expect("home");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = home;
        backend.environment.clear();
        assert!(
            backend
                .configured_providers()
                .expect("providers")
                .is_empty()
        );
        let report = backend
            .collect_quota(Arc::new(AtomicBool::new(false)))
            .expect("local quota report");
        assert!(report.get("protocol_version").is_none());
        for result in report
            .get("results")
            .and_then(Value::as_array)
            .expect("quota results")
        {
            let result = result.as_object().expect("quota result object");
            assert_eq!(result.len(), 4);
            assert!(result.contains_key("provider"));
            assert!(result.contains_key("outcome"));
            assert!(result.contains_key("snapshots"));
            // An isolated home has no credentials, so every provider reports that it was
            // never set up here rather than that collection failed here.
            assert_eq!(
                result.get("sources").and_then(Value::as_array),
                Some(&Vec::new())
            );
        }
        assert!(state.session_json().expect("session state").is_none());
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A body is only described by the validator that came with it. Keeping the old ETag over
    /// a new document made the next conditional request ask about a document this device no
    /// longer held, and a 304 would have confirmed the wrong one.
    #[test]
    fn a_body_with_no_validator_is_stored_without_one() {
        let root = std::env::temp_dir().join(format!("quota-etag-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let catalog = |revision: &str| {
            json!({
                "schema_version": 2,
                "revision": revision,
                "models": [{
                    "canonical_id": "gpt-5.5",
                    "aliases": [{"reported_model": "gpt-5.5-alias", "provider": "openai"}]
                }]
            })
        };
        state
            .commit_model_catalog(&catalog("model-1"), Some("\"model-1\""))
            .expect("first catalog");

        let body = serde_json::to_string(&catalog("model-2")).expect("body");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let address = listener.local_addr().expect("address");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("request");
            let mut request = [0_u8; 8_192];
            let _ = std::io::Read::read(&mut stream, &mut request);
            // A newer document, and no ETag with it.
            std::io::Write::write_all(
                &mut stream,
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \
                     {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            )
            .expect("response");
        });
        let relay =
            Arc::new(RelayClient::for_test(&format!("http://{address}")).expect("test relay"));
        let backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");

        backend.refresh_model_catalog().expect("refresh");

        assert_eq!(
            state.model_catalog().expect("catalog"),
            Some(catalog("model-2"))
        );
        assert_eq!(state.model_catalog_etag().expect("etag"), None);
        server.join().expect("server");
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn model_catalog_refresh_failure_keeps_last_known_good_for_reports() {
        let root = std::env::temp_dir().join(format!("quota-model-lkg-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let value = json!({
            "schema_version": 2,
            "revision": "model-test-1",
            "models": [{
                "canonical_id": "gpt-5.5",
                "aliases": [{"reported_model":"gpt-5.5-alias","provider":"openai"}]
            }]
        });
        state
            .commit_model_catalog(&value, Some("\"model-test-1\""))
            .expect("lkg");

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let address = listener.local_addr().expect("address");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("request");
            let mut request = [0_u8; 8_192];
            let _ = std::io::Read::read(&mut stream, &mut request);
            std::io::Write::write_all(
                &mut stream,
                b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .expect("response");
        });
        let relay =
            Arc::new(RelayClient::for_test(&format!("http://{address}")).expect("test relay"));
        let backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        assert!(backend.refresh_model_catalog().is_err());
        assert_eq!(state.model_catalog().expect("catalog"), Some(value));
        server.join().expect("server");
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A browser store macOS refused is not "no session found". It is a permission the reader
    /// has to grant, no refresh clears it, and the Support page has to say which browser and
    /// which grant — so it travels the browser-session commit and lands as its own source row.
    #[test]
    fn a_commit_that_names_a_refusal_becomes_a_browser_access_denied_source() {
        let root = std::env::temp_dir().join(format!("quota-denied-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = root.join("home");
        backend.environment.clear();
        let backend = Arc::new(backend);
        let service = crate::service::LocalService::new(
            state.clone(),
            crate::ipc::JsonLineWriter::stdout(),
            backend.clone(),
        );

        let denied = service.handle(
            serde_json::from_value(serde_json::json!({
                "type": "request",
                "request_id": "denied",
                "operation": "replace_provider_browser_sessions",
                "payload": {
                    "provider": "cursor",
                    "cookie_headers": [],
                    "access_denials": [{"browser": "Safari", "reason": "full_disk_access"}]
                }
            }))
            .expect("denial request"),
        );
        assert!(denied.error.is_none());
        // No session was stored: a refusal is the absence of one, not a worse one.
        assert!(
            state
                .provider_browser_session("cursor")
                .expect("read")
                .is_none()
        );

        let report = backend.complete_diagnostic_report().expect("diagnostics");
        let source = report
            .sources
            .iter()
            .find(|source| source.code.as_deref() == Some("browser_access_denied"))
            .expect("refusal row");
        assert_eq!(source.subject, "provider:cursor");
        assert_eq!(source.source_id.as_deref(), Some("browser_session"));
        assert_eq!(source.status, DiagnosticStatus::Blocked);
        assert_eq!(source.recovery, DiagnosticRecovery::CheckAccess);
        assert!(source.message.contains("Safari"));
        assert!(source.message.contains("Full Disk Access"));
        // The store's path never reaches a report a person copies out of the app.
        assert!(!source.message.contains(&root.display().to_string()));

        service.shutdown();
        drop(service);
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn diagnostics_treat_empty_and_inactive_as_healthy() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = root.join("home");
        backend.environment.clear();
        let report = backend.diagnostic_report().expect("diagnostics");
        assert_eq!(report.schema_version, DIAGNOSTIC_SCHEMA_VERSION);
        assert_eq!(report.summary.operation, DiagnosticOperation::Healthy);
        assert_eq!(report.summary.attention, DiagnosticAttention::None);
        assert_eq!(
            report
                .surfaces
                .iter()
                .map(|surface| surface.id.as_str())
                .collect::<Vec<_>>(),
            [
                "quota_overview",
                "usage_this_device",
                "usage_account",
                "account"
            ]
        );
        assert!(
            report
                .surfaces
                .iter()
                .all(|surface| surface.data == DiagnosticDataState::Empty)
        );
        let serialized = serde_json::to_string(&report).expect("serialize");
        assert!(!serialized.contains("source_file_id"));
        assert!(!serialized.contains("/tmp"));
        state
            .set_usage_upload_enabled(false)
            .expect("disable Usage upload");
        assert!(!backend.stage_outbox().expect("staging disabled"));
        backend.drain_outbox().expect("upload disabled");
        let disabled = backend
            .complete_diagnostic_report()
            .expect("disabled diagnostics");
        // A signed-out device with Usage sync off has no upload path to report on at all.
        assert!(
            !disabled
                .sources
                .iter()
                .any(|source| source.subject == "usage_upload")
        );
        let account_usage = disabled
            .surfaces
            .iter()
            .find(|surface| surface.id == "usage_account")
            .expect("account usage surface");
        assert_eq!(account_usage.status, DiagnosticStatus::Inactive);
        assert_eq!(disabled.summary.operation, DiagnosticOperation::Healthy);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn diagnostics_name_a_failed_sign_in_from_account_last_error() {
        let root =
            std::env::temp_dir().join(format!("quota-failed-signin-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_component(
                crate::protocol::ComponentName::Account,
                crate::protocol::ComponentStatus::SignedOut,
                Some(serde_json::json!({
                    "auth_status": "signed_out",
                    "account_id": null,
                    "display_label": null,
                    "device_id": null,
                    "device_generation": null,
                    "account_summary": null
                })),
                None,
                Some(IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry)),
                false,
            )
            .expect("failed login");
        let mut backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        backend.home = root.join("home");
        backend.environment.clear();
        let report = backend.diagnostic_report().expect("diagnostics");
        let surface = report
            .surfaces
            .iter()
            .find(|surface| surface.id == "account")
            .expect("account surface");
        assert_eq!(surface.status, DiagnosticStatus::Degraded);
        assert_eq!(surface.recovery, DiagnosticRecovery::Login);
        assert!(
            surface.message.contains("unavailable"),
            "{}",
            surface.message
        );
        assert!(
            surface.message.contains("browser could not be opened"),
            "{}",
            surface.message
        );
        let source = report
            .sources
            .iter()
            .find(|source| source.subject == "account")
            .expect("account source");
        assert_eq!(source.code.as_deref(), Some("unavailable"));
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_rebuilding_cache_reports_local_usage_as_partial() {
        let root = std::env::temp_dir().join(format!("quota-rebuilding-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .mark_cache_rebuilding_for_test(true)
            .expect("rebuilding");
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let report = backend.diagnostic_report().expect("live");
        let usage = report
            .surfaces
            .iter()
            .find(|surface| surface.id == "usage_this_device")
            .expect("usage surface");
        assert_eq!(usage.data, DiagnosticDataState::Partial);
        assert_eq!(usage.recovery, DiagnosticRecovery::Automatic);
        assert_eq!(report.summary.operation, DiagnosticOperation::Healthy);
        assert_eq!(report.summary.attention, DiagnosticAttention::Automatic);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn fresh_store_diagnose_is_empty_not_partial() {
        let root = std::env::temp_dir().join(format!("quota-fresh-diag-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let report = backend.diagnostic_report().expect("diagnostics");
        let usage = report
            .surfaces
            .iter()
            .find(|surface| surface.id == "usage_this_device")
            .expect("usage surface");
        assert_eq!(usage.data, DiagnosticDataState::Empty);
        assert_ne!(usage.data, DiagnosticDataState::Partial);
        assert_eq!(report.summary.attention, DiagnosticAttention::None);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// An identity this device could not read is the one loss no refresh undoes, so it is said
    /// out loud with the action that fixes it rather than filed as an informational note.
    #[test]
    fn a_reset_identity_asks_the_person_to_sign_in_again() {
        let root = std::env::temp_dir().join(format!("quota-identity-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        std::fs::write(root.join("identity.sqlite"), b"not a database").expect("garbage identity");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let report = backend.diagnostic_report().expect("diagnostics");
        let reset = report
            .sources
            .iter()
            .find(|source| source.code.as_deref() == Some("local_identity_reset"))
            .expect("identity reset source");
        assert_eq!(reset.recovery, DiagnosticRecovery::Login);
        assert!(reset.message.contains("Sign in again"));
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_failed_collection_republishes_this_devices_reading_as_failed() {
        let now = Utc::now();
        let observed_at = (now - Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let collected = |status: &str, observed_at: &str| {
            serde_json::json!({
                "results": [{
                    "provider": "codex",
                    "outcome": "success",
                    "snapshots": [{
                        "provider": "codex",
                        "account": {"fingerprint": "account", "fingerprint_scope": "global"},
                        "windows": [{"id": "monthly", "title": "Monthly", "used_percent": 0.0}],
                        "status": status,
                        "observed_at": observed_at
                    }]
                }]
            })
        };
        let report = serde_json::json!({
            "results": [
                {"provider": "codex", "outcome": "auth_required", "snapshots": [], "sources": 1},
                {"provider": "claude", "outcome": "success", "snapshots": []}
            ]
        });

        let previous = collected("available", &observed_at);
        let republished = failure_status_snapshots(&report, Some(&previous), now);
        assert_eq!(republished.len(), 1);
        assert_eq!(
            republished[0].get("status").and_then(Value::as_str),
            Some("auth_required")
        );
        // The numbers and their age are untouched; only what the source can do changed.
        assert_eq!(
            republished[0].get("observed_at").and_then(Value::as_str),
            Some(observed_at.as_str())
        );

        // Once published, saying it again would rewrite the row for nothing.
        let published = collected("auth_required", &observed_at);
        assert!(failure_status_snapshots(&report, Some(&published), now).is_empty());

        // A reading that already aged out is not current wherever it is read, so restating
        // it says nothing and would rewrite the row on every refresh forever.
        let aged_out = collected(
            "available",
            &(now - Duration::days(2)).to_rfc3339_opts(SecondsFormat::Secs, true),
        );
        assert!(failure_status_snapshots(&report, Some(&aged_out), now).is_empty());

        // A provider this device never collected has nothing to republish.
        let empty = serde_json::json!({"results": []});
        assert!(failure_status_snapshots(&report, Some(&empty), now).is_empty());
        assert!(failure_status_snapshots(&report, None, now).is_empty());
    }

    #[test]
    fn a_failed_round_keeps_the_previous_local_overview_item() {
        let now = DateTime::parse_from_rfc3339("2026-08-28T08:00:00Z")
            .expect("now")
            .with_timezone(&Utc);
        let snapshot = |used: f64, observed_at: &str| {
            json!({
                "provider": "grok",
                "account": {"fingerprint": "account", "fingerprint_scope": "global"},
                "windows": [{"id": "monthly", "title": "Monthly", "used_percent": used}],
                "status": "available",
                "observed_at": observed_at
            })
        };
        let previous = vec![
            overview_item(
                &snapshot(12.0, "2026-08-28T07:45:00Z"),
                "local",
                LOCAL_SOURCE_DISPLAY_NAME,
                None,
                now,
            )
            .expect("previous local item"),
        ];
        let timed_out = json!({
            "results": [{
                "provider": "grok",
                "outcome": "unavailable",
                "snapshots": [],
                "sources": [{
                    "source_id": "grok_billing_api",
                    "outcome": "unavailable",
                    "category": "unavailable"
                }]
            }]
        });
        let items = overview_items(&timed_out, None, &previous, now);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].identity.provider, "grok");
        assert_eq!(
            items[0].snapshot["windows"][0]["used_percent"].as_f64(),
            Some(12.0)
        );
        assert_eq!(items[0].selected_source_id, "local");
        assert!(!items[0].is_stale);

        let replaced = json!({
            "results": [{
                "provider": "grok",
                "outcome": "success",
                "snapshots": [snapshot(20.0, "2026-08-28T07:55:00Z")]
            }]
        });
        let items = overview_items(&replaced, None, &previous, now);
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0].snapshot["windows"][0]["used_percent"].as_f64(),
            Some(20.0)
        );

        let empty_success = json!({
            "results": [{
                "provider": "grok",
                "outcome": "success",
                "snapshots": []
            }]
        });
        assert!(overview_items(&empty_success, None, &previous, now).is_empty());

        // A provider this refresh no longer discovered is not resurrected.
        let unsigned = json!({
            "results": [{
                "provider": "grok",
                "outcome": "auth_required",
                "snapshots": [],
                "sources": []
            }]
        });
        assert!(overview_items(&unsigned, None, &previous, now).is_empty());
    }

    #[test]
    fn a_rejected_official_reading_asks_the_owning_cli_again() {
        let auth_required = |provider: &str, source: &str| {
            (
                ProviderId::parse(provider).expect("provider"),
                false,
                None,
                json!({
                    "provider": provider,
                    "outcome": "auth_required",
                    "snapshots": [],
                    "sources": [{
                        "source_id": source,
                        "outcome": "auth_required",
                        "category": "auth_required"
                    }]
                }),
                false,
            )
        };
        let retry = providers_needing_forced_renewal(&[
            auth_required("codex", "chatgpt_usage_api"),
            auth_required("claude", "anthropic_oauth_usage_api"),
            auth_required("cursor", "cursor_dashboard_api"),
            (
                ProviderId::Grok,
                false,
                None,
                json!({
                    "provider": "grok",
                    "outcome": "success",
                    "snapshots": [{}],
                    "sources": [{"source_id": "grok_billing_api", "outcome": "success"}]
                }),
                false,
            ),
            (
                ProviderId::Kimi,
                false,
                None,
                json!({
                    "provider": "kimi",
                    "outcome": "auth_required",
                    "snapshots": [],
                    "sources": []
                }),
                false,
            ),
        ]);
        assert!(retry.contains(&ProviderId::Codex));
        assert!(retry.contains(&ProviderId::Claude));
        assert!(!retry.contains(&ProviderId::Cursor));
        assert!(!retry.contains(&ProviderId::Grok));
        assert!(!retry.contains(&ProviderId::Kimi));
    }

    #[test]
    fn a_forced_pass_skips_providers_already_asked() {
        let retry = HashSet::from([ProviderId::Claude, ProviderId::Codex, ProviderId::Grok]);
        // Recheck already spawned for an expired grant in the first pass.
        assert_eq!(
            forced_renewal_targets(&retry, &HashSet::from([ProviderId::Codex])),
            HashSet::from([ProviderId::Claude, ProviderId::Grok])
        );
        assert!(forced_renewal_targets(&retry, &retry).is_empty());
        // A scheduled refresh that started nothing (in-date grants): rejected readings are asked.
        assert_eq!(forced_renewal_targets(&retry, &HashSet::new()), retry);
    }

    /// A source that cannot be reached ends the refresh with its own name.  This used to
    /// fall through to a provider CLI, so being offline for a moment started programs.
    #[test]
    fn an_unreachable_source_reports_unavailable_and_names_itself() {
        // A port nothing is listening on: bound to learn a free one, then released.
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .expect("port")
            .local_addr()
            .expect("address")
            .port();
        let context = CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-unreachable-source-home"),
            environment: HashMap::from([
                ("LITELLM_API_KEY".to_owned(), "sk-litellm-test".to_owned()),
                (
                    "LITELLM_BASE_URL".to_owned(),
                    format!("http://127.0.0.1:{port}"),
                ),
            ]),
            config_path: Some(PathBuf::from(
                "/tmp/quota-unreachable-source-home/none.json",
            )),
            browser_sessions: HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-15T08:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        };
        let sessions = providers::discover(ProviderId::LiteLlm, &context);
        assert_eq!(sessions.len(), 1);
        let result = collect_discovered_provider(ProviderId::LiteLlm, sessions, &context);
        assert_eq!(
            result.get("outcome").and_then(Value::as_str),
            Some("unavailable")
        );
        assert_eq!(
            result.get("sources"),
            Some(&json!([{
                "source_id": crate::providers::litellm::SOURCE,
                "outcome": "unavailable",
                "category": "unavailable"
            }]))
        );
        // Nothing to sign in to and nothing refused: a network failure says neither.
        assert!(result.get("message").is_none());
        assert!(result.get("access_denied").is_none());
    }

    #[test]
    fn rejected_local_sign_in_is_reported_separately_from_missing_setup() {
        let context = CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-rejected-sign-in-missing-home"),
            environment: HashMap::new(),
            config_path: None,
            browser_sessions: HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-15T08:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        };
        let rejected = collect_discovered_provider(
            ProviderId::Claude,
            vec![ProviderSession {
                provider: ProviderId::Claude,
                credential_source: "fixture".to_owned(),
                cookie_header: None,
            }],
            &context,
        );
        assert_eq!(
            rejected.get("outcome").and_then(Value::as_str),
            Some("auth_required")
        );
        // Recovery names the program that can renew the grant.  Told only to "sign in
        // again", a reader has nowhere to do it.
        assert_eq!(
            rejected.get("message").and_then(Value::as_str),
            Some(
                "The saved sign-in expired or was rejected. Open Claude Code to refresh the sign-in."
            )
        );
        // The rung that reached the verdict travels with it.
        assert_eq!(
            rejected.get("sources"),
            Some(&json!([{
                "source_id": crate::providers::claude::SOURCE,
                "outcome": "auth_required",
                "category": "auth_required"
            }]))
        );
        let never_configured =
            collect_discovered_provider(ProviderId::Claude, Vec::new(), &context);
        assert_eq!(
            never_configured.get("outcome").and_then(Value::as_str),
            Some("auth_required")
        );
        assert_eq!(never_configured.get("message"), None);

        // A Claude Code that emptied its own credential is a third state again. It is
        // discovered, because the device holds the entry, and its recovery is the one that
        // does not say "open Claude Code": the app would open onto the same emptied entry.
        let home = std::env::temp_dir().join(format!("quota-signed-out-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(home.join(".claude")).expect("home");
        fs::write(
            home.join(".claude/.credentials.json"),
            "{\"claudeAiOauth\": {\"accessToken\": \"\", \"refreshToken\": \"\", \"expiresAt\": 0}}",
        )
        .expect("credential");
        let context = CollectionContext {
            home_directory: home.clone(),
            ..context
        };
        let sessions = providers::discover(ProviderId::Claude, &context);
        assert_eq!(sessions.len(), 1);
        let signed_out = collect_discovered_provider(ProviderId::Claude, sessions, &context);
        assert_eq!(
            signed_out.get("message").and_then(Value::as_str),
            Some("Claude Code is signed out. Run `claude` and sign in again.")
        );
        assert_eq!(
            signed_out.get("sources"),
            Some(&json!([{
                "source_id": crate::providers::claude::SIGNED_OUT_SOURCE,
                "outcome": "auth_required",
                "category": "auth_required"
            }]))
        );
        fs::remove_dir_all(&home).expect("cleanup");

        // A withheld Keychain item is not a terminal sign-in: Claude Code can still read it.
        #[cfg(target_os = "macos")]
        {
            let refused_home =
                std::env::temp_dir().join(format!("quota-claude-refused-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(refused_home.join(".claude")).expect("home");
            fs::write(
                refused_home.join(".claude/.credentials.json"),
                "{\"claudeAiOauth\": {\"accessToken\": \"\", \"refreshToken\": \"\", \"expiresAt\": 0}}",
            )
            .expect("credential");
            let refused = CollectionContext {
                home_directory: refused_home.clone(),
                environment: HashMap::from([(
                    "HOME".to_owned(),
                    refused_home.to_string_lossy().into_owned(),
                )]),
                now: Some("2026-08-15T08:00:00Z".to_owned()),
                ..CollectionContext::default()
            };
            refused
                .keychain
                .set(crate::providers::common::KeychainSecret::Refused)
                .expect("unread");
            let sessions = providers::discover(ProviderId::Claude, &refused);
            assert_eq!(sessions.len(), 1);
            let denied = collect_discovered_provider(ProviderId::Claude, sessions, &refused);
            assert_eq!(
                denied.get("access_denied").and_then(Value::as_bool),
                Some(true)
            );
            assert_eq!(
                denied.get("message").and_then(Value::as_str),
                Some(
                    "QuotaBar could not read Claude Code's Keychain item. Open Claude Code to refresh the sign-in."
                )
            );
            fs::remove_dir_all(&refused_home).expect("cleanup");
        }
    }

    /// Extra stored accounts are a last-rung retry after `auth_required`, never after a
    /// network or access failure, and the ladder already spent cookie[0].
    #[test]
    fn extra_browser_accounts_run_only_after_auth_required_and_skip_the_first_cookie() {
        let source_ids = |result: &Value| -> Vec<String> {
            result
                .get("sources")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|source| source.get("source_id")?.as_str().map(str::to_owned))
                .collect()
        };
        let cookies = vec!["cookie-one".to_owned(), "cookie-two".to_owned()];

        // A closed port is Unavailable, not a sign-in problem: the stored cookies stay unread.
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .expect("port")
            .local_addr()
            .expect("address")
            .port();
        let unavailable_context = CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-extra-browser-unavailable-home"),
            environment: HashMap::from([
                ("LITELLM_API_KEY".to_owned(), "sk-litellm-test".to_owned()),
                (
                    "LITELLM_BASE_URL".to_owned(),
                    format!("http://127.0.0.1:{port}"),
                ),
            ]),
            config_path: Some(PathBuf::from(
                "/tmp/quota-extra-browser-unavailable-home/none.json",
            )),
            browser_sessions: HashMap::from([(ProviderId::LiteLlm, cookies.clone())]),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-15T08:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        };
        let sessions = providers::discover(ProviderId::LiteLlm, &unavailable_context);
        assert_eq!(sessions.len(), 1);
        let unavailable =
            collect_discovered_provider(ProviderId::LiteLlm, sessions, &unavailable_context);
        assert_eq!(
            unavailable.get("outcome").and_then(Value::as_str),
            Some("unavailable")
        );
        assert_eq!(
            source_ids(&unavailable),
            vec![crate::providers::litellm::SOURCE]
        );

        // OpenRouter's official collect answers AuthRequired with no key and no request, so
        // extra cookies are attempted. cookie[0] is the ladder's, cookie[1] is this block's.
        let auth_context = CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-extra-browser-auth-home"),
            environment: HashMap::new(),
            config_path: Some(PathBuf::from(
                "/tmp/quota-extra-browser-auth-home/none.json",
            )),
            browser_sessions: HashMap::from([(ProviderId::OpenRouter, cookies)]),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-15T08:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        };
        let official = vec![ProviderSession {
            provider: ProviderId::OpenRouter,
            credential_source: "fixture".to_owned(),
            cookie_header: None,
        }];
        let auth_required =
            collect_discovered_provider(ProviderId::OpenRouter, official, &auth_context);
        assert_eq!(
            auth_required.get("outcome").and_then(Value::as_str),
            Some("auth_required")
        );
        assert_eq!(
            source_ids(&auth_required),
            vec![
                crate::providers::openrouter::SOURCE,
                crate::providers::openrouter::SOURCE
            ]
        );
    }

    /// Every reader resolves one subscription the same way, so the rule is stated once as
    /// a fixture and each implementation answers it. Remote source ids carry a `device:`
    /// prefix that keeps them apart from local collection, which the fixture does not
    /// model because only this device collects locally.
    #[test]
    fn subscription_merge_matches_the_shared_conformance_fixture() {
        const FIXTURE: &str =
            include_str!("../../../protocol/fixtures/quota-observation-conformance.json");
        let fixture: Value = serde_json::from_str(FIXTURE).expect("fixture");
        let source_id = |device_id: &str| format!("device:{device_id}");
        let cases = fixture["merge"].as_array().expect("merge cases");
        assert!(!cases.is_empty());
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let now = DateTime::parse_from_rfc3339(case["now"].as_str().expect("now"))
                .expect("instant")
                .with_timezone(&Utc);
            let mut items = Vec::new();
            for observation in case["observations"].as_array().expect("observations") {
                let device_id = observation["device_id"].as_str().expect("device id");
                let item = overview_item(
                    &observation["snapshot"],
                    &source_id(device_id),
                    device_id,
                    Some(device_id),
                    now,
                )
                .expect("overview item");
                merge_overview_item(&mut items, item);
            }
            sort_overview_items(&mut items);
            let expected = case["expected"].as_array().expect("expected");
            assert_eq!(items.len(), expected.len(), "{name}");
            for (item, expected) in items.iter().zip(expected) {
                let identity = &expected["identity"];
                assert_eq!(item.identity.provider, identity["provider"], "{name}");
                assert_eq!(item.identity.fingerprint, identity["fingerprint"], "{name}");
                assert_eq!(item.identity.scope, identity["scope"], "{name}");
                assert_eq!(
                    item.identity.source_id.as_deref(),
                    identity["source_id"].as_str().map(source_id).as_deref(),
                    "{name}"
                );
                assert_eq!(
                    item.selected_source_id,
                    source_id(expected["selected_device_id"].as_str().expect("selected")),
                    "{name}"
                );
                assert_eq!(item.is_stale, expected["is_stale"], "{name}");
                let sources = expected["sources"].as_array().expect("sources");
                assert_eq!(item.sources.len(), sources.len(), "{name}");
                for (source, expected) in item.sources.iter().zip(sources) {
                    assert_eq!(
                        source.device_id.as_deref(),
                        expected["device_id"].as_str(),
                        "{name}"
                    );
                    assert_eq!(source.observed_at, expected["observed_at"], "{name}");
                    assert_eq!(source.is_stale, expected["is_stale"], "{name}");
                    assert_eq!(
                        source
                            .snapshot
                            .as_ref()
                            .and_then(|snapshot| snapshot.get("observed_at")),
                        expected.get("observed_at"),
                        "{name}"
                    );
                }
            }
        }
    }

    /// The Overview is two readings of one subscription: this device's, and the one Relay
    /// resolved from every other device. The rule is stated once as a fixture and answered here.
    #[test]
    fn two_way_subscription_merge_matches_the_shared_conformance_fixture() {
        const FIXTURE: &str =
            include_str!("../../../protocol/fixtures/quota-observation-conformance.json");
        let fixture: Value = serde_json::from_str(FIXTURE).expect("fixture");
        let cases = fixture["two_way_merge"].as_array().expect("merge cases");
        assert!(!cases.is_empty());
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let quota = json!({
                "results": [{
                    "provider": "codex",
                    "outcome": "success",
                    "snapshots": case["local"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default()
                }]
            });
            let account = json!({
                "account_summary": {
                    "devices": [{
                        "id": "device_remote",
                        "display_name": "Studio",
                        "platform": "macos",
                        "last_seen_at": null,
                        "last_observed_at": null
                    }],
                    "subscriptions": case["remote"].clone()
                }
            });
            let now = DateTime::parse_from_rfc3339(case["now"].as_str().expect("now"))
                .expect("instant")
                .with_timezone(&Utc);
            let items = overview_items(&quota, Some(&account), &[], now);
            let expected = case["expected"].as_array().expect("expected");
            assert_eq!(items.len(), expected.len(), "{name}");
            for (item, expected) in items.iter().zip(expected) {
                assert_eq!(
                    item.selected_source_id,
                    expected["selected_source_id"].as_str().expect("selected"),
                    "{name}"
                );
                assert_eq!(
                    item.sources.len(),
                    expected["sources"].as_u64().expect("sources") as usize,
                    "{name}"
                );
                assert_eq!(item.is_stale, expected["is_stale"], "{name}");
            }
        }
    }

    #[test]
    fn a_source_pin_selects_that_reading_even_when_automatic_would_not() {
        let now = DateTime::parse_from_rfc3339("2026-08-24T10:00:00Z")
            .expect("now")
            .with_timezone(&Utc);
        let local = json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 10.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:00:00Z"
        });
        let remote = json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 20.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:30:00Z"
        });
        let quota =
            json!({"results": [{"provider": "codex", "outcome": "success", "snapshots": [local]}]});
        let account = json!({
            "account_summary": {
                "devices": [{"id": "device_remote", "display_name": "Studio", "platform": "macos", "last_seen_at": null, "last_observed_at": null}],
                "subscriptions": [{
                    "key": "codex|fp|global|",
                    "provider": "codex",
                    "snapshot": remote.clone(),
                    "sources": [{
                        "device_id": "device_remote",
                        "observed_at": "2026-08-24T09:30:00Z",
                        "snapshot": remote
                    }]
                }]
            }
        });
        let automatic = overview_items(&quota, Some(&account), &[], now);
        assert_eq!(automatic[0].selected_source_id, "device:device_remote");
        assert_eq!(automatic[0].sources.len(), 2);
        assert!(
            automatic[0]
                .sources
                .iter()
                .all(|source| source.snapshot.is_some())
        );

        let mut pins = HashMap::new();
        pins.insert("codex|fp|global|".into(), "local".into());
        let pinned = overview_items_with_pins(&quota, Some(&account), &[], &pins, now);
        assert_eq!(pinned[0].selected_source_id, "local");
        assert_eq!(pinned[0].source_pin.as_deref(), Some("local"));
        assert_eq!(pinned[0].automatic_source_id, "device:device_remote");
        assert_eq!(pinned[0].automatic_source_display_name, "Studio");
        assert_eq!(pinned[0].snapshot["windows"][0]["used_percent"], 10.0);

        pins.insert("codex|fp|global|".into(), "missing".into());
        let missing = overview_items_with_pins(&quota, Some(&account), &[], &pins, now);
        assert_eq!(missing[0].selected_source_id, "device:device_remote");
        assert_eq!(missing[0].automatic_source_id, "device:device_remote");
        assert!(missing[0].source_pin.is_none());
    }

    /// An older Relay names every device that read a subscription but sends only the winning
    /// reading. Once this Mac's own reading wins, the other device must not vanish from the
    /// list: it is still a source, with its own freshness and no invented quota.
    #[test]
    fn an_older_device_source_without_a_snapshot_is_still_listed() {
        let now = DateTime::parse_from_rfc3339("2026-08-30T08:00:00Z")
            .expect("now")
            .with_timezone(&Utc);
        let local = json!({
            "provider": "cursor",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "monthly", "title": "Monthly", "used_percent": 10.0, "duration_seconds": 2592000}],
            "status": "available",
            "observed_at": "2026-08-30T07:47:38Z"
        });
        let quota = json!({"results": [{"provider": "cursor", "outcome": "success", "snapshots": [local.clone()]}]});
        let account = json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [
                    {"id": "this-device", "display_name": "Kyle's Mac mini"},
                    {"id": "device_laptop", "display_name": "Hao's Macbook Pro"}
                ],
                "subscriptions": [{
                    "key": "cursor|fp|global|",
                    "provider": "cursor",
                    "snapshot": local,
                    "sources": [
                        {"device_id": "this-device", "observed_at": "2026-08-30T07:47:38Z"},
                        {"device_id": "device_laptop", "observed_at": "2026-08-28T21:29:24Z"}
                    ]
                }]
            }
        });
        let items = overview_items(&quota, Some(&account), &[], now);
        assert_eq!(items.len(), 1);
        let sources: Vec<_> = items[0]
            .sources
            .iter()
            .map(|source| {
                (
                    source.source_id.as_str(),
                    source.display_name.as_str(),
                    source.snapshot.is_some(),
                )
            })
            .collect();
        assert_eq!(
            sources,
            vec![
                ("device:device_laptop", "Hao's Macbook Pro", false),
                ("local", "This Mac", true)
            ]
        );
        assert_eq!(items[0].selected_source_id, "local");
        let laptop = &items[0].sources[0];
        assert_eq!(laptop.observed_at, "2026-08-28T21:29:24Z");
        assert!(laptop.is_stale);
    }

    #[test]
    fn this_macs_uploaded_source_is_not_listed_beside_local() {
        let now = DateTime::parse_from_rfc3339("2026-08-24T10:00:00Z")
            .expect("now")
            .with_timezone(&Utc);
        let local = json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 10.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:00:00Z"
        });
        let remote = json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 20.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:30:00Z"
        });
        let quota = json!({"results": [{"provider": "codex", "outcome": "success", "snapshots": [local.clone()]}]});
        let account = json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [
                    {"id": "this-device", "display_name": "Kitchen Mac", "platform": "macos", "last_seen_at": null, "last_observed_at": null},
                    {"id": "device_remote", "display_name": "Studio", "platform": "macos", "last_seen_at": null, "last_observed_at": null}
                ],
                "subscriptions": [{
                    "key": "codex|fp|global|",
                    "provider": "codex",
                    "snapshot": remote.clone(),
                    "sources": [
                        {"device_id": "this-device", "observed_at": "2026-08-24T09:00:00Z", "snapshot": local},
                        {"device_id": "device_remote", "observed_at": "2026-08-24T09:30:00Z", "snapshot": remote}
                    ]
                }]
            }
        });
        let items = overview_items(&quota, Some(&account), &[], now);
        assert_eq!(items.len(), 1);
        let source_ids: Vec<_> = items[0]
            .sources
            .iter()
            .map(|source| source.source_id.as_str())
            .collect();
        assert_eq!(source_ids, vec!["device:device_remote", "local"]);
        assert_eq!(items[0].selected_source_id, "device:device_remote");
        assert_eq!(
            items[0]
                .sources
                .iter()
                .find(|source| source.source_id == "local")
                .map(|source| source.display_name.as_str()),
            Some(LOCAL_SOURCE_DISPLAY_NAME)
        );
    }

    #[test]
    fn this_macs_uploaded_source_scoped_row_is_not_a_second_subscription() {
        let now = DateTime::parse_from_rfc3339("2026-08-24T10:00:00Z")
            .expect("now")
            .with_timezone(&Utc);
        let local = json!({
            "provider": "grok",
            "account": {"fingerprint": "fp-source", "fingerprint_scope": "source"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 10.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:00:00Z"
        });
        let remote = json!({
            "provider": "grok",
            "account": {"fingerprint": "fp-source", "fingerprint_scope": "source"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 90.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:30:00Z"
        });
        let quota = json!({"results": [{"provider": "grok", "outcome": "success", "snapshots": [local.clone()]}]});
        let account = json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [
                    {"id": "this-device", "display_name": "Kitchen Mac"},
                    {"id": "device_remote", "display_name": "Studio"}
                ],
                "subscriptions": [
                    {
                        "key": "grok|fp-source|source|device:this-device",
                        "provider": "grok",
                        "snapshot": local.clone(),
                        "sources": [{
                            "device_id": "this-device",
                            "observed_at": "2026-08-24T09:00:00Z",
                            "snapshot": local
                        }]
                    },
                    {
                        "key": "grok|fp-source|source|device:device_remote",
                        "provider": "grok",
                        "snapshot": remote.clone(),
                        "sources": [{
                            "device_id": "device_remote",
                            "observed_at": "2026-08-24T09:30:00Z",
                            "snapshot": remote
                        }]
                    }
                ]
            }
        });
        let items = overview_items(&quota, Some(&account), &[], now);
        let identities: Vec<_> = items
            .iter()
            .map(|item| {
                (
                    item.identity.source_id.as_deref(),
                    item.selected_source_id.as_str(),
                )
            })
            .collect();
        assert_eq!(
            identities,
            vec![
                (Some("device:device_remote"), "device:device_remote"),
                (Some("local"), "local"),
            ]
        );
    }

    #[test]
    fn a_source_pin_survives_cache_reset() {
        let root =
            std::env::temp_dir().join(format!("quota-overview-pin-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = StateStore::open(&root).expect("state");
        state
            .set_overview_source_pin("codex|fp|global|", Some("local"))
            .expect("pin");
        state.reset_cache();
        let pins = state.overview_source_pins().expect("pins");
        assert_eq!(
            pins.get("codex|fp|global|").map(String::as_str),
            Some("local")
        );

        let now = DateTime::parse_from_rfc3339("2026-08-24T10:00:00Z")
            .expect("now")
            .with_timezone(&Utc);
        let local = json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 10.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:00:00Z"
        });
        let remote = json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 20.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": "2026-08-24T09:30:00Z"
        });
        let quota =
            json!({"results": [{"provider": "codex", "outcome": "success", "snapshots": [local]}]});
        let account = json!({
            "account_summary": {
                "devices": [{"id": "device_remote", "display_name": "Studio", "platform": "macos", "last_seen_at": null, "last_observed_at": null}],
                "subscriptions": [{
                    "key": "codex|fp|global|",
                    "provider": "codex",
                    "snapshot": remote.clone(),
                    "sources": [{
                        "device_id": "device_remote",
                        "observed_at": "2026-08-24T09:30:00Z",
                        "snapshot": remote
                    }]
                }]
            }
        });
        let items = overview_items_with_pins(&quota, Some(&account), &[], &pins, now);
        assert_eq!(items[0].selected_source_id, "local");
        assert_eq!(items[0].source_pin.as_deref(), Some("local"));
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_missing_source_pin_is_dropped_from_the_store_on_refresh() {
        let root = std::env::temp_dir().join(format!(
            "quota-overview-pin-refresh-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_overview_source_pin("codex|fp|global|", Some("device:device_remote"))
            .expect("pin");
        let backend = NativeBackend::new(
            state.clone(),
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let observed_at = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
        let local = json!({
            "provider": "codex",
            "account": {"fingerprint": "fp", "fingerprint_scope": "global"},
            "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 10.0, "duration_seconds": 604800}],
            "status": "available",
            "observed_at": observed_at
        });
        let quota =
            json!({"results": [{"provider": "codex", "outcome": "success", "snapshots": [local]}]});
        let account = json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [],
                "subscriptions": []
            }
        });
        let _items = backend.build_overview(&quota, Some(&account));
        let pins = state.overview_source_pins().expect("pins");
        assert!(pins.get("codex|fp|global|").is_none());
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn expired_observations_are_stale_and_lose_to_a_still_valid_device() {
        let root = std::env::temp_dir().join(format!("quota-overview-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        // The reading itself says how long it speaks for: a window that reports no reset
        // and no cadence ages out at the maximum, so how old it is decides.
        let snapshot = |observed_at: DateTime<Utc>| {
            json!({
                "provider": "codex",
                "account": {"fingerprint": "account", "fingerprint_scope": "global"},
                "windows": [{"id": "five_hour", "title": "5 hour", "used_percent": 40.0}],
                "status": "available",
                "observed_at": observed_at.to_rfc3339_opts(SecondsFormat::Secs, true)
            })
        };
        let subscription = |device_id: &str, snapshot: Value| {
            json!({
                "key": "codex|account|global|",
                "provider": "codex",
                "snapshot": snapshot.clone(),
                "sources": [{
                    "device_id": device_id,
                    "observed_at": snapshot["observed_at"].clone()
                }]
            })
        };
        let now = Utc::now();
        let quota = json!({"results": []});
        let mut account = json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [{"id": "asleep", "display_name": "Asleep"}],
                "subscriptions": [subscription("asleep", snapshot(now - Duration::days(2)))]
            }
        });
        let expired = backend.build_overview(&quota, Some(&account));
        assert_eq!(expired.len(), 1);
        assert!(expired[0].is_stale);

        // Relay resolves the account's devices into one row, so a fresher reading arrives as
        // that row rather than as a second card to collapse here.
        account["account_summary"]["devices"]
            .as_array_mut()
            .expect("devices")
            .push(json!({"id": "awake", "display_name": "Studio"}));
        account["account_summary"]["subscriptions"] =
            json!([subscription("awake", snapshot(now - Duration::minutes(1)))]);
        let items = backend.build_overview(&quota, Some(&account));
        assert_eq!(items.len(), 1);
        assert!(!items[0].is_stale);
        assert_eq!(items[0].selected_source_display_name, "Studio");
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// Local collection is the only authority for the machine in front of you, so a local
    /// reading of the same instant wins and a newer remote one still takes over.
    #[test]
    fn the_local_reading_wins_a_tie_and_loses_to_a_newer_remote_one() {
        let root = std::env::temp_dir().join(format!("quota-overview-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let snapshot = |observed_at: &str, used: f64| {
            json!({
                "provider": "codex",
                "account": {"fingerprint": "account", "fingerprint_scope": "global"},
                "windows": [{"id": "five_hour", "title": "5 hour", "used_percent": used}],
                "status": "available",
                "observed_at": observed_at
            })
        };
        let now = Utc::now();
        let local_at = (now - Duration::minutes(5)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let quota = json!({
            "results": [{
                "provider": "codex",
                "outcome": "success",
                "snapshots": [snapshot(&local_at, 10.0)]
            }]
        });
        let remote = |observed_at: &str, used: f64| {
            json!({
                "auth_status": "signed_in",
                "account_summary": {
                    "devices": [{"id": "other", "display_name": "Studio"}],
                    "subscriptions": [{
                        "key": "codex|account|global|",
                        "provider": "codex",
                        "snapshot": snapshot(observed_at, used),
                        "sources": [{"device_id": "other", "observed_at": observed_at}]
                    }]
                }
            })
        };

        let tied = remote(&local_at, 90.0);
        let items = backend.build_overview(&quota, Some(&tied));
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].sources.len(), 2);
        assert_eq!(items[0].selected_source_id, "local");

        let newer = (now - Duration::minutes(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let items = backend.build_overview(&quota, Some(&remote(&newer, 90.0)));
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].selected_source_id, "device:other");
        assert_eq!(items[0].selected_source_display_name, "Studio");
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A subscription only this device has, and one only the account has, both stand.
    #[test]
    fn a_subscription_only_one_side_knows_still_reaches_the_overview() {
        let root = std::env::temp_dir().join(format!("quota-overview-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let observed_at = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
        let snapshot = |fingerprint: &str| {
            json!({
                "provider": "codex",
                "account": {"fingerprint": fingerprint, "fingerprint_scope": "global"},
                "windows": [{"id": "five_hour", "title": "5 hour", "used_percent": 40.0}],
                "status": "available",
                "observed_at": observed_at
            })
        };
        let quota = json!({
            "results": [{
                "provider": "codex",
                "outcome": "success",
                "snapshots": [snapshot("local-only")]
            }]
        });
        let account = json!({
            "auth_status": "signed_in",
            "account_summary": {
                "devices": [{"id": "other", "display_name": "Studio"}],
                "subscriptions": [{
                    "key": "codex|remote-only|global|",
                    "provider": "codex",
                    "snapshot": snapshot("remote-only"),
                    "sources": [{"device_id": "other", "observed_at": observed_at}]
                }]
            }
        });
        let items = backend.build_overview(&quota, Some(&account));
        assert_eq!(items.len(), 2);
        assert_eq!(
            items
                .iter()
                .map(|item| item.identity.fingerprint.as_str())
                .collect::<Vec<_>>(),
            vec!["local-only", "remote-only"]
        );
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_discovered_local_source_that_failed_is_actionable_even_with_account_data() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let attempt = state.begin_diagnostic_attempt(
            DiagnosticAttemptKind::QuotaCollection,
            DiagnosticAttemptTrigger::Scheduled,
            Some("provider:codex"),
            None,
        );
        state.finish_diagnostic_attempt(
            attempt,
            &DiagnosticAttemptCompletion::new(
                DiagnosticAttemptOutcome::NoWork,
                Some(DiagnosticAttemptCode::AuthenticationRequired),
            ),
        );
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(json!({"results":[{
                    "provider":"codex","outcome":"auth_required","snapshots":[],
                    "sources":[{
                        "source_id":"chatgpt_usage_api",
                        "outcome":"auth_required",
                        "category":"auth_required"
                    }]
                }]})),
                Some("2026-08-15T08:00:00Z".into()),
                None,
                false,
            )
            .expect("quota");
        state
            .set_overview(&[QuotaOverviewItem {
                identity: QuotaOverviewIdentity {
                    provider: "codex".into(),
                    fingerprint: "account".into(),
                    scope: "global".into(),
                    source_id: None,
                },
                snapshot: json!({}),
                sources: vec![QuotaOverviewSource {
                    source_id: "redacted-in-report".into(),
                    kind: "device".into(),
                    device_id: Some("redacted-in-report".into()),
                    display_name: "Other device".into(),
                    observed_at: "2026-08-15T08:00:00Z".into(),
                    is_stale: false,
                    snapshot: None,
                }],
                selected_source_id: "redacted-in-report".into(),
                selected_source_display_name: "Other device".into(),
                automatic_source_id: "redacted-in-report".into(),
                automatic_source_display_name: "Other device".into(),
                is_stale: false,
                source_pin: None,
            }])
            .expect("overview");
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let report = backend.diagnostic_report().expect("diagnostics");
        // Another device's reading keeps the surface current and the device itself is
        // working, so operation stays healthy. But this Mac holds a sign-in it cannot use,
        // which Overview now says out loud, so Diagnose cannot report nothing to do.
        assert_eq!(
            report
                .surfaces
                .iter()
                .find(|surface| surface.id == "quota_overview")
                .map(|surface| surface.data),
            Some(DiagnosticDataState::Current)
        );
        assert_eq!(report.summary.operation, DiagnosticOperation::Healthy);
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        // The row names the rung that failed, not just the provider: a stale browser session
        // and an unreachable OAuth endpoint are different problems.
        assert!(report.sources.iter().any(|source| {
            source.subject == "provider:codex"
                && source.source_id.as_deref() == Some("chatgpt_usage_api")
                && source.status == DiagnosticStatus::Degraded
                && source.recovery == DiagnosticRecovery::ConfigureProvider
                && source.message.contains("Codex")
        }));
        let serialized = serde_json::to_string(&report).expect("serialize");
        assert!(!serialized.contains("redacted-in-report"));
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn explicit_local_provider_failure_remains_actionable_with_remote_data() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_provider_config("openrouter", "test-key", None)
            .expect("provider config");
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(json!({"results":[{
                    "provider":"openrouter","outcome":"auth_required","snapshots":[],"sources":0
                }]})),
                Some("2026-08-15T08:00:00Z".into()),
                None,
                false,
            )
            .expect("quota");
        state
            .set_overview(&[QuotaOverviewItem {
                identity: QuotaOverviewIdentity {
                    provider: "openrouter".into(),
                    fingerprint: "account".into(),
                    scope: "global".into(),
                    source_id: None,
                },
                snapshot: json!({}),
                sources: vec![QuotaOverviewSource {
                    source_id: "private-device".into(),
                    kind: "device".into(),
                    device_id: Some("private-device".into()),
                    display_name: "Other device".into(),
                    observed_at: "2026-08-15T08:00:00Z".into(),
                    is_stale: false,
                    snapshot: None,
                }],
                selected_source_id: "private-device".into(),
                selected_source_display_name: "Other device".into(),
                automatic_source_id: "private-device".into(),
                automatic_source_display_name: "Other device".into(),
                is_stale: false,
                source_pin: None,
            }])
            .expect("overview");
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );

        let report = backend.diagnostic_report().expect("diagnostics");

        assert_eq!(report.summary.operation, DiagnosticOperation::Degraded);
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        assert!(report.sources.iter().any(|source| {
            source.subject == "provider:openrouter"
                && source.status == DiagnosticStatus::Degraded
                && source.recovery == DiagnosticRecovery::ConfigureProvider
        }));
        assert!(
            !serde_json::to_string(&report)
                .unwrap()
                .contains("private-device")
        );
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn invalid_explicit_provider_configuration_is_scoped_and_redacted() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        fs::write(
            root.join("providers.json"),
            br#"{"api_key":"secret-value","path":"/Users/private""#,
        )
        .expect("invalid provider configuration");
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );

        let report = backend.diagnostic_report().expect("diagnostics");

        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        assert!(report.sources.iter().any(|source| {
            source.subject == "provider_configuration"
                && source.status == DiagnosticStatus::Blocked
                && source.code.as_deref() == Some("config_unreadable")
        }));
        let serialized = serde_json::to_string(&report).expect("serialize");
        assert!(!serialized.contains("secret-value"));
        assert!(!serialized.contains("/Users/private"));
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn pending_upload_waits_normally_until_a_completed_attempt_fails() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .write_session_json(&json!({"status":"active"}))
            .expect("session");
        state
            .insert_usage_dirty_hour_for_test(UsageAgent::Codex, "2026-08-10T12:00:00Z", 1)
            .expect("dirty hour");
        let backend = NativeBackend::new(
            state.clone(),
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let upload_source = |report: &DiagnosticReport| {
            report
                .sources
                .iter()
                .find(|source| source.subject == "usage_upload")
                .cloned()
                .expect("upload source")
        };

        let waiting = backend.evaluate_diagnostic_report(true).expect("waiting");
        let source = upload_source(&waiting);
        assert_eq!(source.status, DiagnosticStatus::Ok);
        assert_eq!(source.recovery, DiagnosticRecovery::Automatic);
        assert_eq!(waiting.summary.operation, DiagnosticOperation::Healthy);

        let finish = |outcome, code| {
            let attempt = state.begin_diagnostic_attempt(
                DiagnosticAttemptKind::UsageUpload,
                DiagnosticAttemptTrigger::Scheduled,
                None,
                None,
            );
            assert!(attempt.is_some());
            state.finish_diagnostic_attempt(
                attempt,
                &DiagnosticAttemptCompletion::new(outcome, code),
            );
        };

        finish(
            DiagnosticAttemptOutcome::Failed,
            Some(DiagnosticAttemptCode::NetworkError),
        );
        let failed = backend.evaluate_diagnostic_report(true).expect("failed");
        assert_eq!(upload_source(&failed).status, DiagnosticStatus::Degraded);
        assert_eq!(
            upload_source(&failed).code.as_deref(),
            Some("network_error")
        );

        // While uploadable work is still waiting, a later `no_work` attempt does not retire
        // the failure it never answered.
        finish(
            DiagnosticAttemptOutcome::NoWork,
            Some(DiagnosticAttemptCode::NoWork),
        );
        let still_failed = backend
            .evaluate_diagnostic_report(true)
            .expect("still failed");
        assert_eq!(
            upload_source(&still_failed).status,
            DiagnosticStatus::Degraded
        );

        finish(DiagnosticAttemptOutcome::Success, None);
        let recovered = backend.evaluate_diagnostic_report(true).expect("recovered");
        assert_eq!(upload_source(&recovered).status, DiagnosticStatus::Ok);
        assert_eq!(recovered.summary.operation, DiagnosticOperation::Healthy);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_partial_usage_scan_is_one_row_per_agent_with_the_reason_worth_acting_on() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .write_usage_scan_diagnostics(
                UsageAgent::Cursor,
                &json!({
                    "status": "partial",
                    "reason_counts": {"malformed_json": 4, "truncated_tail": 1}
                }),
            )
            .expect("scan diagnostics");
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );

        let report = backend
            .evaluate_diagnostic_report(true)
            .expect("diagnostics");

        let agents = report
            .sources
            .iter()
            .filter(|source| source.subject.starts_with("agent:"))
            .collect::<Vec<_>>();
        assert_eq!(agents.len(), 1);
        // A file that grew while it was read is ordinary; records this build could not parse
        // are the half someone can fix, so that is the one the row names.
        assert_eq!(agents[0].subject, "agent:cursor");
        assert_eq!(agents[0].code.as_deref(), Some("malformed_json"));
        assert_eq!(agents[0].recovery, DiagnosticRecovery::UpdateSource);
        assert_eq!(
            report
                .surfaces
                .iter()
                .find(|surface| surface.id == "usage_this_device")
                .map(|surface| surface.data),
            Some(DiagnosticDataState::Partial)
        );
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// The cap on how many rows a report carries is a cap on what it prints, not on what it
    /// noticed: folding after the cut let a long list of healthy sources hide the one row that
    /// said sign in again.
    #[test]
    fn a_capped_source_list_still_reports_the_attention_it_dropped() {
        let root = std::env::temp_dir().join(format!("quota-capped-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        drop(state);
        // A device that could not read who it is: the one row a refresh cannot retire, and the
        // last one pushed.
        fs::write(root.join("identity.sqlite"), b"not a database").expect("garbage");
        let state = Arc::new(StateStore::open(&root).expect("reopen"));

        let results = (0..MAXIMUM_DIAGNOSTIC_SOURCES + 4)
            .map(|index| {
                json!({
                    "provider": format!("provider_{index}"),
                    "outcome": "success",
                    "snapshots": [{"provider": "codex"}],
                    "sources": [{"source_id": "s", "outcome": "success", "category": "success"}]
                })
            })
            .collect::<Vec<_>>();
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(json!({"results": results})),
                None,
                None,
                false,
            )
            .expect("quota");
        let backend = NativeBackend::new(
            state.clone(),
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );

        let report = backend
            .evaluate_diagnostic_report(true)
            .expect("diagnostics");

        assert_eq!(report.sources.len(), MAXIMUM_DIAGNOSTIC_SOURCES);
        assert!(
            !report
                .sources
                .iter()
                .any(|source| source.subject == "local_state"),
            "the row that needed acting on is past the cap"
        );
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A credential is proven by being spent on the rung that spends it. A browser session
    /// answering for the same provider proves nothing about the sign-in on disk, and a rung
    /// that stopped working takes the proof back with it.
    #[test]
    fn only_a_rung_spending_this_device_s_own_credential_proves_it() {
        let root = std::env::temp_dir().join(format!("quota-proven-{}", uuid::Uuid::new_v4()));
        let codex_home = root.join("codex");
        fs::create_dir_all(&codex_home).expect("codex home");
        fs::write(
            codex_home.join("auth.json"),
            r#"{"tokens": {"access_token": "opaque-token", "account_id": "acct"}}"#,
        )
        .expect("auth");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state.clone(),
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let mut context = CollectionContext {
            home_directory: root.clone(),
            environment: HashMap::from([(
                "CODEX_HOME".to_owned(),
                codex_home.to_string_lossy().into_owned(),
            )]),
            ..CollectionContext::default()
        };
        // Each refresh builds its context from the cache, which is what the record is for.
        let reload = |context: &mut CollectionContext, state: &StateStore| {
            context.proven_credentials = state
                .proven_provider_credentials()
                .ok()
                .flatten()
                .and_then(|raw| serde_json::from_str(&raw).ok())
                .unwrap_or_default();
        };
        let result = |source_id: &str, outcome: &str| {
            json!({
                "provider": "codex",
                "outcome": outcome,
                "snapshots": [],
                "sources": [{"source_id": source_id, "outcome": outcome, "category": outcome}]
            })
        };
        let proven = |state: &StateStore| {
            state
                .proven_provider_credentials()
                .expect("record")
                .unwrap_or_default()
        };
        let fingerprint = crate::providers::common::sha256_hex("opaque-token");

        // A stored browser session answering for Codex says nothing about `auth.json`.
        backend.record_proven_credentials(
            &[result(
                crate::providers::common::BROWSER_SESSION_SOURCE,
                "success",
            )],
            &context,
        );
        assert!(!proven(&state).contains(&fingerprint));

        reload(&mut context, &state);
        backend.record_proven_credentials(&[result(codex::SOURCE, "success")], &context);
        assert!(proven(&state).contains(&fingerprint));

        // The same sign-in refused is a sign-in that has to earn a renewal again.
        reload(&mut context, &state);
        backend.record_proven_credentials(&[result(codex::SOURCE, "auth_required")], &context);
        assert!(!proven(&state).contains(&fingerprint));
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// The hour still being written to is not work owed, and neither is an hour before this
    /// device's privacy watermark: staging skips both, so the count that says how much is
    /// waiting skips them too — and the marks it can never stage are retired rather than left
    /// to sit in the cache saying the upload is behind.
    #[test]
    fn only_complete_hours_inside_the_watermark_count_as_pending_uploads() {
        let root = std::env::temp_dir().join(format!("quota-pending-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let now = Utc::now();
        let hour = |back: i64| floor_utc_hour(&(now - Duration::hours(back)));
        let mut session = active_session();
        session["usage_deleted_before"] = json!(hour(3));
        state.write_session_json(&session).expect("session");
        for back in [4, 2, 0] {
            state
                .insert_usage_dirty_hour_for_test(UsageAgent::Codex, &hour(back), 1)
                .expect("dirty hour");
        }
        let backend = NativeBackend::new(
            state.clone(),
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );

        assert_eq!(backend.uploadable_dirty_hour_count().expect("count"), 1);

        // The mark before the watermark is not waiting on anything, and does not stay.
        state
            .forget_dirty_usage_hours_before(&hour(3))
            .expect("retire");
        assert_eq!(
            state
                .dirty_usage_hour_batch(EPOCH_HOUR, "9999-12-31T23:00:00Z", 100)
                .expect("dirty")
                .len(),
            2
        );
        assert_eq!(backend.uploadable_dirty_hour_count().expect("count"), 1);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn timezone_prefers_explicit_valid_tz_and_resolves_without_tz() {
        use crate::providers::common::resolve_timezone;
        let explicit = HashMap::from([(String::from("TZ"), String::from("Asia/Tokyo"))]);
        assert_eq!(resolve_timezone(&explicit).name(), "Asia/Tokyo");
        let invalid = HashMap::from([(String::from("TZ"), String::from("not/a-zone"))]);
        assert_ne!(resolve_timezone(&invalid).name(), "not/a-zone");
    }

    /// An upload is bounded by hours and by bytes, and packing never drops an hour to fit.
    #[test]
    fn an_upload_packs_by_hours_and_by_bytes_without_dropping_one() {
        let row = |speed: usize| usage::UsageRow {
            agent: UsageAgent::Codex,
            billing_channel: usage::BillingChannel::OpenaiDirect,
            channel_source: usage::ChannelSource::Explicit,
            model: "gpt-5.6-sol".into(),
            context_bucket: usage::ContextBucket::Le128k,
            service_tier: "standard".into(),
            speed: format!("speed{speed}"),
            inference_geo: "global".into(),
            input_tokens: 1_200,
            cache_read_tokens: 400,
            cache_write_5m_tokens: 100,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: 0,
            output_tokens: 350,
            reasoning_tokens: 120,
            requests: 4,
            web_search_requests: 1,
            web_fetch_requests: 0,
            source_cost_microusd: None,
            source_cost_covered_requests: 0,
        };
        let hour = |index: usize, rows: usize| UsageOutboxEntry {
            agent: UsageAgent::Codex,
            bucket_start_utc: DateTime::parse_from_rfc3339("2026-01-01T00:00:00Z")
                .expect("base hour")
                .checked_add_signed(chrono::Duration::hours(index as i64))
                .expect("hour")
                .to_rfc3339_opts(SecondsFormat::Secs, true),
            scan_version: 3,
            partial: false,
            rows: (0..rows).map(row).collect(),
        };

        // Small hours: the hour bound is what stops the batch.
        let many = (0..usage::MAX_USAGE_HOURS_PER_UPLOAD + 10)
            .map(|index| hour(index, 1))
            .collect::<Vec<_>>();
        assert_eq!(
            usage_upload_batch_size(UsageAgent::Codex, 1, &many),
            usage::MAX_USAGE_HOURS_PER_UPLOAD
        );
        let upload = usage_upload(
            UsageAgent::Codex,
            1,
            &many[..usage::MAX_USAGE_HOURS_PER_UPLOAD],
        )
        .expect("upload");
        assert!(crate::relay::validate_usage_submission(&upload).is_ok());

        // Fat hours: the byte bound is, and every packed hour still travels whole.
        let fat = (0..8)
            .map(|index| hour(index, usage::MAX_USAGE_ROWS_PER_HOUR))
            .collect::<Vec<_>>();
        let taken = usage_upload_batch_size(UsageAgent::Codex, 1, &fat);
        assert!((1..fat.len()).contains(&taken), "{taken}");
        let upload = usage_upload(UsageAgent::Codex, 1, &fat[..taken]).expect("upload");
        assert!(crate::relay::validate_usage_submission(&upload).is_ok());
        assert_eq!(
            upload["hours"].as_array().expect("hours").len(),
            taken,
            "packing never truncates an hour"
        );
        assert!(serde_json::to_vec(&upload).expect("bytes").len() <= 1_048_576);
    }

    /// The payloads this device sends, checked against the JSON Schema `packages/protocol`
    /// exports rather than against a second description of the same contract.
    ///
    /// The schema is the shape: which keys are required, which are refused, and what each one
    /// holds. The value bounds a shape cannot state — token subsets, source-cost coverage,
    /// unique row identities — are the validators', and the shared fixture is what keeps those
    /// in step across runtimes.
    #[test]
    fn what_this_device_uploads_matches_the_exported_json_schema() {
        const USAGE_SCHEMA: &str = include_str!("../../../protocol/schema/usage.json");
        const SNAPSHOT_SCHEMA: &str = include_str!("../../../protocol/schema/quota-snapshot.json");

        let hour = UsageOutboxEntry {
            agent: UsageAgent::Codex,
            bucket_start_utc: "2026-08-12T09:00:00Z".into(),
            scan_version: 7,
            partial: false,
            rows: vec![usage::UsageRow {
                agent: UsageAgent::Codex,
                billing_channel: usage::BillingChannel::OpenaiDirect,
                channel_source: usage::ChannelSource::Explicit,
                model: "gpt-5.6-sol".into(),
                context_bucket: usage::ContextBucket::Le128k,
                service_tier: "standard".into(),
                speed: "standard".into(),
                inference_geo: "global".into(),
                input_tokens: 1_200,
                cache_read_tokens: 400,
                cache_write_5m_tokens: 100,
                cache_write_1h_tokens: 0,
                cache_write_inferred_tokens: 0,
                output_tokens: 350,
                reasoning_tokens: 120,
                requests: 4,
                web_search_requests: 1,
                web_fetch_requests: 0,
                source_cost_microusd: Some("4200".into()),
                source_cost_covered_requests: 4,
            }],
        };
        let upload = usage_upload(UsageAgent::Codex, 3, &[hour]).expect("upload");
        JsonSchema::parse(USAGE_SCHEMA)
            .check(&upload)
            .expect("the Usage upload matches the exported schema");

        // A row without a reported cost omits the key rather than sending it as null.
        let bare = usage_upload(
            UsageAgent::Codex,
            3,
            &[UsageOutboxEntry {
                agent: UsageAgent::Codex,
                bucket_start_utc: "2026-08-12T10:00:00Z".into(),
                scan_version: 8,
                partial: true,
                rows: Vec::new(),
            }],
        )
        .expect("empty upload");
        JsonSchema::parse(USAGE_SCHEMA)
            .check(&bare)
            .expect("an emptied hour matches the exported schema");

        // The check is not vacuous: a key the contract does not name is refused, and so is a
        // value of the wrong kind.
        let mut extra = upload.clone();
        extra["uploaded_at"] = json!("2026-08-12T09:31:00Z");
        assert!(JsonSchema::parse(USAGE_SCHEMA).check(&extra).is_err());
        let mut wrong = upload;
        wrong["hours"][0]["scan_version"] = json!("seven");
        assert!(JsonSchema::parse(USAGE_SCHEMA).check(&wrong).is_err());

        let envelope = crate::relay::snapshot_envelope(
            3,
            vec![json!({
                "provider": "codex",
                "account": {"fingerprint": "codex_account_1", "fingerprint_scope": "global"},
                "windows": [{"id": "weekly", "title": "Weekly", "used_percent": 42.0}],
                "status": "available",
                "observed_at": "2026-08-12T09:30:00Z"
            })],
        );
        JsonSchema::parse(SNAPSHOT_SCHEMA)
            .check(&envelope)
            .expect("the snapshot envelope matches the exported schema");
    }

    /// The part of JSON Schema an exported contract uses: what a document is made of, not what
    /// its text has to look like. String patterns are the runtime validators' job, and the
    /// shared conformance fixture is what proves those agree across runtimes.
    struct JsonSchema {
        root: Value,
    }

    impl JsonSchema {
        fn parse(document: &str) -> Self {
            Self {
                root: serde_json::from_str(document).expect("schema document"),
            }
        }

        fn check(&self, value: &Value) -> Result<(), String> {
            self.check_at(value, &self.root, "$")
        }

        fn check_at(&self, value: &Value, schema: &Value, path: &str) -> Result<(), String> {
            let schema = self.resolve(schema);
            let object = schema
                .as_object()
                .ok_or_else(|| format!("{path}: schema"))?;
            if let Some(branches) = object.get("anyOf").and_then(Value::as_array) {
                return branches
                    .iter()
                    .any(|branch| self.check_at(value, branch, path).is_ok())
                    .then_some(())
                    .ok_or_else(|| format!("{path}: matches none of anyOf"));
            }
            if let Some(expected) = object.get("const")
                && value != expected
            {
                return Err(format!("{path}: expected {expected}, found {value}"));
            }
            if let Some(members) = object.get("enum").and_then(Value::as_array)
                && !members.contains(value)
            {
                return Err(format!("{path}: {value} is not a member"));
            }
            match object.get("type").and_then(Value::as_str) {
                Some("object") => self.check_object(value, object, path),
                Some("array") => self.check_array(value, object, path),
                Some("string") if !value.is_string() => Err(format!("{path}: expected a string")),
                Some("boolean") if !value.is_boolean() => Err(format!("{path}: expected a bool")),
                Some("integer") if value.as_i64().is_none() => {
                    Err(format!("{path}: expected an integer"))
                }
                Some("number") if !value.is_number() => Err(format!("{path}: expected a number")),
                Some("null") if !value.is_null() => Err(format!("{path}: expected null")),
                _ => Ok(()),
            }
        }

        fn check_object(
            &self,
            value: &Value,
            schema: &serde_json::Map<String, Value>,
            path: &str,
        ) -> Result<(), String> {
            let object = value
                .as_object()
                .ok_or_else(|| format!("{path}: expected an object"))?;
            let properties = schema.get("properties").and_then(Value::as_object);
            for key in schema
                .get("required")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                if !object.contains_key(key) {
                    return Err(format!("{path}: missing {key}"));
                }
            }
            for (key, item) in object {
                match properties.and_then(|properties| properties.get(key)) {
                    Some(property) => self.check_at(item, property, &format!("{path}.{key}"))?,
                    None if schema.get("additionalProperties") == Some(&Value::Bool(false)) => {
                        return Err(format!("{path}: {key} is not part of the contract"));
                    }
                    None => {}
                }
            }
            Ok(())
        }

        fn check_array(
            &self,
            value: &Value,
            schema: &serde_json::Map<String, Value>,
            path: &str,
        ) -> Result<(), String> {
            let items = value
                .as_array()
                .ok_or_else(|| format!("{path}: expected an array"))?;
            if let Some(maximum) = schema.get("maxItems").and_then(Value::as_u64)
                && items.len() as u64 > maximum
            {
                return Err(format!("{path}: more than {maximum} items"));
            }
            let Some(item_schema) = schema.get("items") else {
                return Ok(());
            };
            for (index, item) in items.iter().enumerate() {
                self.check_at(item, item_schema, &format!("{path}[{index}]"))?;
            }
            Ok(())
        }

        /// A `$ref` inside the exported document, which only ever names a sibling `$defs` entry.
        fn resolve<'a>(&'a self, schema: &'a Value) -> &'a Value {
            let Some(reference) = schema.get("$ref").and_then(Value::as_str) else {
                return schema;
            };
            let name = reference
                .strip_prefix("#/$defs/")
                .expect("only local $defs references");
            self.root
                .get("$defs")
                .and_then(|defs| defs.get(name))
                .map(|target| self.resolve(target))
                .expect("a named definition")
        }
    }

    /// An empty hour is a fact: it is how a device says everything it once reported for that
    /// hour is gone.
    #[test]
    fn an_hour_with_nothing_left_in_it_still_travels() {
        let upload = usage_upload(
            UsageAgent::Codex,
            3,
            &[UsageOutboxEntry {
                agent: UsageAgent::Codex,
                bucket_start_utc: "2026-08-12T09:00:00Z".into(),
                scan_version: 7,
                partial: true,
                rows: Vec::new(),
            }],
        )
        .expect("upload");
        assert!(crate::relay::validate_usage_submission(&upload).is_ok());
        assert_eq!(upload["hours"][0]["partial"], json!(true));
        assert_eq!(upload["hours"][0]["rows"], json!([]));
    }

    #[test]
    fn complete_scans_produce_a_complete_local_report() {
        let root = std::env::temp_dir().join(format!("quota-report-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let backend = NativeBackend::new(state, relay, "QuotaTest", "test");
        let collection = UsageCollection {
            timezone: "UTC".to_owned(),
            generated_at: "2026-08-10T00:00:00Z".to_owned(),
            agents: UsageAgent::ALL
                .iter()
                .copied()
                .map(|agent| AgentUsage {
                    coverage: usage::ScanCoverage {
                        agent,
                        start_at: "2026-08-09T00:00:00Z".to_owned(),
                        end_at: "2026-08-10T00:00:00Z".to_owned(),
                        status: CoverageStatus::Complete,
                        reasons: Vec::new(),
                    },
                })
                .collect(),
        };
        let report = backend
            .usage_report(&collection, None, None)
            .expect("report");
        assert_eq!(
            report.get("status").and_then(Value::as_str),
            Some("complete")
        );
        assert_eq!(
            report["range"],
            json!({"from": "2026-08-10", "to": "2026-08-10"})
        );
        assert!(report.get("usage").is_none());
        assert!(report.get("today").is_none());
        assert!(
            report
                .get("coverage")
                .and_then(Value::as_array)
                .is_some_and(|items| items.iter().all(|item| {
                    item.get("status").and_then(Value::as_str) == Some("complete")
                }))
        );
        let cached = backend.state.snapshot().expect("cached periods");
        assert_eq!(
            cached
                .usage_periods
                .local
                .last_7_days
                .as_ref()
                .and_then(|detail| detail.get("range")),
            Some(&json!({"from": "2026-08-04", "to": "2026-08-10"}))
        );
        assert!(cached.usage_periods.local.today.is_some());
        assert_eq!(
            cached
                .usage_periods
                .local
                .today
                .as_ref()
                .and_then(|detail| detail.pointer("/usage/totals/input_tokens"))
                .and_then(Value::as_u64),
            Some(0)
        );
        assert!(
            cached
                .usage_periods
                .local
                .today
                .as_ref()
                .and_then(|detail| detail.pointer("/usage/models_truncated"))
                .is_none()
        );
        assert!(cached.usage_periods.local.last_30_days.is_some());
        assert!(cached.usage_periods.local.all.is_some());
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// Relay's deletion watermark is the whole bound, kept to the instant; a device never
    /// deleted starts at the epoch, and a session that cannot say which it is fails closed.
    #[test]
    fn usage_lower_bound_is_precise_and_fails_closed() {
        assert_eq!(
            effective_usage_lower_bound(&json!({
                "usage_deleted_before": "2026-08-10T00:00:00.123Z"
            }))
            .expect("lower bound"),
            "2026-08-10T00:00:00.123Z"
        );
        assert_eq!(
            effective_usage_lower_bound(&json!({ "usage_deleted_before": null }))
                .expect("lower bound"),
            "1970-01-01T00:00:00Z"
        );
        assert!(
            effective_usage_lower_bound(&json!({ "usage_deleted_before": "invalid" })).is_err()
        );
        assert!(effective_usage_lower_bound(&json!({})).is_err());
    }
}
