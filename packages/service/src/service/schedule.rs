//! Quota collection cadence, Account poll, and window-reset catch-up.
//!
//! One scheduler thread waits for the next of three events. Provider collection uses the stored
//! interval. Account reads run every minute and are skipped when a collection that already
//! includes an Account read is due. A window `resets_at` that falls before the next collection
//! wakes a quota-only pass.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::observation::instant;
use crate::protocol::{
    ACCOUNT_SYNC_INTERVAL_SECONDS, DEFAULT_QUOTA_REFRESH_INTERVAL_SECONDS,
    QUOTA_REFRESH_INTERVALS_SECONDS,
};

/// Extra delay after `resets_at` so the provider has rolled the window before we read it.
pub const RESET_BOUNDARY_SLACK: Duration = Duration::from_secs(2);

pub const fn account_sync_interval() -> Duration {
    Duration::from_secs(ACCOUNT_SYNC_INTERVAL_SECONDS)
}

pub const fn default_quota_refresh_interval() -> Duration {
    Duration::from_secs(DEFAULT_QUOTA_REFRESH_INTERVAL_SECONDS)
}

pub fn quota_refresh_interval(seconds: u64) -> Option<Duration> {
    QUOTA_REFRESH_INTERVALS_SECONDS
        .contains(&seconds)
        .then_some(Duration::from_secs(seconds))
}

/// Which scheduler event is due first. Equal instants prefer a collection over an Account-only
/// read, and a reset catch-up over a periodic collection that would cover it anyway.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchedulerWake {
    Account,
    Quota,
    ResetBoundary,
}

/// Why the scheduler thread was woken before its sleep elapsed.
///
/// These are not the same: a cadence change restarts the collection clock from now, a reset
/// catch-up only recomputes the next sleep, and shutdown is a separate flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SchedulerSignal {
    #[default]
    Idle,
    Recalculate,
    CadenceChanged,
}

/// The collection deadline after a signal. A reset wake must not postpone the periodic tick.
pub fn next_quota_after_signal(
    signal: SchedulerSignal,
    now: Instant,
    interval: Duration,
    next_quota: Instant,
) -> Instant {
    match signal {
        SchedulerSignal::CadenceChanged => now + interval,
        SchedulerSignal::Idle | SchedulerSignal::Recalculate => next_quota,
    }
}

pub fn next_wake(
    next_account: Instant,
    next_quota: Instant,
    next_reset: Option<Instant>,
) -> (SchedulerWake, Instant) {
    let mut kind = SchedulerWake::Account;
    let mut at = next_account;
    if next_quota <= at {
        kind = SchedulerWake::Quota;
        at = next_quota;
    }
    if let Some(reset) = next_reset
        && reset <= at
    {
        kind = SchedulerWake::ResetBoundary;
        at = reset;
    }
    (kind, at)
}

/// The next window reset this collection should catch, if it lands before the next periodic
/// quota tick. Already-attempted instants are skipped so a failed catch-up cannot loop.
pub fn next_reset_boundary(
    quota: &Value,
    now: DateTime<Utc>,
    next_quota_at: DateTime<Utc>,
    attempted: &HashSet<i64>,
) -> Option<DateTime<Utc>> {
    let slack = chrono::Duration::seconds(RESET_BOUNDARY_SLACK.as_secs() as i64);
    quota
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|result| {
            result
                .get("snapshots")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .flat_map(|snapshot| {
            snapshot
                .get("windows")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(|window| instant(window.get("resets_at")))
        .filter(|reset| *reset > now)
        .map(|reset| reset + slack)
        .filter(|wake| *wake < next_quota_at)
        .filter(|wake| !attempted.contains(&wake.timestamp()))
        .min()
}

pub fn instant_from_utc(
    at: DateTime<Utc>,
    now_utc: DateTime<Utc>,
    now: Instant,
) -> Option<Instant> {
    let delta = at.signed_duration_since(now_utc);
    if delta.num_milliseconds() <= 0 {
        return Some(now);
    }
    Some(now + Duration::from_millis(delta.num_milliseconds() as u64))
}

pub fn utc_from_instant(
    at: Instant,
    now: Instant,
    now_utc: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    if at <= now {
        return Some(now_utc);
    }
    now_utc.checked_add_signed(chrono::Duration::from_std(at - now).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn utc(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(secs, 0).single().expect("timestamp")
    }

    #[test]
    fn only_the_named_intervals_are_collection_cadences() {
        assert_eq!(quota_refresh_interval(60), Some(Duration::from_secs(60)));
        assert_eq!(quota_refresh_interval(120), Some(Duration::from_secs(120)));
        assert_eq!(quota_refresh_interval(300), Some(Duration::from_secs(300)));
        assert_eq!(quota_refresh_interval(600), Some(Duration::from_secs(600)));
        assert_eq!(quota_refresh_interval(900), Some(Duration::from_secs(900)));
        assert_eq!(quota_refresh_interval(180), None);
        assert_eq!(quota_refresh_interval(0), None);
    }

    #[test]
    fn a_sooner_reset_wins_over_the_periodic_ticks() {
        let origin = Instant::now();
        let (kind, at) = next_wake(
            origin + Duration::from_secs(60),
            origin + Duration::from_secs(300),
            Some(origin + Duration::from_secs(12)),
        );
        assert_eq!(kind, SchedulerWake::ResetBoundary);
        assert_eq!(at, origin + Duration::from_secs(12));
    }

    #[test]
    fn a_due_collection_skips_a_same_instant_account_read() {
        let origin = Instant::now();
        let due = origin + Duration::from_secs(60);
        let (kind, at) = next_wake(due, due, None);
        assert_eq!(kind, SchedulerWake::Quota);
        assert_eq!(at, due);
    }

    #[test]
    fn a_reset_inside_the_next_interval_is_caught() {
        let now = utc(1_000);
        let next_quota = utc(1_000 + 300);
        let quota = json!({
            "results": [{
                "snapshots": [{
                    "windows": [
                        {"resets_at": "1970-01-01T00:17:20Z"},
                        {"resets_at": "1970-01-01T01:00:00Z"}
                    ]
                }]
            }]
        });
        let wake = next_reset_boundary(&quota, now, next_quota, &HashSet::new()).expect("wake");
        assert_eq!(wake, utc(1_040 + 2));
    }

    #[test]
    fn a_reset_after_the_next_collection_is_left_to_that_tick() {
        let now = utc(1_000);
        let next_quota = utc(1_300);
        let quota = json!({
            "results": [{
                "snapshots": [{
                    "windows": [{"resets_at": "1970-01-01T00:22:00Z"}]
                }]
            }]
        });
        assert_eq!(
            next_reset_boundary(&quota, now, next_quota, &HashSet::new()),
            None
        );
    }

    #[test]
    fn a_recalculate_wake_does_not_postpone_the_collection_clock() {
        let now = Instant::now();
        let next_quota = now + Duration::from_secs(40);
        let interval = Duration::from_secs(60);
        assert_eq!(
            next_quota_after_signal(SchedulerSignal::Recalculate, now, interval, next_quota),
            next_quota
        );
        assert_eq!(
            next_quota_after_signal(SchedulerSignal::CadenceChanged, now, interval, next_quota),
            now + interval
        );
    }

    #[test]
    fn a_reset_is_judged_against_the_scheduled_tick_not_completion_time() {
        let collection_finished = utc(1_020);
        let next_quota = utc(1_060);
        let quota = json!({
            "results": [{
                "snapshots": [{
                    "windows": [{"resets_at": "1970-01-01T00:17:35Z"}]
                }]
            }]
        });
        // 17:35 + 2s slack = 1_057, before the scheduled tick at 1_060, after completion at 1_020.
        assert_eq!(
            next_reset_boundary(&quota, collection_finished, next_quota, &HashSet::new()),
            Some(utc(1_057))
        );
        // Judging from completion+interval (1_080) would still catch it; a reset at 1_070 would
        // be wrongly caught that way, and correctly left to the 1_060 tick.
        let later = json!({
            "results": [{
                "snapshots": [{
                    "windows": [{"resets_at": "1970-01-01T00:17:48Z"}]
                }]
            }]
        });
        assert_eq!(
            next_reset_boundary(&later, collection_finished, next_quota, &HashSet::new()),
            None
        );
        assert!(
            next_reset_boundary(
                &later,
                collection_finished,
                collection_finished + chrono::Duration::seconds(60),
                &HashSet::new()
            )
            .is_some()
        );
    }

    #[test]
    fn an_attempted_boundary_is_not_scheduled_again() {
        let now = utc(1_000);
        let next_quota = utc(1_300);
        let quota = json!({
            "results": [{
                "snapshots": [{
                    "windows": [{"resets_at": "1970-01-01T00:17:20Z"}]
                }]
            }]
        });
        let mut attempted = HashSet::new();
        attempted.insert((1_040 + 2) as i64);
        assert_eq!(
            next_reset_boundary(&quota, now, next_quota, &attempted),
            None
        );
    }
}
