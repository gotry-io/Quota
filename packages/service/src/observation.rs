//! What one quota observation still says about current quota.
//!
//! Every input is part of the reading, so each reader derives the boundary from the
//! snapshot rather than trusting a value stamped onto it at collection time. A reader that
//! depended on the stamp presented readings that predate it as current forever, and no
//! collector can be relied on to have stamped a reading another device uploaded.

use chrono::{DateTime, Duration, Utc};
use serde_json::Value;

/// How long an observation may claim to describe current quota when its own windows say
/// nothing shorter. A device that stops collecting must stop answering for a live account.
pub const MAX_SNAPSHOT_VALIDITY_SECONDS: i64 = 86_400;

/// The instant this observation stops describing current quota.
///
/// The first window reset is the exact boundary: at it that window refills and the number
/// the reading carries is wrong. Windows that report no reset fall back to their own
/// cadence, and every observation ages out at [`MAX_SNAPSHOT_VALIDITY_SECONDS`]. A reading
/// this cannot place in time has no boundary, and reads as not current.
pub fn snapshot_valid_until(snapshot: &Value) -> Option<DateTime<Utc>> {
    let observed = instant(snapshot.get("observed_at"))?;
    let limit = observed.checked_add_signed(Duration::seconds(MAX_SNAPSHOT_VALIDITY_SECONDS))?;
    let windows = snapshot
        .get("windows")
        .and_then(Value::as_array)
        .map_or::<&[Value], _>(&[], Vec::as_slice);
    let earliest_reset = windows
        .iter()
        .filter_map(|window| instant(window.get("resets_at")))
        .filter(|reset| *reset > observed)
        .min();
    let shortest_cadence = windows
        .iter()
        .filter_map(|window| window.get("duration_seconds").and_then(Value::as_i64))
        .min()
        .and_then(|seconds| observed.checked_add_signed(Duration::try_seconds(seconds)?));
    Some(
        earliest_reset
            .or(shortest_cadence)
            .map_or(limit, |boundary| boundary.min(limit)),
    )
}

/// Whether this observation describes current quota: the source could still read, and the
/// reading has not aged past its own boundary.
pub fn snapshot_is_current(snapshot: &Value, now: DateTime<Utc>) -> bool {
    snapshot.get("status").and_then(Value::as_str) == Some("available")
        && snapshot_valid_until(snapshot).is_some_and(|valid_until| valid_until > now)
}

pub fn instant(value: Option<&Value>) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value?.as_str()?)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const FIXTURE: &str =
        include_str!("../../protocol/fixtures/quota-observation-conformance.json");

    #[test]
    fn freshness_matches_the_shared_conformance_fixture() {
        let fixture: Value = serde_json::from_str(FIXTURE).expect("fixture");
        let cases = fixture["freshness"].as_array().expect("freshness cases");
        assert!(!cases.is_empty());
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let now = instant(case.get("now")).expect("now");
            let snapshot = &case["snapshot"];
            let expected = &case["expected"];
            let valid_until = snapshot_valid_until(snapshot).expect("valid until");
            assert_eq!(
                valid_until.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                expected["valid_until"].as_str().expect("expected instant"),
                "{name}"
            );
            let expected_current = expected["status"].as_str() == Some("available");
            assert_eq!(
                snapshot_is_current(snapshot, now),
                expected_current,
                "{name}"
            );
        }
    }

    #[test]
    fn a_reading_without_a_placeable_observation_time_is_not_current() {
        let snapshot = json!({"status": "available", "windows": [], "observed_at": "not a time"});
        assert_eq!(snapshot_valid_until(&snapshot), None);
        assert!(!snapshot_is_current(&snapshot, Utc::now()));
    }
}
