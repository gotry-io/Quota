//! Whether a quota window's current burn rate lasts to its reset.
//!
//! `used_percent`, `resets_at`, and `duration_seconds` are the whole input, so pace is
//! derived from the reading by whoever holds it rather than projected by its collector. This
//! runtime answers for QuotaBar: the service states each window's pace in the IPC state it
//! publishes, and the app prints what it is handed. See ADR 0035.

use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};

use crate::observation::instant;

/// Below this much of the window elapsed, the sample says nothing about the rest of it.
pub const MINIMUM_PACE_ELAPSED_FRACTION: f64 = 0.05;

/// Below this much used, the sample says nothing either: a few percent is noise, not a rate.
pub const MINIMUM_PACE_USED_PERCENT: f64 = 2.0;

/// The projection is a ratio of a small number and runs away; this is where it stops.
pub const MAXIMUM_PACE_PROJECTION_PERCENT: f64 = 999.0;

/// Inside this band of the even rate, a window is neither ahead nor behind.
pub const PACE_ON_TRACK_BAND: (f64, f64) = (0.9, 1.1);

/// The pace of one window, in the shape the IPC state carries it.
///
/// `{"kind": "none"}` is a window this cannot answer for: no cadence, a wallet with no budget
/// to spend against, or too little of the window behind it to mean anything.
pub fn window_pace(window: &Value, now: DateTime<Utc>) -> Value {
    let none = json!({ "kind": "none" });
    let (Some(resets_at), Some(seconds), Some(used)) = (
        instant(window.get("resets_at")),
        window.get("duration_seconds").and_then(Value::as_i64),
        window.get("used_percent").and_then(Value::as_f64),
    ) else {
        return none;
    };
    let balance_only = window.get("remaining_value").is_some_and(Value::is_number)
        && !window.get("limit_value").is_some_and(Value::is_number);
    if seconds <= 0 || balance_only {
        return none;
    }
    let cadence = seconds as f64;
    let window_start = resets_at - Duration::seconds(seconds);
    let elapsed =
        (((now - window_start).num_milliseconds() as f64) / 1_000.0 / cadence).clamp(0.0, 1.0);
    if elapsed < MINIMUM_PACE_ELAPSED_FRACTION || used < MINIMUM_PACE_USED_PERCENT {
        return none;
    }
    let projected = (used / elapsed).min(MAXIMUM_PACE_PROJECTION_PERCENT);
    let ratio = projected / 100.0;
    let tempo = if ratio > PACE_ON_TRACK_BAND.1 {
        "ahead"
    } else if ratio < PACE_ON_TRACK_BAND.0 {
        "behind"
    } else {
        "on_track"
    };
    let delta = ((ratio - 1.0) * 100.0).round() as i64;
    if projected <= 100.0 {
        return json!({
            "kind": "lasts",
            "tempo": tempo,
            "delta_percent": delta,
            "projected_at_reset": projected
        });
    }
    // At the current rate the window is spent this far into itself, stated to the second so
    // every runtime names the same instant.
    let offset = (cadence * (100.0 / used) * elapsed).round() as i64;
    let exhausts_at = window_start + Duration::seconds(offset);
    json!({
        "kind": "runs_out",
        "tempo": tempo,
        "delta_percent": delta,
        "projected_at_reset": projected,
        "exhausts_at": exhausts_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
    })
}

/// Restate a snapshot with each of its windows carrying its own pace.
///
/// The published state is what QuotaBar reads, so the derivation happens once here rather
/// than in the app: one rule, one answer, and no second implementation to disagree with it.
pub fn snapshot_with_pace(snapshot: &Value, now: DateTime<Utc>) -> Value {
    let mut restated = snapshot.clone();
    let Some(windows) = restated.get_mut("windows").and_then(Value::as_array_mut) else {
        return restated;
    };
    for window in windows {
        let pace = window_pace(window, now);
        if let Some(object) = window.as_object_mut() {
            object.insert("pace".to_owned(), pace);
        }
    }
    restated
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../protocol/fixtures/quota-pace-conformance.json");

    #[test]
    fn pace_matches_the_shared_conformance_fixture() {
        let fixture: Value = serde_json::from_str(FIXTURE).expect("fixture");
        let cases = fixture["cases"].as_array().expect("cases");
        assert!(cases.len() >= 12);
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let now = instant(case.get("now")).expect("now");
            assert_eq!(
                window_pace(&case["window"], now),
                case["expected"],
                "{name}"
            );
        }
    }

    #[test]
    fn a_window_whose_reset_cannot_be_placed_has_no_pace() {
        let window = json!({
            "id": "five_hour",
            "title": "5 Hours",
            "used_percent": 50,
            "resets_at": "not a time",
            "duration_seconds": 18000
        });
        assert_eq!(window_pace(&window, Utc::now()), json!({ "kind": "none" }));
    }

    #[test]
    fn a_snapshot_carries_a_pace_on_every_window() {
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
                { "id": "balance", "title": "Balance", "used_percent": 0, "remaining_value": 4.0 }
            ]
        });
        let now = instant(Some(&json!("2026-09-05T09:30:00Z"))).expect("now");
        let restated = snapshot_with_pace(&snapshot, now);
        let windows = restated["windows"].as_array().expect("windows");
        assert_eq!(windows[0]["pace"]["kind"], json!("lasts"));
        assert_eq!(windows[1]["pace"], json!({ "kind": "none" }));
    }
}
