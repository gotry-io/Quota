//! Produce, back-fill, and read Account quota history.
//!
//! The bucketing rules live in [`crate::history`]. This module is the Relay trip: after a
//! collection, global-scope samples past the watermark; on the `false → true` transition, the
//! whole span, once.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use chrono::{SecondsFormat, Utc};
use serde_json::Value;

use crate::catalog::ProviderId;
use crate::history::{
    MAXIMUM_QUOTA_HISTORY_POINTS_PER_UPLOAD, MAXIMUM_QUOTA_HISTORY_UPLOAD_BYTES,
    QuotaHistoryLocalSample, QuotaHistorySeriesInput, QuotaHistorySyncedPoint,
    QuotaHistoryUploadAnswer, chunk_quota_history_upload, history_sync_enabled,
    plan_quota_history_upload, quota_history_reseed_oldest, quota_history_rows_lost,
    quota_history_series_key, whole_second_utc,
};
use crate::protocol::{ComponentName, ErrorCode, QuotaOverviewIdentity, RecoveryAction};
use crate::service::BackendError;
use crate::state::{QuotaHistoryReadCache, QuotaHistorySeriesRecord, QuotaHistorySyncRecord};

use super::{AccountManager, RelayError, is_active_session, relay_backend_error};

impl AccountManager {
    /// The settings document just stored. A `false → true` transition backfills once.
    pub(crate) fn note_history_settings(
        &self,
        account_id: &str,
        document: &Value,
        cancel: &std::sync::atomic::AtomicBool,
    ) {
        if self.note_history_switch(account_id, document) {
            let Ok(_guard) = self.history_lock.lock() else {
                return;
            };
            self.upload_locked(account_id, true, cancel);
        }
    }

    /// The same, for the IPC lane: the record is written now and the backfill — several PUTs of
    /// up to 20 s each — runs on its own thread, so `set_account_settings` and
    /// `refresh_account_settings` answer at once and no other IPC request waits behind it.
    pub(crate) fn note_history_settings_detached(
        self: &Arc<Self>,
        account_id: &str,
        document: &Value,
    ) {
        if !self.note_history_switch(account_id, document) {
            return;
        }
        let manager = Arc::clone(self);
        let account_id = account_id.to_owned();
        let spawned = std::thread::Builder::new()
            .name("quota-history-backfill".to_owned())
            .spawn(move || {
                let Ok(_guard) = manager.history_lock.lock() else {
                    return;
                };
                manager.upload_locked(
                    &account_id,
                    true,
                    &std::sync::atomic::AtomicBool::new(false),
                );
            });
        match spawned {
            Ok(handle) => {
                // An earlier handle is dropped, not joined: its thread finishes on its own,
                // and the IPC lane must not wait behind it.
                if let Ok(mut slot) = self.history_backfill.lock() {
                    *slot = Some(handle);
                }
            }
            Err(_) => eprintln!("quota-history: could not start the backfill thread"),
        }
    }

    /// Blocks until the detached backfill, if one is running, has finished.
    pub(crate) fn wait_for_history_backfill(&self) {
        let handle = self
            .history_backfill
            .lock()
            .ok()
            .and_then(|mut slot| slot.take());
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }

    /// Records what the document says about the switch. `true` when a backfill is owed.
    fn note_history_switch(&self, account_id: &str, document: &Value) -> bool {
        let Ok(_guard) = self.history_lock.lock() else {
            return false;
        };
        let Ok(mut record) = self.state.quota_history_sync(account_id) else {
            return false;
        };
        let enabled = history_sync_enabled(document);
        // Off is honoured even while Relay says the Account is full: the switch turning off is
        // how the rows go, and the record must forget its watermarks so the next switch-on
        // backfills instead of resuming past data Relay no longer holds.
        if !enabled {
            if record.sync
                || record.backfill_done
                || record.refused_revision.is_some()
                || !record.series.is_empty()
                || record.last_error.is_some()
            {
                record.sync = false;
                record.backfill_done = false;
                record.refused_revision = None;
                record.series.clear();
                record.last_error = None;
                let _ = self.state.set_quota_history_sync(account_id, &record);
            }
            return false;
        }
        if self.history_full.load(Ordering::Acquire) {
            return false;
        }
        let revision = document.get("revision").and_then(Value::as_u64);
        if record.refused_revision.is_some() && record.refused_revision == revision {
            return false;
        }
        let needs_backfill = !record.sync || !record.backfill_done;
        record.sync = true;
        record.refused_revision = None;
        if self
            .state
            .set_quota_history_sync(account_id, &record)
            .is_err()
        {
            return false;
        }
        needs_backfill
    }

    /// After samples from this collection are in `cache.sqlite`. Incremental when this on-period
    /// was already backfilled; otherwise the backfill that a crash left unfinished.
    pub(crate) fn sync_quota_history_after_collection(
        &self,
        cancel: &std::sync::atomic::AtomicBool,
    ) {
        let Ok(_guard) = self.history_lock.lock() else {
            return;
        };
        // The previous `413` asked us to wait until this collection.
        self.history_full.store(false, Ordering::Release);
        let Ok(Some((session, _epoch))) = self.state.session_snapshot() else {
            return;
        };
        if !is_active_session(&session) {
            return;
        }
        let Some(account_id) = session.get("account_id").and_then(Value::as_str) else {
            return;
        };
        let Ok(Some(cached)) = self.state.account_settings_cache(account_id) else {
            return;
        };
        if !history_sync_enabled(&cached.state.document) {
            return;
        }
        let Ok(record) = self.state.quota_history_sync(account_id) else {
            return;
        };
        let revision = cached
            .state
            .document
            .get("revision")
            .and_then(Value::as_u64);
        if record.refused_revision.is_some() && record.refused_revision == revision {
            return;
        }
        self.upload_locked(account_id, !record.backfill_done, cancel);
    }

    /// One subscription, Relay's merge already applied. 304 reuses the cached body.
    pub(crate) fn read_account_quota_history(
        &self,
        provider: &str,
        fingerprint: &str,
        since: &str,
        cancel: &std::sync::atomic::AtomicBool,
    ) -> Result<Value, BackendError> {
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        let (mut session, mut session_epoch) = self.active_session_pair()?;
        let access_token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(BackendError::unavailable)?
            .to_owned();
        let cached = self
            .state
            .quota_history_read_cache(&account_id)
            .ok()
            .flatten();
        let etag = cached.as_ref().and_then(|cache| {
            (cache.provider == provider
                && cache.fingerprint == fingerprint
                && cache.since == since
                && !cache.etag.is_empty())
            .then_some(cache.etag.as_str())
        });
        let (next_etag, body) = self
            .client
            .account_quota_history(&access_token, provider, fingerprint, since, etag)
            .map_err(|error| relay_backend_error(error, session_epoch))?;
        match body {
            Some(body) => {
                if let Some(etag) = next_etag.filter(|value| !value.is_empty()) {
                    let _ = self.state.set_quota_history_read_cache(
                        &account_id,
                        &QuotaHistoryReadCache {
                            provider: provider.to_owned(),
                            fingerprint: fingerprint.to_owned(),
                            since: since.to_owned(),
                            etag,
                            body: body.clone(),
                        },
                    );
                }
                Ok(body)
            }
            None => cached
                .filter(|cache| {
                    cache.provider == provider
                        && cache.fingerprint == fingerprint
                        && cache.since == since
                })
                .map(|cache| {
                    if let Some(etag) = next_etag.filter(|value| !value.is_empty()) {
                        let _ = self.state.set_quota_history_read_cache(
                            &account_id,
                            &QuotaHistoryReadCache {
                                etag,
                                ..cache.clone()
                            },
                        );
                    }
                    cache.body
                })
                .ok_or_else(|| {
                    BackendError::new(crate::protocol::IpcError::new(
                        ErrorCode::InvalidResponse,
                        RecoveryAction::Retry,
                    ))
                }),
        }
    }

    fn upload_locked(
        &self,
        account_id: &str,
        backfill: bool,
        cancel: &std::sync::atomic::AtomicBool,
    ) {
        if cancel.load(Ordering::Acquire) || self.history_full.load(Ordering::Acquire) {
            return;
        }
        let Ok((mut session, mut session_epoch)) = self.active_session_pair() else {
            return;
        };
        if session.get("account_id").and_then(Value::as_str) != Some(account_id) {
            return;
        }
        let Ok(access_token) = self.ensure_fresh_session(&mut session, &mut session_epoch) else {
            return;
        };
        let Some(generation) = session
            .get("device_generation")
            .and_then(Value::as_u64)
            .filter(|generation| *generation > 0)
        else {
            return;
        };
        let Ok(mut record) = self.state.quota_history_sync(account_id) else {
            return;
        };
        let revision = self
            .state
            .account_settings_cache(account_id)
            .ok()
            .flatten()
            .and_then(|cached| {
                cached
                    .state
                    .document
                    .get("revision")
                    .and_then(Value::as_u64)
            });
        // Relay lost rows of a series behind this device (the switch went off and on between
        // two of its refreshes): that series is backfilled again, once per pass.
        let mut rebackfilled = false;
        loop {
            let now = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
            let planned = plan_quota_history_upload(&series_inputs(&self.state, &record), &now);
            if planned.is_empty() {
                // Nothing to send is not an error, so an earlier one stops being shown.
                let changed = (backfill && !record.backfill_done) || record.last_error.is_some();
                if backfill && !record.backfill_done {
                    record.backfill_done = true;
                    record.sync = true;
                }
                record.last_error = None;
                if changed {
                    let _ = self.state.set_quota_history_sync(account_id, &record);
                }
                return;
            }
            let chunks = chunk_quota_history_upload(
                &planned,
                generation,
                MAXIMUM_QUOTA_HISTORY_POINTS_PER_UPLOAD,
                MAXIMUM_QUOTA_HISTORY_UPLOAD_BYTES,
            );
            let mut lost = Vec::new();
            for chunk in &chunks {
                if cancel.load(Ordering::Acquire) {
                    return;
                }
                match self.client.put_quota_history(&access_token, chunk) {
                    Ok(answer) => {
                        let answered_at = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
                        // The second pass re-seeds the record; it does not judge again.
                        if !rebackfilled {
                            lost = lost_series(&record, chunk, &answer, &answered_at);
                        }
                        remember_chunk(&mut record, chunk, &answered_at);
                        apply_answer(&mut record, &answer);
                        for key in &lost {
                            record.series.remove(key);
                        }
                        record.last_upload_at = Some(answered_at);
                        record.last_error = None;
                        if self
                            .state
                            .set_quota_history_sync(account_id, &record)
                            .is_err()
                        {
                            return;
                        }
                        if !lost.is_empty() {
                            // The rest of this plan resumes past watermarks the lost series no
                            // longer has; plan again from the cleared record.
                            break;
                        }
                    }
                    Err(RelayError::Rejected { ref code, .. }) if code == "history_sync_off" => {
                        record.series.clear();
                        record.sync = false;
                        record.backfill_done = false;
                        record.refused_revision = revision;
                        record.last_error = Some("history_sync_off".to_owned());
                        let _ = self.state.set_quota_history_sync(account_id, &record);
                        return;
                    }
                    Err(RelayError::Rejected { ref code, status })
                        if code == "quota_history_full" || status == 413 =>
                    {
                        record.last_error = Some("quota_history_full".to_owned());
                        self.history_full.store(true, Ordering::Release);
                        eprintln!("quota-history: upload stopped, quota_history_full");
                        let _ = self.state.set_quota_history_sync(account_id, &record);
                        return;
                    }
                    Err(error) => {
                        let code = history_error_code(&error);
                        if code == "rejected" && record.last_error.as_deref() != Some(code) {
                            eprintln!(
                                "quota-history: Relay refused the upload body (400); a clock more than one bucket ahead of Relay does this on every upload"
                            );
                        }
                        record.last_error = Some(code.to_owned());
                        let _ = self.state.set_quota_history_sync(account_id, &record);
                        let backend = relay_backend_error(error, session_epoch);
                        if let Some(epoch) = backend.sign_out_epoch() {
                            let _ = self.state.clear_session_if_epoch(epoch);
                        }
                        return;
                    }
                }
            }
            if lost.is_empty() || rebackfilled {
                break;
            }
            rebackfilled = true;
            eprintln!(
                "quota-history: Relay no longer holds rows this device uploaded; backfilling {} series again",
                lost.len()
            );
        }
        if backfill {
            record.backfill_done = true;
            record.sync = true;
            let _ = self.state.set_quota_history_sync(account_id, &record);
        }
    }
}

fn history_error_code(error: &RelayError) -> &'static str {
    match error {
        RelayError::AuthenticationRequired => "authentication_required",
        RelayError::InvalidResponse | RelayError::ResponseTooLarge => "invalid_response",
        RelayError::Rejected { code, .. } if code == "history_sync_off" => "history_sync_off",
        RelayError::Rejected { code, .. } if code == "quota_history_full" => "quota_history_full",
        // Relay refused the body itself: a point it will not take, which a clock more than one
        // bucket ahead of Relay's produces on every upload. Named apart from a network failure so
        // the Settings caption can say what to check.
        RelayError::Rejected { status: 400, .. } => "rejected",
        _ => "network",
    }
}

pub(super) fn series_inputs(
    state: &crate::state::StateStore,
    record: &QuotaHistorySyncRecord,
) -> Vec<QuotaHistorySeriesInput> {
    let quota = state
        .component(ComponentName::Quota)
        .ok()
        .flatten()
        .and_then(|component| component.value);
    let overview = state.overview().unwrap_or_default();
    let samples = state.quota_samples().unwrap_or_default();
    let mut windows = BTreeMap::<(String, String), (String, String, i64)>::new();
    if let Some(quota) = quota.as_ref() {
        collect_quota_windows(quota, &mut windows);
    }
    for item in &overview {
        if item.identity.scope != "global" {
            continue;
        }
        collect_snapshot_windows(
            &item.identity.provider,
            &item.identity.fingerprint,
            &item.snapshot,
            &mut windows,
        );
    }
    let mut series = Vec::new();
    for ((selector, window_id), (provider, fingerprint, duration_seconds)) in windows {
        let Some(stored) = samples
            .get(&selector)
            .and_then(|windows| windows.get(&window_id))
        else {
            continue;
        };
        let key = quota_history_series_key(&provider, &fingerprint, &window_id);
        let progress = record.series.get(&key);
        series.push(QuotaHistorySeriesInput {
            provider,
            fingerprint,
            window_id,
            duration_seconds,
            samples: stored.iter().map(local_sample).collect(),
            previous: progress
                .map(|progress| progress.previous.clone())
                .unwrap_or_default(),
            watermark: progress.and_then(|progress| progress.watermark.clone()),
        });
    }
    series
}

fn local_sample(sample: &crate::history::QuotaSample) -> QuotaHistoryLocalSample {
    let observed_at = if sample.observed_at.timestamp_subsec_nanos() == 0 {
        sample
            .observed_at
            .to_rfc3339_opts(SecondsFormat::Secs, true)
    } else {
        sample
            .observed_at
            .to_rfc3339_opts(SecondsFormat::Millis, true)
    };
    QuotaHistoryLocalSample {
        observed_at,
        used_percent: sample.used_percent,
        resets_at: sample.resets_at.to_rfc3339_opts(SecondsFormat::Secs, true),
    }
}

fn collect_quota_windows(
    quota: &Value,
    windows: &mut BTreeMap<(String, String), (String, String, i64)>,
) {
    for snapshot in quota
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|result| result.get("snapshots").and_then(Value::as_array))
        .flatten()
    {
        let Some(provider) = snapshot.get("provider").and_then(Value::as_str) else {
            continue;
        };
        let Some(account) = snapshot.get("account") else {
            continue;
        };
        let Some(fingerprint) = account.get("fingerprint").and_then(Value::as_str) else {
            continue;
        };
        collect_snapshot_windows(provider, fingerprint, snapshot, windows);
    }
}

fn collect_snapshot_windows(
    provider: &str,
    fingerprint: &str,
    snapshot: &Value,
    windows: &mut BTreeMap<(String, String), (String, String, i64)>,
) {
    let scope = snapshot
        .get("account")
        .and_then(|account| account.get("fingerprint_scope"))
        .and_then(Value::as_str)
        .unwrap_or("global");
    if scope != "global" || ProviderId::parse(provider).is_none() || !is_opaque_id(fingerprint) {
        return;
    }
    let selector = QuotaOverviewIdentity::selector_for(provider, fingerprint, "global", None);
    let Some(list) = snapshot.get("windows").and_then(Value::as_array) else {
        return;
    };
    for window in list {
        let Some(window_id) = window.get("id").and_then(Value::as_str) else {
            continue;
        };
        let Some(duration) = window.get("duration_seconds").and_then(Value::as_i64) else {
            continue;
        };
        if duration < 0 || !is_window_id(window_id) {
            continue;
        }
        windows
            .entry((selector.clone(), window_id.to_owned()))
            .or_insert_with(|| (provider.to_owned(), fingerprint.to_owned(), duration));
    }
}

fn remember_chunk(record: &mut QuotaHistorySyncRecord, chunk: &Value, now: &str) {
    let Some(series) = chunk.get("series").and_then(Value::as_array) else {
        return;
    };
    for series in series {
        let Some(provider) = series.get("provider").and_then(Value::as_str) else {
            continue;
        };
        let Some(fingerprint) = series.get("fingerprint").and_then(Value::as_str) else {
            continue;
        };
        let Some(window_id) = series.get("window_id").and_then(Value::as_str) else {
            continue;
        };
        let key = quota_history_series_key(provider, fingerprint, window_id);
        let slot = record.series.entry(key).or_default();
        let duration_seconds = series
            .get("duration_seconds")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if let Some(chunk_oldest) = chunk_series_oldest(series) {
            slot.oldest = Some(quota_history_reseed_oldest(
                slot.oldest.as_deref(),
                &chunk_oldest,
                duration_seconds,
                now,
            ));
        }
        for point in series
            .get("points")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let (Some(resets_at), Some(bucket_start), Some(used_percent)) = (
                point.get("resets_at").and_then(Value::as_str),
                point.get("bucket_start").and_then(Value::as_str),
                point.get("used_percent").and_then(Value::as_f64),
            ) else {
                continue;
            };
            remember_point(
                slot,
                QuotaHistorySyncedPoint {
                    resets_at: resets_at.to_owned(),
                    bucket_start: bucket_start.to_owned(),
                    used_percent,
                },
            );
        }
    }
}

/// The oldest `bucket_start` one series of a chunk sent.
fn chunk_series_oldest(series: &Value) -> Option<String> {
    series
        .get("points")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|point| point.get("bucket_start").and_then(Value::as_str))
        .filter_map(|bucket_start| Some((whole_second_utc(bucket_start)?, bucket_start)))
        .min_by_key(|(instant, _)| *instant)
        .map(|(_, bucket_start)| bucket_start.to_owned())
}

fn remember_point(slot: &mut QuotaHistorySeriesRecord, point: QuotaHistorySyncedPoint) {
    if let Some(existing) = slot
        .previous
        .iter_mut()
        .find(|existing| existing.resets_at == point.resets_at)
    {
        if point.bucket_start >= existing.bucket_start {
            if point.bucket_start == existing.bucket_start {
                existing.used_percent = existing.used_percent.max(point.used_percent);
            } else {
                *existing = point;
            }
        }
    } else {
        slot.previous.push(point);
    }
    if slot.previous.len() > 64 {
        slot.previous
            .sort_by(|left, right| left.resets_at.cmp(&right.resets_at));
        let extra = slot.previous.len() - 64;
        slot.previous.drain(0..extra);
    }
}

/// The series of `chunk` whose rows Relay no longer holds, judged before this chunk is
/// remembered: see [`quota_history_rows_lost`].
fn lost_series(
    record: &QuotaHistorySyncRecord,
    chunk: &Value,
    answer: &Value,
    now: &str,
) -> Vec<String> {
    let answered = answer
        .get("series")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let mut lost = Vec::new();
    for series in chunk
        .get("series")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let field = |name: &str| series.get(name).and_then(Value::as_str);
        let (Some(provider), Some(fingerprint), Some(window_id)) =
            (field("provider"), field("fingerprint"), field("window_id"))
        else {
            continue;
        };
        let key = quota_history_series_key(provider, fingerprint, window_id);
        let Some(chunk_oldest) = chunk_series_oldest(series) else {
            continue;
        };
        // Both from before this chunk is remembered.
        let slot = record.series.get(&key);
        let recorded = slot.and_then(|slot| slot.oldest.as_deref());
        let watermark = slot.and_then(|slot| slot.watermark.as_deref());
        let answer = answered
            .iter()
            .find(|candidate| {
                candidate.get("provider").and_then(Value::as_str) == Some(provider)
                    && candidate.get("fingerprint").and_then(Value::as_str) == Some(fingerprint)
                    && candidate.get("window_id").and_then(Value::as_str) == Some(window_id)
            })
            .map_or(QuotaHistoryUploadAnswer::Absent, |candidate| {
                QuotaHistoryUploadAnswer::Oldest(
                    candidate.get("oldest_bucket_start").and_then(Value::as_str),
                )
            });
        let duration_seconds = series
            .get("duration_seconds")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if quota_history_rows_lost(
            recorded,
            watermark,
            &chunk_oldest,
            answer,
            duration_seconds,
            now,
        ) {
            lost.push(key);
        }
    }
    lost
}

fn apply_answer(record: &mut QuotaHistorySyncRecord, answer: &Value) {
    let Some(series) = answer.get("series").and_then(Value::as_array) else {
        return;
    };
    for series in series {
        let Some(provider) = series.get("provider").and_then(Value::as_str) else {
            continue;
        };
        let Some(fingerprint) = series.get("fingerprint").and_then(Value::as_str) else {
            continue;
        };
        let Some(window_id) = series.get("window_id").and_then(Value::as_str) else {
            continue;
        };
        let Some(bucket_start) = series.get("bucket_start").and_then(Value::as_str) else {
            continue;
        };
        let key = quota_history_series_key(provider, fingerprint, window_id);
        let slot = record.series.entry(key).or_default();
        let replace = slot
            .watermark
            .as_deref()
            .is_none_or(|current| bucket_start > current);
        if replace {
            slot.watermark = Some(bucket_start.to_owned());
        }
    }
}

pub(super) fn quota_history_read_path(provider: &str, fingerprint: &str, since: &str) -> String {
    let mut query = url::form_urlencoded::Serializer::new(String::new());
    query.append_pair("provider", provider);
    query.append_pair("fingerprint", fingerprint);
    query.append_pair("since", since);
    format!("/api/v6/account/quota-history?{}", query.finish())
}

pub(super) fn validate_quota_history_upload_response(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64)
        != Some(crate::protocol::MANAGED_DATA_PROTOCOL)
    {
        return Err(RelayError::InvalidResponse);
    }
    let series = object
        .get("series")
        .and_then(Value::as_array)
        .ok_or(RelayError::InvalidResponse)?;
    for series in series {
        let series = series.as_object().ok_or(RelayError::InvalidResponse)?;
        let provider = series
            .get("provider")
            .and_then(Value::as_str)
            .ok_or(RelayError::InvalidResponse)?;
        let fingerprint = series
            .get("fingerprint")
            .and_then(Value::as_str)
            .ok_or(RelayError::InvalidResponse)?;
        let window_id = series
            .get("window_id")
            .and_then(Value::as_str)
            .ok_or(RelayError::InvalidResponse)?;
        let bucket_start = series
            .get("bucket_start")
            .and_then(Value::as_str)
            .ok_or(RelayError::InvalidResponse)?;
        // Optional on read: a Relay before the 2026-09-23 amendment does not send it.
        let oldest_is_valid = match series.get("oldest_bucket_start") {
            None => true,
            Some(value) => value
                .as_str()
                .is_some_and(|value| chrono::DateTime::parse_from_rfc3339(value).is_ok()),
        };
        if ProviderId::parse(provider).is_none()
            || !is_opaque_id(fingerprint)
            || !is_window_id(window_id)
            || chrono::DateTime::parse_from_rfc3339(bucket_start).is_err()
            || !oldest_is_valid
        {
            return Err(RelayError::InvalidResponse);
        }
    }
    Ok(())
}

pub(super) fn validate_quota_history_read(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64)
        != Some(crate::protocol::MANAGED_DATA_PROTOCOL)
        || !object.get("sync").is_some_and(Value::is_boolean)
    {
        return Err(RelayError::InvalidResponse);
    }
    let windows = object
        .get("windows")
        .and_then(Value::as_object)
        .ok_or(RelayError::InvalidResponse)?;
    for (window_id, window) in windows {
        if !is_window_id(window_id) {
            return Err(RelayError::InvalidResponse);
        }
        let window = window.as_object().ok_or(RelayError::InvalidResponse)?;
        if window
            .get("duration_seconds")
            .and_then(Value::as_i64)
            .is_none_or(|seconds| seconds < 0)
        {
            return Err(RelayError::InvalidResponse);
        }
        let points = window
            .get("points")
            .and_then(Value::as_array)
            .ok_or(RelayError::InvalidResponse)?;
        for point in points {
            let point = point.as_object().ok_or(RelayError::InvalidResponse)?;
            let resets_at = point
                .get("resets_at")
                .and_then(Value::as_str)
                .ok_or(RelayError::InvalidResponse)?;
            let bucket_start = point
                .get("bucket_start")
                .and_then(Value::as_str)
                .ok_or(RelayError::InvalidResponse)?;
            let used = point
                .get("used_percent")
                .and_then(Value::as_f64)
                .ok_or(RelayError::InvalidResponse)?;
            if chrono::DateTime::parse_from_rfc3339(resets_at).is_err()
                || chrono::DateTime::parse_from_rfc3339(bucket_start).is_err()
                || !used.is_finite()
                || !(0.0..=100.0).contains(&used)
            {
                return Err(RelayError::InvalidResponse);
            }
        }
    }
    Ok(())
}

fn is_opaque_id(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.len() <= 128
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

fn is_window_id(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.len() <= 64
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"._:+-".contains(&byte))
}
