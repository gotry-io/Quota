//! Production backend adapter.  The service owns orchestration; this adapter owns the concrete
//! provider, Usage, pricing, and Relay calls and returns only protocol-shaped values.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use chrono::{DateTime, SecondsFormat, Timelike, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::catalog::ProviderId;
use crate::pricing::{self, UsageCostMode};
use crate::protocol::{
    ErrorCode, IpcError, QuotaOverviewIdentity, QuotaOverviewItem, QuotaOverviewSource,
    RecoveryAction,
};
use crate::providers::common::ErrorCategory;
use crate::providers::{self, CollectionContext};
use crate::relay::{AccountManager, RelayClient};
use crate::service::{BackendError, LocalBackend, LoginOutcome, RefreshOutcome};
use crate::state::{StateStore, UsageDirtyRange, now_rfc3339};
use crate::usage::{self, CoverageStatus, UsageAgent, UsageHourlyFact, UsageScanOptions};

const PARSER_REVISION: &str = "quota-usage-rust-2";
const FILE_INDEX_PARSER_REVISION: &str = "usage-rust-v3";
const MAX_USAGE_UPLOADS_PER_REFRESH: usize = 8;
const DEFAULT_TIMEZONE: &str = "UTC";

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
            let scan = usage::scan_local_usage(agent, &options).map_err(|_| BackendError {
                error: IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
            })?;
            if scan.coverage.status == CoverageStatus::Complete {
                self.state
                    .apply_usage_scan(agent, &scan)
                    .map_err(|_| BackendError::unavailable())?;
            }
            agents.push(AgentUsage {
                coverage: scan.coverage.clone(),
            });
        }
        let events = self
            .state
            .usage_events()
            .map_err(|_| BackendError::unavailable())?;
        if agents
            .iter()
            .all(|agent| agent.coverage.status == CoverageStatus::Complete)
        {
            // The Rust file index/normalized-record tables are now the source of truth; the
            // released cursor artifact has been observed and is no longer retained.
            crate::compatibility::finish_released_usage_cache(&self.state);
        }
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
        let totals = usage::fold_usage_facts(rows).map_err(|_| BackendError {
            error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
        })?;
        let cost = pricing::calculate_usage_cost(rows, catalog, UsageCostMode::Calculate).map_err(
            |_| BackendError {
                error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
            },
        )?;
        let breakdowns =
            usage::build_usage_breakdowns(rows, catalog, UsageCostMode::Calculate, false)
                .map_err(|_| BackendError::unavailable())?;
        let (from, to) = usage_date_range(rows);
        Ok(json!({
            "protocol_version": 2,
            "generated_at": usage.generated_at,
            "aggregation_timezone": usage.timezone,
            "range": {"from": from, "to": to},
            "status": status,
            "totals": totals,
            "cost": cost,
            "coverage": coverage,
            "breakdowns": breakdowns
        }))
    }

    fn refresh_pricing(
        &self,
        released: crate::compatibility::ReleasedPricingCache,
    ) -> Result<Value, BackendError> {
        let old = self
            .state
            .component(crate::protocol::ComponentName::Pricing)
            .ok()
            .flatten()
            .and_then(|component| component.value);
        let local = old.or(released.catalog);
        let etag = self
            .state
            .pricing_etag()
            .map_err(|_| BackendError::unavailable())?
            .or(released.etag);
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

    fn stage_outbox(&self, timezone: &str) -> Result<(), BackendError> {
        let Some((session, session_epoch)) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
        else {
            return Ok(());
        };
        if session.get("status").and_then(Value::as_str) != Some("active") {
            return Ok(());
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
            return Ok(());
        }
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
        let events = self
            .state
            .usage_events()
            .map_err(|_| BackendError::unavailable())?;
        let complete_until = DateTime::parse_from_rfc3339(&floor_utc_hour(&Utc::now()))
            .map_err(|_| BackendError::unavailable())?;
        for range in &dirty_ranges {
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
                let chunk_end = (start + chrono::Duration::hours(usage::MAX_USAGE_COVERAGE_HOURS))
                    .min(eligible_end);
                let range_rows = events
                    .iter()
                    .filter(|event| {
                        event.agent == range.agent
                            && DateTime::parse_from_rfc3339(&event.occurred_at)
                                .ok()
                                .is_some_and(|occurred| {
                                    occurred >= start
                                        && occurred < chunk_end
                                        && occurred >= lower_bound
                                })
                    })
                    .cloned()
                    .collect::<Vec<_>>();
                let rows = usage::aggregate_usage_events(&range_rows, timezone).map_err(|_| {
                    BackendError {
                        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                    }
                })?;
                if rows.len() > usage::MAX_USAGE_ROWS {
                    return Err(BackendError {
                        error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                    });
                }
                let mut rows_value = serde_json::to_value(&rows).map_err(|_| BackendError {
                    error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                })?;
                if let Some(row_values) = rows_value.as_array_mut() {
                    for row in row_values {
                        if row.get("source_cost_microusd").is_some_and(Value::is_null)
                            && let Some(object) = row.as_object_mut()
                        {
                            object.remove("source_cost_microusd");
                        }
                    }
                }
                let submission_id = stable_range_submission_id(&SubmissionIdentity {
                    agent: range.agent,
                    start: &start,
                    end: &chunk_end,
                    timezone,
                    account_id,
                    device_id,
                    generation,
                    sequence,
                    rows: &rows,
                });
                let consumed = UsageDirtyRange {
                    agent: range.agent,
                    start_at: start.to_rfc3339_opts(SecondsFormat::Secs, true),
                    end_at: chunk_end.to_rfc3339_opts(SecondsFormat::Secs, true),
                };
                let submission = json!({
                    "protocol_version": 2,
                    "submission_id": submission_id,
                    "device_id": device_id,
                    "generation": generation,
                    "sequence": sequence,
                    "parser_revision": PARSER_REVISION,
                    "aggregation_timezone": timezone,
                    "coverage": {
                        "agent": range.agent,
                        "start_at": start.to_rfc3339_opts(SecondsFormat::Secs, true),
                        "end_at": chunk_end.to_rfc3339_opts(SecondsFormat::Secs, true),
                        "status": "complete"
                    },
                    "rows": rows_value
                });
                crate::relay::validate_usage_submission(&submission).map_err(|_| BackendError {
                    error: IpcError::new(ErrorCode::InvalidState, RecoveryAction::Retry),
                })?;
                if self
                    .state
                    .stage_outbox_entry(account_id, &submission, &consumed)
                    .map_err(|_| BackendError::unavailable())?
                {
                    sequence = sequence.saturating_add(1);
                    stage_slots -= 1;
                    if stage_slots == 0 {
                        return Ok(());
                    }
                }
                start = chunk_end;
            }
        }
        Ok(())
    }

    fn drain_outbox(&self) -> Result<(), BackendError> {
        let Some((session, session_epoch)) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
        else {
            return Ok(());
        };
        if session.get("status").and_then(Value::as_str) != Some("active")
            || !self
                .state
                .active_session_at_epoch(session_epoch)
                .map_err(|_| BackendError::unavailable())?
        {
            return Ok(());
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
        for entry in entries.into_iter().take(MAX_USAGE_UPLOADS_PER_REFRESH) {
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
                "partial" => break,
                "stale_generation" | "deleted" => {
                    return Err(BackendError {
                        error: IpcError::new(
                            ErrorCode::AuthenticationRequired,
                            RecoveryAction::Login,
                        ),
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
        Ok(())
    }

    fn timezone(&self) -> String {
        resolve_timezone(&self.environment)
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
        let released = crate::compatibility::released_pricing_cache(&self.state);
        let cached_catalog = self
            .state
            .component(crate::protocol::ComponentName::Pricing)
            .ok()
            .flatten()
            .and_then(|component| component.value)
            .or(released.catalog.clone())
            .and_then(|value| serde_json::from_value(value).ok());
        let pricing = self.refresh_pricing(released);
        let catalog = pricing
            .as_ref()
            .ok()
            .and_then(|value| serde_json::from_value(value.clone()).ok())
            .or(cached_catalog);
        let usage_collection = usage.ok();
        let usage_value = match usage_collection.as_ref() {
            Some(value) => self.usage_report(value, catalog.as_ref()),
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
                        if let Ok(quota_payload) = &quota_value
                            && let Err(error) = self.account.upload_quota_report(quota_payload)
                        {
                            account_sync_error = Some(error);
                        }
                        if let Some(usage_collection) = usage_collection.as_ref() {
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
                            } else if let Err(error) = self.stage_outbox(&usage_collection.timezone)
                            {
                                account_sync_error = Some(error);
                            }
                        }
                        if account_sync_error.is_none()
                            && let Err(error) = self.drain_outbox()
                        {
                            account_sync_error = Some(error);
                        }
                        if account_sync_error.is_none() {
                            account_value = self.account.refresh_account_state(cancel.as_ref());
                            if account_value.as_ref().err().is_some_and(|error| {
                                error.error.code == ErrorCode::AuthenticationRequired
                            }) {
                                self.clear_active_session();
                            }
                        } else if let Some(error) = account_sync_error {
                            account_value = Err(error);
                        }
                    }
                    Err(error) => {
                        if error.error.code == ErrorCode::AuthenticationRequired {
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

fn usage_date_range(rows: &[UsageHourlyFact]) -> (String, String) {
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let from = rows
        .iter()
        .map(|row| row.usage_date.clone())
        .min()
        .unwrap_or_else(|| today.clone());
    let to = rows
        .iter()
        .map(|row| row.usage_date.clone())
        .max()
        .unwrap_or(today);
    (from, to)
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

struct SubmissionIdentity<'a> {
    agent: UsageAgent,
    start: &'a DateTime<chrono::FixedOffset>,
    end: &'a DateTime<chrono::FixedOffset>,
    timezone: &'a str,
    account_id: &'a str,
    device_id: &'a str,
    generation: u64,
    sequence: u64,
    rows: &'a [UsageHourlyFact],
}

fn stable_range_submission_id(identity: &SubmissionIdentity<'_>) -> String {
    let material = json!({
        "parser_revision": PARSER_REVISION,
        "agent": identity.agent,
        "aggregation_timezone": identity.timezone,
        "account_id": identity.account_id,
        "device_id": identity.device_id,
        "generation": identity.generation,
        "sequence": identity.sequence,
        "start_at": identity.start.to_rfc3339_opts(SecondsFormat::Secs, true),
        "end_at": identity.end.to_rfc3339_opts(SecondsFormat::Secs, true),
        "rows": identity.rows,
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
    MAX_USAGE_UPLOADS_PER_REFRESH.saturating_sub(existing_entries)
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
    fn timezone_prefers_explicit_valid_tz_and_resolves_without_tz() {
        let explicit = HashMap::from([(String::from("TZ"), String::from("Asia/Tokyo"))]);
        assert_eq!(resolve_timezone(&explicit), "Asia/Tokyo");
        let invalid = HashMap::from([(String::from("TZ"), String::from("not/a-zone"))]);
        assert_ne!(resolve_timezone(&invalid), "not/a-zone");
    }

    #[test]
    fn usage_upload_batch_matches_stage_and_drain_budget() {
        assert_eq!(usage_stage_slots(0), 8);
        assert_eq!(usage_stage_slots(7), 1);
        assert_eq!(usage_stage_slots(8), 0);
        assert_eq!(usage_stage_slots(64), 0);
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
        let report = backend.usage_report(&collection, None).expect("report");
        assert_eq!(
            report.get("status").and_then(Value::as_str),
            Some("complete")
        );
        assert!(
            report
                .get("coverage")
                .and_then(Value::as_array)
                .is_some_and(|items| items.iter().all(|item| {
                    item.get("status").and_then(Value::as_str) == Some("complete")
                }))
        );
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
