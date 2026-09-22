//! Plan A history payload measurement (ADR 0051).
//!
//! Fills 30 days × 12 providers × 3 windows at the 300 s decimation, folds through
//! [`LocalQuotaHistory`] the way a state push restates Overview, and prints the JSON byte
//! size. A second path copies `~/.config/quota/cache.sqlite` and folds that image read-only.
//!
//! ```sh
//! cargo test --locked --package quota-service --lib \
//!     -- history_payload --ignored --nocapture
//! ```

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use uuid::Uuid;

use super::{LocalQuotaHistory, overview_item};
use crate::catalog::ProviderId;
use crate::history::{HISTORY_DECIMATION_SECONDS, HISTORY_RETENTION_DAYS, QuotaSample};
use crate::protocol::{QuotaOverviewIdentity, QuotaOverviewItem};
use crate::state::{QuotaSamplesBySubscription, StateStore};

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

/// Fills `quota_samples`, then folds a read-only copy of this Mac's cache if one exists.
#[test]
#[ignore = "fills 30 days of quota_samples and copies ~/.config/quota/cache.sqlite"]
fn plan_a_history_payload_size() {
    let now = DateTime::parse_from_rfc3339("2026-09-16T12:00:00Z")
        .expect("now")
        .with_timezone(&Utc);
    let root = temp_root("history-payload");
    let store = StateStore::open(&root).expect("state");
    let inserted = store.seed_quota_samples(synthetic_rows(now)).expect("seed");
    let samples = store.quota_samples().expect("samples");
    assert_eq!(
        inserted,
        samples
            .values()
            .flat_map(|windows| windows.values().map(Vec::len))
            .sum::<usize>()
    );
    let synthetic = measure(&samples, now);
    println!(
        "synthetic_sqlite: rows={} overview_bytes={} history_bytes={}",
        synthetic.sample_rows, synthetic.overview_bytes, synthetic.history_bytes
    );
    drop(store);
    let _ = fs::remove_dir_all(&root);

    match copy_user_cache() {
        None => println!("real_cache: skipped (no ~/.config/quota/cache.sqlite)"),
        Some(copy) => {
            let samples = samples_from_readonly_cache(&copy.path).expect("read copy");
            let now = samples
                .values()
                .flat_map(|windows| windows.values())
                .flatten()
                .map(|sample| sample.observed_at)
                .max()
                .unwrap_or_else(Utc::now);
            let real = measure(&samples, now);
            println!(
                "real_cache: rows={} overview_bytes={} history_bytes={} path={}",
                real.sample_rows,
                real.overview_bytes,
                real.history_bytes,
                copy.path.display()
            );
            copy.cleanup();
        }
    }
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
                    let duration = cadence_seconds(id, group);
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

fn cadence_seconds(window_id: &str, samples: &[QuotaSample]) -> i64 {
    match window_id {
        "five_hour" => 18_000,
        "weekly" | "seven_day" => 604_800,
        "monthly" => 2_592_000,
        "hourly" => 3_600,
        "daily" => 86_400,
        _ => inferred_cadence(samples).unwrap_or(0),
    }
}

fn inferred_cadence(samples: &[QuotaSample]) -> Option<i64> {
    let mut resets: Vec<DateTime<Utc>> = samples.iter().map(|sample| sample.resets_at).collect();
    resets.sort();
    resets.dedup();
    if let Some(gap) = resets
        .windows(2)
        .map(|pair| (pair[1] - pair[0]).num_seconds())
        .filter(|gap| *gap > 0)
        .min()
    {
        return Some(gap);
    }
    let first = samples.iter().map(|sample| sample.observed_at).min()?;
    let resets_at = samples.last()?.resets_at;
    let span = (resets_at - first).num_seconds();
    (span > 0).then_some(span)
}

fn rfc3339(instant: DateTime<Utc>) -> String {
    instant.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn samples_from_readonly_cache(path: &Path) -> Result<QuotaSamplesBySubscription, rusqlite::Error> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut statement = conn.prepare(
        "SELECT subscription_key, window_id, resets_at, observed_at, used_percent
         FROM quota_samples ORDER BY observed_at",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, f64>(4)?,
        ))
    })?;
    let mut samples = QuotaSamplesBySubscription::new();
    for row in rows {
        let (subscription_key, window_id, resets_at, observed_at, used_percent) = row?;
        let (Some(resets_at), Ok(observed_at)) = (
            crate::history::whole_second_utc(&resets_at),
            DateTime::parse_from_rfc3339(&observed_at),
        ) else {
            continue;
        };
        samples
            .entry(subscription_key)
            .or_default()
            .entry(window_id)
            .or_default()
            .push(QuotaSample {
                resets_at,
                observed_at: observed_at.with_timezone(&Utc),
                used_percent,
            });
    }
    Ok(samples)
}

struct CacheCopy {
    path: PathBuf,
    root: PathBuf,
}

impl CacheCopy {
    fn cleanup(self) {
        let _ = fs::remove_dir_all(self.root);
    }
}

fn copy_user_cache() -> Option<CacheCopy> {
    let src = PathBuf::from(std::env::var_os("HOME")?).join(".config/quota/cache.sqlite");
    if !src.is_file() {
        return None;
    }
    let root = std::env::temp_dir().join(format!("quota-cache-copy-{}", Uuid::new_v4()));
    fs::create_dir_all(&root).ok()?;
    let path = root.join("cache-copy.sqlite");
    fs::copy(&src, &path).ok()?;
    for suffix in ["-wal", "-shm"] {
        let side = PathBuf::from(format!("{}{suffix}", src.display()));
        if side.is_file() {
            let dest = PathBuf::from(format!("{}{suffix}", path.display()));
            let _ = fs::copy(&side, dest);
        }
    }
    Some(CacheCopy { path, root })
}

fn temp_root(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("quota-{name}-{}", Uuid::new_v4()));
    fs::create_dir_all(&root).expect("root");
    fs::canonicalize(&root).expect("canonical root")
}
