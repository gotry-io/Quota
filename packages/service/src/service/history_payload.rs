//! Plan A history payload measurement (ADR 0051).
//!
//! Fills 30 days × 12 providers × 3 windows at the 300 s decimation, folds through
//! [`LocalQuotaHistory`] the way a state push restates Overview, and prints the JSON byte
//! size.
//!
//! ```sh
//! cargo test --locked --package quota-service --lib -- history_payload --nocapture
//! ```

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde_json::{Value, json};

use super::{LocalQuotaHistory, overview_item};
use crate::catalog::ProviderId;
use crate::history::{HISTORY_DECIMATION_SECONDS, HISTORY_RETENTION_DAYS, QuotaSample};
use crate::protocol::{QuotaOverviewIdentity, QuotaOverviewItem};
use crate::state::QuotaSamplesBySubscription;

/// Above this, the 30-day fold does not ride on every state push (plan B).
const PLAN_A_BUDGET_BYTES: usize = 200 * 1024;

const WINDOWS: &[(&str, i64)] = &[
    ("five_hour", 18_000),
    ("weekly", 604_800),
    ("monthly", 2_592_000),
];

struct PayloadSize {
    sample_rows: usize,
    overview_bytes: usize,
    history_bytes: usize,
}

/// In-memory fill of the Plan A grid, folded and serialised the way Overview is.
#[test]
fn thirty_day_history_in_state_exceeds_the_plan_a_budget() {
    let now = DateTime::parse_from_rfc3339("2026-09-16T12:00:00Z")
        .expect("now")
        .with_timezone(&Utc);
    let samples = synthetic_samples(now);
    let size = measure(&samples, now);
    println!(
        "synthetic: rows={} overview_bytes={} ({:.1} KB) history_bytes={} ({:.1} KB) budget={} KB",
        size.sample_rows,
        size.overview_bytes,
        size.overview_bytes as f64 / 1024.0,
        size.history_bytes,
        size.history_bytes as f64 / 1024.0,
        PLAN_A_BUDGET_BYTES / 1024
    );
    assert!(
        size.overview_bytes > PLAN_A_BUDGET_BYTES,
        "Plan A ships the folded 30-day history on every state push; {} bytes is over the {} byte budget",
        size.overview_bytes,
        PLAN_A_BUDGET_BYTES
    );
}

fn measure(samples: &QuotaSamplesBySubscription, now: DateTime<Utc>) -> PayloadSize {
    let snapshots = snapshots_from_samples(samples, now);
    let history = LocalQuotaHistory::new(samples.clone(), now);
    let items: Vec<QuotaOverviewItem> = snapshots
        .iter()
        .filter_map(|snapshot| {
            overview_item(snapshot, "local", "This Mac", None, Some(&history), now)
        })
        .collect();
    let overview_bytes = serde_json::to_vec(&items).expect("overview json").len();
    let history_bytes = items
        .iter()
        .map(|item| {
            history_bytes_in(&item.snapshot)
                + item
                    .sources
                    .iter()
                    .map(|source| source.snapshot.as_ref().map(history_bytes_in).unwrap_or(0))
                    .sum::<usize>()
        })
        .sum();
    PayloadSize {
        sample_rows: samples
            .values()
            .flat_map(|windows| windows.values().map(Vec::len))
            .sum(),
        overview_bytes,
        history_bytes,
    }
}

fn snapshots_from_samples(samples: &QuotaSamplesBySubscription, now: DateTime<Utc>) -> Vec<Value> {
    let providers: BTreeMap<String, &'static str> = ProviderId::ALL
        .iter()
        .map(|provider| {
            (
                QuotaOverviewIdentity::selector_for(provider.as_str(), "measure", "global", None),
                provider.as_str(),
            )
        })
        .collect();
    samples
        .iter()
        .map(|(key, windows)| {
            let provider = providers.get(key).copied().unwrap_or("codex");
            let window_values: Vec<Value> = windows
                .iter()
                .filter_map(|(id, group)| {
                    let last = group.last()?;
                    let duration = cadence_seconds(id);
                    (duration > 0).then(|| {
                        json!({
                            "id": id,
                            "title": id,
                            "used_percent": last.used_percent,
                            "resets_at": rfc3339(last.resets_at),
                            "duration_seconds": duration
                        })
                    })
                })
                .collect();
            json!({
                "provider": provider,
                "account": {"fingerprint": "measure", "fingerprint_scope": "global"},
                "windows": window_values,
                "status": "available",
                "observed_at": rfc3339(now)
            })
        })
        .collect()
}

fn history_bytes_in(value: &Value) -> usize {
    value
        .get("windows")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|window| window.get("history"))
        .map(|history| {
            serde_json::to_vec(history)
                .map(|bytes| bytes.len())
                .unwrap_or(0)
        })
        .sum()
}

fn synthetic_samples(now: DateTime<Utc>) -> QuotaSamplesBySubscription {
    let mut samples = QuotaSamplesBySubscription::new();
    for (key, _provider, window_id, resets_at, observed_at, used_percent) in synthetic_rows(now) {
        samples
            .entry(key)
            .or_default()
            .entry(window_id.to_owned())
            .or_default()
            .push(QuotaSample {
                resets_at,
                observed_at,
                used_percent,
            });
    }
    samples
}

fn synthetic_rows(
    now: DateTime<Utc>,
) -> impl Iterator<
    Item = (
        String,
        &'static str,
        &'static str,
        DateTime<Utc>,
        DateTime<Utc>,
        f64,
    ),
> {
    let start = now - Duration::days(HISTORY_RETENTION_DAYS);
    let step = Duration::seconds(HISTORY_DECIMATION_SECONDS);
    let timestamps = std::iter::successors(Some(start), move |previous| {
        let next = *previous + step;
        (next <= now).then_some(next)
    });
    timestamps.flat_map(move |observed_at| {
        ProviderId::ALL.iter().flat_map(move |provider| {
            let key =
                QuotaOverviewIdentity::selector_for(provider.as_str(), "measure", "global", None);
            WINDOWS.iter().map(move |&(window_id, duration)| {
                let resets_at = containing_resets_at(observed_at, now, duration);
                let window_start = resets_at - Duration::seconds(duration);
                let elapsed = ((observed_at - window_start).num_milliseconds() as f64
                    / 1_000.0
                    / duration as f64)
                    .clamp(0.0, 1.0);
                (
                    key.clone(),
                    provider.as_str(),
                    window_id,
                    resets_at,
                    observed_at,
                    (elapsed * 80.0 * 100.0).round() / 100.0,
                )
            })
        })
    })
}

/// The running window resets at `now`, so a monthly window's current curve holds the full
/// 30-day fill — the largest current-window payload Plan A would push.
fn containing_resets_at(
    observed_at: DateTime<Utc>,
    current_resets_at: DateTime<Utc>,
    duration_seconds: i64,
) -> DateTime<Utc> {
    let delta = (current_resets_at - observed_at).num_seconds();
    let periods_back = if delta <= 0 {
        0
    } else {
        (delta - 1) / duration_seconds
    };
    current_resets_at - Duration::seconds(periods_back * duration_seconds)
}

fn cadence_seconds(window_id: &str) -> i64 {
    WINDOWS
        .iter()
        .find(|(id, _)| *id == window_id)
        .map_or(0, |(_, duration)| *duration)
}

fn rfc3339(instant: DateTime<Utc>) -> String {
    instant.to_rfc3339_opts(SecondsFormat::Secs, true)
}
