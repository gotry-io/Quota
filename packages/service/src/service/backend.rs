//! Production backend adapter.  The service owns orchestration; this adapter owns the concrete
//! provider, Usage, pricing, and Relay calls and returns only protocol-shaped values.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use chrono::{DateTime, Days, Duration, SecondsFormat, Timelike, Utc};
use chrono_tz::Tz;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::catalog::ProviderId;
use crate::observation::snapshot_is_current;
use crate::pricing;
use crate::protocol::{
    DiagnosticAttemptCode, DiagnosticAttemptKind, DiagnosticAttemptOutcome,
    DiagnosticAttemptTrigger, DiagnosticAttention, DiagnosticCheck, DiagnosticClient,
    DiagnosticDataState, DiagnosticFinding, DiagnosticImpact, DiagnosticMode, DiagnosticOperation,
    DiagnosticRecovery, DiagnosticRefresh, DiagnosticRefreshPhase, DiagnosticReport,
    DiagnosticSeverity, DiagnosticSource, DiagnosticSummary, DiagnosticSurface, ErrorCode,
    IpcError, LOCAL_COLLECTION_PROTOCOL, LOCAL_USAGE_PROTOCOL, MANAGED_DATA_PROTOCOL,
    QuotaOverviewIdentity, QuotaOverviewItem, QuotaOverviewSource, RecoveryAction, UsagePeriod,
    UsageSource,
};
use crate::providers::common::{ErrorCategory, ProviderSession};
use crate::providers::{self, CollectionContext};
use crate::relay::{AccountManager, RelayClient};
use crate::service::{BackendError, LocalBackend, LoginOutcome, RefreshOutcome};
use crate::state::{
    DiagnosticAttemptCompletion, DiagnosticAttemptHandle, HealthEvidenceTrust, RepairSite,
    StateStore, UsageDirtyRange, now_rfc3339,
};
use crate::usage::{
    self, CoverageReasonCode, CoverageStatus, UsageAgent, UsageHourlyFact, UsageScanOptions,
};

const PARSER_REVISION: &str = "quota-usage-rust-4";
const MAX_USAGE_OUTBOX_ENTRIES: usize = 64;
const MAX_USAGE_MULTIPART_PARTS: usize = 64;

fn metrics<const N: usize>(values: [(&str, i64); N]) -> BTreeMap<String, i64> {
    values
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value.clamp(0, 1_000_000)))
        .collect()
}

fn array_len(value: Option<&Value>, key: &str) -> i64 {
    value
        .and_then(Value::as_object)
        .and_then(|object| object.get(key))
        .and_then(Value::as_array)
        .map(|items| items.len() as i64)
        .unwrap_or(0)
}

fn uploadable_dirty_range_count(ranges: &[UsageDirtyRange], now: DateTime<Utc>) -> i64 {
    let Ok(complete_until) = DateTime::parse_from_rfc3339(&floor_utc_hour(&now)) else {
        return ranges.len().min(i64::MAX as usize) as i64;
    };
    ranges
        .iter()
        .filter(|range| {
            DateTime::parse_from_rfc3339(&range.start_at)
                .map(|start| start < complete_until)
                .unwrap_or(true)
        })
        .count()
        .min(i64::MAX as usize) as i64
}

fn error_code_wire(code: ErrorCode) -> String {
    serde_json::to_value(code)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "unknown_error".to_owned())
}

fn backend_attempt_error(
    error: &IpcError,
) -> (
    DiagnosticAttemptOutcome,
    DiagnosticAttemptCode,
    DiagnosticRecovery,
) {
    if error.code == ErrorCode::Cancelled {
        return (
            DiagnosticAttemptOutcome::Cancelled,
            DiagnosticAttemptCode::Cancelled,
            DiagnosticRecovery::None,
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
    let recovery = match error.recovery_action {
        RecoveryAction::None => DiagnosticRecovery::None,
        RecoveryAction::Retry => DiagnosticRecovery::Retry,
        RecoveryAction::Login => DiagnosticRecovery::Login,
        RecoveryAction::ConfigureProvider => DiagnosticRecovery::ConfigureProvider,
        RecoveryAction::Upgrade => DiagnosticRecovery::Upgrade,
        RecoveryAction::Reinstall => DiagnosticRecovery::Reinstall,
    };
    (DiagnosticAttemptOutcome::Failed, code, recovery)
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
        DiagnosticAttemptCode::InvalidUsageBatch => "invalid_usage_batch",
        DiagnosticAttemptCode::UnrepresentableHour => "unrepresentable_hour",
        DiagnosticAttemptCode::DeviceDeleted => "device_deleted",
        DiagnosticAttemptCode::UploadDisabled => "upload_disabled",
        DiagnosticAttemptCode::SignedOut => "signed_out",
    }
}

fn device_health_code_for_attempt(attempt: &crate::protocol::DiagnosticAttempt) -> &'static str {
    if attempt.outcome == DiagnosticAttemptOutcome::Interrupted
        || attempt.code == Some(DiagnosticAttemptCode::ProcessInterrupted)
    {
        return "process_interrupted";
    }
    if attempt.code == Some(DiagnosticAttemptCode::InvalidState) {
        return "local_state_invalid";
    }
    match attempt.kind {
        DiagnosticAttemptKind::Refresh => "refresh_failed",
        DiagnosticAttemptKind::QuotaCollection => "quota_collection_failed",
        DiagnosticAttemptKind::UsageScan => "usage_scan_partial",
        DiagnosticAttemptKind::UsageUpload => "usage_upload_failed",
        DiagnosticAttemptKind::AccountSync => "account_sync_failed",
        DiagnosticAttemptKind::PricingRefresh => "pricing_refresh_failed",
        DiagnosticAttemptKind::DeviceHealthUpload => "refresh_failed",
    }
}

fn diagnostic_attempt_timestamp(attempt: &crate::protocol::DiagnosticAttempt) -> String {
    attempt
        .completed_at
        .clone()
        .unwrap_or_else(|| attempt.started_at.clone())
}

fn pricing_diagnostic_metrics(value: Option<&Value>) -> BTreeMap<String, i64> {
    let valid = value.is_some_and(|value| pricing::validate_pricing_catalog(value).valid);
    metrics([
        ("catalog_present", i64::from(value.is_some())),
        ("catalog_valid", i64::from(valid)),
        ("entries", array_len(value, "entries")),
    ])
}

fn account_diagnostic_metrics(
    value: Option<&Value>,
    session: Option<&Value>,
) -> BTreeMap<String, i64> {
    let auth_status = value
        .and_then(Value::as_object)
        .and_then(|object| object.get("auth_status"))
        .and_then(Value::as_str);
    let summary = value
        .and_then(Value::as_object)
        .and_then(|object| object.get("account_summary"));
    metrics([
        ("signed_in", i64::from(auth_status == Some("signed_in"))),
        (
            "session_active",
            i64::from(
                session
                    .and_then(Value::as_object)
                    .and_then(|object| object.get("status"))
                    .and_then(Value::as_str)
                    == Some("active"),
            ),
        ),
        (
            "session_logout_pending",
            i64::from(
                session
                    .and_then(Value::as_object)
                    .and_then(|object| object.get("status"))
                    .and_then(Value::as_str)
                    == Some("logout_pending"),
            ),
        ),
        ("devices", array_len(summary, "devices")),
        ("observations", array_len(summary, "quota")),
    ])
}

pub struct NativeBackend {
    state: Arc<StateStore>,
    relay: Arc<RelayClient>,
    account: AccountManager,
    home: PathBuf,
    environment: HashMap<String, String>,
    client_name: String,
    client_version: String,
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
        }
    }

    fn begin_attempt(
        &self,
        kind: DiagnosticAttemptKind,
        source: DiagnosticSource,
        subject: Option<&str>,
        mode: DiagnosticMode,
    ) -> Result<DiagnosticAttemptHandle, BackendError> {
        let parent = self
            .state
            .running_refresh_attempt()
            .map_err(|_| BackendError::unavailable())?;
        self.state
            .begin_diagnostic_attempt(
                kind,
                parent
                    .map(|(_, trigger)| trigger)
                    .unwrap_or(DiagnosticAttemptTrigger::Manual),
                source,
                subject,
                mode,
                parent.map(|(handle, _)| handle),
            )
            .map_err(|_| BackendError::unavailable())
    }

    fn finish_attempt(
        &self,
        handle: DiagnosticAttemptHandle,
        outcome: DiagnosticAttemptOutcome,
        code: Option<DiagnosticAttemptCode>,
        recovery: DiagnosticRecovery,
        metrics: BTreeMap<String, i64>,
    ) -> Result<(), BackendError> {
        self.state
            .finish_diagnostic_attempt(
                handle,
                &DiagnosticAttemptCompletion {
                    outcome,
                    code,
                    recovery,
                    metrics,
                },
            )
            .map_err(|_| BackendError::unavailable())?;
        Ok(())
    }

    fn finish_backend_result_attempt<T>(
        &self,
        handle: DiagnosticAttemptHandle,
        result: &Result<T, BackendError>,
        metrics: BTreeMap<String, i64>,
    ) -> Result<(), BackendError> {
        match result {
            Ok(_) => self.finish_attempt(
                handle,
                DiagnosticAttemptOutcome::Success,
                None,
                DiagnosticRecovery::None,
                metrics,
            ),
            Err(error) => {
                let (outcome, code, recovery) = backend_attempt_error(&error.error);
                self.finish_attempt(handle, outcome, Some(code), recovery, metrics)
            }
        }
    }

    /// Collect provider quota without Usage, pricing, account synchronization, or uploads.
    ///
    /// This is the local-only path used by diagnostic/status callers.  Full refresh remains the
    /// only path that performs account synchronization and outbox work.
    pub fn collect_quota(&self, cancel: Arc<AtomicBool>) -> Result<Value, BackendError> {
        self.collect_quota_for(ProviderId::ALL, cancel)
    }

    /// Discover providers through the same provider-owned credential paths used for collection.
    /// No account or Relay state is read or changed.
    pub fn configured_providers(&self) -> Result<Vec<ProviderId>, BackendError> {
        let context = self.collection_context(Arc::new(AtomicBool::new(false)))?;
        Ok(ProviderId::ALL
            .iter()
            .copied()
            .filter(|provider| !providers::discover(*provider, &context).is_empty())
            .collect())
    }

    pub fn diagnostic_report(&self) -> Result<DiagnosticReport, BackendError> {
        match self.state.health_evidence_trust() {
            HealthEvidenceTrust::FailClosed => Ok(self.fail_closed_report()),
            HealthEvidenceTrust::PersistRetry => Err(BackendError::unavailable()),
            HealthEvidenceTrust::TrustedSnapshot => {
                let mut report = self
                    .state
                    .diagnostic_snapshot()
                    .map_err(|_| BackendError::unavailable())?
                    .ok_or_else(BackendError::unavailable)?;
                report.generated_at = now_rfc3339();
                report.client = self.diagnostic_client();
                report.recent_activity = self
                    .state
                    .diagnostic_recent_activity()
                    .map_err(|_| BackendError::unavailable())?;
                Ok(report)
            }
            HealthEvidenceTrust::EvaluateLive => self.evaluate_diagnostic_report(false),
        }
    }

    pub fn complete_diagnostic_report(&self) -> Result<DiagnosticReport, BackendError> {
        match self.state.health_evidence_trust() {
            HealthEvidenceTrust::FailClosed => Ok(self.fail_closed_report()),
            HealthEvidenceTrust::PersistRetry => Err(BackendError::unavailable()),
            HealthEvidenceTrust::TrustedSnapshot | HealthEvidenceTrust::EvaluateLive => {
                let report = self.evaluate_diagnostic_report(true)?;
                if self.state.write_diagnostic_snapshot(&report).is_err() {
                    let _ = self.state.run_repair(RepairSite::WriteFailure);
                    let _ = self.state.write_diagnostic_snapshot(&report);
                }
                Ok(report)
            }
        }
    }

    fn fail_closed_report(&self) -> DiagnosticReport {
        let now = now_rfc3339();
        let revision = self.state.current_revision().unwrap_or(0);
        let recent_activity = self.state.diagnostic_recent_activity().unwrap_or(
            crate::protocol::DiagnosticRecentActivity {
                attempts: Vec::new(),
                history_truncated: false,
            },
        );
        DiagnosticReport {
            schema_version: 2,
            summary: DiagnosticSummary {
                operation: DiagnosticOperation::Blocked,
                data: DiagnosticDataState::Unknown,
                attention: DiagnosticAttention::Required,
            },
            refresh: DiagnosticRefresh {
                phase: DiagnosticRefreshPhase::Idle,
                revision,
                as_of: now.clone(),
                started_at: None,
                next_due_at: None,
            },
            generated_at: now.clone(),
            client: self.diagnostic_client(),
            surfaces: vec![
                DiagnosticSurface {
                    name: "quota_overview".into(),
                    operation: DiagnosticOperation::Blocked,
                    data: DiagnosticDataState::Unknown,
                    source: None,
                    metrics: BTreeMap::new(),
                },
                DiagnosticSurface {
                    name: "usage_this_device".into(),
                    operation: DiagnosticOperation::Blocked,
                    data: DiagnosticDataState::Unknown,
                    source: Some(DiagnosticSource::ThisDevice),
                    metrics: BTreeMap::new(),
                },
                DiagnosticSurface {
                    name: "usage_account".into(),
                    operation: DiagnosticOperation::Blocked,
                    data: DiagnosticDataState::Unknown,
                    source: Some(DiagnosticSource::Account),
                    metrics: BTreeMap::new(),
                },
                DiagnosticSurface {
                    name: "account".into(),
                    operation: DiagnosticOperation::Blocked,
                    data: DiagnosticDataState::Unknown,
                    source: Some(DiagnosticSource::Account),
                    metrics: BTreeMap::new(),
                },
            ],
            checks: vec![DiagnosticCheck {
                name: "local_state".into(),
                source: DiagnosticSource::System,
                subject: None,
                mode: DiagnosticMode::Required,
                operation: DiagnosticOperation::Blocked,
                data: DiagnosticDataState::Unknown,
                last_attempt_at: Some(now.clone()),
                last_success_at: None,
                metrics: metrics([("repaired", 0)]),
            }],
            findings: vec![DiagnosticFinding {
                component: "local_state".into(),
                source: DiagnosticSource::System,
                subject: None,
                code: "invalid_state".into(),
                severity: DiagnosticSeverity::Error,
                impact: DiagnosticImpact::System,
                recovery: DiagnosticRecovery::Reinstall,
                count: 1,
                observed_at: now,
                message: "Local state cannot be written and could not be repaired automatically."
                    .into(),
            }],
            recent_activity,
        }
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
        let recent_activity = self
            .state
            .diagnostic_recent_activity()
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
        let mut surfaces = Vec::with_capacity(4);
        let mut checks = Vec::new();
        let mut findings = Vec::new();

        let mut local_quota_sources = 0i64;
        let mut account_quota_sources = 0i64;
        let mut current_quota = 0i64;
        let mut account_provider_states = BTreeMap::<String, bool>::new();
        for item in &snapshot.overview {
            if !item.is_stale {
                current_quota = current_quota.saturating_add(1);
            }
            for source in &item.sources {
                if source.kind == "local" {
                    local_quota_sources = local_quota_sources.saturating_add(1);
                } else if source.kind == "device" {
                    account_quota_sources = account_quota_sources.saturating_add(1);
                    account_provider_states
                        .entry(item.identity.provider.clone())
                        .and_modify(|current| *current |= !source.is_stale)
                        .or_insert(!source.is_stale);
                }
            }
        }
        let quota_data = if snapshot.overview.is_empty() {
            DiagnosticDataState::Empty
        } else if current_quota > 0 {
            DiagnosticDataState::Current
        } else {
            DiagnosticDataState::Stale
        };
        surfaces.push(DiagnosticSurface {
            name: "quota_overview".into(),
            operation: DiagnosticOperation::Healthy,
            data: quota_data,
            source: None,
            metrics: metrics([
                ("items", snapshot.overview.len() as i64),
                ("current_items", current_quota),
                ("this_device_sources", local_quota_sources),
                ("account_sources", account_quota_sources),
            ]),
        });
        for (provider, current) in account_provider_states {
            checks.push(DiagnosticCheck {
                name: "quota_collection".into(),
                source: DiagnosticSource::Account,
                subject: Some(format!("provider:{provider}")),
                mode: DiagnosticMode::Required,
                operation: DiagnosticOperation::Healthy,
                data: if current {
                    DiagnosticDataState::Current
                } else {
                    DiagnosticDataState::Stale
                },
                last_attempt_at: account.as_ref().and_then(|value| value.updated_at.clone()),
                last_success_at: account.as_ref().and_then(|value| value.updated_at.clone()),
                metrics: metrics([("sources", 1)]),
            });
        }

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
                let attempt_facts = self
                    .state
                    .diagnostic_attempt_facts(
                        DiagnosticAttemptKind::QuotaCollection,
                        DiagnosticSource::ThisDevice,
                        Some(&subject),
                    )
                    .map_err(|_| BackendError::unavailable())?;
                // From the report in hand, which is the collection this check explains. The
                // journal answers when it ran, not what it found.
                let discovered = result.get("sources").and_then(Value::as_u64).unwrap_or(0) > 0;
                if !explicit && !discovered {
                    continue;
                }
                let mode = if explicit {
                    DiagnosticMode::Required
                } else {
                    DiagnosticMode::Opportunistic
                };
                let outcome = result
                    .get("outcome")
                    .and_then(Value::as_str)
                    .unwrap_or("error");
                let snapshots = array_len(Some(result), "snapshots");
                let success = outcome == "success" && snapshots > 0;
                checks.push(DiagnosticCheck {
                    name: "quota_collection".into(),
                    source: DiagnosticSource::ThisDevice,
                    subject: Some(subject.clone()),
                    mode,
                    operation: if success {
                        DiagnosticOperation::Healthy
                    } else {
                        DiagnosticOperation::Degraded
                    },
                    data: if success {
                        DiagnosticDataState::Current
                    } else {
                        DiagnosticDataState::Empty
                    },
                    last_attempt_at: attempt_facts
                        .latest_completed
                        .as_ref()
                        .map(diagnostic_attempt_timestamp),
                    last_success_at: attempt_facts
                        .latest_success
                        .as_ref()
                        .map(diagnostic_attempt_timestamp),
                    metrics: metrics([
                        ("sources", i64::from(discovered)),
                        ("snapshots", snapshots),
                    ]),
                });
                if !success {
                    let access_denied =
                        result.get("access_denied").and_then(Value::as_bool) == Some(true);
                    let code = match outcome {
                        _ if access_denied => "access_denied",
                        "auth_required" => "auth_required",
                        "unsupported" => "unsupported",
                        "unavailable" => "unavailable",
                        _ => "provider_error",
                    };
                    // A source this device holds and cannot use is actionable however it
                    // was set up. Only absent setup is quiet, and it never reaches here.
                    findings.push(DiagnosticFinding {
                        component: "quota_collection".into(),
                        source: DiagnosticSource::ThisDevice,
                        subject: Some(subject),
                        code: code.into(),
                        severity: DiagnosticSeverity::Warning,
                        impact: DiagnosticImpact::Source,
                        recovery: match code {
                            "auth_required" => DiagnosticRecovery::ConfigureProvider,
                            // Signing in again rewrites a secret this Mac still would not be
                            // handed, and retrying asks for it once more every five minutes.
                            "access_denied" => DiagnosticRecovery::CheckAccess,
                            _ => DiagnosticRecovery::Retry,
                        },
                        count: 1,
                        observed_at: attempt_facts
                            .latest_completed
                            .as_ref()
                            .map(diagnostic_attempt_timestamp)
                            .unwrap_or_else(|| now.clone()),
                        message: if explicit {
                            "Configured collection on this device did not produce quota data."
                        } else {
                            "A local source this device discovered could not be collected."
                        }
                        .into(),
                    });
                }
            }
        }

        let (config_present, config_readable) = self.state.provider_config_status();
        if config_present {
            checks.push(DiagnosticCheck {
                name: "provider_configuration".into(),
                source: DiagnosticSource::ThisDevice,
                subject: None,
                mode: DiagnosticMode::Required,
                operation: if config_readable {
                    DiagnosticOperation::Healthy
                } else {
                    DiagnosticOperation::Degraded
                },
                data: if config_readable {
                    DiagnosticDataState::Current
                } else {
                    DiagnosticDataState::Unknown
                },
                last_attempt_at: Some(now.clone()),
                last_success_at: config_readable.then(|| now.clone()),
                metrics: metrics([("present", 1), ("valid", i64::from(config_readable))]),
            });
        }
        if config_present && !config_readable {
            findings.push(DiagnosticFinding {
                component: "provider_configuration".into(),
                source: DiagnosticSource::ThisDevice,
                subject: None,
                code: "config_unreadable".into(),
                severity: DiagnosticSeverity::Error,
                impact: DiagnosticImpact::Source,
                recovery: DiagnosticRecovery::ConfigureProvider,
                count: 1,
                observed_at: now.clone(),
                message: "Saved provider configuration cannot be read safely.".into(),
            });
        }

        let force_usage_partial = self
            .state
            .diagnose_forces_usage_partial()
            .map_err(|_| BackendError::unavailable())?;
        let last_good_local_usage = [
            &snapshot.usage_periods.local.today,
            &snapshot.usage_periods.local.last_7_days,
            &snapshot.usage_periods.local.last_30_days,
            &snapshot.usage_periods.local.all,
        ]
        .into_iter()
        .any(Option::is_some)
            || usage.as_ref().is_some_and(|record| record.value.is_some());
        let (file_count, record_count, partial_hours, scan_diagnostics) = if allow_usage_index_reads
        {
            let mut file_count = 0i64;
            for agent in UsageAgent::ALL {
                file_count = file_count.saturating_add(
                    self.state
                        .usage_file_index(agent)
                        .map_err(|_| BackendError::unavailable())?
                        .len() as i64,
                );
            }
            let record_count = self
                .state
                .usage_event_count()
                .map_err(|_| BackendError::unavailable())?
                .min(i64::MAX as u64) as i64;
            let partial_hours = self
                .state
                .partial_usage_hours()
                .map_err(|_| BackendError::unavailable())?;
            let scan_diagnostics = self
                .state
                .usage_scan_diagnostics()
                .map_err(|_| BackendError::unavailable())?;
            (file_count, record_count, partial_hours, scan_diagnostics)
        } else {
            (0, 0, HashSet::new(), Vec::new())
        };
        let mut usage_partial = force_usage_partial || !partial_hours.is_empty();
        let mut usage_requires_attention = false;
        for (agent, value, observed_at) in &scan_diagnostics {
            let subject = format!("agent:{}", agent.as_str());
            let attempt_facts = self
                .state
                .diagnostic_attempt_facts(
                    DiagnosticAttemptKind::UsageScan,
                    DiagnosticSource::ThisDevice,
                    Some(&subject),
                )
                .map_err(|_| BackendError::unavailable())?;
            let attempt_observed_at = attempt_facts
                .latest_completed
                .as_ref()
                .map(diagnostic_attempt_timestamp)
                .unwrap_or_else(|| observed_at.clone());
            let status = value.get("status").and_then(Value::as_str);
            let partial = status == Some("partial") || status == Some("blocked");
            usage_partial |= partial;
            let partial_for_agent = partial_hours
                .iter()
                .filter(|(candidate, _)| candidate == agent)
                .count() as i64;
            checks.push(DiagnosticCheck {
                name: "usage_scan".into(),
                source: DiagnosticSource::ThisDevice,
                subject: Some(subject.clone()),
                mode: DiagnosticMode::Required,
                operation: if status == Some("blocked") {
                    DiagnosticOperation::Degraded
                } else {
                    DiagnosticOperation::Healthy
                },
                data: if partial {
                    DiagnosticDataState::Partial
                } else if value
                    .get("valid_records")
                    .and_then(Value::as_i64)
                    .unwrap_or(0)
                    > 0
                {
                    DiagnosticDataState::Current
                } else {
                    DiagnosticDataState::Empty
                },
                last_attempt_at: attempt_facts
                    .latest_completed
                    .as_ref()
                    .map(diagnostic_attempt_timestamp),
                last_success_at: attempt_facts
                    .latest_success
                    .as_ref()
                    .map(diagnostic_attempt_timestamp),
                metrics: metrics([
                    (
                        "scanned_files",
                        value
                            .get("scanned_files")
                            .and_then(Value::as_i64)
                            .unwrap_or(0),
                    ),
                    (
                        "partial_files",
                        value
                            .get("partial_files")
                            .and_then(Value::as_i64)
                            .unwrap_or(0),
                    ),
                    (
                        "valid_records",
                        value
                            .get("valid_records")
                            .and_then(Value::as_i64)
                            .unwrap_or(0),
                    ),
                    ("partial_hours", partial_for_agent),
                ]),
            });
            if status == Some("blocked") {
                usage_requires_attention = true;
                findings.push(DiagnosticFinding {
                    component: "usage_scan".into(),
                    source: DiagnosticSource::ThisDevice,
                    subject: Some(subject.clone()),
                    code: "scan_unavailable".into(),
                    severity: DiagnosticSeverity::Warning,
                    impact: DiagnosticImpact::Surface,
                    recovery: DiagnosticRecovery::Retry,
                    count: 1,
                    observed_at: attempt_observed_at.clone(),
                    message: "This Usage source could not be scanned.".into(),
                });
            }
            for (code, count) in value
                .get("reason_counts")
                .and_then(Value::as_object)
                .into_iter()
                .flatten()
            {
                let count = count.as_i64().unwrap_or(0).clamp(0, 1_000_000);
                if count == 0 {
                    continue;
                }
                let transient = matches!(
                    code.as_str(),
                    "truncated_tail" | "source_changed" | "scan_cancelled"
                );
                let access = matches!(code.as_str(), "permission_denied" | "source_unreadable");
                usage_requires_attention |= !transient;
                findings.push(DiagnosticFinding {
                    component: "usage_scan".into(),
                    source: DiagnosticSource::ThisDevice,
                    subject: Some(format!("agent:{}", agent.as_str())),
                    code: code.clone(),
                    severity: if transient {
                        DiagnosticSeverity::Info
                    } else {
                        DiagnosticSeverity::Warning
                    },
                    impact: DiagnosticImpact::Surface,
                    recovery: if transient {
                        DiagnosticRecovery::Automatic
                    } else if access {
                        DiagnosticRecovery::CheckAccess
                    } else {
                        DiagnosticRecovery::UpdateSource
                    },
                    count,
                    observed_at: attempt_observed_at.clone(),
                    message: if transient {
                        "The source changed while it was being scanned; the next refresh will retry."
                    } else {
                        "Invalid Usage input was isolated while valid records were retained."
                    }
                    .into(),
                });
            }
        }
        let usage_operation = match usage.as_ref().map(|value| value.status) {
            Some(crate::protocol::ComponentStatus::Error) => DiagnosticOperation::Degraded,
            _ => DiagnosticOperation::Healthy,
        };
        let local_usage_data = if usage_partial {
            DiagnosticDataState::Partial
        } else if record_count > 0 || (!allow_usage_index_reads && last_good_local_usage) {
            DiagnosticDataState::Current
        } else {
            DiagnosticDataState::Empty
        };
        surfaces.push(DiagnosticSurface {
            name: "usage_this_device".into(),
            operation: usage_operation,
            data: local_usage_data,
            source: Some(DiagnosticSource::ThisDevice),
            metrics: metrics([
                ("files", file_count),
                ("records", record_count),
                ("partial_hours", partial_hours.len() as i64),
                ("agents", scan_diagnostics.len() as i64),
            ]),
        });

        let account_usage_available = [
            &snapshot.usage_periods.account.today,
            &snapshot.usage_periods.account.last_7_days,
            &snapshot.usage_periods.account.last_30_days,
            &snapshot.usage_periods.account.all,
        ]
        .into_iter()
        .filter(|value| value.is_some())
        .count() as i64;
        surfaces.push(DiagnosticSurface {
            name: "usage_account".into(),
            operation: DiagnosticOperation::Healthy,
            data: if !usage_upload_enabled || !account_signed_in {
                DiagnosticDataState::Empty
            } else if account_usage_available > 0 {
                DiagnosticDataState::Current
            } else {
                DiagnosticDataState::Empty
            },
            source: Some(DiagnosticSource::Account),
            metrics: metrics([
                ("enabled", i64::from(usage_upload_enabled)),
                ("periods", account_usage_available),
            ]),
        });

        let account_sync_facts = self
            .state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::AccountSync,
                DiagnosticSource::Account,
                None,
            )
            .map_err(|_| BackendError::unavailable())?;
        let account_attempt_failed = account_active
            && account_sync_facts
                .latest_completed
                .as_ref()
                .is_some_and(|attempt| {
                    matches!(
                        attempt.outcome,
                        DiagnosticAttemptOutcome::Failed | DiagnosticAttemptOutcome::Interrupted
                    )
                });
        let account_operation = match account.as_ref().map(|value| value.status) {
            Some(crate::protocol::ComponentStatus::Stale)
            | Some(crate::protocol::ComponentStatus::AuthRequired)
            | Some(crate::protocol::ComponentStatus::Error)
                if account_signed_in || account_active =>
            {
                DiagnosticOperation::Degraded
            }
            _ if account_attempt_failed => DiagnosticOperation::Degraded,
            _ => DiagnosticOperation::Healthy,
        };
        let account_data = if !account_signed_in && !account_active {
            DiagnosticDataState::Empty
        } else if account_operation == DiagnosticOperation::Degraded {
            DiagnosticDataState::Stale
        } else {
            DiagnosticDataState::Current
        };
        let account_metrics = account_diagnostic_metrics(
            account.as_ref().and_then(|value| value.value.as_ref()),
            session.as_ref(),
        );
        surfaces.push(DiagnosticSurface {
            name: "account".into(),
            operation: account_operation,
            data: account_data,
            source: Some(DiagnosticSource::Account),
            metrics: account_metrics,
        });
        if account_operation != DiagnosticOperation::Healthy {
            let error = account.as_ref().and_then(|value| value.last_error.as_ref());
            let code = error
                .map(|value| error_code_wire(value.code))
                .unwrap_or_else(|| "account_unavailable".into());
            findings.push(DiagnosticFinding {
                component: "account".into(),
                source: DiagnosticSource::Account,
                subject: None,
                code,
                severity: DiagnosticSeverity::Warning,
                impact: DiagnosticImpact::Surface,
                recovery: if error.is_some_and(|value| value.code.requires_login()) {
                    DiagnosticRecovery::Login
                } else {
                    DiagnosticRecovery::Retry
                },
                count: 1,
                observed_at: account
                    .as_ref()
                    .and_then(|_| {
                        account_sync_facts
                            .latest_completed
                            .as_ref()
                            .map(diagnostic_attempt_timestamp)
                    })
                    .unwrap_or_else(|| now.clone()),
                message: "Signed-in Account data could not be refreshed.".into(),
            });
        }

        let dirty_ranges = self
            .state
            .dirty_usage_ranges()
            .map_err(|_| BackendError::unavailable())?;
        let outbox_count = self
            .state
            .outbox_entries()
            .map_err(|_| BackendError::unavailable())?
            .len() as i64;
        let uploadable_dirty_count = uploadable_dirty_range_count(&dirty_ranges, Utc::now());
        let upload_facts = self
            .state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::UsageUpload,
                DiagnosticSource::Account,
                None,
            )
            .map_err(|_| BackendError::unavailable())?;
        let latest_upload = upload_facts.latest_completed.as_ref();
        let upload_waiting = outbox_count + uploadable_dirty_count > 0;
        let unresolved_upload_problem = latest_upload
            .filter(|attempt| {
                matches!(
                    attempt.outcome,
                    DiagnosticAttemptOutcome::Failed
                        | DiagnosticAttemptOutcome::Interrupted
                        | DiagnosticAttemptOutcome::Partial
                )
            })
            .or_else(|| {
                upload_waiting.then_some(())?;
                upload_facts.latest_problem_after_success.as_ref()
            });
        let sync_failed =
            account_active && usage_upload_enabled && unresolved_upload_problem.is_some();
        let sync_blocked = sync_failed
            && unresolved_upload_problem
                .is_some_and(|attempt| attempt.code == Some(DiagnosticAttemptCode::InvalidState));
        let sync_mode = if account_active && usage_upload_enabled {
            DiagnosticMode::Required
        } else {
            DiagnosticMode::Inactive
        };
        checks.push(DiagnosticCheck {
            name: "usage_upload".into(),
            source: DiagnosticSource::Account,
            subject: None,
            mode: sync_mode,
            operation: if sync_blocked {
                DiagnosticOperation::Blocked
            } else if sync_failed {
                DiagnosticOperation::Degraded
            } else {
                DiagnosticOperation::Healthy
            },
            data: if upload_waiting {
                DiagnosticDataState::Partial
            } else {
                DiagnosticDataState::Current
            },
            last_attempt_at: latest_upload.map(|attempt| {
                attempt
                    .completed_at
                    .clone()
                    .unwrap_or_else(|| attempt.started_at.clone())
            }),
            last_success_at: upload_facts
                .latest_success
                .as_ref()
                .map(diagnostic_attempt_timestamp),
            metrics: metrics([
                ("enabled", i64::from(usage_upload_enabled)),
                ("dirty_ranges", dirty_ranges.len() as i64),
                ("uploadable_dirty_ranges", uploadable_dirty_count),
                ("outbox", outbox_count),
                ("waiting", i64::from(upload_waiting)),
            ]),
        });
        if sync_failed {
            let code = unresolved_upload_problem
                .and_then(|attempt| attempt.code)
                .map(diagnostic_attempt_code_wire)
                .unwrap_or("unavailable");
            findings.push(DiagnosticFinding {
                component: "usage_upload".into(),
                source: DiagnosticSource::Account,
                subject: None,
                code: code.into(),
                severity: if sync_blocked {
                    DiagnosticSeverity::Error
                } else {
                    DiagnosticSeverity::Warning
                },
                impact: if sync_blocked {
                    DiagnosticImpact::System
                } else {
                    DiagnosticImpact::Source
                },
                recovery: unresolved_upload_problem
                    .map(|attempt| attempt.recovery)
                    .unwrap_or(DiagnosticRecovery::Retry),
                count: 1,
                observed_at: unresolved_upload_problem
                    .and_then(|attempt| attempt.completed_at.clone())
                    .unwrap_or_else(|| now.clone()),
                message: "A completed Usage upload attempt did not make progress.".into(),
            });
        }

        let pricing_value = pricing.as_ref().and_then(|value| value.value.as_ref());
        let pricing_metrics = pricing_diagnostic_metrics(pricing_value);
        let pricing_valid = pricing_metrics.get("catalog_valid") == Some(&1);
        let pricing_required = record_count > 0;
        let pricing_facts = self
            .state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::PricingRefresh,
                DiagnosticSource::System,
                None,
            )
            .map_err(|_| BackendError::unavailable())?;
        let pricing_attempt_failed =
            pricing_facts
                .latest_completed
                .as_ref()
                .is_some_and(|attempt| {
                    matches!(
                        attempt.outcome,
                        DiagnosticAttemptOutcome::Failed | DiagnosticAttemptOutcome::Interrupted
                    )
                });
        checks.push(DiagnosticCheck {
            name: "pricing_catalog".into(),
            source: DiagnosticSource::System,
            subject: None,
            mode: if pricing_required {
                DiagnosticMode::Required
            } else {
                DiagnosticMode::Inactive
            },
            operation: if pricing_required
                && ((pricing_value.is_some() && !pricing_valid) || pricing_attempt_failed)
            {
                DiagnosticOperation::Degraded
            } else {
                DiagnosticOperation::Healthy
            },
            data: if pricing_valid {
                DiagnosticDataState::Current
            } else {
                DiagnosticDataState::Empty
            },
            last_attempt_at: pricing_facts
                .latest_completed
                .as_ref()
                .map(diagnostic_attempt_timestamp),
            last_success_at: pricing_facts
                .latest_success
                .as_ref()
                .map(diagnostic_attempt_timestamp),
            metrics: pricing_metrics,
        });
        if pricing_required
            && ((pricing_value.is_some() && !pricing_valid) || pricing_attempt_failed)
        {
            findings.push(DiagnosticFinding {
                component: "pricing_catalog".into(),
                source: DiagnosticSource::System,
                subject: None,
                code: "invalid_catalog".into(),
                severity: DiagnosticSeverity::Warning,
                impact: DiagnosticImpact::Surface,
                recovery: DiagnosticRecovery::Retry,
                count: 1,
                observed_at: pricing_facts
                    .latest_completed
                    .as_ref()
                    .map(diagnostic_attempt_timestamp)
                    .unwrap_or_else(|| now.clone()),
                message: "The pricing catalog is invalid; Usage totals remain available.".into(),
            });
        }

        if let Some(salvaged_at) = self
            .state
            .state_salvaged_at()
            .map_err(|_| BackendError::unavailable())?
        {
            let within_window = DateTime::parse_from_rfc3339(&salvaged_at)
                .ok()
                .is_some_and(|value| Utc::now() - value.with_timezone(&Utc) < Duration::hours(24));
            if within_window {
                checks.push(DiagnosticCheck {
                    name: "local_state".into(),
                    source: DiagnosticSource::System,
                    subject: None,
                    mode: DiagnosticMode::Required,
                    operation: DiagnosticOperation::Healthy,
                    data: DiagnosticDataState::Current,
                    last_attempt_at: Some(salvaged_at.clone()),
                    last_success_at: Some(salvaged_at.clone()),
                    metrics: metrics([("repaired", 1)]),
                });
                findings.push(DiagnosticFinding {
                    component: "local_state".into(),
                    source: DiagnosticSource::System,
                    subject: None,
                    code: "state_repaired".into(),
                    severity: DiagnosticSeverity::Info,
                    impact: DiagnosticImpact::None,
                    recovery: DiagnosticRecovery::None,
                    count: 1,
                    observed_at: salvaged_at,
                    message: "Local storage was rebuilt. Quota and Account were preserved.".into(),
                });
            }
        }

        let mut operation = DiagnosticOperation::Healthy;
        for surface in &surfaces {
            operation = worst_operation(operation, surface.operation);
        }
        for check in &checks {
            if check.mode == DiagnosticMode::Required {
                operation = worst_operation(operation, check.operation);
            }
        }
        let data = if usage_partial {
            DiagnosticDataState::Partial
        } else if quota_data == DiagnosticDataState::Stale
            || account_data == DiagnosticDataState::Stale
        {
            DiagnosticDataState::Stale
        } else if quota_data == DiagnosticDataState::Current
            || local_usage_data == DiagnosticDataState::Current
            || account_data == DiagnosticDataState::Current
        {
            DiagnosticDataState::Current
        } else {
            DiagnosticDataState::Empty
        };
        let attention_findings = findings
            .iter()
            .filter(|finding| finding.code != "state_repaired")
            .collect::<Vec<_>>();
        let mut attention = if attention_findings.iter().any(|finding| {
            finding.severity == DiagnosticSeverity::Error
                || (finding.severity == DiagnosticSeverity::Warning
                    && finding.recovery != DiagnosticRecovery::Retry)
        }) || usage_requires_attention
        {
            DiagnosticAttention::Required
        } else if attention_findings
            .iter()
            .any(|finding| finding.severity == DiagnosticSeverity::Warning)
        {
            DiagnosticAttention::Automatic
        } else if attention_findings
            .iter()
            .any(|finding| finding.severity == DiagnosticSeverity::Info)
        {
            DiagnosticAttention::Optional
        } else if account_active
            && usage_upload_enabled
            && outbox_count + uploadable_dirty_count > 0
        {
            DiagnosticAttention::Automatic
        } else {
            DiagnosticAttention::None
        };
        if force_usage_partial && attention != DiagnosticAttention::Required {
            attention = DiagnosticAttention::Automatic;
        };
        let next_due_at = DateTime::parse_from_rfc3339(&now)
            .ok()
            .map(|value| (value + Duration::minutes(5)).to_rfc3339_opts(SecondsFormat::Secs, true));
        Ok(DiagnosticReport {
            schema_version: 2,
            summary: DiagnosticSummary {
                operation,
                data,
                attention,
            },
            refresh: DiagnosticRefresh {
                phase: DiagnosticRefreshPhase::Idle,
                revision: snapshot.revision,
                as_of: now.clone(),
                started_at: None,
                next_due_at,
            },
            generated_at: now,
            client: self.diagnostic_client(),
            surfaces,
            checks: checks.into_iter().take(128).collect(),
            findings: findings.into_iter().take(256).collect(),
            recent_activity,
        })
    }

    /// Collect only the selected providers through the local-only path.  This keeps CLI status
    /// provider selection separate from the full refresh that may upload account data.
    pub fn collect_quota_for(
        &self,
        provider_ids: &[ProviderId],
        cancel: Arc<AtomicBool>,
    ) -> Result<Value, BackendError> {
        let context = self.collection_context(cancel.clone())?;
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
        let attempts =
            thread::scope(|scope| {
                let mut jobs = Vec::with_capacity(provider_ids.len());
                for provider in provider_ids.iter().copied() {
                    let context = context.clone();
                    let mode = if configured.contains(provider.as_str()) {
                        DiagnosticMode::Required
                    } else {
                        DiagnosticMode::Opportunistic
                    };
                    let sessions = providers::discover(provider, &context);
                    let source_count = sessions.len() as i64;
                    if sessions.is_empty() && mode == DiagnosticMode::Opportunistic {
                        jobs.push((provider, mode, None, source_count, None));
                        continue;
                    }
                    let subject = format!("provider:{}", provider.as_str());
                    let handle = self.begin_attempt(
                        DiagnosticAttemptKind::QuotaCollection,
                        DiagnosticSource::ThisDevice,
                        Some(&subject),
                        mode,
                    )?;
                    jobs.push((
                        provider,
                        mode,
                        Some(handle),
                        source_count,
                        Some(scope.spawn(move || {
                            collect_discovered_provider(provider, sessions, &context)
                        })),
                    ));
                }
                let joined = jobs
                    .into_iter()
                    .map(|(provider, mode, handle, source_count, job)| match job {
                        Some(job) => match job.join() {
                            Ok(result) => (provider, mode, handle, source_count, result, false),
                            Err(_) => (
                                provider,
                                mode,
                                handle,
                                source_count,
                                json!({
                                    "provider": provider,
                                    "outcome": "error",
                                    "snapshots": []
                                }),
                                true,
                            ),
                        },
                        None => (
                            provider,
                            mode,
                            None,
                            source_count,
                            json!({
                                "provider": provider,
                                "outcome": "auth_required",
                                "snapshots": []
                            }),
                            false,
                        ),
                    })
                    .collect::<Vec<_>>();
                Ok::<_, BackendError>(joined)
            });
        let attempts = attempts?;
        let cancelled = cancel.load(Ordering::Acquire);
        let mut results = Vec::with_capacity(attempts.len());
        for (_, mode, handle, source_count, mut result, panicked) in attempts {
            let snapshot_count = result
                .get("snapshots")
                .and_then(Value::as_array)
                .map(|values| values.len() as i64)
                .unwrap_or(0);
            let result_outcome = result
                .get("outcome")
                .and_then(Value::as_str)
                .unwrap_or("error");
            let (outcome, code, recovery) = if cancelled {
                (
                    DiagnosticAttemptOutcome::Cancelled,
                    Some(DiagnosticAttemptCode::Cancelled),
                    DiagnosticRecovery::None,
                )
            } else if panicked {
                (
                    DiagnosticAttemptOutcome::Failed,
                    Some(DiagnosticAttemptCode::Unavailable),
                    DiagnosticRecovery::Retry,
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
                        DiagnosticRecovery::CheckAccess,
                    ),
                    "success" => (
                        DiagnosticAttemptOutcome::Success,
                        None,
                        DiagnosticRecovery::None,
                    ),
                    "auth_required" if mode == DiagnosticMode::Opportunistic => (
                        DiagnosticAttemptOutcome::NoWork,
                        Some(DiagnosticAttemptCode::AuthenticationRequired),
                        DiagnosticRecovery::None,
                    ),
                    "auth_required" => (
                        DiagnosticAttemptOutcome::Failed,
                        Some(DiagnosticAttemptCode::AuthenticationRequired),
                        DiagnosticRecovery::ConfigureProvider,
                    ),
                    _ => (
                        DiagnosticAttemptOutcome::Failed,
                        Some(DiagnosticAttemptCode::ProviderError),
                        DiagnosticRecovery::Retry,
                    ),
                }
            };
            if let Some(handle) = handle {
                self.finish_attempt(
                    handle,
                    outcome,
                    code,
                    recovery,
                    metrics([("sources", source_count), ("snapshots", snapshot_count)]),
                )?;
            }
            // Stamped here, with the count this loop already journals, so no collector
            // return path can forget it — a panicked one included.
            result["sources"] = json!(source_count);
            results.push(result);
        }
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        Ok(json!({
            "protocol_version": LOCAL_COLLECTION_PROTOCOL,
            "captured_at": captured_at,
            "results": results
        }))
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
            .map(|(provider, session)| (provider, session.cookie_header))
            .collect();
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
        })
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
        for agent in UsageAgent::ALL {
            if cancel.load(Ordering::Acquire) {
                return Err(BackendError::cancelled());
            }
            if self.state.last_persistence_requires_abort() {
                return Err(BackendError::unavailable());
            }
            let file_index = self
                .state
                .usage_file_index(agent)
                .map_err(|_| BackendError::unavailable())?;
            let subject = format!("agent:{}", agent.as_str());
            let attempt = self.begin_attempt(
                DiagnosticAttemptKind::UsageScan,
                DiagnosticSource::ThisDevice,
                Some(&subject),
                DiagnosticMode::Required,
            )?;
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
                        &json!({
                            "status": "blocked",
                            "scanned_files": 0,
                            "skipped_files": 0,
                            "indexed_records": 0,
                            "reason_counts": {"scan_failed": 1}
                        }),
                    );
                    self.finish_attempt(
                        attempt,
                        DiagnosticAttemptOutcome::Failed,
                        Some(DiagnosticAttemptCode::Unavailable),
                        DiagnosticRecovery::Retry,
                        metrics([("scanned_sources", 0), ("indexed_records", 0)]),
                    )?;
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
                    });
                }
            };
            let _ = self
                .state
                .write_usage_scan_diagnostics(agent, &usage_scan_diagnostic(&scan));
            // Apply complete source files even when another file for the same agent is partial.
            // The state layer keeps the last-good rows for partial sources, so one malformed or
            // unreadable file cannot roll back unrelated complete sources.
            if self.state.apply_usage_scan(agent, &scan).is_err() {
                let _ = self.state.write_usage_scan_diagnostics(
                    agent,
                    &json!({
                        "status": "blocked",
                        "scanned_files": scan.scanned_source_count,
                        "skipped_files": scan.skipped_source_count,
                        "indexed_records": scan.records.len(),
                        "valid_records": scan.records.len(),
                        "ignored_empty_records": scan.ignored_empty_records,
                        "reason_counts": {"state_apply_failed": 1}
                    }),
                );
                self.finish_attempt(
                    attempt,
                    DiagnosticAttemptOutcome::Failed,
                    Some(DiagnosticAttemptCode::InvalidState),
                    DiagnosticRecovery::Retry,
                    metrics([
                        ("scanned_sources", scan.scanned_source_count as i64),
                        ("indexed_records", scan.records.len() as i64),
                    ]),
                )?;
                return Err(BackendError::unavailable());
            }
            let (outcome, code, recovery) = if scan.scanned_source_count == 0
                && scan.skipped_source_count == 0
                && scan.deleted_source_file_ids.is_empty()
            {
                (
                    DiagnosticAttemptOutcome::NoWork,
                    Some(DiagnosticAttemptCode::NoWork),
                    DiagnosticRecovery::None,
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
                    if transient {
                        DiagnosticRecovery::Automatic
                    } else if malformed {
                        DiagnosticRecovery::UpdateSource
                    } else {
                        DiagnosticRecovery::CheckAccess
                    },
                )
            } else {
                (
                    DiagnosticAttemptOutcome::Success,
                    None,
                    DiagnosticRecovery::None,
                )
            };
            self.finish_attempt(
                attempt,
                outcome,
                code,
                recovery,
                metrics([
                    ("scanned_sources", scan.scanned_source_count as i64),
                    ("skipped_sources", scan.skipped_source_count as i64),
                    ("indexed_records", scan.records.len() as i64),
                    ("reason_count", scan.coverage.reasons.len() as i64),
                ]),
            )?;
            agents.push(AgentUsage {
                coverage: scan.coverage.clone(),
            });
        }
        let events = self
            .state
            .usage_events()
            .map_err(|_| BackendError::unavailable())?;
        let rows = usage::aggregate_usage_events(&events, &timezone).map_err(|_| BackendError {
            error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
        })?;
        Ok(UsageCollection {
            timezone,
            generated_at: now_rfc3339(),
            agents,
            rows,
        })
    }

    fn usage_report(
        &self,
        usage: &UsageCollection,
        catalog: Option<&pricing::PricingCatalog>,
        model_catalog: Option<&crate::model_catalog::ModelCatalog>,
    ) -> Result<Value, BackendError> {
        let rows = &usage.rows;
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
        let generated_at =
            usage::parse_instant(&usage.generated_at).ok_or_else(|| BackendError {
                error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
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
                local_usage_detail(
                    period,
                    rows,
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
        let today = usage_period_range(UsagePeriod::Today, &usage.timezone, generated_at)?.0;
        let (from, to) = usage_date_range(rows, &today);
        Ok(json!({
            "protocol_version": LOCAL_USAGE_PROTOCOL,
            "generated_at": usage.generated_at,
            "aggregation_timezone": usage.timezone,
            "range": {"from": from, "to": to},
            "status": status,
            "model_catalog_revision": model_catalog.map(|value| value.revision.clone()),
            "coverage": coverage
        }))
    }

    fn refresh_pricing(&self) -> Result<Value, BackendError> {
        let attempt = self.begin_attempt(
            DiagnosticAttemptKind::PricingRefresh,
            DiagnosticSource::System,
            None,
            DiagnosticMode::Required,
        )?;
        let result = self.refresh_pricing_inner();
        let entry_count = result
            .as_ref()
            .ok()
            .and_then(|value| value.get("entries"))
            .and_then(Value::as_array)
            .map(|values| values.len() as i64)
            .unwrap_or(0);
        self.finish_backend_result_attempt(
            attempt,
            &result,
            metrics([("pricing_catalog", 1), ("entries", entry_count)]),
        )?;
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
                self.state
                    .commit_pricing_catalog(&value, next_etag.as_deref().or(etag.as_deref()))
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((next_etag, None)) => {
                let Some(value) = local else {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                    });
                };
                if !pricing::validate_pricing_catalog(&value).valid {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                    });
                }
                self.state
                    .commit_pricing_catalog(&value, next_etag.as_deref().or(etag.as_deref()))
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((_, Some(_))) => Err(BackendError {
                error: IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry),
            }),
            Err(error) => Err(BackendError {
                error: crate::relay::relay_error_for_backend(error),
            }),
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
                self.state
                    .commit_model_catalog(&value, next_etag.as_deref().or(etag.as_deref()))
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((next_etag, None)) => {
                let Some(value) = local else {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                    });
                };
                if !crate::model_catalog::validate_model_catalog_value(&value).valid {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                    });
                }
                self.state
                    .commit_model_catalog(&value, next_etag.as_deref().or(etag.as_deref()))
                    .map_err(|_| BackendError::unavailable())?;
                Ok(value)
            }
            Ok((_, Some(_))) => Err(BackendError {
                error: IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry),
            }),
            Err(error) => Err(BackendError {
                error: crate::relay::relay_error_for_backend(error),
            }),
        }
    }

    fn stage_outbox(&self, timezone: &str) -> Result<bool, BackendError> {
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
        let lower_bound = DateTime::parse_from_rfc3339(&effective_usage_lower_bound(&session)?)
            .map_err(|_| invalid_local_state())?;
        let existing = self
            .state
            .outbox_entries_for(account_id, device_id, generation)
            .map_err(|_| BackendError::unavailable())?;
        let mut stage_slots = usage_stage_slots(existing.len());
        if stage_slots == 0 {
            return Ok(false);
        }
        let mut blocked_unrepresentable = false;
        let mut sequence = session
            .get("next_usage_sequence")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        for entry in &existing {
            if let Some(value) = entry.get("sequence").and_then(Value::as_u64) {
                sequence = sequence.max(value.saturating_add(1));
            }
        }
        let dirty_ranges = self
            .state
            .dirty_usage_ranges()
            .map_err(|_| BackendError::unavailable())?;
        let partial_hours = self
            .state
            .partial_usage_hours()
            .map_err(|_| BackendError::unavailable())?;
        let events = self
            .state
            .usage_events()
            .map_err(|_| BackendError::unavailable())?;
        // Aggregate the retained event history once. Re-scanning and re-parsing every event for
        // each candidate hour made a long history quadratic during staging.
        let aggregate_events = events
            .iter()
            .filter(|event| {
                DateTime::parse_from_rfc3339(&event.occurred_at)
                    .ok()
                    .is_some_and(|occurred| occurred >= lower_bound)
            })
            .cloned()
            .collect::<Vec<_>>();
        let aggregated_rows = usage::aggregate_usage_events(&aggregate_events, timezone)
            .map_err(|_| BackendError::unavailable())?;
        let mut rows_by_hour = HashMap::<(UsageAgent, String), Vec<UsageHourlyFact>>::new();
        for row in aggregated_rows {
            rows_by_hour
                .entry((row.agent, row.bucket_start_utc.clone()))
                .or_default()
                .push(row);
        }
        let complete_until = DateTime::parse_from_rfc3339(&floor_utc_hour(&Utc::now()))
            .map_err(|_| BackendError::unavailable())?;
        for range in &dirty_ranges {
            if !self
                .state
                .usage_upload_enabled()
                .map_err(|_| BackendError::unavailable())?
            {
                return Ok(false);
            }
            if !self
                .state
                .active_session_at_epoch(session_epoch)
                .map_err(|_| BackendError::unavailable())?
            {
                return Err(BackendError {
                    error: IpcError::new(ErrorCode::AuthenticationRequired, RecoveryAction::Login),
                });
            }
            let mut start = DateTime::parse_from_rfc3339(&range.start_at)
                .map_err(|_| BackendError::unavailable())?;
            let end = DateTime::parse_from_rfc3339(&range.end_at)
                .map_err(|_| BackendError::unavailable())?;
            let eligible_end = end.min(complete_until);
            while start < eligible_end {
                // Usage is immutable at UTC-hour granularity. Grow the largest deterministic
                // contiguous chunk that fits every released boundary; never truncate rows.
                let first_end = (start + chrono::Duration::hours(1)).min(eligible_end);
                let first_partial = partial_hours.contains(&(
                    range.agent,
                    start.to_rfc3339_opts(SecondsFormat::Secs, true),
                ));
                let mut chunk_rows =
                    usage_rows_for_range(&rows_by_hour, range.agent, &start, &first_end);
                let first_context = UsageSubmissionContext {
                    agent: range.agent,
                    start: &start,
                    end: &first_end,
                    timezone,
                    account_id,
                    device_id,
                    generation,
                    partial: first_partial,
                };
                if !usage_submission_fits(&first_context, sequence, &chunk_rows) {
                    let consumed = UsageDirtyRange {
                        agent: range.agent,
                        start_at: start.to_rfc3339_opts(SecondsFormat::Secs, true),
                        end_at: first_end.to_rfc3339_opts(SecondsFormat::Secs, true),
                    };
                    if let Some((batch_id, submissions)) =
                        usage_multipart_submissions(&first_context, sequence, &chunk_rows)
                    {
                        if !self
                            .state
                            .usage_upload_enabled()
                            .map_err(|_| BackendError::unavailable())?
                        {
                            return Ok(false);
                        }
                        if submissions.len() > stage_slots {
                            // Durable outbox capacity is separate from this refresh's drain
                            // budget. Wait for enough capacity to stage the complete batch.
                            return Ok(blocked_unrepresentable);
                        }
                        if self
                            .state
                            .stage_multipart_outbox_entries(
                                account_id,
                                device_id,
                                generation,
                                &batch_id,
                                &consumed,
                                &submissions,
                            )
                            .map_err(|_| BackendError::unavailable())?
                        {
                            sequence = sequence.saturating_add(submissions.len() as u64);
                            stage_slots -= submissions.len();
                            if stage_slots == 0 {
                                return Ok(blocked_unrepresentable);
                            }
                        }
                        start = first_end;
                        continue;
                    }
                    blocked_unrepresentable = true;
                    start = first_end;
                    continue;
                }
                let mut chunk_end = first_end;
                while chunk_end < eligible_end
                    && chunk_end - start < chrono::Duration::hours(usage::MAX_USAGE_COVERAGE_HOURS)
                {
                    let next_end = (chunk_end + chrono::Duration::hours(1)).min(eligible_end);
                    let next_partial = partial_hours.contains(&(
                        range.agent,
                        chunk_end.to_rfc3339_opts(SecondsFormat::Secs, true),
                    ));
                    if next_partial != first_partial {
                        break;
                    }
                    let next_rows =
                        usage_rows_for_range(&rows_by_hour, range.agent, &start, &next_end);
                    let next_context = UsageSubmissionContext {
                        agent: range.agent,
                        start: &start,
                        end: &next_end,
                        timezone,
                        account_id,
                        device_id,
                        generation,
                        partial: first_partial,
                    };
                    if !usage_submission_fits(&next_context, sequence, &next_rows) {
                        break;
                    }
                    chunk_end = next_end;
                    chunk_rows = next_rows;
                }
                let context = UsageSubmissionContext {
                    agent: range.agent,
                    start: &start,
                    end: &chunk_end,
                    timezone,
                    account_id,
                    device_id,
                    generation,
                    partial: first_partial,
                };
                let submission = usage_submission(&context, sequence, &chunk_rows)
                    .ok_or_else(BackendError::unavailable)?;
                let consumed = UsageDirtyRange {
                    agent: range.agent,
                    start_at: start.to_rfc3339_opts(SecondsFormat::Secs, true),
                    end_at: chunk_end.to_rfc3339_opts(SecondsFormat::Secs, true),
                };
                if !self
                    .state
                    .usage_upload_enabled()
                    .map_err(|_| BackendError::unavailable())?
                {
                    return Ok(false);
                }
                if self
                    .state
                    .stage_outbox_entry(account_id, &submission, &consumed)
                    .map_err(|_| BackendError::unavailable())?
                {
                    sequence = sequence.saturating_add(1);
                    stage_slots -= 1;
                    if stage_slots == 0 {
                        return Ok(blocked_unrepresentable);
                    }
                }
                start = chunk_end;
            }
        }
        Ok(blocked_unrepresentable)
    }

    fn drain_outbox(&self) -> Result<bool, BackendError> {
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
        if session.get("status").and_then(Value::as_str) != Some("active")
            || !self
                .state
                .active_session_at_epoch(session_epoch)
                .map_err(|_| BackendError::unavailable())?
        {
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
        let entries = self
            .state
            .outbox_entries_for(account_id, device_id, generation)
            .map_err(|_| BackendError::unavailable())?;
        let mut rejected = false;
        for entry in entries.into_iter().take(MAX_USAGE_OUTBOX_ENTRIES) {
            if !self
                .state
                .usage_upload_enabled()
                .map_err(|_| BackendError::unavailable())?
            {
                return Ok(rejected);
            }
            let submission_id = entry
                .get("submission_id")
                .and_then(Value::as_str)
                .ok_or_else(BackendError::unavailable)?;
            let sequence = entry
                .get("sequence")
                .and_then(Value::as_u64)
                .ok_or_else(BackendError::unavailable)?;
            let response = self.account.upload_usage(&entry)?;
            if response.get("device_id").and_then(Value::as_str) != Some(device_id)
                || response.get("device_generation").and_then(Value::as_u64) != Some(generation)
            {
                return Err(BackendError {
                    error: IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry),
                });
            }
            let outcome = response
                .get("outcome")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match outcome {
                "accepted" | "duplicate" => {
                    if response.get("accepted_sequence").and_then(Value::as_u64) != Some(sequence) {
                        return Err(BackendError {
                            error: IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry),
                        });
                    }
                    self.account.record_usage_response(&response)?;
                    self.state
                        .acknowledge_outbox_entry(submission_id)
                        .map_err(|_| BackendError::unavailable())?;
                }
                "rejected" => {
                    if response
                        .get("accepted_sequence")
                        .is_none_or(|value| !value.is_null())
                        || response.get("next_sequence").and_then(Value::as_u64)
                            != Some(sequence.saturating_add(1))
                        || response.get("rejection_reason").and_then(Value::as_str)
                            != Some("duplicate_fact_identity")
                    {
                        return Err(BackendError {
                            error: IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry),
                        });
                    }
                    self.account.record_usage_response(&response)?;
                    self.state
                        .acknowledge_outbox_entry(submission_id)
                        .map_err(|_| BackendError::unavailable())?;
                    rejected = true;
                }
                "partial" => break,
                "stale_generation" => {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::StaleGeneration, RecoveryAction::Login),
                    });
                }
                "deleted" => {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::DeviceDeleted, RecoveryAction::Login),
                    });
                }
                "sequence_conflict" => {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall),
                    });
                }
                _ => return Err(BackendError::unavailable()),
            }
        }
        Ok(rejected)
    }

    fn timezone(&self) -> String {
        crate::providers::common::resolve_timezone(&self.environment)
            .name()
            .to_owned()
    }

    fn refresh_account_usage_periods(
        &self,
        account_value: &Value,
        cancel: &AtomicBool,
    ) -> Result<(), BackendError> {
        let mut periods = Vec::new();
        if let Some(all) = account_value
            .get("account_summary")
            .and_then(|summary| summary.get("usage"))
            .cloned()
        {
            push_account_usage_period(&mut periods, UsagePeriod::All, all);
        }
        let timezone = self.timezone();
        for period in [
            UsagePeriod::Today,
            UsagePeriod::Last7Days,
            UsagePeriod::Last30Days,
        ] {
            let (_, range) = usage_period_range(period, &timezone, Utc::now())?;
            let (from, to) = range.ok_or_else(BackendError::unavailable)?;
            let query = format!("cost_mode=auto&from={from}&to={to}");
            match self.account.account_usage(&query, cancel) {
                Ok(usage) => push_account_usage_period(&mut periods, period, usage),
                Err(error) if error.error.code.requires_login() => return Err(error),
                Err(_) => {}
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

    fn build_overview(&self, quota: &Value, account: Option<&Value>) -> Vec<QuotaOverviewItem> {
        let mut items = Vec::new();
        let now = Utc::now();
        if let Some(results) = quota.get("results").and_then(Value::as_array) {
            for result in results {
                for snapshot in result
                    .get("snapshots")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    if let Some(item) = overview_item(snapshot, "local", "Local", None, now) {
                        merge_overview_item(&mut items, item);
                    }
                }
            }
        }
        if let Some(summary) = account
            .and_then(|value| value.get("account_summary"))
            .and_then(Value::as_object)
        {
            // The account summary replays what this device uploaded. Local collection is
            // the only authority for this device, so reading its own upload back would keep
            // a rejected or removed local source on screen as another device's report.
            let this_device = account
                .and_then(|value| value.get("device_id"))
                .and_then(Value::as_str);
            let display_names = summary
                .get("devices")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|device| {
                    Some((
                        device.get("device_id")?.as_str()?.to_owned(),
                        device.get("display_name")?.as_str()?.to_owned(),
                    ))
                })
                .collect::<HashMap<_, _>>();
            if let Some(observations) = summary.get("quota").and_then(Value::as_array) {
                for observation in observations {
                    let Some(device_id) = observation.get("device_id").and_then(Value::as_str)
                    else {
                        continue;
                    };
                    if Some(device_id) == this_device {
                        continue;
                    }
                    let Some(snapshot) = observation.get("snapshot") else {
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
                    let display_name = display_names
                        .get(device_id)
                        .map(String::as_str)
                        .unwrap_or("Other device");
                    if let Some(item) = overview_item(
                        snapshot,
                        &format!("device:{device_id}"),
                        display_name,
                        Some(device_id),
                        now,
                    ) {
                        merge_overview_item(&mut items, item);
                    }
                }
            }
        }
        sort_overview_items(&mut items);
        items
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
/// Only a reading that is still current is worth restating, and that is also what makes
/// this terminate. A reading that already aged out says nothing new: every reader reached
/// that verdict from the reading itself. A reading that is current is restated once,
/// because the restatement is no longer `available` and so is no longer current. Whether
/// the account this compares against was fetched a moment or an hour ago cannot turn that
/// into a row rewritten on every refresh.
fn failure_status_snapshots(
    report: &Value,
    account: Option<&Value>,
    device_id: &str,
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
    account
        .and_then(|value| value.get("account_summary"))
        .and_then(|value| value.get("quota"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|observation| {
            observation.get("device_id").and_then(Value::as_str) == Some(device_id)
        })
        .filter_map(|observation| {
            let snapshot = observation.get("snapshot")?;
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
            "snapshots": []
        });
    }
    let mut snapshots = Vec::new();
    let mut failure = None;
    for session in sessions {
        match providers::collect(provider, &session, context) {
            // Expiry is derived from the reading itself by whoever reads it, so this
            // uploads the observation and nothing about how long it stays current.
            Ok(snapshot) => snapshots.push(serde_json::to_value(&snapshot).unwrap_or(Value::Null)),
            Err(error) => failure = Some(error.category),
        }
    }
    if snapshots.is_empty() {
        let category = failure.unwrap_or(ErrorCategory::Unavailable);
        let mut result =
            json!({"provider": provider, "outcome": category.as_str(), "snapshots": []});
        // A discovered source that answers `auth_required` is a sign-in this machine still
        // holds and the provider no longer accepts. That is a different recovery from a
        // provider that was never set up here, so it is reported as its own message.
        if category == ErrorCategory::AuthRequired {
            result["message"] = json!("The saved sign-in expired or was rejected. Sign in again.");
        }
        if category == ErrorCategory::AccessDenied {
            result["access_denied"] = json!(true);
            result["message"] =
                json!("A saved sign-in is stored here but this Mac was refused it. Check access.");
        }
        result
    } else {
        json!({
            "provider": provider,
            "outcome": "success",
            "snapshots": snapshots
        })
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

    fn publish_device_health(&self, report: &DiagnosticReport) -> Result<(), BackendError> {
        let session = self
            .state
            .session_json()
            .map_err(|_| BackendError::unavailable())?;
        if !session
            .as_ref()
            .is_some_and(|value| value.get("status").and_then(Value::as_str) == Some("active"))
        {
            return Ok(());
        }
        let usage_upload_enabled = self
            .state
            .usage_upload_enabled()
            .map_err(|_| BackendError::unavailable())?;
        let last_account_sync = self
            .state
            .diagnostic_attempt_facts(
                DiagnosticAttemptKind::AccountSync,
                DiagnosticSource::Account,
                None,
            )
            .map_err(|_| BackendError::unavailable())?
            .latest_success
            .as_ref()
            .map(diagnostic_attempt_timestamp);
        let relevant_attempt = self
            .state
            .latest_diagnostic_problem(usage_upload_enabled)
            .map_err(|_| BackendError::unavailable())?;
        let summary_is_healthy = report.summary.operation == DiagnosticOperation::Healthy
            && matches!(
                report.summary.data,
                DiagnosticDataState::Current | DiagnosticDataState::Empty
            )
            && matches!(
                report.summary.attention,
                DiagnosticAttention::None | DiagnosticAttention::Automatic
            );
        let top_code = (!summary_is_healthy)
            .then(|| {
                relevant_attempt
                    .as_ref()
                    .map(device_health_code_for_attempt)
            })
            .flatten();
        let consecutive_failures = self
            .state
            .consecutive_refresh_failures()
            .map_err(|_| BackendError::unavailable())? as i64;
        let client_product = match self.client_name.as_str() {
            "QuotaBar" => "quotabar",
            "QuotaCLI" => "quotacli",
            _ => return Ok(()),
        };
        let platform = match std::env::consts::OS {
            "macos" => "macos",
            "linux" => "linux",
            _ => return Ok(()),
        };
        let signal = json!({
            "schema_version": 1,
            "client_product": client_product,
            "client_version": self.client_version,
            "platform": platform,
            "summary": report.summary,
            "top_code": top_code,
            "consecutive_failures": consecutive_failures,
            "usage_upload_enabled": usage_upload_enabled,
            "last_successful_account_sync_at": last_account_sync,
        });
        let digest = format!("{:x}", Sha256::digest(signal.to_string().as_bytes()));
        let observed = Utc::now();
        if !self
            .state
            .device_health_upload_due(&digest, observed)
            .map_err(|_| BackendError::unavailable())?
        {
            return Ok(());
        }
        let parent = self
            .state
            .latest_refresh_attempt()
            .map_err(|_| BackendError::unavailable())?;
        let attempt = self
            .state
            .begin_diagnostic_attempt(
                DiagnosticAttemptKind::DeviceHealthUpload,
                parent
                    .map(|(_, trigger)| trigger)
                    .unwrap_or(DiagnosticAttemptTrigger::Scheduled),
                DiagnosticSource::Account,
                None,
                DiagnosticMode::Required,
                parent.map(|(handle, _)| handle),
            )
            .map_err(|_| BackendError::unavailable())?;
        let observed_at = observed.to_rfc3339_opts(SecondsFormat::Secs, true);
        let payload = json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "schema_version": 1,
            "client_product": client_product,
            "client_version": self.client_version,
            "platform": platform,
            "observed_at": observed_at,
            "refresh_revision": report.refresh.revision,
            "last_completed_refresh_at": report.refresh.as_of,
            "last_successful_account_sync_at": last_account_sync,
            "summary": report.summary,
            "top_code": top_code,
            "consecutive_failures": consecutive_failures,
            "usage_upload_enabled": usage_upload_enabled,
        });
        let result = self.account.upload_device_health(&payload);
        match &result {
            Ok(response) => {
                let ignored =
                    response.get("status").and_then(Value::as_str) == Some("ignored_stale");
                if !ignored {
                    let received_at = response
                        .get("received_at")
                        .and_then(Value::as_str)
                        .ok_or_else(BackendError::unavailable)?;
                    self.state
                        .record_device_health_upload(report.refresh.revision, &digest, received_at)
                        .map_err(|_| BackendError::unavailable())?;
                }
                self.finish_attempt(
                    attempt,
                    if ignored {
                        DiagnosticAttemptOutcome::NoWork
                    } else {
                        DiagnosticAttemptOutcome::Success
                    },
                    ignored.then_some(DiagnosticAttemptCode::NoWork),
                    DiagnosticRecovery::None,
                    BTreeMap::new(),
                )?;
            }
            Err(error) => {
                let (outcome, code, recovery) = backend_attempt_error(&error.error);
                self.finish_attempt(attempt, outcome, Some(code), recovery, BTreeMap::new())?;
            }
        }
        result.map(|_| ())
    }

    fn validate_provider_browser_session(
        &self,
        provider: ProviderId,
        cookie_header: &str,
    ) -> Result<crate::providers::ValidatedBrowserSession, BackendError> {
        let context = self.collection_context(Arc::new(AtomicBool::new(false)))?;
        providers::validate_browser_session(provider, cookie_header, &context).map_err(|error| {
            BackendError {
                error: match error.category {
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
                },
            }
        })
    }

    fn refresh(&self, cancel: Arc<AtomicBool>) -> RefreshOutcome {
        let quota_cancel = cancel.clone();
        let usage_cancel = cancel.clone();
        let (quota, usage) = thread::scope(|scope| {
            let quota_job = scope.spawn(|| self.collect_quota(quota_cancel));
            let usage_job = scope.spawn(|| self.collect_usage(usage_cancel));
            let quota_result = quota_job
                .join()
                .unwrap_or_else(|_| Err(BackendError::unavailable()));
            let usage_result = usage_job
                .join()
                .unwrap_or_else(|_| Err(BackendError::unavailable()));
            (quota_result, usage_result)
        });
        let cached_catalog = self
            .state
            .component(crate::protocol::ComponentName::Pricing)
            .ok()
            .flatten()
            .and_then(|component| component.value)
            .and_then(|value| serde_json::from_value(value).ok());
        let cached_model_catalog = self.state.model_catalog().ok().flatten().and_then(|value| {
            crate::model_catalog::validate_model_catalog_value(&value)
                .valid
                .then(|| serde_json::from_value(value).ok())
                .flatten()
        });
        if self.state.last_persistence_requires_abort() {
            let usage_value = match usage.as_ref().ok() {
                Some(value) => self.usage_report(
                    value,
                    cached_catalog.as_ref(),
                    cached_model_catalog.as_ref(),
                ),
                None => Err(BackendError::unavailable()),
            };
            return RefreshOutcome {
                quota,
                usage: usage_value,
                account: Err(BackendError::unavailable()),
                pricing: Err(BackendError::unavailable()),
                overview: None,
            };
        }
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
        if self.state.last_persistence_requires_abort() {
            return RefreshOutcome {
                quota: quota_value,
                usage: usage_value,
                account: Err(BackendError::unavailable()),
                pricing: Err(BackendError::unavailable()),
                overview: None,
            };
        }
        // One read for the two things that need last refresh's account: restating this
        // device's failed readings before the upload, and filling the Overview after it.
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
        let mut account_value: Result<Value, BackendError> = Err(BackendError {
            error: IpcError::new(ErrorCode::AuthenticationRequired, RecoveryAction::Login),
        });
        let mut overview = None;
        match self.state.session_json() {
            _ if cancel.load(Ordering::Acquire) => {
                account_value = Err(BackendError::cancelled());
            }
            Ok(Some(session))
                if session.get("status").and_then(Value::as_str) == Some("active") =>
            {
                match self.begin_attempt(
                    DiagnosticAttemptKind::AccountSync,
                    DiagnosticSource::Account,
                    None,
                    DiagnosticMode::Required,
                ) {
                    Ok(account_attempt) => match self.account.sync_control_and_update() {
                        Ok(_) if cancel.load(Ordering::Acquire) => {
                            account_value = Err(BackendError::cancelled());
                        }
                        Ok(_) => {
                            let current_session =
                                self.state.session_json().ok().flatten().unwrap_or(session);
                            let mut account_sync_error = None;
                            let mut attempt_journal_error = None;
                            let mut stage_blocked = false;
                            if let Ok(quota_payload) = &quota_value {
                                let device_id = current_session
                                    .get("device_id")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default();
                                let restated = failure_status_snapshots(
                                    quota_payload,
                                    stored_account.as_ref(),
                                    device_id,
                                    Utc::now(),
                                );
                                if let Err(error) =
                                    self.account.upload_quota_report(quota_payload, &restated)
                                {
                                    record_account_sync_error(&mut account_sync_error, error);
                                }
                            }
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
                            if usage_upload_enabled
                                && let Some(usage_collection) = usage_collection.as_ref()
                            {
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
                                                &usage_collection.timezone,
                                                &lower_bound,
                                            )
                                            .map_err(|_| BackendError::unavailable())
                                    });
                                if let Err(error) = context_result {
                                    record_account_sync_error(&mut account_sync_error, error);
                                } else {
                                    match self.stage_outbox(&usage_collection.timezone) {
                                        Ok(blocked) => stage_blocked = blocked,
                                        Err(error) => record_account_sync_error(
                                            &mut account_sync_error,
                                            error,
                                        ),
                                    }
                                }
                            }
                            if usage_upload_enabled && account_sync_error.is_none() {
                                let before = self
                                    .state
                                    .outbox_entries()
                                    .ok()
                                    .map(|entries| entries.len() as i64)
                                    .unwrap_or(0);
                                match self.begin_attempt(
                                    DiagnosticAttemptKind::UsageUpload,
                                    DiagnosticSource::Account,
                                    None,
                                    DiagnosticMode::Required,
                                ) {
                                    Ok(upload_attempt) => match self.drain_outbox() {
                                        Ok(rejected) => {
                                            let pending = self
                                                .state
                                                .outbox_entries()
                                                .ok()
                                                .map(|entries| entries.len() as i64)
                                                .unwrap_or(0);
                                            let attempted = before.saturating_sub(pending);
                                            let (outcome, code, recovery) = match (
                                                stage_blocked,
                                                rejected,
                                                attempted,
                                            ) {
                                                (true, _, _) => (
                                                    DiagnosticAttemptOutcome::Failed,
                                                    Some(
                                                        DiagnosticAttemptCode::UnrepresentableHour,
                                                    ),
                                                    DiagnosticRecovery::Feedback,
                                                ),
                                                (false, true, _) => (
                                                    DiagnosticAttemptOutcome::Failed,
                                                    Some(DiagnosticAttemptCode::InvalidUsageBatch),
                                                    DiagnosticRecovery::UpdateSource,
                                                ),
                                                (false, false, 0) => (
                                                    DiagnosticAttemptOutcome::NoWork,
                                                    Some(DiagnosticAttemptCode::NoWork),
                                                    DiagnosticRecovery::None,
                                                ),
                                                (false, false, _) => (
                                                    DiagnosticAttemptOutcome::Success,
                                                    None,
                                                    DiagnosticRecovery::None,
                                                ),
                                            };
                                            let _ = self.finish_attempt(
                                                upload_attempt,
                                                outcome,
                                                code,
                                                recovery,
                                                metrics([
                                                    ("attempted", attempted),
                                                    ("pending", pending),
                                                ]),
                                            );
                                        }
                                        Err(error) => {
                                            let (outcome, code, recovery) =
                                                backend_attempt_error(&error.error);
                                            let _ = self.finish_attempt(
                                                upload_attempt,
                                                outcome,
                                                Some(code),
                                                recovery,
                                                metrics([("attempted", 0), ("pending", before)]),
                                            );
                                            record_account_sync_error(
                                                &mut account_sync_error,
                                                error,
                                            );
                                        }
                                    },
                                    Err(error) => {
                                        attempt_journal_error = Some(error.clone());
                                        record_account_sync_error(&mut account_sync_error, error)
                                    }
                                }
                            }
                            account_value = account_read_after_sync(
                                account_sync_error,
                                cancel.load(Ordering::Acquire),
                                || self.account.refresh_account_state(cancel.as_ref()),
                            );
                            if usage_upload_enabled
                                && let Ok(value) = &account_value
                                && let Err(error) =
                                    self.refresh_account_usage_periods(value, cancel.as_ref())
                                && error.error.code.requires_login()
                            {
                                account_value = Err(error);
                            }
                            if account_value
                                .as_ref()
                                .err()
                                .is_some_and(|error| error.error.code.requires_login())
                            {
                                self.clear_active_session();
                            }
                            let device_count = account_value
                                .as_ref()
                                .ok()
                                .and_then(|value| value.get("account_summary"))
                                .and_then(|value| value.get("devices"))
                                .and_then(Value::as_array)
                                .map(|values| values.len() as i64)
                                .unwrap_or(0);
                            if let Some(error) = attempt_journal_error {
                                let (outcome, code, recovery) = backend_attempt_error(&error.error);
                                let _ = self.finish_attempt(
                                    account_attempt,
                                    outcome,
                                    Some(code),
                                    recovery,
                                    metrics([("devices", device_count)]),
                                );
                            } else {
                                let _ = self.finish_backend_result_attempt(
                                    account_attempt,
                                    &account_value,
                                    metrics([("devices", device_count)]),
                                );
                            }
                        }
                        Err(error) => {
                            let (outcome, code, recovery) = backend_attempt_error(&error.error);
                            let _ = self.finish_attempt(
                                account_attempt,
                                outcome,
                                Some(code),
                                recovery,
                                BTreeMap::new(),
                            );
                            if error.error.code.requires_login() {
                                self.clear_active_session();
                            }
                            account_value = Err(error);
                        }
                    },
                    Err(error) => account_value = Err(error),
                }
            }
            Ok(Some(session))
                if session.get("status").and_then(Value::as_str) == Some("logout_pending") =>
            {
                match self.account.logout(&session) {
                    Ok(()) => {
                        self.clear_pending_session();
                        account_value = Err(BackendError {
                            error: IpcError::new(
                                ErrorCode::AuthenticationRequired,
                                RecoveryAction::Login,
                            ),
                        });
                    }
                    Err(error) => account_value = Err(error),
                }
            }
            Ok(None) => {}
            Ok(Some(_)) => {
                account_value = Err(BackendError {
                    error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall),
                });
            }
            Err(_) => account_value = Err(BackendError::unavailable()),
        }
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

    fn login(&self, _: &str, cancel: Arc<AtomicBool>) -> Result<LoginOutcome, BackendError> {
        self.account.login(cancel.as_ref())
    }

    fn logout(&self, pending_session: &Value) -> Result<(), BackendError> {
        self.account.logout(pending_session)
    }
}

impl NativeBackend {
    fn clear_active_session(&self) {
        if let Ok(Some((session, epoch))) = self.state.session_snapshot()
            && session.get("status").and_then(Value::as_str) == Some("active")
        {
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
    rows: Vec<UsageHourlyFact>,
}

struct AgentUsage {
    coverage: usage::ScanCoverage,
}

fn usage_period_range(
    period: UsagePeriod,
    timezone: &str,
    now: DateTime<Utc>,
) -> Result<(String, Option<(String, String)>), BackendError> {
    let timezone = Tz::from_str(timezone).map_err(|_| BackendError::unavailable())?;
    let today = now.with_timezone(&timezone).date_naive();
    let today_text = today.format("%Y-%m-%d").to_string();
    let previous_days = match period {
        UsagePeriod::Today => Some(0),
        UsagePeriod::Last7Days => Some(6),
        UsagePeriod::Last30Days => Some(29),
        UsagePeriod::All => None,
    };
    let Some(previous_days) = previous_days else {
        return Ok((today_text, None));
    };
    let from = today
        .checked_sub_days(Days::new(previous_days))
        .ok_or_else(BackendError::unavailable)?
        .format("%Y-%m-%d")
        .to_string();
    Ok((today_text.clone(), Some((from, today_text))))
}

fn local_usage_detail(
    period: UsagePeriod,
    rows: &[UsageHourlyFact],
    timezone: &str,
    generated_at: DateTime<Utc>,
    pricing_catalog: Option<&pricing::PricingCatalog>,
    model_catalog: Option<&crate::model_catalog::ModelCatalog>,
    incomplete: bool,
) -> Result<Value, BackendError> {
    let (today, range) = usage_period_range(period, timezone, generated_at)?;
    let selected_rows = match &range {
        Some((from, to)) => rows
            .iter()
            .filter(|row| {
                row.usage_date.as_str() >= from.as_str() && row.usage_date.as_str() <= to.as_str()
            })
            .cloned()
            .collect::<Vec<_>>(),
        None => rows.to_vec(),
    };
    let summary = usage::build_local_usage_summary(&selected_rows, pricing_catalog, model_catalog)
        .map_err(|_| BackendError::unavailable())?;
    let details_truncated = summary.models_truncated || summary.cost.unpriced_truncated;
    let (from, to) = range.unwrap_or_else(|| usage_date_range(&selected_rows, &today));
    Ok(json!({
        "range": {"from": from, "to": to},
        "usage": summary,
        "incomplete": incomplete,
        "details_truncated": details_truncated
    }))
}

fn push_account_usage_period(
    periods: &mut Vec<(UsagePeriod, Value)>,
    period: UsagePeriod,
    value: Value,
) {
    if let Ok(detail) = account_usage_detail(value) {
        periods.push((period, detail));
    }
}

fn account_usage_detail(value: Value) -> Result<Value, BackendError> {
    let object = value.as_object().ok_or_else(invalid_usage_detail)?;
    let totals = account_summary_totals(object.get("totals").ok_or_else(invalid_usage_detail)?)?;
    let cost = object
        .get("cost")
        .cloned()
        .ok_or_else(invalid_usage_detail)?;
    let agents = object
        .get("agents")
        .cloned()
        .ok_or_else(invalid_usage_detail)?;
    let incomplete = object.get("coverage").and_then(Value::as_str) == Some("partial");
    let breakdowns_truncated =
        object.get("breakdowns_truncated").and_then(Value::as_bool) == Some(true);
    let unpriced_truncated = cost.get("unpriced_truncated").and_then(Value::as_bool) == Some(true);
    let mut usage = json!({
        "totals": totals,
        "cost": cost,
        "agents": agents
    });
    if breakdowns_truncated {
        usage["models_truncated"] = Value::Bool(true);
    }
    Ok(json!({
        "range": object.get("range").cloned().ok_or_else(invalid_usage_detail)?,
        "usage": usage,
        "incomplete": incomplete,
        "details_truncated": breakdowns_truncated || unpriced_truncated
    }))
}

fn account_summary_totals(value: &Value) -> Result<Value, BackendError> {
    let object = value.as_object().ok_or_else(invalid_usage_detail)?;
    let count = |name: &str| {
        object
            .get(name)
            .and_then(Value::as_u64)
            .ok_or_else(invalid_usage_detail)
    };
    let input = count("input_tokens")?;
    let output = count("output_tokens")?;
    let cache_write_inferred = count("cache_write_inferred_tokens")?;
    let cache_write = count("cache_write_5m_tokens")?
        .checked_add(count("cache_write_1h_tokens")?)
        .and_then(|value| value.checked_add(cache_write_inferred))
        .ok_or_else(invalid_usage_detail)?;
    Ok(json!({
        "total_tokens": input.checked_add(output).ok_or_else(invalid_usage_detail)?,
        "input_tokens": input,
        "output_tokens": output,
        "cache_read_input_tokens": count("cache_read_tokens")?,
        "cache_write_input_tokens": cache_write,
        "reasoning_tokens": count("reasoning_tokens")?,
        "messages": count("requests")?
    }))
}

fn invalid_usage_detail() -> BackendError {
    BackendError {
        error: IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry),
    }
}

fn usage_date_range(rows: &[UsageHourlyFact], fallback_date: &str) -> (String, String) {
    let from = rows
        .iter()
        .map(|row| row.usage_date.clone())
        .min()
        .unwrap_or_else(|| fallback_date.to_owned());
    let to = rows
        .iter()
        .map(|row| row.usage_date.clone())
        .max()
        .unwrap_or_else(|| fallback_date.to_owned());
    (from, to)
}

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
    let complete_sources = scan
        .sources
        .iter()
        .filter(|source| source.coverage.status == CoverageStatus::Complete)
        .count();
    let partial_sources = scan.sources.len().saturating_sub(complete_sources);
    json!({
        "status": match scan.coverage.status {
            CoverageStatus::Complete => "complete",
            CoverageStatus::Partial => "partial",
        },
        "scanned_files": scan.scanned_source_count,
        "skipped_files": scan.skipped_source_count,
        "complete_files": complete_sources,
        "partial_files": partial_sources,
        "indexed_records": scan.records.len(),
        "valid_records": scan.records.len(),
        "ignored_empty_records": scan.ignored_empty_records,
        "reason_counts": reason_counts,
    })
}

fn effective_usage_lower_bound(session: &Value) -> Result<String, BackendError> {
    let left = session
        .get("upload_not_before")
        .and_then(Value::as_str)
        .ok_or_else(invalid_local_state)
        .and_then(|value| DateTime::parse_from_rfc3339(value).map_err(|_| invalid_local_state()))?;
    let right = match session.get("usage_deleted_before") {
        Some(Value::Null) => DateTime::parse_from_rfc3339("1970-01-01T00:00:00Z")
            .map_err(|_| invalid_local_state())?,
        Some(Value::String(value)) => {
            DateTime::parse_from_rfc3339(value).map_err(|_| invalid_local_state())?
        }
        _ => return Err(invalid_local_state()),
    };
    Ok(left.max(right).to_rfc3339_opts(SecondsFormat::AutoSi, true))
}

fn invalid_local_state() -> BackendError {
    BackendError {
        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall),
    }
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

/// After successful control sync, run the read-only account summary when allowed.
///
/// Non-authentication upload/staging/outbox failures stay in the sync diagnostic and must not
/// block the account summary. Session-authority failures and cancellation skip the account read.
fn account_read_after_sync<F>(
    sync_error: Option<BackendError>,
    cancelled: bool,
    read: F,
) -> Result<Value, BackendError>
where
    F: FnOnce() -> Result<Value, BackendError>,
{
    if cancelled {
        return Err(BackendError::cancelled());
    }
    if let Some(error) = sync_error
        && error.error.code.requires_login()
    {
        return Err(error);
    }
    read()
}

struct UsageSubmissionContext<'a> {
    agent: UsageAgent,
    start: &'a DateTime<chrono::FixedOffset>,
    end: &'a DateTime<chrono::FixedOffset>,
    timezone: &'a str,
    account_id: &'a str,
    device_id: &'a str,
    generation: u64,
    partial: bool,
}

fn usage_rows_for_range(
    rows_by_hour: &HashMap<(UsageAgent, String), Vec<UsageHourlyFact>>,
    agent: UsageAgent,
    start: &DateTime<chrono::FixedOffset>,
    end: &DateTime<chrono::FixedOffset>,
) -> Vec<UsageHourlyFact> {
    let mut rows = Vec::new();
    let mut hour = *start;
    while hour < *end {
        let key = (agent, hour.to_rfc3339_opts(SecondsFormat::Secs, true));
        if let Some(bucket_rows) = rows_by_hour.get(&key) {
            rows.extend(bucket_rows.iter().cloned());
        }
        hour += chrono::Duration::hours(1);
    }
    rows
}

fn usage_submission_fits(
    context: &UsageSubmissionContext<'_>,
    sequence: u64,
    rows: &[UsageHourlyFact],
) -> bool {
    if rows.len() > usage::MAX_USAGE_ROWS {
        return false;
    }
    let Some(submission) = usage_submission(context, sequence, rows) else {
        return false;
    };
    serde_json::to_vec(&submission)
        .ok()
        .is_some_and(|bytes| bytes.len() <= crate::relay::MAXIMUM_REQUEST_BYTES)
        && crate::relay::validate_usage_submission(&submission).is_ok()
}

fn usage_submission(
    context: &UsageSubmissionContext<'_>,
    sequence: u64,
    rows: &[UsageHourlyFact],
) -> Option<Value> {
    let submission_id = stable_range_submission_id(context, sequence, rows);
    let mut rows_value = serde_json::to_value(rows).ok()?;
    if let Some(row_values) = rows_value.as_array_mut() {
        for row in row_values {
            if row.get("source_cost_microusd").is_some_and(Value::is_null)
                && let Some(object) = row.as_object_mut()
            {
                object.remove("source_cost_microusd");
            }
        }
    }
    let mut submission = json!({
        "protocol_version": MANAGED_DATA_PROTOCOL,
        "submission_id": submission_id,
        "device_id": context.device_id,
        "generation": context.generation,
        "sequence": sequence,
        "parser_revision": PARSER_REVISION,
        "aggregation_timezone": context.timezone,
        "coverage": {
            "agent": context.agent,
            "start_at": context.start.to_rfc3339_opts(SecondsFormat::Secs, true),
            "end_at": context.end.to_rfc3339_opts(SecondsFormat::Secs, true),
            "status": if context.partial { "partial" } else { "complete" }
        },
        "rows": rows_value
    });
    if context.partial {
        submission["write_mode"] = json!("merge_partial");
    }
    Some(submission)
}

fn usage_multipart_submissions(
    context: &UsageSubmissionContext<'_>,
    sequence: u64,
    rows: &[UsageHourlyFact],
) -> Option<(String, Vec<Value>)> {
    if rows.is_empty()
        || rows.len() > usage::MAX_USAGE_ROWS.saturating_mul(MAX_USAGE_MULTIPART_PARTS)
    {
        return None;
    }
    let mut identities = HashSet::with_capacity(rows.len());
    for row in rows {
        let identity = serde_json::to_string(&(
            &row.bucket_start_utc,
            &row.usage_date,
            row.usage_hour,
            row.agent,
            row.billing_channel,
            row.channel_source,
            &row.model,
            row.context_bucket,
            &row.service_tier,
            &row.speed,
            &row.inference_geo,
        ))
        .ok()?;
        if !identities.insert(identity) {
            return None;
        }
    }
    let batch_id = stable_usage_batch_id(context, rows);
    // Use the maximum part count while packing. The final count can only make the metadata
    // smaller, so a part that fits this conservative envelope is safe at the final rebuild.
    let provisional_count = MAX_USAGE_MULTIPART_PARTS as u64;
    let mut ranges = Vec::<(usize, usize)>::new();
    let mut offset = 0usize;
    while offset < rows.len() {
        let max_len = (rows.len() - offset).min(usage::MAX_USAGE_ROWS);
        if !multipart_submission_fits(
            context,
            sequence.saturating_add(ranges.len() as u64),
            &batch_id,
            ranges.len() as u64,
            provisional_count,
            &rows[offset..offset + 1],
        ) {
            return None;
        }
        // Byte fit is monotonic over a prefix. Binary search keeps high-cardinality hours near
        // O(parts * log(rows)) instead of serializing every growing prefix.
        let mut low = 1usize;
        let mut high = max_len;
        while low < high {
            let middle = low + (high - low).div_ceil(2);
            if multipart_submission_fits(
                context,
                sequence.saturating_add(ranges.len() as u64),
                &batch_id,
                ranges.len() as u64,
                provisional_count,
                &rows[offset..offset + middle],
            ) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        let next = offset + low;
        ranges.push((offset, next));
        offset = next;
        if ranges.len() >= MAX_USAGE_MULTIPART_PARTS && offset < rows.len() {
            return None;
        }
    }
    if ranges.len() < 2 || ranges.len() > MAX_USAGE_MULTIPART_PARTS {
        return None;
    }
    let part_count = ranges.len() as u64;
    let submissions = ranges
        .iter()
        .enumerate()
        .map(|(part_index, (from, to))| {
            usage_multipart_submission(
                context,
                sequence.saturating_add(part_index as u64),
                &batch_id,
                part_index as u64,
                part_count,
                &rows[*from..*to],
            )
        })
        .collect::<Option<Vec<_>>>()?;
    submissions
        .iter()
        .all(|submission| {
            serde_json::to_vec(submission)
                .ok()
                .is_some_and(|bytes| bytes.len() <= crate::relay::MAXIMUM_REQUEST_BYTES)
                && crate::relay::validate_usage_submission(submission).is_ok()
        })
        .then_some((batch_id, submissions))
}

fn multipart_submission_fits(
    context: &UsageSubmissionContext<'_>,
    sequence: u64,
    batch_id: &str,
    part_index: u64,
    part_count: u64,
    rows: &[UsageHourlyFact],
) -> bool {
    usage_multipart_submission(context, sequence, batch_id, part_index, part_count, rows)
        .and_then(|submission| {
            serde_json::to_vec(&submission)
                .ok()
                .filter(|bytes| bytes.len() <= crate::relay::MAXIMUM_REQUEST_BYTES)
                .map(|_| submission)
        })
        .is_some_and(|submission| crate::relay::validate_usage_submission(&submission).is_ok())
}

fn usage_multipart_submission(
    context: &UsageSubmissionContext<'_>,
    sequence: u64,
    batch_id: &str,
    part_index: u64,
    part_count: u64,
    rows: &[UsageHourlyFact],
) -> Option<Value> {
    let mut submission = usage_submission(context, sequence, rows)?;
    submission["multipart"] = json!({
        "batch_id": batch_id,
        "part_index": part_index,
        "part_count": part_count
    });
    Some(submission)
}

fn stable_usage_batch_id(context: &UsageSubmissionContext<'_>, rows: &[UsageHourlyFact]) -> String {
    let material = json!({
        "parser_revision": PARSER_REVISION,
        "agent": context.agent,
        "aggregation_timezone": context.timezone,
        "account_id": context.account_id,
        "device_id": context.device_id,
        "generation": context.generation,
        "partial": context.partial,
        "start_at": context.start.to_rfc3339_opts(SecondsFormat::Secs, true),
        "end_at": context.end.to_rfc3339_opts(SecondsFormat::Secs, true),
        "rows": rows,
    });
    let digest = Sha256::digest(serde_json::to_vec(&material).unwrap_or_default());
    format!("usage_batch_{digest:x}")
}

fn stable_range_submission_id(
    context: &UsageSubmissionContext<'_>,
    sequence: u64,
    rows: &[UsageHourlyFact],
) -> String {
    let material = json!({
        "parser_revision": PARSER_REVISION,
        "agent": context.agent,
        "aggregation_timezone": context.timezone,
        "account_id": context.account_id,
        "device_id": context.device_id,
        "generation": context.generation,
        "sequence": sequence,
        "partial": context.partial,
        "start_at": context.start.to_rfc3339_opts(SecondsFormat::Secs, true),
        "end_at": context.end.to_rfc3339_opts(SecondsFormat::Secs, true),
        "rows": rows,
    });
    let digest = Sha256::digest(serde_json::to_vec(&material).unwrap_or_default());
    format!("usage_{digest:x}")
}

fn floor_utc_hour(value: &DateTime<Utc>) -> String {
    value
        .with_minute(0)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .unwrap_or(*value)
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn usage_stage_slots(existing_entries: usize) -> usize {
    MAX_USAGE_OUTBOX_ENTRIES.saturating_sub(existing_entries)
}

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
        }],
        selected_source_id: source_id.to_owned(),
        selected_source_display_name: display_name.to_owned(),
        is_stale: stale,
    })
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
        existing.selected_source_id = incoming.selected_source_id;
        existing.selected_source_display_name = incoming.selected_source_display_name;
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

    #[test]
    fn non_auth_sync_error_still_reads_account_summary() {
        let mut reads = 0;
        let result = account_read_after_sync(Some(BackendError::unavailable()), false, || {
            reads += 1;
            Ok(json!({"status": "active"}))
        });
        assert_eq!(reads, 1);
        assert_eq!(result.expect("account read"), json!({"status": "active"}));
    }

    #[test]
    fn requires_login_sync_error_skips_account_summary() {
        for code in [
            ErrorCode::AuthenticationRequired,
            ErrorCode::DeviceDeleted,
            ErrorCode::StaleGeneration,
        ] {
            let result = account_read_after_sync(
                Some(BackendError {
                    error: IpcError::new(code, RecoveryAction::Login),
                }),
                false,
                || panic!("account read must not run for requires-login sync error"),
            );
            let error = result.expect_err("expected skip");
            assert_eq!(error.error.code, code);
            assert!(error.error.code.requires_login());
        }
    }

    #[test]
    fn cancellation_skips_account_summary_even_with_non_auth_sync_error() {
        let result = account_read_after_sync(Some(BackendError::unavailable()), true, || {
            panic!("account read must not run when cancelled")
        });
        assert_eq!(
            result.expect_err("expected skip").error.code,
            ErrorCode::Cancelled
        );
        let result = account_read_after_sync(None, true, || {
            panic!("account read must not run when cancelled")
        });
        assert_eq!(
            result.expect_err("expected skip").error.code,
            ErrorCode::Cancelled
        );
    }

    #[test]
    fn successful_sync_reads_account_summary() {
        let mut reads = 0;
        let result = account_read_after_sync(None, false, || {
            reads += 1;
            Ok(json!({"plan": "pro"}))
        });
        assert_eq!(reads, 1);
        assert_eq!(result.expect("account read"), json!({"plan": "pro"}));
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
                BackendError {
                    error: IpcError::new(code, RecoveryAction::Login),
                },
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
            BackendError {
                error: IpcError::new(ErrorCode::AuthenticationRequired, RecoveryAction::Login),
            },
        );
        assert_eq!(
            slot.expect("promoted requires-login error").error.code,
            ErrorCode::AuthenticationRequired
        );
    }

    #[test]
    fn usage_periods_are_inclusive_and_use_the_service_timezone() {
        let now = DateTime::parse_from_rfc3339("2026-08-12T18:00:00Z")
            .expect("instant")
            .with_timezone(&Utc);
        assert_eq!(
            usage_period_range(UsagePeriod::Last7Days, "Asia/Singapore", now)
                .expect("range")
                .1,
            Some(("2026-08-07".into(), "2026-08-13".into()))
        );
        assert!(
            usage_period_range(UsagePeriod::All, "Asia/Singapore", now)
                .expect("range")
                .1
                .is_none()
        );
    }

    /// One statement per contract: the account read always carries its per-agent breakdown, so
    /// a summary without it is refused rather than rebuilt from the display breakdowns.
    #[test]
    fn account_usage_detail_requires_the_agent_breakdown() {
        let cost = json!({
            "mode": "calculate",
            "basis": "none",
            "status": "unavailable",
            "amount_microusd": null,
            "catalog_revision": null,
            "calculated_rows": 0,
            "reported_rows": 0,
            "unpriced_rows": 1,
            "assumptions": [],
            "unpriced": []
        });
        let totals = json!({
            "input_tokens": 8,
            "cache_read_tokens": 2,
            "cache_write_5m_tokens": 1,
            "cache_write_1h_tokens": 0,
            "cache_write_inferred_tokens": 0,
            "output_tokens": 5,
            "reasoning_tokens": 3,
            "requests": 2,
            "web_search_requests": 0,
            "web_fetch_requests": 0,
            "source_cost_microusd": null,
            "source_cost_covered_requests": 0
        });
        assert!(
            account_usage_detail(json!({
                "range": {"from": "2026-08-06", "to": "2026-08-12"},
                "totals": totals,
                "cost": cost,
                "coverage": "complete",
                "breakdowns": [{
                    "dimension": "model",
                    "key": "gpt-test",
                    "totals": totals,
                    "cost": cost
                }]
            }))
            .is_err()
        );
    }

    #[test]
    fn account_usage_detail_keeps_structured_clients() {
        let cost = json!({
            "mode": "calculate",
            "basis": "calculated",
            "status": "complete",
            "amount_microusd": "1",
            "catalog_revision": "official-2026-08-10-4",
            "calculated_rows": 1,
            "reported_rows": 0,
            "unpriced_rows": 0,
            "assumptions": [],
            "unpriced": []
        });
        let summary_totals = json!({
            "total_tokens": 13,
            "input_tokens": 8,
            "output_tokens": 5,
            "cache_read_input_tokens": 2,
            "cache_write_input_tokens": 1,
            "reasoning_tokens": 3,
            "messages": 2
        });
        let relay_totals = json!({
            "input_tokens": 8,
            "cache_read_tokens": 2,
            "cache_write_5m_tokens": 1,
            "cache_write_1h_tokens": 0,
            "cache_write_inferred_tokens": 0,
            "output_tokens": 5,
            "reasoning_tokens": 3,
            "requests": 2,
            "web_search_requests": 0,
            "web_fetch_requests": 0,
            "source_cost_microusd": null,
            "source_cost_covered_requests": 0
        });
        let detail = account_usage_detail(json!({
            "range": {"from": "2026-08-13", "to": "2026-08-13"},
            "totals": relay_totals,
            "cost": cost,
            "coverage": "partial",
            "breakdowns": [],
            "agents": [{
                "agent": "codex",
                "totals": summary_totals,
                "cost": cost,
                "providers": [{
                    "provider": "openai",
                    "totals": summary_totals,
                    "cost": cost,
                    "models": [{"model": "gpt-5.4", "totals": summary_totals, "cost": cost}]
                }]
            }]
        }))
        .expect("detail");
        assert_eq!(detail["usage"]["agents"][0]["agent"], "codex");
        assert_eq!(detail["usage"]["totals"]["messages"], 2);
        assert_eq!(detail["incomplete"], json!(true));
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
                .diagnostic_recent_activity()
                .expect("activity")
                .attempts
                .iter()
                .all(|attempt| attempt.kind != DiagnosticAttemptKind::UsageScan)
        );
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
        assert_eq!(
            report.get("protocol_version").and_then(Value::as_i64),
            Some(crate::protocol::LOCAL_COLLECTION_PROTOCOL)
        );
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
            assert_eq!(result.get("sources").and_then(Value::as_u64), Some(0));
        }
        assert!(state.session_json().expect("session state").is_none());
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

    #[test]
    fn diagnostics_v2_treats_empty_and_inactive_as_healthy() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let mut backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        backend.home = root.join("home");
        backend.environment.clear();
        let report = backend.diagnostic_report().expect("diagnostics");
        assert_eq!(report.schema_version, 2);
        assert_eq!(report.summary.operation, DiagnosticOperation::Healthy);
        assert_eq!(report.summary.data, DiagnosticDataState::Empty);
        assert_eq!(report.summary.attention, DiagnosticAttention::None);
        let serialized = serde_json::to_string(&report).expect("serialize");
        assert!(!serialized.contains("source_file_id"));
        assert!(!serialized.contains("/tmp"));
        state
            .set_usage_upload_enabled(false)
            .expect("disable Usage upload");
        assert!(!backend.stage_outbox("UTC").expect("staging disabled"));
        assert!(!backend.drain_outbox().expect("upload disabled"));
        let disabled = backend
            .complete_diagnostic_report()
            .expect("disabled diagnostics");
        let sync = disabled
            .checks
            .iter()
            .find(|check| check.name == "usage_upload")
            .expect("sync check");
        assert_eq!(sync.mode, DiagnosticMode::Inactive);
        assert_eq!(sync.operation, DiagnosticOperation::Healthy);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn persist_probe_corruption_returns_fail_closed_without_salvage() {
        let root = std::env::temp_dir().join(format!("quota-fail-closed-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state.clone(),
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        backend
            .complete_diagnostic_report()
            .expect("plant snapshot");
        state
            .fail_persist_probe_with_corruption_for_test()
            .expect("corrupt writes");

        let report = backend.diagnostic_report().expect("fail closed");
        assert_eq!(report.summary.operation, DiagnosticOperation::Blocked);
        assert_eq!(report.summary.data, DiagnosticDataState::Unknown);
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.code == "invalid_state"
                    && finding.recovery == DiagnosticRecovery::Reinstall)
        );
        assert_eq!(
            report
                .surfaces
                .iter()
                .map(|surface| surface.name.as_str())
                .collect::<Vec<_>>(),
            vec![
                "quota_overview",
                "usage_this_device",
                "usage_account",
                "account"
            ]
        );
        assert!(state.state_salvaged_at().expect("marker").is_none());
        drop(backend);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn untrusted_snapshot_evaluate_live_skips_usage_counts_and_is_partial() {
        let root = std::env::temp_dir().join(format!("quota-untrusted-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .insert_usage_file_record_for_test()
            .expect("usage rows");
        state.set_snapshot_untrusted(true).expect("untrusted");
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
            .find(|surface| surface.name == "usage_this_device")
            .expect("usage surface");
        assert_eq!(usage.data, DiagnosticDataState::Partial);
        assert_eq!(usage.metrics.get("files"), Some(&0));
        assert_eq!(usage.metrics.get("records"), Some(&0));
        assert_eq!(report.summary.data, DiagnosticDataState::Partial);
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
            .find(|surface| surface.name == "usage_this_device")
            .expect("usage surface");
        assert_eq!(usage.data, DiagnosticDataState::Empty);
        assert_ne!(usage.data, DiagnosticDataState::Partial);
        assert_eq!(report.summary.data, DiagnosticDataState::Empty);
        assert_eq!(report.summary.attention, DiagnosticAttention::None);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn state_repaired_finding_is_excluded_from_attention() {
        let root = std::env::temp_dir().join(format!("quota-repaired-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .set_state_salvaged_at(Some(&now_rfc3339()))
            .expect("salvaged");
        state
            .set_usage_reindex_pending(false)
            .expect("reindex clear");
        state.set_snapshot_untrusted(false).expect("trusted");
        let scan = state
            .begin_diagnostic_attempt(
                DiagnosticAttemptKind::UsageScan,
                DiagnosticAttemptTrigger::Startup,
                DiagnosticSource::ThisDevice,
                Some("agent:codex"),
                DiagnosticMode::Required,
                None,
            )
            .expect("scan");
        state
            .finish_diagnostic_attempt(
                scan,
                &DiagnosticAttemptCompletion {
                    outcome: DiagnosticAttemptOutcome::Success,
                    code: None,
                    recovery: DiagnosticRecovery::None,
                    metrics: metrics([("valid_records", 0)]),
                },
            )
            .expect("scan done");
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let report = backend.diagnostic_report().expect("diagnostics");
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.code == "state_repaired"
                    && finding.severity == DiagnosticSeverity::Info)
        );
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "local_state"
                    && check.metrics.get("repaired") == Some(&1))
        );
        assert_eq!(report.summary.attention, DiagnosticAttention::None);
        let usage = report
            .surfaces
            .iter()
            .find(|surface| surface.name == "usage_this_device")
            .expect("usage surface");
        assert_eq!(usage.data, DiagnosticDataState::Empty);
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_failed_collection_republishes_this_devices_reading_as_failed() {
        let now = Utc::now();
        let observed_at = (now - Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let reading = |status: &str| {
            serde_json::json!({
                "device_id": "device_self",
                "snapshot": {
                    "provider": "codex",
                    "account": {"fingerprint": "account", "fingerprint_scope": "global"},
                    "windows": [{"id": "monthly", "title": "Monthly", "used_percent": 0.0}],
                    "status": status,
                    "observed_at": observed_at
                }
            })
        };
        let summary =
            |observations: Value| serde_json::json!({"account_summary": {"quota": observations}});
        let report = serde_json::json!({
            "results": [
                {"provider": "codex", "outcome": "auth_required", "snapshots": [], "sources": 1},
                {"provider": "claude", "outcome": "success", "snapshots": []}
            ]
        });

        let account = summary(serde_json::json!([
            reading("available"),
            // Another device's reading of the same provider is not this device's to speak for.
            {"device_id": "device_other", "snapshot": reading("available")["snapshot"]}
        ]));
        let republished = failure_status_snapshots(&report, Some(&account), "device_self", now);
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

        // Once published, saying it again would rewrite the row and spend a sequence.
        let published = summary(serde_json::json!([reading("auth_required")]));
        assert!(failure_status_snapshots(&report, Some(&published), "device_self", now).is_empty());

        // A reading that already aged out is not current wherever it is read, so restating
        // it says nothing and would rewrite the row on every refresh forever.
        let aged_out = summary(serde_json::json!([{
            "device_id": "device_self",
            "snapshot": {
                "provider": "codex",
                "account": {"fingerprint": "account", "fingerprint_scope": "global"},
                "windows": [{"id": "monthly", "title": "Monthly", "used_percent": 0.0}],
                "status": "available",
                "observed_at": (now - Duration::days(2)).to_rfc3339_opts(SecondsFormat::Secs, true)
            }
        }]));
        assert!(failure_status_snapshots(&report, Some(&aged_out), "device_self", now).is_empty());

        // A provider this device never uploaded has nothing to republish.
        let empty = summary(serde_json::json!([]));
        assert!(failure_status_snapshots(&report, Some(&empty), "device_self", now).is_empty());
        assert!(failure_status_snapshots(&report, None, "device_self", now).is_empty());
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
        };
        let rejected = collect_discovered_provider(
            ProviderId::Claude,
            vec![ProviderSession {
                provider: ProviderId::Claude,
                credential_source: "fixture".to_owned(),
            }],
            &context,
        );
        assert_eq!(
            rejected.get("outcome").and_then(Value::as_str),
            Some("auth_required")
        );
        assert_eq!(
            rejected.get("message").and_then(Value::as_str),
            Some("The saved sign-in expired or was rejected. Sign in again.")
        );
        let never_configured =
            collect_discovered_provider(ProviderId::Claude, Vec::new(), &context);
        assert_eq!(
            never_configured.get("outcome").and_then(Value::as_str),
            Some("auth_required")
        );
        assert_eq!(never_configured.get("message"), None);
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
                }
            }
        }
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
        let now = Utc::now();
        let quota = json!({"results": []});
        let mut account = json!({
            "auth_status": "signed_in",
            "device_id": "this-device",
            "account_summary": {
                "devices": [{"device_id": "asleep", "display_name": "Asleep"}],
                "quota": [{"device_id": "asleep", "snapshot": snapshot(now - Duration::days(2))}]
            }
        });
        let expired = backend.build_overview(&quota, Some(&account));
        assert_eq!(expired.len(), 1);
        assert!(expired[0].is_stale);

        account["account_summary"]["devices"]
            .as_array_mut()
            .expect("devices")
            .push(json!({"device_id": "awake", "display_name": "Studio"}));
        account["account_summary"]["quota"]
            .as_array_mut()
            .expect("observations")
            .push(json!({
                "device_id": "awake",
                "snapshot": snapshot(now - Duration::minutes(1))
            }));
        let items = backend.build_overview(&quota, Some(&account));
        assert_eq!(items.len(), 1);
        assert!(!items[0].is_stale);
        assert_eq!(items[0].selected_source_display_name, "Studio");
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn overview_ignores_this_device_upload_and_keeps_other_devices() {
        let root = std::env::temp_dir().join(format!("quota-overview-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let backend = NativeBackend::new(
            state,
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );
        let snapshot = |observed_at: &str| {
            json!({
                "provider": "codex",
                "account": {"fingerprint": "account", "fingerprint_scope": "global"},
                "windows": [{"id": "five_hour", "title": "5 hour", "used_percent": 40.0}],
                "status": "available",
                "observed_at": observed_at
            })
        };
        // The local sign-in was rejected, so this device collected nothing this refresh.
        let quota = json!({
            "results": [{"provider": "codex", "outcome": "auth_required", "snapshots": []}]
        });
        let mut account = json!({
            "auth_status": "signed_in",
            "account_id": "account",
            "device_id": "this-device",
            "device_generation": 1,
            "account_summary": {
                "devices": [
                    {"device_id": "this-device", "display_name": "This Mac"},
                    {"device_id": "other-device", "display_name": "Studio"}
                ],
                "quota": [
                    {"device_id": "this-device", "snapshot": snapshot("2026-08-15T08:00:00Z")}
                ]
            }
        });

        assert!(backend.build_overview(&quota, Some(&account)).is_empty());

        account["account_summary"]["quota"]
            .as_array_mut()
            .expect("observations")
            .push(json!({
                "device_id": "other-device",
                "snapshot": snapshot("2026-08-15T09:00:00Z")
            }));
        let items = backend.build_overview(&quota, Some(&account));
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].sources.len(), 1);
        assert_eq!(items[0].selected_source_display_name, "Studio");
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_discovered_local_source_that_failed_is_actionable_even_with_account_data() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let attempt = state
            .begin_diagnostic_attempt(
                DiagnosticAttemptKind::QuotaCollection,
                DiagnosticAttemptTrigger::Scheduled,
                DiagnosticSource::ThisDevice,
                Some("provider:codex"),
                DiagnosticMode::Opportunistic,
                None,
            )
            .expect("quota attempt");
        state
            .finish_diagnostic_attempt(
                attempt,
                &DiagnosticAttemptCompletion {
                    outcome: DiagnosticAttemptOutcome::NoWork,
                    code: Some(DiagnosticAttemptCode::AuthenticationRequired),
                    recovery: DiagnosticRecovery::None,
                    metrics: metrics([("sources", 1), ("snapshots", 0)]),
                },
            )
            .expect("finish quota attempt");
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(json!({"results":[{
                    "provider":"codex","outcome":"auth_required","snapshots":[],"sources":1
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
                }],
                selected_source_id: "redacted-in-report".into(),
                selected_source_display_name: "Other device".into(),
                is_stale: false,
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
        assert_eq!(report.summary.data, DiagnosticDataState::Current);
        assert_eq!(report.summary.operation, DiagnosticOperation::Healthy);
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        assert!(report.findings.iter().any(|finding| {
            finding.subject.as_deref() == Some("provider:codex")
                && finding.severity == DiagnosticSeverity::Warning
                && finding.impact == DiagnosticImpact::Source
                && finding.recovery == DiagnosticRecovery::ConfigureProvider
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
                }],
                selected_source_id: "private-device".into(),
                selected_source_display_name: "Other device".into(),
                is_stale: false,
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
        assert_eq!(report.summary.data, DiagnosticDataState::Current);
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        assert!(report.findings.iter().any(|finding| {
            finding.subject.as_deref() == Some("provider:openrouter")
                && finding.severity == DiagnosticSeverity::Warning
                && finding.recovery == DiagnosticRecovery::ConfigureProvider
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

        assert_eq!(report.summary.operation, DiagnosticOperation::Degraded);
        assert_eq!(report.summary.attention, DiagnosticAttention::Required);
        assert!(report.checks.iter().any(|check| {
            check.name == "provider_configuration"
                && check.mode == DiagnosticMode::Required
                && check.operation == DiagnosticOperation::Degraded
        }));
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.code == "config_unreadable")
        );
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
            .insert_usage_dirty_range_for_test(&UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-10T12:00:00Z".into(),
                end_at: "2026-08-10T13:00:00Z".into(),
            })
            .expect("dirty range");
        let backend = NativeBackend::new(
            state.clone(),
            Arc::new(RelayClient::new().expect("relay")),
            "QuotaTest",
            "test",
        );

        let waiting = backend.evaluate_diagnostic_report(true).expect("waiting");
        let upload = waiting
            .checks
            .iter()
            .find(|check| check.name == "usage_upload")
            .expect("upload check");
        assert_eq!(upload.operation, DiagnosticOperation::Healthy);
        assert_eq!(upload.metrics.get("waiting"), Some(&1));
        assert!(
            !waiting
                .findings
                .iter()
                .any(|finding| finding.component == "usage_upload")
        );

        let attempt = state
            .begin_diagnostic_attempt(
                DiagnosticAttemptKind::UsageUpload,
                DiagnosticAttemptTrigger::Scheduled,
                DiagnosticSource::Account,
                None,
                DiagnosticMode::Required,
                None,
            )
            .expect("upload attempt");
        state
            .finish_diagnostic_attempt(
                attempt,
                &DiagnosticAttemptCompletion {
                    outcome: DiagnosticAttemptOutcome::Failed,
                    code: Some(DiagnosticAttemptCode::NetworkError),
                    recovery: DiagnosticRecovery::Retry,
                    metrics: metrics([("attempted", 1), ("pending", 1)]),
                },
            )
            .expect("upload failure");
        let failed = backend.evaluate_diagnostic_report(true).expect("failed");
        assert_eq!(failed.summary.operation, DiagnosticOperation::Degraded);
        assert!(
            failed
                .findings
                .iter()
                .any(|finding| finding.component == "usage_upload")
        );

        let retry = state
            .begin_diagnostic_attempt(
                DiagnosticAttemptKind::UsageUpload,
                DiagnosticAttemptTrigger::Scheduled,
                DiagnosticSource::Account,
                None,
                DiagnosticMode::Required,
                None,
            )
            .expect("retry attempt");
        state
            .finish_diagnostic_attempt(
                retry,
                &DiagnosticAttemptCompletion {
                    outcome: DiagnosticAttemptOutcome::NoWork,
                    code: Some(DiagnosticAttemptCode::NoWork),
                    recovery: DiagnosticRecovery::None,
                    metrics: metrics([("attempted", 0), ("pending", 0)]),
                },
            )
            .expect("finish retry");
        let still_failed = backend
            .evaluate_diagnostic_report(true)
            .expect("still failed");
        assert_eq!(
            still_failed.summary.operation,
            DiagnosticOperation::Degraded
        );
        assert!(
            still_failed
                .findings
                .iter()
                .any(|finding| finding.component == "usage_upload")
        );

        let success = state
            .begin_diagnostic_attempt(
                DiagnosticAttemptKind::UsageUpload,
                DiagnosticAttemptTrigger::Scheduled,
                DiagnosticSource::Account,
                None,
                DiagnosticMode::Required,
                None,
            )
            .expect("success attempt");
        state
            .finish_diagnostic_attempt(
                success,
                &DiagnosticAttemptCompletion {
                    outcome: DiagnosticAttemptOutcome::Success,
                    code: None,
                    recovery: DiagnosticRecovery::None,
                    metrics: metrics([("attempted", 1), ("pending", 1)]),
                },
            )
            .expect("finish success");
        let recovered = backend.evaluate_diagnostic_report(true).expect("recovered");
        assert_eq!(recovered.summary.operation, DiagnosticOperation::Healthy);
        assert!(
            !recovered
                .findings
                .iter()
                .any(|finding| finding.component == "usage_upload")
        );
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn usage_findings_are_scoped_and_not_repeated_as_rollups() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        state
            .write_usage_scan_diagnostics(
                UsageAgent::Cursor,
                &json!({
                    "status":"partial","scanned_files":2,"partial_files":1,"valid_records":9,
                    "reason_counts":{"malformed_json":4,"truncated_tail":1}
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

        assert!(
            report
                .findings
                .iter()
                .all(|finding| { finding.subject.as_deref() == Some("agent:cursor") })
        );
        assert_eq!(
            report
                .findings
                .iter()
                .map(|finding| finding.code.as_str())
                .collect::<HashSet<_>>(),
            HashSet::from(["malformed_json", "truncated_tail"])
        );
        assert!(!report.findings.iter().any(|finding| {
            matches!(finding.code.as_str(), "scan_partial" | "partial_sources")
        }));
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn diagnostics_do_not_treat_the_open_hour_as_a_pending_upload() {
        let now = DateTime::parse_from_rfc3339("2026-08-15T04:30:00Z")
            .expect("now")
            .with_timezone(&Utc);
        let ranges = [
            UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-15T03:00:00Z".into(),
                end_at: "2026-08-15T04:00:00Z".into(),
            },
            UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-15T04:00:00Z".into(),
                end_at: "2026-08-15T05:00:00Z".into(),
            },
        ];
        assert_eq!(uploadable_dirty_range_count(&ranges, now), 1);
        assert_eq!(uploadable_dirty_range_count(&ranges[1..], now), 0);
    }

    #[test]
    fn timezone_prefers_explicit_valid_tz_and_resolves_without_tz() {
        use crate::providers::common::resolve_timezone;
        let explicit = HashMap::from([(String::from("TZ"), String::from("Asia/Tokyo"))]);
        assert_eq!(resolve_timezone(&explicit).name(), "Asia/Tokyo");
        let invalid = HashMap::from([(String::from("TZ"), String::from("not/a-zone"))]);
        assert_ne!(resolve_timezone(&invalid).name(), "not/a-zone");
    }

    #[test]
    fn usage_upload_batch_matches_stage_and_drain_budget() {
        assert_eq!(usage_stage_slots(0), 64);
        assert_eq!(usage_stage_slots(63), 1);
        assert_eq!(usage_stage_slots(64), 0);
        assert_eq!(MAX_USAGE_OUTBOX_ENTRIES, MAX_USAGE_MULTIPART_PARTS);
    }

    #[test]
    fn multipart_builder_splits_rows_and_bytes_without_truncating() {
        let start = DateTime::parse_from_rfc3339("2026-08-10T12:00:00Z").expect("start");
        let end = DateTime::parse_from_rfc3339("2026-08-10T13:00:00Z").expect("end");
        let context = UsageSubmissionContext {
            agent: UsageAgent::Codex,
            start: &start,
            end: &end,
            timezone: "UTC",
            account_id: "account_test",
            device_id: "device_test",
            generation: 1,
            partial: false,
        };
        let fact = || UsageHourlyFact {
            bucket_start_utc: "2026-08-10T12:00:00Z".into(),
            usage_date: "2026-08-10".into(),
            usage_hour: 12,
            agent: UsageAgent::Codex,
            billing_channel: crate::usage::BillingChannel::Unknown,
            channel_source: crate::usage::ChannelSource::Unknown,
            model: "model".into(),
            context_bucket: crate::usage::ContextBucket::Le128k,
            service_tier: "standard".into(),
            speed: "standard".into(),
            inference_geo: "global".into(),
            input_tokens: 1,
            cache_read_tokens: 0,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: 0,
            output_tokens: 1,
            reasoning_tokens: 0,
            requests: 1,
            web_search_requests: 0,
            web_fetch_requests: 0,
            source_cost_microusd: None,
            source_cost_covered_requests: 0,
        };
        let rows = (0..=usage::MAX_USAGE_ROWS)
            .map(|index| {
                let mut row = fact();
                row.model = format!("model-{index}");
                row
            })
            .collect::<Vec<_>>();
        let (batch_id, submissions) =
            usage_multipart_submissions(&context, 10, &rows).expect("row-bound multipart");
        assert_eq!(submissions.len(), 2);
        let mut retained = 0usize;
        for (index, submission) in submissions.iter().enumerate() {
            let multipart = submission
                .get("multipart")
                .and_then(Value::as_object)
                .expect("multipart metadata");
            assert_eq!(
                multipart.get("batch_id").and_then(Value::as_str),
                Some(batch_id.as_str())
            );
            assert_eq!(
                multipart.get("part_index").and_then(Value::as_u64),
                Some(index as u64)
            );
            assert_eq!(multipart.get("part_count").and_then(Value::as_u64), Some(2));
            assert_eq!(
                submission.get("sequence").and_then(Value::as_u64),
                Some(10 + index as u64)
            );
            let part_rows = submission
                .get("rows")
                .and_then(Value::as_array)
                .expect("part rows");
            assert!(part_rows.len() <= usage::MAX_USAGE_ROWS);
            retained += part_rows.len();
            assert!(
                serde_json::to_vec(submission).expect("bytes").len()
                    <= crate::relay::MAXIMUM_REQUEST_BYTES
            );
            crate::relay::validate_usage_submission(submission).expect("valid part");
        }
        assert_eq!(retained, rows.len());

        let fat_rows = (0..usage::MAX_USAGE_ROWS)
            .map(|index| {
                let mut row = fact();
                row.model = format!("{index:06}-{}", "m".repeat(121));
                row.service_tier = "s".repeat(64);
                row.speed = "f".repeat(64);
                row.inference_geo = "g".repeat(64);
                row
            })
            .collect::<Vec<_>>();
        let (_, byte_parts) =
            usage_multipart_submissions(&context, 20, &fat_rows).expect("byte-bound multipart");
        assert!(byte_parts.len() > 1);
        assert!(byte_parts.iter().all(|part| {
            serde_json::to_vec(part).expect("bytes").len() <= crate::relay::MAXIMUM_REQUEST_BYTES
        }));

        let mut duplicate_rows = rows.clone();
        duplicate_rows[usage::MAX_USAGE_ROWS] = duplicate_rows[0].clone();
        assert!(usage_multipart_submissions(&context, 30, &duplicate_rows).is_none());

        let too_many = vec![fact(); usage::MAX_USAGE_ROWS * MAX_USAGE_MULTIPART_PARTS + 1];
        assert!(usage_multipart_submissions(&context, 40, &too_many).is_none());
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
            rows: Vec::new(),
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

    #[test]
    fn usage_lower_bound_is_precise_and_fails_closed() {
        let session = json!({
            "upload_not_before": "2026-08-10T00:00:00Z",
            "usage_deleted_before": "2026-08-10T00:00:00.123Z"
        });
        assert_eq!(
            effective_usage_lower_bound(&session).expect("lower bound"),
            "2026-08-10T00:00:00.123Z"
        );
        assert!(
            effective_usage_lower_bound(&json!({
                "upload_not_before": "invalid",
                "usage_deleted_before": null
            }))
            .is_err()
        );
        assert!(
            effective_usage_lower_bound(&json!({
                "upload_not_before": "2026-08-10T00:00:00Z"
            }))
            .is_err()
        );
    }
}
