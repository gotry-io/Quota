//! Production backend adapter.  The service owns orchestration; this adapter owns the concrete
//! provider, Usage, pricing, and Relay calls and returns only protocol-shaped values.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::fs::OpenOptions;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

use chrono::{DateTime, Days, SecondsFormat, Timelike, Utc};
use chrono_tz::Tz;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::catalog::ProviderId;
use crate::pricing;
use crate::protocol::{
    DiagnosticClient, DiagnosticComponent, DiagnosticIssue, DiagnosticReport, DiagnosticSeverity,
    DiagnosticStatus, ErrorCode, IpcError, QuotaOverviewIdentity, QuotaOverviewItem,
    QuotaOverviewSource, RecoveryAction, UsagePeriod, UsageSource,
};
use crate::providers::common::ErrorCategory;
use crate::providers::{self, CollectionContext};
use crate::relay::{AccountManager, RelayClient};
use crate::service::{BackendError, LocalBackend, LoginOutcome, RefreshOutcome};
use crate::state::{StateStore, UsageDirtyRange, now_rfc3339};
use crate::usage::{self, CoverageStatus, UsageAgent, UsageHourlyFact, UsageScanOptions};

const PARSER_REVISION: &str = "quota-usage-rust-4";
const FILE_INDEX_PARSER_REVISION: &str = "usage-rust-v5";
const MAX_USAGE_OUTBOX_ENTRIES: usize = 64;
const MAX_USAGE_MULTIPART_PARTS: usize = 64;
const DEFAULT_TIMEZONE: &str = "UTC";

fn metrics<const N: usize>(values: [(&str, i64); N]) -> BTreeMap<String, i64> {
    values
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value.clamp(0, 1_000_000)))
        .collect()
}

fn component_name(name: crate::protocol::ComponentName) -> &'static str {
    match name {
        crate::protocol::ComponentName::Quota => "quota",
        crate::protocol::ComponentName::Usage => "usage",
        crate::protocol::ComponentName::Account => "account",
        crate::protocol::ComponentName::Pricing => "pricing",
        crate::protocol::ComponentName::Providers => "providers",
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

fn outcome_count(value: Option<&Value>, outcome: &str) -> i64 {
    value
        .and_then(Value::as_object)
        .and_then(|object| object.get("results"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|result| result.get("outcome").and_then(Value::as_str) == Some(outcome))
        .count() as i64
}

fn quota_diagnostic_metrics(value: Option<&Value>) -> BTreeMap<String, i64> {
    let snapshots = value
        .and_then(Value::as_object)
        .and_then(|object| object.get("results"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|result| array_len(Some(result), "snapshots"))
        .sum::<i64>();
    metrics([
        ("results", array_len(value, "results")),
        ("snapshots", snapshots),
        ("success", outcome_count(value, "success")),
        ("auth_required", outcome_count(value, "auth_required")),
        ("unavailable", outcome_count(value, "unavailable")),
        ("error", outcome_count(value, "error")),
        ("unsupported", outcome_count(value, "unsupported")),
    ])
}

fn quota_collection_status(value: Option<&Value>) -> &'static str {
    let metrics = quota_diagnostic_metrics(value);
    let results = metrics.get("results").copied().unwrap_or(0);
    let success = metrics.get("success").copied().unwrap_or(0);
    let auth_required = metrics.get("auth_required").copied().unwrap_or(0);
    let failures = auth_required
        + metrics.get("unavailable").copied().unwrap_or(0)
        + metrics.get("error").copied().unwrap_or(0)
        + metrics.get("unsupported").copied().unwrap_or(0);
    if results == 0 || success == 0 {
        "blocked"
    } else if failures > 0 {
        "degraded"
    } else {
        "ready"
    }
}

fn error_code_wire(code: ErrorCode) -> String {
    serde_json::to_value(code)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "unknown_error".to_owned())
}

fn safe_sync_error_code(value: Option<&Value>) -> &'static str {
    match value.and_then(Value::as_str) {
        Some("invalid_request") => "invalid_request",
        Some("unsupported_operation") => "unsupported_operation",
        Some("invalid_state") => "invalid_state",
        Some("client_upgrade_required") => "client_upgrade_required",
        Some("busy") => "busy",
        Some("cancelled") => "cancelled",
        Some("authentication_required") => "authentication_required",
        Some("device_deleted") => "device_deleted",
        Some("stale_generation") => "stale_generation",
        Some("unavailable") => "unavailable",
        Some("provider_error") => "provider_error",
        Some("network_error") => "network_error",
        Some("invalid_response") => "invalid_response",
        Some("internal") => "internal",
        Some("unrepresentable_hour") => "unrepresentable_hour",
        Some("invalid_usage_batch") => "invalid_usage_batch",
        _ => "sync_failed",
    }
}

fn pricing_diagnostic_metrics(value: Option<&Value>) -> BTreeMap<String, i64> {
    let valid = value.is_some_and(|value| pricing::validate_pricing_catalog(value).valid);
    metrics([
        ("catalog_present", i64::from(value.is_some())),
        ("catalog_valid", i64::from(valid)),
        ("entries", array_len(value, "entries")),
    ])
}

fn model_catalog_diagnostic_metrics(value: Option<&Value>) -> BTreeMap<String, i64> {
    let valid =
        value.is_some_and(|value| crate::model_catalog::validate_model_catalog_value(value).valid);
    let revision_available = value
        .and_then(Value::as_object)
        .and_then(|object| object.get("revision"))
        .and_then(Value::as_str)
        .is_some_and(|revision| !revision.is_empty());
    metrics([
        ("catalog_present", i64::from(value.is_some())),
        ("catalog_valid", i64::from(valid)),
        ("revision_available", i64::from(revision_available)),
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

fn config_file_diagnostic(root: &std::path::Path) -> (bool, bool) {
    let path = root.join("providers.json");
    let present = match fs::metadata(&path) {
        Ok(metadata) => metadata.is_file(),
        Err(_) => false,
    };
    let readable = present
        && OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
            .is_ok();
    (present, readable)
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
        let device_name = std::env::var("HOSTNAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| client_name.to_owned());
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

    /// Collect provider quota without Usage, pricing, account synchronization, or uploads.
    ///
    /// This is the local-only path used by diagnostic/status callers.  Full refresh remains the
    /// only path that performs account synchronization and outbox work.
    pub fn collect_quota(&self, cancel: Arc<AtomicBool>) -> Result<Value, BackendError> {
        self.collect_quota_for(ProviderId::ALL, cancel)
    }

    /// Discover providers through the same provider-owned credential paths used for collection.
    /// No account or Relay state is read or changed.
    pub fn configured_providers(&self) -> Vec<ProviderId> {
        let context = self.collection_context(Arc::new(AtomicBool::new(false)));
        ProviderId::ALL
            .iter()
            .copied()
            .filter(|provider| !providers::discover(*provider, &context).is_empty())
            .collect()
    }

    pub fn diagnostic_report(&self) -> Result<DiagnosticReport, BackendError> {
        let mut components = Vec::with_capacity(6);
        let mut issues = Vec::new();
        let mut degraded = false;
        let mut blocked = false;

        let discovered = self.configured_providers().len() as i64;
        let (config_present, config_readable) = config_file_diagnostic(self.state.root());
        let configured = match self.state.snapshot() {
            Ok(snapshot) => snapshot
                .providers
                .iter()
                .filter(|provider| provider.configured)
                .count() as i64,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "providers".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "provider configuration state could not be read".into(),
                });
                0
            }
        };
        if config_present && !config_readable {
            issues.push(DiagnosticIssue {
                component: "providers".into(),
                code: "config_unreadable".into(),
                severity: DiagnosticSeverity::Error,
                count: 1,
                message: "recovery_configure_provider".into(),
            });
        }
        components.push(DiagnosticComponent {
            name: "providers".into(),
            status: if config_present && !config_readable {
                degraded = true;
                "degraded"
            } else {
                "ready"
            }
            .into(),
            message: None,
            metrics: metrics([
                ("configured", configured),
                ("discovered", discovered),
                ("config_present", i64::from(config_present)),
                ("config_readable", i64::from(config_readable)),
                (
                    "config_root_explicit",
                    i64::from(self.environment.contains_key("XDG_CONFIG_HOME")),
                ),
            ]),
        });

        let component = |name: &str,
                         record: Option<crate::state::ComponentRecord>,
                         metrics: BTreeMap<String, i64>,
                         issues: &mut Vec<DiagnosticIssue>,
                         degraded: &mut bool,
                         blocked: &mut bool| {
            let (status, message) = match record {
                Some(record) => {
                    let status = match record.status {
                        crate::protocol::ComponentStatus::Ready => "ready",
                        crate::protocol::ComponentStatus::Stale => "degraded",
                        crate::protocol::ComponentStatus::AuthRequired => "blocked",
                        crate::protocol::ComponentStatus::Unavailable => "blocked",
                        crate::protocol::ComponentStatus::Unsupported => "degraded",
                        crate::protocol::ComponentStatus::Error => "degraded",
                        crate::protocol::ComponentStatus::SignedOut => "ready",
                    };
                    if status == "degraded" {
                        *degraded = true;
                    } else if status == "blocked" {
                        *blocked = true;
                    }
                    if status != "ready" {
                        let (code, message) = record
                            .last_error
                            .as_ref()
                            .map(|error| {
                                (
                                    serde_json::to_value(error.code)
                                        .ok()
                                        .and_then(|value| value.as_str().map(str::to_owned))
                                        .unwrap_or_else(|| "component_error".into()),
                                    format!(
                                        "recovery_{}",
                                        serde_json::to_value(error.recovery_action)
                                            .ok()
                                            .and_then(|value| value.as_str().map(str::to_owned))
                                            .unwrap_or_else(|| "retry".into())
                                    ),
                                )
                            })
                            .unwrap_or_else(|| (status.into(), "component_not_ready".into()));
                        issues.push(DiagnosticIssue {
                            component: name.into(),
                            code,
                            severity: if status == "blocked" {
                                DiagnosticSeverity::Error
                            } else {
                                DiagnosticSeverity::Warning
                            },
                            count: 1,
                            message,
                        });
                    }
                    (status.into(), None)
                }
                None => {
                    *blocked = true;
                    issues.push(DiagnosticIssue {
                        component: name.into(),
                        code: "unavailable".into(),
                        severity: DiagnosticSeverity::Error,
                        count: 1,
                        message: "component has no stored state".into(),
                    });
                    ("blocked".into(), Some("no stored state".into()))
                }
            };
            DiagnosticComponent {
                name: name.into(),
                status,
                message,
                metrics,
            }
        };

        let mut read_component =
            |name: crate::protocol::ComponentName| match self.state.component(name) {
                Ok(value) => value,
                Err(_) => {
                    degraded = true;
                    issues.push(DiagnosticIssue {
                        component: component_name(name).into(),
                        code: "state_unavailable".into(),
                        severity: DiagnosticSeverity::Error,
                        count: 1,
                        message: "component state could not be read".into(),
                    });
                    None
                }
            };
        let quota = read_component(crate::protocol::ComponentName::Quota);
        let usage = read_component(crate::protocol::ComponentName::Usage);
        let pricing = read_component(crate::protocol::ComponentName::Pricing);
        let account = read_component(crate::protocol::ComponentName::Account);
        let mut file_count = 0i64;
        for agent in UsageAgent::ALL {
            match self.state.usage_file_index(agent) {
                Ok(index) => file_count = file_count.saturating_add(index.len() as i64),
                Err(_) => {
                    degraded = true;
                    issues.push(DiagnosticIssue {
                        component: "usage".into(),
                        code: "state_unavailable".into(),
                        severity: DiagnosticSeverity::Error,
                        count: 1,
                        message: "Usage file index could not be read".into(),
                    });
                    break;
                }
            }
        }
        let record_count = match self.state.usage_events() {
            Ok(events) => events.len() as i64,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "usage".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "Usage records could not be read".into(),
                });
                0
            }
        };
        let usage_upload_enabled = match self.state.usage_upload_enabled() {
            Ok(enabled) => enabled,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "sync".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "Usage upload preference could not be read".into(),
                });
                true
            }
        };
        let dirty_count = match self.state.dirty_usage_ranges() {
            Ok(ranges) => ranges.len() as i64,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "sync".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "dirty Usage ranges could not be read".into(),
                });
                0
            }
        };
        let partial_count = match self.state.partial_usage_hours() {
            Ok(hours) => hours.len() as i64,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "usage".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "partial Usage ranges could not be read".into(),
                });
                0
            }
        };
        let outbox_count = match self.state.outbox_entries() {
            Ok(entries) => entries.len() as i64,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "sync".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "Usage outbox could not be read".into(),
                });
                0
            }
        };
        let scan_diagnostics = match self.state.usage_scan_diagnostics() {
            Ok(values) => values,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "usage".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "scan diagnostics could not be read".into(),
                });
                Vec::new()
            }
        };
        let mut usage_metrics = metrics([
            ("files", file_count),
            ("records", record_count),
            ("dirty_ranges", dirty_count),
            ("partial_hours", partial_count),
            ("scan_agents", scan_diagnostics.len() as i64),
        ]);
        let mut reason_counts = BTreeMap::<String, i64>::new();
        for (_, value) in &scan_diagnostics {
            if value.get("status").and_then(Value::as_str) == Some("blocked") {
                blocked = true;
                issues.push(DiagnosticIssue {
                    component: "usage".into(),
                    code: "scan_blocked".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "recovery_retry".into(),
                });
            } else if value.get("status").and_then(Value::as_str) == Some("partial") {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "usage".into(),
                    code: "scan_partial".into(),
                    severity: DiagnosticSeverity::Warning,
                    count: 1,
                    message: "some Usage sources are incomplete".into(),
                });
            }
            for (reason, count) in value
                .get("reason_counts")
                .and_then(Value::as_object)
                .into_iter()
                .flatten()
            {
                let count = count
                    .as_u64()
                    .map(|value| value.min(i64::MAX as u64) as i64)
                    .or_else(|| count.as_i64())
                    .unwrap_or(0)
                    .max(0);
                let entry = reason_counts.entry(reason.clone()).or_default();
                *entry = entry.saturating_add(count);
            }
        }
        for metric in [
            "scanned_files",
            "skipped_files",
            "complete_files",
            "partial_files",
            "indexed_records",
            "valid_records",
            "ignored_empty_records",
        ] {
            let total = scan_diagnostics
                .iter()
                .filter_map(|(_, value)| value.get(metric).and_then(Value::as_i64))
                .sum::<i64>();
            usage_metrics.insert(metric.into(), total.clamp(0, 1_000_000));
        }
        for (reason, count) in reason_counts {
            if count > 0 {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "usage".into(),
                    code: reason.clone(),
                    severity: DiagnosticSeverity::Warning,
                    count,
                    message: "records or sources were isolated during parsing".into(),
                });
            }
        }
        if partial_count > 0 {
            degraded = true;
            issues.push(DiagnosticIssue {
                component: "usage".into(),
                code: "partial_sources".into(),
                severity: DiagnosticSeverity::Warning,
                count: partial_count,
                message: "some source hours retain last-good data".into(),
            });
        }
        if usage_upload_enabled && outbox_count > 0 {
            degraded = true;
            issues.push(DiagnosticIssue {
                component: "sync".into(),
                code: "pending_upload".into(),
                severity: DiagnosticSeverity::Warning,
                count: outbox_count,
                message: "usage uploads are pending".into(),
            });
        }
        let quota_value = quota.as_ref().and_then(|record| record.value.as_ref());
        let pricing_value = pricing.as_ref().and_then(|record| record.value.as_ref());
        let model_catalog_value = self.state.model_catalog().ok().flatten();
        let account_value = account.as_ref().and_then(|record| record.value.as_ref());
        let session = match self.state.session_json() {
            Ok(value) => value,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "account".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "account session state could not be read".into(),
                });
                None
            }
        };
        let quota_metrics = quota_diagnostic_metrics(quota_value);
        let pricing_metrics = pricing_diagnostic_metrics(pricing_value);
        let model_catalog_metrics = model_catalog_diagnostic_metrics(model_catalog_value.as_ref());
        usage_metrics.extend(
            model_catalog_metrics
                .iter()
                .map(|(key, value)| (format!("model_{key}"), *value)),
        );
        let account_metrics = account_diagnostic_metrics(account_value, session.as_ref());
        if pricing_value.is_some()
            && !pricing::validate_pricing_catalog(pricing_value.unwrap()).valid
        {
            degraded = true;
            issues.push(DiagnosticIssue {
                component: "pricing".into(),
                code: "invalid_catalog".into(),
                severity: DiagnosticSeverity::Warning,
                count: 1,
                message: "last pricing catalog failed validation".into(),
            });
        }
        if model_catalog_value
            .as_ref()
            .is_some_and(|value| !crate::model_catalog::validate_model_catalog_value(value).valid)
        {
            degraded = true;
            issues.push(DiagnosticIssue {
                component: "usage".into(),
                code: "invalid_model_catalog".into(),
                severity: DiagnosticSeverity::Warning,
                count: 1,
                message: "last model catalog failed validation".into(),
            });
        }
        let sync_diagnostic = match self.state.sync_diagnostic() {
            Ok(value) => value,
            Err(_) => {
                degraded = true;
                issues.push(DiagnosticIssue {
                    component: "sync".into(),
                    code: "state_unavailable".into(),
                    severity: DiagnosticSeverity::Error,
                    count: 1,
                    message: "last upload status could not be read".into(),
                });
                None
            }
        };
        let sync_status_value = sync_diagnostic
            .as_ref()
            .and_then(|value| value.get("status"))
            .and_then(Value::as_str);
        let sync_blocked = usage_upload_enabled && sync_status_value == Some("blocked");
        let sync_failed = usage_upload_enabled && sync_status_value == Some("failed");
        let sync_degraded = usage_upload_enabled && sync_status_value == Some("degraded");
        if sync_blocked {
            blocked = true;
            let code = safe_sync_error_code(
                sync_diagnostic
                    .as_ref()
                    .and_then(|value| value.get("error")),
            );
            issues.push(DiagnosticIssue {
                component: "sync".into(),
                code: code.into(),
                severity: DiagnosticSeverity::Error,
                count: 1,
                message: "recovery_retry".into(),
            });
        } else if sync_failed || sync_degraded {
            degraded = true;
            let code = safe_sync_error_code(
                sync_diagnostic
                    .as_ref()
                    .and_then(|value| value.get("error")),
            );
            issues.push(DiagnosticIssue {
                component: "sync".into(),
                code: code.into(),
                severity: DiagnosticSeverity::Warning,
                count: 1,
                message: "recovery_retry".into(),
            });
        }
        let quota_status = quota_collection_status(quota_value);
        let quota_failures = [
            ("auth_required", DiagnosticSeverity::Error),
            ("unavailable", DiagnosticSeverity::Warning),
            ("error", DiagnosticSeverity::Warning),
            ("unsupported", DiagnosticSeverity::Warning),
        ];
        for (code, severity) in quota_failures {
            let count = quota_metrics.get(code).copied().unwrap_or(0);
            if count > 0 {
                issues.push(DiagnosticIssue {
                    component: "quota".into(),
                    code: code.into(),
                    severity,
                    count,
                    message: if code == "auth_required" {
                        "recovery_login".into()
                    } else {
                        "recovery_retry".into()
                    },
                });
            }
        }
        let mut quota_component = component(
            "quota",
            quota,
            quota_metrics,
            &mut issues,
            &mut degraded,
            &mut blocked,
        );
        if quota_status == "blocked" {
            quota_component.status = "blocked".into();
            blocked = true;
        } else if quota_status == "degraded" {
            quota_component.status = "degraded".into();
            degraded = true;
        }
        components.push(quota_component);
        components.push(component(
            "usage",
            usage,
            usage_metrics,
            &mut issues,
            &mut degraded,
            &mut blocked,
        ));
        components.push(component(
            "pricing",
            pricing,
            pricing_metrics,
            &mut issues,
            &mut degraded,
            &mut blocked,
        ));
        components.push(component(
            "account",
            account,
            account_metrics,
            &mut issues,
            &mut degraded,
            &mut blocked,
        ));
        let sync_status = if !usage_upload_enabled {
            "ready"
        } else if sync_blocked {
            "blocked"
        } else if sync_failed || sync_degraded {
            "degraded"
        } else if outbox_count == 0 && dirty_count == 0 {
            "ready"
        } else {
            "degraded"
        };
        components.push(DiagnosticComponent {
            name: "sync".into(),
            status: sync_status.into(),
            message: None,
            metrics: metrics([
                ("usage_upload_enabled", i64::from(usage_upload_enabled)),
                ("dirty_ranges", dirty_count),
                ("outbox", outbox_count),
                ("partial_hours", partial_count),
                (
                    "last_upload_success",
                    i64::from(
                        sync_diagnostic
                            .as_ref()
                            .and_then(|value| value.get("status"))
                            .and_then(Value::as_str)
                            == Some("success"),
                    ),
                ),
                ("last_upload_failed", i64::from(sync_failed)),
                ("last_upload_degraded", i64::from(sync_degraded)),
                ("last_upload_blocked", i64::from(sync_blocked)),
            ]),
        });
        if sync_status == "degraded" {
            degraded = true;
        }
        let status = if blocked {
            DiagnosticStatus::Blocked
        } else if degraded {
            DiagnosticStatus::Degraded
        } else {
            DiagnosticStatus::Healthy
        };
        let report = DiagnosticReport {
            schema_version: 1,
            status,
            generated_at: now_rfc3339(),
            client: DiagnosticClient {
                name: self.client_name.clone(),
                version: self.client_version.clone(),
            },
            components,
            issues: issues.into_iter().take(256).collect(),
        };
        Ok(report)
    }

    /// Collect only the selected providers through the local-only path.  This keeps CLI status
    /// provider selection separate from the full refresh that may upload account data.
    pub fn collect_quota_for(
        &self,
        provider_ids: &[ProviderId],
        cancel: Arc<AtomicBool>,
    ) -> Result<Value, BackendError> {
        let context = self.collection_context(cancel.clone());
        let captured_at = context.observed_at();
        let results = thread::scope(|scope| {
            let jobs = provider_ids.iter().copied().map(|provider| {
                let context = context.clone();
                (
                    provider,
                    scope.spawn(move || collect_one_provider(provider, &context)),
                )
            });
            jobs.into_iter()
                .map(|(provider, job)| {
                    job.join().unwrap_or_else(|_| {
                        json!({
                            "provider": provider,
                            "outcome": "error",
                            "snapshots": []
                        })
                    })
                })
                .collect::<Vec<_>>()
        });
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        Ok(json!({
            "protocol_version": 2,
            "captured_at": captured_at,
            "results": results
        }))
    }

    fn collection_context(&self, cancel: Arc<AtomicBool>) -> CollectionContext {
        CollectionContext {
            home_directory: self.home.clone(),
            environment: self.environment.clone(),
            config_path: Some(self.state.root().join("providers.json")),
            client_name: self.client_name.clone(),
            client_version: self.client_version.clone(),
            now: Some(now_rfc3339()),
            cancel: Some(cancel),
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
        for agent in UsageAgent::ALL {
            if cancel.load(Ordering::Acquire) {
                return Err(BackendError::cancelled());
            }
            let options = UsageScanOptions {
                home_directory: Some(self.home.clone()),
                environment: self.environment.clone(),
                // The scanner uses the full retained timeline only to qualify changed files.  It
                // skips unchanged files from the SQLite file index; precise upload ranges come
                // from old/new normalized records in `apply_usage_scan` below.
                start_at: "1970-01-01T00:00:00Z".to_owned(),
                end_at: end_at.clone(),
                cancelled: Some(cancel.clone()),
                parser_revision: FILE_INDEX_PARSER_REVISION.to_owned(),
                file_index: self
                    .state
                    .usage_file_index(agent)
                    .map_err(|_| BackendError::unavailable())?,
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
                return Err(BackendError::unavailable());
            }
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
                    "client": agent.coverage.agent,
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
            "protocol_version": 3,
            "generated_at": usage.generated_at,
            "aggregation_timezone": usage.timezone,
            "range": {"from": from, "to": to},
            "status": status,
            "model_catalog_revision": model_catalog.map(|value| value.revision.clone()),
            "coverage": coverage
        }))
    }

    fn refresh_pricing(&self) -> Result<Value, BackendError> {
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
        resolve_timezone(&self.environment)
    }

    fn refresh_account_usage_periods(
        &self,
        account_value: &Value,
        cancel: &AtomicBool,
    ) -> Result<(), BackendError> {
        let all = account_value
            .get("account_summary")
            .and_then(|summary| summary.get("usage"))
            .cloned()
            .ok_or_else(BackendError::unavailable)?;
        let mut periods = vec![(UsagePeriod::All, account_usage_detail(all)?)];
        for period in [
            UsagePeriod::Today,
            UsagePeriod::Last7Days,
            UsagePeriod::Last30Days,
        ] {
            let (_, range) = usage_period_range(period, &self.timezone(), Utc::now())?;
            let (from, to) = range.ok_or_else(BackendError::unavailable)?;
            let query = format!("cost_mode=calculate&from={from}&to={to}");
            periods.push((
                period,
                account_usage_detail(self.account.account_usage(&query, cancel)?)?,
            ));
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
                        merge_overview_item(&mut items, item, now);
                    }
                }
            }
        }
        if let Some(summary) = account
            .and_then(|value| value.get("account_summary"))
            .and_then(Value::as_object)
        {
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
                    let Some(snapshot) = observation.get("snapshot") else {
                        continue;
                    };
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
                        merge_overview_item(&mut items, item, now);
                    }
                }
            }
        }
        items.sort_by(|left, right| {
            (
                &left.identity.provider,
                &left.identity.fingerprint,
                &left.identity.scope,
                &left.identity.source_id,
            )
                .cmp(&(
                    &right.identity.provider,
                    &right.identity.fingerprint,
                    &right.identity.scope,
                    &right.identity.source_id,
                ))
        });
        items
    }
}

fn resolve_timezone(environment: &HashMap<String, String>) -> String {
    if let Some(value) = environment
        .get("TZ")
        .filter(|value| value.parse::<chrono_tz::Tz>().is_ok())
    {
        return value.clone();
    }
    iana_time_zone::get_timezone()
        .ok()
        .filter(|value| value.parse::<chrono_tz::Tz>().is_ok())
        .unwrap_or_else(|| DEFAULT_TIMEZONE.to_owned())
}

fn collect_one_provider(provider: ProviderId, context: &CollectionContext) -> Value {
    let sessions = providers::discover(provider, context);
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
            Ok(snapshot) => snapshots.push(serde_json::to_value(snapshot).unwrap_or(Value::Null)),
            Err(error) => failure = Some(error.category),
        }
    }
    if snapshots.is_empty() {
        let outcome = match failure.unwrap_or(ErrorCategory::Unavailable) {
            ErrorCategory::AuthRequired => "auth_required",
            ErrorCategory::Unsupported => "unsupported",
            ErrorCategory::Unavailable => "unavailable",
            ErrorCategory::Error => "error",
        };
        json!({"provider": provider, "outcome": outcome, "snapshots": []})
    } else {
        json!({
            "provider": provider,
            "outcome": "success",
            "snapshots": snapshots
        })
    }
}

impl LocalBackend for NativeBackend {
    fn diagnose(&self) -> Result<DiagnosticReport, BackendError> {
        self.diagnostic_report()
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
                match self.account.sync_control_and_update() {
                    Ok(_) if cancel.load(Ordering::Acquire) => {
                        account_value = Err(BackendError::cancelled());
                    }
                    Ok(_) => {
                        let current_session =
                            self.state.session_json().ok().flatten().unwrap_or(session);
                        let mut account_sync_error = None;
                        let mut stage_blocked = false;
                        if let Ok(quota_payload) = &quota_value
                            && let Err(error) = self.account.upload_quota_report(quota_payload)
                        {
                            account_sync_error = Some(error);
                        }
                        let usage_upload_enabled = match self.state.usage_upload_enabled() {
                            Ok(enabled) => enabled,
                            Err(_) => {
                                account_sync_error = Some(BackendError::unavailable());
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
                                account_sync_error = Some(error);
                            } else {
                                match self.stage_outbox(&usage_collection.timezone) {
                                    Ok(blocked) => stage_blocked = blocked,
                                    Err(error) => account_sync_error = Some(error),
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
                            match self.drain_outbox() {
                                Ok(rejected) => {
                                    let pending = self
                                        .state
                                        .outbox_entries()
                                        .ok()
                                        .map(|entries| entries.len() as i64)
                                        .unwrap_or(0);
                                    if stage_blocked {
                                        self.record_sync_diagnostic(json!({
                                            "status": "blocked",
                                            "attempted": before.saturating_sub(pending),
                                            "pending": pending,
                                            "error": "unrepresentable_hour"
                                        }));
                                    } else if rejected {
                                        self.record_sync_diagnostic(json!({
                                            "status": "degraded",
                                            "attempted": before.saturating_sub(pending),
                                            "pending": pending,
                                            "error": "invalid_usage_batch"
                                        }));
                                    } else {
                                        self.record_sync_diagnostic(json!({
                                            "status": "success",
                                            "attempted": before.saturating_sub(pending),
                                            "pending": pending
                                        }));
                                    }
                                }
                                Err(error) => {
                                    self.record_sync_diagnostic(json!({
                                        "status": "failed",
                                        "attempted": before,
                                        "pending": before,
                                        "error": error_code_wire(error.error.code)
                                    }));
                                    account_sync_error = Some(error);
                                }
                            }
                        } else if let Some(error) = &account_sync_error {
                            self.record_sync_diagnostic(json!({
                                "status": "failed",
                                "attempted": 0,
                                "pending": self.state.outbox_entries().ok().map(|entries| entries.len()).unwrap_or(0),
                                "error": error_code_wire(error.error.code)
                            }));
                        }
                        if account_sync_error.is_none() {
                            account_value = self.account.refresh_account_state(cancel.as_ref());
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
                        } else if let Some(error) = account_sync_error {
                            account_value = Err(error);
                        }
                    }
                    Err(error) => {
                        if error.error.code.requires_login() {
                            self.clear_active_session();
                        }
                        account_value = Err(error);
                    }
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
            let stored_account = self
                .state
                .component(crate::protocol::ComponentName::Account)
                .ok()
                .flatten()
                .and_then(|component| component.value);
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
    fn record_sync_diagnostic(&self, value: Value) {
        let _ = self.state.write_sync_diagnostic(&value);
    }

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
        "fallback_models": [],
        "incomplete": incomplete,
        "details_truncated": details_truncated
    }))
}

fn account_usage_detail(value: Value) -> Result<Value, BackendError> {
    let object = value.as_object().ok_or_else(invalid_usage_detail)?;
    let totals = account_summary_totals(object.get("totals").ok_or_else(invalid_usage_detail)?)?;
    let cost = object
        .get("cost")
        .cloned()
        .ok_or_else(invalid_usage_detail)?;
    let has_clients = object.contains_key("clients");
    let clients = object.get("clients").cloned().unwrap_or_else(|| json!([]));
    let fallback_models = if has_clients {
        Vec::new()
    } else {
        object
            .get("breakdowns")
            .and_then(Value::as_array)
            .ok_or_else(invalid_usage_detail)?
            .iter()
            .filter(|item| item.get("dimension").and_then(Value::as_str) == Some("model"))
            .map(|item| {
                Ok(json!({
                    "model": item
                        .get("key")
                        .and_then(Value::as_str)
                        .ok_or_else(invalid_usage_detail)?,
                    "totals": account_summary_totals(
                        item.get("totals").ok_or_else(invalid_usage_detail)?
                    )?,
                    "cost": item.get("cost").cloned().ok_or_else(invalid_usage_detail)?
                }))
            })
            .collect::<Result<Vec<_>, BackendError>>()?
    };
    let coverage = object
        .get("coverage")
        .and_then(Value::as_array)
        .ok_or_else(invalid_usage_detail)?;
    let coverage_truncated =
        object.get("coverage_truncated").and_then(Value::as_bool) == Some(true);
    let breakdowns_truncated =
        object.get("breakdowns_truncated").and_then(Value::as_bool) == Some(true);
    let unpriced_truncated = cost.get("unpriced_truncated").and_then(Value::as_bool) == Some(true);
    let mut usage = json!({
        "totals": totals,
        "cost": cost,
        "clients": clients
    });
    if breakdowns_truncated {
        usage["models_truncated"] = Value::Bool(true);
    }
    Ok(json!({
        "range": object.get("range").cloned().ok_or_else(invalid_usage_detail)?,
        "usage": usage,
        "fallback_models": fallback_models,
        "incomplete": coverage_truncated
            || coverage.iter().any(|item| {
                item.get("status").and_then(Value::as_str) == Some("partial")
            }),
        "details_truncated": coverage_truncated || breakdowns_truncated || unpriced_truncated
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
        "protocol_version": 2,
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
    let stale = !snapshot_is_valid(snapshot, now);
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

fn snapshot_is_valid(snapshot: &Value, now: DateTime<Utc>) -> bool {
    if snapshot.get("status").and_then(Value::as_str) != Some("available") {
        return false;
    }
    snapshot
        .get("valid_until")
        .and_then(Value::as_str)
        .is_none_or(|value| {
            DateTime::parse_from_rfc3339(value)
                .map(|value| value.with_timezone(&Utc) > now)
                .unwrap_or(false)
        })
}

fn merge_overview_item(
    items: &mut Vec<QuotaOverviewItem>,
    mut incoming: QuotaOverviewItem,
    now: DateTime<Utc>,
) {
    let Some(existing) = items
        .iter_mut()
        .find(|item| item.identity == incoming.identity)
    else {
        items.push(incoming);
        return;
    };
    let incoming_better = overview_choice_is_better(&incoming, existing, now);
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

fn overview_choice_is_better(
    incoming: &QuotaOverviewItem,
    existing: &QuotaOverviewItem,
    now: DateTime<Utc>,
) -> bool {
    let incoming_valid = snapshot_is_valid(&incoming.snapshot, now);
    let existing_valid = snapshot_is_valid(&existing.snapshot, now);
    if incoming_valid != existing_valid {
        return incoming_valid;
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
    snapshot
        .get("observed_at")
        .and_then(Value::as_str)
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
        .unwrap_or(DateTime::<Utc>::MIN_UTC)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

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

    #[test]
    fn account_usage_detail_preserves_models_without_structured_clients() {
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
        let detail = account_usage_detail(json!({
            "range": {"from": "2026-08-06", "to": "2026-08-12"},
            "totals": totals,
            "cost": cost,
            "coverage": [],
            "breakdowns": [{
                "dimension": "model",
                "key": "gpt-test",
                "totals": totals,
                "cost": cost
            }]
        }))
        .expect("detail");
        assert_eq!(detail["usage"]["totals"]["total_tokens"], 13);
        assert_eq!(detail["usage"]["totals"]["messages"], 2);
        assert_eq!(detail["fallback_models"][0]["model"], "gpt-test");
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
        assert!(backend.configured_providers().is_empty());
        let report = backend
            .collect_quota(Arc::new(AtomicBool::new(false)))
            .expect("local quota report");
        assert_eq!(
            report.get("protocol_version").and_then(Value::as_u64),
            Some(2)
        );
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
            "schema_version": 1,
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
    fn diagnostic_report_is_bounded_without_source_details() {
        let root = std::env::temp_dir().join(format!("quota-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let relay = Arc::new(RelayClient::new().expect("relay"));
        let backend = NativeBackend::new(state.clone(), relay, "QuotaTest", "test");
        state
            .write_sync_diagnostic(&json!({
                "status": "blocked",
                "error": "unrepresentable_hour"
            }))
            .expect("sync diagnostic");
        let report = backend.diagnostic_report().expect("diagnostics");
        assert_eq!(report.schema_version, 1);
        assert_eq!(report.components.len(), 6);
        assert_eq!(
            report
                .components
                .iter()
                .map(|component| component.name.as_str())
                .collect::<Vec<_>>(),
            ["providers", "quota", "usage", "pricing", "account", "sync"]
        );
        let serialized = serde_json::to_string(&report).expect("serialize");
        assert!(!serialized.contains("source_file_id"));
        assert!(!serialized.contains("/tmp"));
        assert!(
            report
                .issues
                .iter()
                .any(|issue| issue.component == "sync" && issue.code == "unrepresentable_hour")
        );
        assert_eq!(
            report
                .components
                .iter()
                .find(|component| component.name == "sync")
                .map(|component| component.status.as_str()),
            Some("blocked")
        );
        state
            .write_sync_diagnostic(&json!({
                "status": "degraded",
                "error": "invalid_usage_batch"
            }))
            .expect("degraded sync diagnostic");
        let degraded = backend.diagnostic_report().expect("degraded diagnostics");
        assert_eq!(
            degraded
                .components
                .iter()
                .find(|component| component.name == "sync")
                .map(|component| component.status.as_str()),
            Some("degraded")
        );
        assert!(
            degraded
                .issues
                .iter()
                .any(|issue| issue.component == "sync" && issue.code == "invalid_usage_batch")
        );
        state
            .set_usage_upload_enabled(false)
            .expect("disable Usage upload");
        assert!(!backend.stage_outbox("UTC").expect("staging disabled"));
        assert!(!backend.drain_outbox().expect("upload disabled"));
        let disabled = backend.diagnostic_report().expect("disabled diagnostics");
        let sync = disabled
            .components
            .iter()
            .find(|component| component.name == "sync")
            .expect("sync component");
        assert_eq!(sync.status, "ready");
        assert_eq!(sync.metrics.get("usage_upload_enabled"), Some(&0));
        assert!(
            !disabled
                .issues
                .iter()
                .any(|issue| issue.component == "sync" && issue.code == "invalid_usage_batch")
        );
        drop(backend);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn quota_diagnostics_classify_all_failed_and_mixed_outcomes() {
        let all_auth = json!({
            "results": [
                {"provider": "one", "outcome": "auth_required", "snapshots": []},
                {"provider": "two", "outcome": "auth_required", "snapshots": []}
            ]
        });
        assert_eq!(quota_collection_status(Some(&all_auth)), "blocked");

        let all_unavailable = json!({
            "results": [
                {"provider": "one", "outcome": "unavailable", "snapshots": []},
                {"provider": "two", "outcome": "error", "snapshots": []}
            ]
        });
        assert_eq!(quota_collection_status(Some(&all_unavailable)), "blocked");

        let mixed = json!({
            "results": [
                {"provider": "one", "outcome": "success", "snapshots": [{}]},
                {"provider": "two", "outcome": "unavailable", "snapshots": []}
            ]
        });
        assert_eq!(quota_collection_status(Some(&mixed)), "degraded");
        assert_eq!(quota_diagnostic_metrics(Some(&mixed))["success"], 1);
        assert_eq!(quota_diagnostic_metrics(Some(&mixed))["unavailable"], 1);
    }

    #[test]
    fn timezone_prefers_explicit_valid_tz_and_resolves_without_tz() {
        let explicit = HashMap::from([(String::from("TZ"), String::from("Asia/Tokyo"))]);
        assert_eq!(resolve_timezone(&explicit), "Asia/Tokyo");
        let invalid = HashMap::from([(String::from("TZ"), String::from("not/a-zone"))]);
        assert_ne!(resolve_timezone(&invalid), "not/a-zone");
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
