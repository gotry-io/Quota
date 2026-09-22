//! How a window's local samples fold into the history a surface draws, and how those samples
//! become the buckets an Account upload carries.
//!
//! Pace answers a window from one reading ([`crate::pace`], ADR 0035). A curve needs more than
//! one, so this device keeps its own readings in `cache.sqlite` and folds them here: the line
//! behind the reader, the dashed extrapolation ADR 0035 already names, and the windows that
//! belong to the reader's today. The fold stays on the device (ADR 0042). While the Account's
//! history switch is on, [`bucket_quota_samples`] is what a producer uploads (ADR 0062). This
//! module does not talk to Relay.

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::observation::instant;
use crate::pace::window_pace;

/// Two readings closer together than this say the same thing about the curve, so only the
/// first of them becomes a point.
pub const HISTORY_DECIMATION_SECONDS: i64 = 300;

/// How long a sample is worth keeping. A month covers every window cadence a provider states
/// and every "what did yesterday look like" a reader asks, and stops there.
pub const HISTORY_RETENTION_DAYS: i64 = 30;

/// One stored reading of one window.
#[derive(Debug, Clone, PartialEq)]
pub struct QuotaSample {
    pub resets_at: DateTime<Utc>,
    pub observed_at: DateTime<Utc>,
    pub used_percent: f64,
}

/// The history of one window, in the shape the IPC state carries it, or `None` when there is
/// nothing to draw: no sample yet, or a window with no cadence to place its samples in.
///
/// `points` is the curve so far as `(elapsed_fraction, used_percent)`; `projection` is the one
/// point the dashed line ends on, ADR 0035's `projected_at_reset` at `elapsed = 1`;
/// `windows_today` is every window of this id the reader's day holds.
pub fn window_history(
    window: &Value,
    samples: &[QuotaSample],
    now: DateTime<Utc>,
    utc_offset_seconds: i32,
) -> Option<Value> {
    let resets_at = instant(window.get("resets_at"))?;
    let seconds = window
        .get("duration_seconds")
        .and_then(Value::as_i64)
        .filter(|seconds| *seconds > 0)?;
    let cadence = seconds as f64;

    let mut grouped: BTreeMap<DateTime<Utc>, Vec<&QuotaSample>> = BTreeMap::new();
    for sample in samples {
        grouped.entry(sample.resets_at).or_default().push(sample);
    }
    for group in grouped.values_mut() {
        group.sort_by_key(|sample| sample.observed_at);
    }
    if grouped.is_empty() {
        return None;
    }

    let current = grouped.get(&resets_at).map(|group| rising(group));
    let points = current
        .as_deref()
        .map(|rising| curve(rising, resets_at, seconds, cadence))
        .unwrap_or_default();
    let projection = current
        .as_deref()
        .and_then(|rising| rising.last())
        .and_then(|(sample, used)| {
            let projected = window_pace(
                &json!({
                    "used_percent": used,
                    "resets_at": resets_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                    "duration_seconds": seconds
                }),
                sample.observed_at,
            );
            projected
                .get("projected_at_reset")
                .and_then(Value::as_f64)
                .map(|value| json!({ "elapsed_fraction": 1.0, "used_percent": round(value, 2) }))
        });

    let today = local_day(now, utc_offset_seconds);
    let windows_today = grouped
        .iter()
        .filter(|(group_resets, _)| {
            local_day(**group_resets, utc_offset_seconds) == today || **group_resets > now
        })
        .map(|(group_resets, group)| {
            let peak = group
                .iter()
                .map(|sample| sample.used_percent)
                .fold(f64::NEG_INFINITY, f64::max);
            json!({
                "started_at": rfc3339(*group_resets - Duration::seconds(seconds)),
                "resets_at": rfc3339(*group_resets),
                "peak_used_percent": round(peak, 2),
                "is_current": *group_resets == resets_at
            })
        })
        .collect::<Vec<_>>();

    if points.is_empty() && windows_today.is_empty() {
        return None;
    }
    Some(json!({
        "points": points,
        "projection": projection,
        "windows_today": windows_today
    }))
}

/// Restate a snapshot with each of its windows carrying the history of its own samples.
///
/// Only a reading this device took itself has samples behind it, so only such a snapshot is
/// passed here: a window with nothing stored simply keeps no `history` key.
pub fn snapshot_with_history(
    snapshot: &Value,
    samples: &BTreeMap<String, Vec<QuotaSample>>,
    now: DateTime<Utc>,
    utc_offset_seconds: i32,
) -> Value {
    let mut restated = snapshot.clone();
    let Some(windows) = restated.get_mut("windows").and_then(Value::as_array_mut) else {
        return restated;
    };
    for window in windows {
        let Some(id) = window.get("id").and_then(Value::as_str).map(str::to_owned) else {
            continue;
        };
        let history = window_history(
            window,
            samples.get(&id).map(Vec::as_slice).unwrap_or_default(),
            now,
            utc_offset_seconds,
        );
        if let (Some(history), Some(object)) = (history, window.as_object_mut()) {
            object.insert("history".to_owned(), history);
        }
    }
    restated
}

/// A window's samples with their used percent made non-decreasing.
///
/// Inside one window a provider only ever spends, so a reading that came back lower is the
/// provider disagreeing with itself; the curve keeps the higher number rather than dipping.
fn rising<'a>(group: &[&'a QuotaSample]) -> Vec<(&'a QuotaSample, f64)> {
    let mut peak = f64::NEG_INFINITY;
    group
        .iter()
        .map(|sample| {
            peak = peak.max(sample.used_percent);
            (*sample, peak)
        })
        .collect()
}

/// The thinned curve: the first reading, one reading per decimation interval after it, and
/// always the last, which is the point the reader is standing on.
fn curve(
    rising: &[(&QuotaSample, f64)],
    resets_at: DateTime<Utc>,
    seconds: i64,
    cadence: f64,
) -> Vec<Value> {
    let window_start = resets_at - Duration::seconds(seconds);
    let mut kept: Vec<&(&QuotaSample, f64)> = Vec::new();
    for entry in rising {
        let far_enough = kept.last().is_none_or(|(last, _)| {
            (entry.0.observed_at - last.observed_at).num_seconds() >= HISTORY_DECIMATION_SECONDS
        });
        if far_enough {
            kept.push(entry);
        }
    }
    if let Some(last) = rising.last()
        && kept
            .last()
            .is_none_or(|kept| kept.0.observed_at != last.0.observed_at)
    {
        kept.push(last);
    }
    kept.into_iter()
        .map(|(sample, used)| {
            let elapsed = (((sample.observed_at - window_start).num_milliseconds() as f64)
                / 1_000.0
                / cadence)
                .clamp(0.0, 1.0);
            json!({
                "elapsed_fraction": round(elapsed, 4),
                "used_percent": round(*used, 2)
            })
        })
        .collect()
}

/// The reader's calendar day, taken at their offset from UTC.
fn local_day(instant: DateTime<Utc>, utc_offset_seconds: i32) -> NaiveDate {
    (instant + Duration::seconds(i64::from(utc_offset_seconds))).date_naive()
}

fn rfc3339(instant: DateTime<Utc>) -> String {
    instant.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn round(value: f64, decimals: u32) -> f64 {
    let scale = 10f64.powi(decimals as i32);
    (value * scale).round() / scale
}

/// Cap: a monthly window never keeps more than thirty days.
pub const QUOTA_HISTORY_MAX_SPAN_SECONDS: i64 = 30 * 86_400;
/// Floor: a chart's left edge is never the retention edge (48 h, not 24 h).
pub const QUOTA_HISTORY_MIN_SPAN_SECONDS: i64 = 48 * 3_600;
/// How many window lengths the span covers before the min/max clamp.
pub const QUOTA_HISTORY_SPAN_DURATION_MULTIPLE: i64 = 4;
pub const QUOTA_HISTORY_SHORT_WINDOW_BUCKET_SECONDS: i64 = 900;
pub const QUOTA_HISTORY_LONG_WINDOW_BUCKET_SECONDS: i64 = 3_600;
pub const QUOTA_HISTORY_SHORT_WINDOW_MAX_DURATION_SECONDS: i64 = 86_400;
pub const MAXIMUM_QUOTA_HISTORY_POINTS_PER_UPLOAD: usize = 2_000;
pub const MAXIMUM_QUOTA_HISTORY_UPLOAD_BYTES: usize = 256 * 1024;

/// One local remaining-quota reading, before it is downsampled for upload.
#[derive(Debug, Clone, PartialEq)]
pub struct QuotaHistoryLocalSample {
    pub observed_at: String,
    pub used_percent: f64,
    pub resets_at: String,
}

/// One bucket a device uploads. `resets_at` is whole-second UTC so one instant is one series.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaHistorySyncedPoint {
    pub resets_at: String,
    pub bucket_start: String,
    pub used_percent: f64,
}

/// A merged Account point. The local 12-hex selector is never on the wire.
#[derive(Debug, Clone, PartialEq)]
pub struct QuotaHistoryMergePoint {
    pub window_id: String,
    pub resets_at: String,
    pub bucket_start: String,
    pub used_percent: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BucketQuotaSamples {
    Points(Vec<QuotaHistorySyncedPoint>),
    /// A series with no duration is not a window a producer can place.
    Refused,
}

/// `history.sync` from an Account settings document. Absent is false.
pub fn history_sync_enabled(document: &Value) -> bool {
    document
        .get("history")
        .and_then(|history| history.get("sync"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// How long one window's history is kept and uploaded: `min(30 d, max(48 h, 4 × duration))`.
pub fn quota_history_span_seconds(duration_seconds: i64) -> i64 {
    QUOTA_HISTORY_MAX_SPAN_SECONDS.min(
        QUOTA_HISTORY_MIN_SPAN_SECONDS
            .max(QUOTA_HISTORY_SPAN_DURATION_MULTIPLE.saturating_mul(duration_seconds.max(0))),
    )
}

/// Bucket size: 900 s when the window is a day or shorter, otherwise 3 600 s.
pub fn quota_history_bucket_seconds(duration_seconds: i64) -> i64 {
    if duration_seconds <= QUOTA_HISTORY_SHORT_WINDOW_MAX_DURATION_SECONDS {
        QUOTA_HISTORY_SHORT_WINDOW_BUCKET_SECONDS
    } else {
        QUOTA_HISTORY_LONG_WINDOW_BUCKET_SECONDS
    }
}

/// Whole-second UTC RFC 3339. Subseconds are truncated, not rounded, and any offset becomes `Z`.
///
/// `2026-09-21T15:00:00.900Z` and `2026-09-21T10:00:00-05:00` are both `2026-09-21T15:00:00Z`.
pub fn canonical_rfc3339_utc(value: &str) -> Option<String> {
    Some(whole_second_utc(value)?.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

/// The instant [`canonical_rfc3339_utc`] names, for a read that still has the old spelling.
pub fn whole_second_utc(value: &str) -> Option<DateTime<Utc>> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .ok()?
        .with_timezone(&Utc);
    DateTime::from_timestamp(parsed.timestamp(), 0)
}

/// `floor(observed_at / size) × size` in UTC, for the window's bucket size.
pub fn quota_history_bucket_start_utc(observed_at: &str, duration_seconds: i64) -> Option<String> {
    let epoch_ms = DateTime::parse_from_rfc3339(observed_at)
        .ok()?
        .timestamp_millis();
    let size_ms = quota_history_bucket_seconds(duration_seconds).saturating_mul(1_000);
    if size_ms <= 0 {
        return None;
    }
    let start = epoch_ms.div_euclid(size_ms).saturating_mul(size_ms);
    DateTime::from_timestamp_millis(start)
        .map(|instant| instant.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

fn instant_millis(value: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|instant| instant.timestamp_millis())
}

/// The earliest `bucket_start` still inside the window's span, optionally plus slack buckets.
pub fn quota_history_span_cutoff_ms(
    duration_seconds: i64,
    now: &str,
    slack_buckets: i64,
) -> Option<i64> {
    let now_ms = instant_millis(now)?;
    let slack =
        slack_buckets.saturating_mul(quota_history_bucket_seconds(duration_seconds)) * 1_000;
    Some(now_ms - quota_history_span_seconds(duration_seconds).saturating_mul(1_000) - slack)
}

/// Relay refuses a point older than the span plus one bucket, or more than one bucket ahead of now.
pub fn quota_history_upload_point_out_of_range(
    bucket_start: &str,
    duration_seconds: i64,
    now: &str,
) -> bool {
    let Some(start) = instant_millis(bucket_start) else {
        return true;
    };
    let Some(cutoff) = quota_history_span_cutoff_ms(duration_seconds, now, 1) else {
        return true;
    };
    if start < cutoff {
        return true;
    }
    let Some(now_ms) = instant_millis(now) else {
        return true;
    };
    start > now_ms + quota_history_bucket_seconds(duration_seconds).saturating_mul(1_000)
}

/// Downsample local samples of one window into the points a device uploads.
///
/// The value of a bucket is the maximum `used_percent` in it for that `resets_at`. A bucket
/// whose value equals the previous uploaded bucket of the same `resets_at` is not sent. Points
/// older than the window's span are dropped. A missing or negative duration is refused.
pub fn bucket_quota_samples(
    samples: &[QuotaHistoryLocalSample],
    duration_seconds: Option<i64>,
    previous: &[QuotaHistorySyncedPoint],
    now: &str,
) -> BucketQuotaSamples {
    let Some(duration_seconds) = duration_seconds.filter(|seconds| *seconds >= 0) else {
        return BucketQuotaSamples::Refused;
    };
    let Some(cutoff) = quota_history_span_cutoff_ms(duration_seconds, now, 0) else {
        return BucketQuotaSamples::Refused;
    };
    let mut last_by_reset: BTreeMap<String, (String, f64)> = BTreeMap::new();
    for point in previous {
        let resets_at =
            canonical_rfc3339_utc(&point.resets_at).unwrap_or_else(|| point.resets_at.clone());
        let replace = last_by_reset
            .get(&resets_at)
            .is_none_or(|(bucket_start, _)| point.bucket_start.as_str() >= bucket_start.as_str());
        if replace {
            last_by_reset.insert(resets_at, (point.bucket_start.clone(), point.used_percent));
        }
    }
    let mut buckets: BTreeMap<(String, String), QuotaHistorySyncedPoint> = BTreeMap::new();
    for sample in samples {
        let Some(resets_at) = canonical_rfc3339_utc(&sample.resets_at) else {
            continue;
        };
        let Some(bucket_start) =
            quota_history_bucket_start_utc(&sample.observed_at, duration_seconds)
        else {
            continue;
        };
        let Some(start_ms) = instant_millis(&bucket_start) else {
            continue;
        };
        if start_ms < cutoff {
            continue;
        }
        let key = (resets_at.clone(), bucket_start.clone());
        let replace = buckets
            .get(&key)
            .is_none_or(|existing| sample.used_percent > existing.used_percent);
        if replace {
            buckets.insert(
                key,
                QuotaHistorySyncedPoint {
                    resets_at,
                    bucket_start,
                    used_percent: sample.used_percent,
                },
            );
        }
    }
    let mut uploaded = Vec::new();
    for point in buckets.into_values() {
        if last_by_reset
            .get(&point.resets_at)
            .is_some_and(|(_, used)| *used == point.used_percent)
        {
            continue;
        }
        last_by_reset.insert(
            point.resets_at.clone(),
            (point.bucket_start.clone(), point.used_percent),
        );
        uploaded.push(point);
    }
    BucketQuotaSamples::Points(uploaded)
}

/// Union several devices' points: one point per `(window_id, resets_at, bucket_start)`, maximum
/// `used_percent`, oldest first.
pub fn merge_quota_history(devices: &[Vec<QuotaHistoryMergePoint>]) -> Vec<QuotaHistoryMergePoint> {
    let mut merged: BTreeMap<(String, String, String), QuotaHistoryMergePoint> = BTreeMap::new();
    for points in devices {
        for point in points {
            let key = (
                point.window_id.clone(),
                point.resets_at.clone(),
                point.bucket_start.clone(),
            );
            let replace = merged
                .get(&key)
                .is_none_or(|existing| point.used_percent > existing.used_percent);
            if replace {
                merged.insert(key, point.clone());
            }
        }
    }
    merged.into_values().collect()
}

/// One point in an upload, still attached to the series it belongs to.
#[derive(Debug, Clone, PartialEq)]
pub struct QuotaHistoryUploadPoint {
    pub provider: String,
    pub fingerprint: String,
    pub window_id: String,
    pub duration_seconds: i64,
    pub point: QuotaHistorySyncedPoint,
}

/// What one global-scope window contributes. `watermark` is the newest `bucket_start` Relay
/// already holds; samples that bucket strictly before it are not sent again.
#[derive(Debug, Clone)]
pub struct QuotaHistorySeriesInput {
    pub provider: String,
    pub fingerprint: String,
    pub window_id: String,
    pub duration_seconds: i64,
    pub samples: Vec<QuotaHistoryLocalSample>,
    pub previous: Vec<QuotaHistorySyncedPoint>,
    pub watermark: Option<String>,
}

/// The points a producer should upload, oldest first, already inside Relay's acceptance window.
pub fn plan_quota_history_upload(
    series: &[QuotaHistorySeriesInput],
    now: &str,
) -> Vec<QuotaHistoryUploadPoint> {
    let mut points = Vec::new();
    for series in series {
        if series.duration_seconds < 0 {
            continue;
        }
        let samples: Vec<QuotaHistoryLocalSample> = series
            .samples
            .iter()
            .filter(|sample| {
                sample.used_percent.is_finite() && (0.0..=100.0).contains(&sample.used_percent)
            })
            .filter(|sample| {
                let Some(bucket_start) =
                    quota_history_bucket_start_utc(&sample.observed_at, series.duration_seconds)
                else {
                    return false;
                };
                series
                    .watermark
                    .as_ref()
                    .is_none_or(|watermark| bucket_start.as_str() >= watermark.as_str())
            })
            .cloned()
            .collect();
        let BucketQuotaSamples::Points(bucketed) = bucket_quota_samples(
            &samples,
            Some(series.duration_seconds),
            &series.previous,
            now,
        ) else {
            continue;
        };
        for point in bucketed {
            if quota_history_upload_point_out_of_range(
                &point.bucket_start,
                series.duration_seconds,
                now,
            ) {
                continue;
            }
            points.push(QuotaHistoryUploadPoint {
                provider: series.provider.clone(),
                fingerprint: series.fingerprint.clone(),
                window_id: series.window_id.clone(),
                duration_seconds: series.duration_seconds,
                point,
            });
        }
    }
    points.sort_by(|left, right| {
        left.point
            .bucket_start
            .cmp(&right.point.bucket_start)
            .then(left.point.resets_at.cmp(&right.point.resets_at))
            .then(left.window_id.cmp(&right.window_id))
            .then(left.provider.cmp(&right.provider))
            .then(left.fingerprint.cmp(&right.fingerprint))
    });
    points
}

/// Split an upload into requests of at most `max_points` and `max_bytes`, oldest first.
pub fn chunk_quota_history_upload(
    points: &[QuotaHistoryUploadPoint],
    generation: u64,
    max_points: usize,
    max_bytes: usize,
) -> Vec<Value> {
    if max_points == 0 || max_bytes == 0 || points.is_empty() {
        return Vec::new();
    }
    let mut ordered = points.to_vec();
    ordered.sort_by(|left, right| {
        left.point
            .bucket_start
            .cmp(&right.point.bucket_start)
            .then(left.point.resets_at.cmp(&right.point.resets_at))
            .then(left.window_id.cmp(&right.window_id))
            .then(left.provider.cmp(&right.provider))
            .then(left.fingerprint.cmp(&right.fingerprint))
    });
    let mut chunks = Vec::new();
    let mut current: Vec<&QuotaHistoryUploadPoint> = Vec::new();
    for point in &ordered {
        if current.len() >= max_points {
            chunks.push(quota_history_upload_body(generation, &current));
            current.clear();
        }
        current.push(point);
        let size = serde_json::to_vec(&quota_history_upload_body(generation, &current))
            .map(|bytes| bytes.len())
            .unwrap_or(usize::MAX);
        if size > max_bytes {
            current.pop();
            if !current.is_empty() {
                chunks.push(quota_history_upload_body(generation, &current));
            }
            current.clear();
            current.push(point);
            let alone = serde_json::to_vec(&quota_history_upload_body(generation, &current))
                .map(|bytes| bytes.len())
                .unwrap_or(usize::MAX);
            if alone > max_bytes {
                current.clear();
            }
        }
    }
    if !current.is_empty() {
        chunks.push(quota_history_upload_body(generation, &current));
    }
    chunks
}

fn quota_history_upload_body(generation: u64, points: &[&QuotaHistoryUploadPoint]) -> Value {
    let mut series: Vec<Value> = Vec::new();
    for point in points {
        let same = series.iter_mut().find(|series| {
            series.get("provider").and_then(Value::as_str) == Some(point.provider.as_str())
                && series.get("fingerprint").and_then(Value::as_str)
                    == Some(point.fingerprint.as_str())
                && series.get("window_id").and_then(Value::as_str) == Some(point.window_id.as_str())
                && series.get("duration_seconds").and_then(Value::as_i64)
                    == Some(point.duration_seconds)
        });
        let point_json = json!({
            "resets_at": point.point.resets_at,
            "bucket_start": point.point.bucket_start,
            "used_percent": point.point.used_percent,
        });
        if let Some(points) = same
            .and_then(|series| series.get_mut("points"))
            .and_then(Value::as_array_mut)
        {
            points.push(point_json);
        } else {
            series.push(json!({
                "provider": point.provider,
                "fingerprint": point.fingerprint,
                "window_id": point.window_id,
                "duration_seconds": point.duration_seconds,
                "points": [point_json],
            }));
        }
    }
    json!({
        "protocol_version": crate::protocol::MANAGED_DATA_PROTOCOL,
        "generation": generation,
        "series": series,
    })
}

/// Preference key for one series: provider, fingerprint, window. Not the local selector.
pub fn quota_history_series_key(provider: &str, fingerprint: &str, window_id: &str) -> String {
    format!("{provider}\u{0}{fingerprint}\u{0}{window_id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../protocol/fixtures/quota-history-conformance.json");

    fn samples(value: &Value) -> Vec<QuotaSample> {
        value
            .as_array()
            .expect("samples")
            .iter()
            .map(|sample| QuotaSample {
                resets_at: instant(sample.get("resets_at")).expect("resets_at"),
                observed_at: instant(sample.get("observed_at")).expect("observed_at"),
                used_percent: sample["used_percent"].as_f64().expect("used_percent"),
            })
            .collect()
    }

    /// The fixture states its numbers to the precision every runtime rounds to, so the
    /// comparison is over the rounded values rather than over two binary expansions of them.
    fn same(left: &Value, right: &Value, name: &str) {
        match (left, right) {
            (Value::Number(left), Value::Number(right)) => {
                let (left, right) = (
                    left.as_f64().expect("number"),
                    right.as_f64().expect("number"),
                );
                assert!((left - right).abs() < 1e-6, "{name}: {left} vs {right}");
            }
            (Value::Array(left), Value::Array(right)) => {
                assert_eq!(left.len(), right.len(), "{name}");
                for (left, right) in left.iter().zip(right) {
                    same(left, right, name);
                }
            }
            (Value::Object(left), Value::Object(right)) => {
                assert_eq!(
                    left.keys().collect::<Vec<_>>(),
                    right.keys().collect::<Vec<_>>(),
                    "{name}"
                );
                for (key, value) in left {
                    same(value, &right[key], name);
                }
            }
            (left, right) => assert_eq!(left, right, "{name}"),
        }
    }

    #[test]
    fn history_matches_the_shared_conformance_fixture() {
        let fixture: Value = serde_json::from_str(FIXTURE).expect("fixture");
        let cases = fixture["cases"].as_array().expect("cases");
        assert!(cases.len() >= 8);
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let now = instant(case.get("now")).expect("now");
            let offset = case["utc_offset_seconds"].as_i64().expect("offset") as i32;
            let folded = window_history(&case["window"], &samples(&case["samples"]), now, offset);
            same(&folded.unwrap_or(Value::Null), &case["expected"], name);
            if let Some(peer) = case.get("peer") {
                let peer_folded =
                    window_history(&case["window"], &samples(&peer["samples"]), now, offset);
                same(
                    &peer_folded.unwrap_or(Value::Null),
                    &peer["expected"],
                    &format!("{name} peer"),
                );
                assert_ne!(
                    case["samples"][0]["used_percent"], peer["samples"][0]["used_percent"],
                    "{name}: peer values must differ"
                );
            }
        }
    }

    #[test]
    fn a_snapshot_carries_history_only_on_the_windows_that_have_samples() {
        let snapshot = json!({
            "provider": "codex",
            "windows": [
                {
                    "id": "five_hour",
                    "title": "5 Hours",
                    "used_percent": 50,
                    "resets_at": "2026-09-05T12:00:00Z",
                    "duration_seconds": 18000
                },
                {
                    "id": "weekly",
                    "title": "Weekly",
                    "used_percent": 10,
                    "resets_at": "2026-09-08T00:00:00Z",
                    "duration_seconds": 604800
                }
            ]
        });
        let mut stored = BTreeMap::new();
        stored.insert(
            "five_hour".to_owned(),
            vec![QuotaSample {
                resets_at: instant(Some(&json!("2026-09-05T12:00:00Z"))).expect("resets"),
                observed_at: instant(Some(&json!("2026-09-05T09:30:00Z"))).expect("observed"),
                used_percent: 50.0,
            }],
        );
        let now = instant(Some(&json!("2026-09-05T09:30:00Z"))).expect("now");
        let restated = snapshot_with_history(&snapshot, &stored, now, 0);
        let windows = restated["windows"].as_array().expect("windows");
        assert_eq!(
            windows[0]["history"]["points"]
                .as_array()
                .expect("points")
                .len(),
            1
        );
        assert!(windows[1].get("history").is_none());
    }

    /// Decimation keeps the first reading of each 300 s span after the previous kept point,
    /// and always the last (ADR 0042).
    #[test]
    fn decimation_keeps_the_first_sample_of_each_five_minute_bucket() {
        let resets = instant(Some(&json!("2026-09-05T12:00:00Z"))).expect("resets");
        let sample = |observed: &str, used: f64| QuotaSample {
            resets_at: resets,
            observed_at: instant(Some(&json!(observed))).expect("observed"),
            used_percent: used,
        };
        let window = json!({
            "id": "five_hour",
            "title": "5 Hours",
            "used_percent": 50,
            "resets_at": "2026-09-05T12:00:00Z",
            "duration_seconds": 18000
        });
        let folded = window_history(
            &window,
            &[
                sample("2026-09-05T07:30:00Z", 10.0),
                sample("2026-09-05T07:32:00Z", 12.0),
                sample("2026-09-05T07:34:59Z", 14.0),
                sample("2026-09-05T07:35:00Z", 16.0),
                sample("2026-09-05T07:36:00Z", 18.0),
                sample("2026-09-05T09:30:00Z", 50.0),
            ],
            instant(Some(&json!("2026-09-05T09:30:00Z"))).expect("now"),
            0,
        )
        .expect("history");
        let points = folded["points"].as_array().expect("points");
        assert_eq!(
            points
                .iter()
                .map(|point| point["used_percent"].as_f64().expect("used"))
                .collect::<Vec<_>>(),
            vec![10.0, 16.0, 50.0]
        );
    }

    /// Samples of five_hour, weekly, and monthly fold onto their own windows and nowhere else.
    #[test]
    fn three_windows_fold_separately() {
        let snapshot = json!({
            "provider": "codex",
            "windows": [
                {
                    "id": "five_hour",
                    "title": "5 Hours",
                    "used_percent": 40,
                    "resets_at": "2026-09-05T12:00:00Z",
                    "duration_seconds": 18000
                },
                {
                    "id": "weekly",
                    "title": "Weekly",
                    "used_percent": 20,
                    "resets_at": "2026-09-08T00:00:00Z",
                    "duration_seconds": 604800
                },
                {
                    "id": "monthly",
                    "title": "Monthly",
                    "used_percent": 8,
                    "resets_at": "2026-10-01T00:00:00Z",
                    "duration_seconds": 2592000
                }
            ]
        });
        let sample = |resets: &str, observed: &str, used: f64| QuotaSample {
            resets_at: instant(Some(&json!(resets))).expect("resets"),
            observed_at: instant(Some(&json!(observed))).expect("observed"),
            used_percent: used,
        };
        let mut stored = BTreeMap::new();
        stored.insert(
            "five_hour".to_owned(),
            vec![
                sample("2026-09-05T12:00:00Z", "2026-09-05T08:00:00Z", 10.0),
                sample("2026-09-05T12:00:00Z", "2026-09-05T09:30:00Z", 40.0),
            ],
        );
        stored.insert(
            "weekly".to_owned(),
            vec![sample("2026-09-08T00:00:00Z", "2026-09-05T09:30:00Z", 20.0)],
        );
        stored.insert(
            "monthly".to_owned(),
            vec![sample("2026-10-01T00:00:00Z", "2026-09-05T09:30:00Z", 8.0)],
        );
        let now = instant(Some(&json!("2026-09-05T09:30:00Z"))).expect("now");
        let restated = snapshot_with_history(&snapshot, &stored, now, 0);
        let windows = restated["windows"].as_array().expect("windows");
        let used = |index: usize| {
            windows[index]["history"]["points"]
                .as_array()
                .expect("points")
                .iter()
                .map(|point| point["used_percent"].as_f64().expect("used"))
                .collect::<Vec<_>>()
        };
        assert_eq!(used(0), vec![10.0, 40.0]);
        assert_eq!(used(1), vec![20.0]);
        assert_eq!(used(2), vec![8.0]);
    }

    const SYNC_FIXTURE: &str =
        include_str!("../../protocol/fixtures/quota-history-sync-conformance.json");

    fn local_samples(value: &Value) -> Vec<QuotaHistoryLocalSample> {
        value
            .as_array()
            .expect("samples")
            .iter()
            .map(|sample| QuotaHistoryLocalSample {
                observed_at: sample["observed_at"]
                    .as_str()
                    .expect("observed_at")
                    .to_owned(),
                used_percent: sample["used_percent"].as_f64().expect("used_percent"),
                resets_at: sample["resets_at"].as_str().expect("resets_at").to_owned(),
            })
            .collect()
    }

    fn synced_points(value: &Value) -> Vec<QuotaHistorySyncedPoint> {
        value
            .as_array()
            .unwrap_or(&Vec::new())
            .iter()
            .map(|point| QuotaHistorySyncedPoint {
                resets_at: point["resets_at"].as_str().expect("resets_at").to_owned(),
                bucket_start: point["bucket_start"]
                    .as_str()
                    .expect("bucket_start")
                    .to_owned(),
                used_percent: point["used_percent"].as_f64().expect("used_percent"),
            })
            .collect()
    }

    fn points_json(points: &[QuotaHistorySyncedPoint]) -> Value {
        Value::Array(
            points
                .iter()
                .map(|point| {
                    json!({
                        "resets_at": point.resets_at,
                        "bucket_start": point.bucket_start,
                        "used_percent": point.used_percent,
                    })
                })
                .collect(),
        )
    }

    fn merge_points(value: &Value) -> Vec<QuotaHistoryMergePoint> {
        value
            .as_array()
            .expect("points")
            .iter()
            .map(|point| QuotaHistoryMergePoint {
                window_id: point["window_id"].as_str().expect("window_id").to_owned(),
                resets_at: point["resets_at"].as_str().expect("resets_at").to_owned(),
                bucket_start: point["bucket_start"]
                    .as_str()
                    .expect("bucket_start")
                    .to_owned(),
                used_percent: point["used_percent"].as_f64().expect("used_percent"),
            })
            .collect()
    }

    fn merge_json(points: &[QuotaHistoryMergePoint]) -> Value {
        Value::Array(
            points
                .iter()
                .map(|point| {
                    json!({
                        "window_id": point.window_id,
                        "resets_at": point.resets_at,
                        "bucket_start": point.bucket_start,
                        "used_percent": point.used_percent,
                    })
                })
                .collect(),
        )
    }

    #[test]
    fn quota_history_sync_matches_every_bucket_and_merge_case() {
        let fixture: Value = serde_json::from_str(SYNC_FIXTURE).expect("fixture");
        let now = fixture["now"].as_str().expect("now");
        let buckets = fixture["bucket"].as_array().expect("bucket");
        assert!(buckets.len() >= 11, "bucket cases");
        for case in buckets {
            let name = case["name"].as_str().expect("name");
            let case_now = case.get("now").and_then(Value::as_str).unwrap_or(now);
            let duration = case.get("duration_seconds").and_then(Value::as_i64);
            let result = bucket_quota_samples(
                &local_samples(&case["samples"]),
                duration,
                &synced_points(&case["previous"]),
                case_now,
            );
            if case["expected"].get("refused").and_then(Value::as_bool) == Some(true) {
                assert!(
                    matches!(result, BucketQuotaSamples::Refused),
                    "{name} should be refused"
                );
                continue;
            }
            let BucketQuotaSamples::Points(points) = result else {
                panic!("{name} was refused");
            };
            same(&points_json(&points), &case["expected"], name);
        }
        let merges = fixture["merge"].as_array().expect("merge");
        assert!(merges.len() >= 3, "merge cases");
        for case in merges {
            let name = case["name"].as_str().expect("name");
            let devices = case["devices"]
                .as_array()
                .expect("devices")
                .iter()
                .map(merge_points)
                .collect::<Vec<_>>();
            same(
                &merge_json(&merge_quota_history(&devices)),
                &case["expected"],
                name,
            );
        }
    }

    #[test]
    fn one_bucket_ahead_of_now_is_kept_and_two_are_not() {
        let now = "2026-09-21T12:00:00Z";
        assert!(!quota_history_upload_point_out_of_range(
            "2026-09-21T12:15:00Z",
            18_000,
            now
        ));
        assert!(quota_history_upload_point_out_of_range(
            "2026-09-21T12:30:00Z",
            18_000,
            now
        ));
    }

    #[test]
    fn fractional_resets_at_is_one_series() {
        let samples = vec![
            QuotaHistoryLocalSample {
                observed_at: "2026-09-21T10:00:00Z".to_owned(),
                used_percent: 10.0,
                resets_at: "2026-09-21T15:00:00.400Z".to_owned(),
            },
            QuotaHistoryLocalSample {
                observed_at: "2026-09-21T10:16:00Z".to_owned(),
                used_percent: 10.0,
                resets_at: "2026-09-21T15:00:00Z".to_owned(),
            },
        ];
        let BucketQuotaSamples::Points(points) =
            bucket_quota_samples(&samples, Some(18_000), &[], "2026-09-21T12:00:00Z")
        else {
            panic!("refused");
        };
        assert_eq!(points.len(), 1, "{points:?}");
        assert_eq!(points[0].resets_at, "2026-09-21T15:00:00Z");
        assert_eq!(points[0].used_percent, 10.0);
    }

    #[test]
    fn uploads_are_chunked_oldest_first_under_the_point_and_byte_caps() {
        let point = |bucket: &str| QuotaHistoryUploadPoint {
            provider: "codex".to_owned(),
            fingerprint: "account_test".to_owned(),
            window_id: "five_hour".to_owned(),
            duration_seconds: 18_000,
            point: QuotaHistorySyncedPoint {
                resets_at: "2026-09-21T15:00:00Z".to_owned(),
                bucket_start: bucket.to_owned(),
                used_percent: 10.0,
            },
        };
        let points = vec![
            point("2026-09-21T10:30:00Z"),
            point("2026-09-21T10:00:00Z"),
            point("2026-09-21T10:15:00Z"),
        ];
        let chunks = chunk_quota_history_upload(&points, 3, 2, usize::MAX);
        assert_eq!(chunks.len(), 2);
        assert_eq!(
            chunks[0]["series"][0]["points"][0]["bucket_start"],
            "2026-09-21T10:00:00Z"
        );
        assert_eq!(
            chunks[0]["series"][0]["points"]
                .as_array()
                .expect("points")
                .len(),
            2
        );
        assert_eq!(chunks[0]["generation"], 3);
        assert_eq!(chunks[0]["protocol_version"], 6);
        let one = chunk_quota_history_upload(&points[..1], 3, 10, usize::MAX);
        let one_len = serde_json::to_vec(&one[0]).expect("bytes").len();
        let wide = chunk_quota_history_upload(&points, 3, 10, one_len);
        assert_eq!(wide.len(), 3, "{wide:?}");
    }
}
