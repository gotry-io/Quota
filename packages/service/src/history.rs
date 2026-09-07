//! How a window's local samples fold into the history a surface draws.
//!
//! Pace answers a window from one reading ([`crate::pace`], ADR 0035). A curve needs more than
//! one, so this device keeps its own readings in `cache.sqlite` and folds them here: the line
//! behind the reader, the dashed extrapolation ADR 0035 already names, and the windows that
//! belong to the reader's today. Samples never leave the machine that took them, so nothing in
//! this module touches an upload. See ADR 0042.

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, NaiveDate, Utc};
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
}
