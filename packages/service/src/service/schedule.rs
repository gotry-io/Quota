//! Quota collection cadence, Account poll, window-reset catch-up, and status-page poll.
//!
//! One scheduler thread waits for the next of four events. Each provider keeps its own
//! collection clock (ADR 0063): the interval [`super::cadence`] gives it, moved by up to 10 %
//! either way, from the last pass that included it. A pass collects every provider due within
//! [`DUE_SLACK`], so providers on the same interval stay in one pass. Account reads run every
//! minute and are skipped when a collection that already includes an Account read is due. A
//! window `resets_at` that falls before its provider's next collection wakes a pass for the
//! providers resetting then. Official status pages are polled every ten minutes and never win a
//! tie against quota, reset, or Account work.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::catalog::ProviderId;
use crate::observation::instant;
use crate::protocol::{
    ACCOUNT_SYNC_INTERVAL_SECONDS, DEFAULT_QUOTA_REFRESH_INTERVAL_SECONDS,
    PROVIDER_STATUS_INTERVAL_SECONDS, QUOTA_REFRESH_INTERVALS_SECONDS,
};

/// Extra delay after `resets_at` so the provider has rolled the window before we read it.
pub const RESET_BOUNDARY_SLACK: Duration = Duration::from_secs(2);
/// A pass also takes every provider due this soon after it, so clocks on one interval stay
/// together rather than drifting into a pass each.
pub const DUE_SLACK: Duration = Duration::from_secs(30);

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

pub const fn provider_status_interval() -> Duration {
    Duration::from_secs(PROVIDER_STATUS_INTERVAL_SECONDS)
}

/// Which scheduler event is due first. Equal instants prefer a collection over an Account-only
/// read, a reset catch-up over a periodic collection that would cover it anyway, and any of
/// those over a status-page poll.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchedulerWake {
    Account,
    Quota,
    ResetBoundary,
    ProviderStatus,
}

/// Why the scheduler thread was woken before its sleep elapsed. Several can be posted before it
/// wakes, and none may swallow another.
///
/// These are not the same: a cadence change restarts every collection clock from now, a
/// collection request runs a pass now and restarts the clocks it covers, a reset catch-up only
/// recomputes the next sleep, and shutdown is a separate flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SchedulerSignals {
    pub recalculate: bool,
    pub cadence_changed: bool,
    pub demand: bool,
}

impl SchedulerSignals {
    pub const fn is_idle(self) -> bool {
        !self.recalculate && !self.cadence_changed && !self.demand
    }
}

/// Every provider whose clock is due by `now` plus [`DUE_SLACK`].
pub fn due_providers(next_due: &BTreeMap<ProviderId, Instant>, now: Instant) -> Vec<ProviderId> {
    next_due
        .iter()
        .filter(|(_, at)| **at <= now + DUE_SLACK)
        .map(|(provider, _)| *provider)
        .collect()
}

/// When a pass taking `due` should start so that none of them waits for a pass of its own: the
/// latest instant one of them may be asked, when that is still ahead. A provider held by its
/// floor for a few more seconds would otherwise be left out and run alone right after, reading
/// the Account and uploading a second time.
pub fn shared_pass_at(
    due: &[ProviderId],
    earliest: &BTreeMap<ProviderId, Instant>,
    now: Instant,
) -> Option<Instant> {
    due.iter()
        .filter_map(|provider| earliest.get(provider).copied())
        .filter(|at| *at > now && *at <= now + DUE_SLACK)
        .max()
}

pub fn next_wake(
    next_account: Instant,
    next_quota: Instant,
    next_reset: Option<Instant>,
    next_status: Instant,
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
    if next_status < at {
        kind = SchedulerWake::ProviderStatus;
        at = next_status;
    }
    (kind, at)
}

/// The next window reset this collection should catch, and the providers resetting then, if it
/// lands before that provider's next periodic tick. Already-attempted instants are skipped so a
/// failed catch-up cannot loop.
pub fn next_reset_boundary(
    quota: &Value,
    now: DateTime<Utc>,
    next_due_at: impl Fn(ProviderId) -> DateTime<Utc>,
    attempted: &HashSet<i64>,
) -> Option<(DateTime<Utc>, BTreeSet<ProviderId>)> {
    let slack = chrono::Duration::seconds(RESET_BOUNDARY_SLACK.as_secs() as i64);
    let wakes = quota
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
        .filter_map(|snapshot| {
            let provider = snapshot
                .get("provider")
                .and_then(Value::as_str)
                .and_then(ProviderId::parse)?;
            Some(
                snapshot
                    .get("windows")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .map(move |window| (provider, window)),
            )
        })
        .flatten()
        .filter_map(|(provider, window)| Some((provider, instant(window.get("resets_at"))?)))
        .filter(|(_, reset)| *reset > now)
        .map(|(provider, reset)| (provider, reset + slack))
        .filter(|(provider, wake)| *wake < next_due_at(*provider))
        .filter(|(_, wake)| !attempted.contains(&wake.timestamp()))
        .collect::<Vec<_>>();
    let first = wakes.iter().map(|(_, wake)| *wake).min()?;
    Some((
        first,
        wakes
            .into_iter()
            .filter(|(_, wake)| *wake == first)
            .map(|(provider, _)| provider)
            .collect(),
    ))
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

    fn resetting(provider: &str, resets_at: &[&str]) -> Value {
        json!({
            "results": [{
                "snapshots": [{
                    "provider": provider,
                    "windows": resets_at
                        .iter()
                        .map(|at| json!({"resets_at": at}))
                        .collect::<Vec<_>>()
                }]
            }]
        })
    }

    #[test]
    fn a_sooner_reset_wins_over_the_periodic_ticks() {
        let origin = Instant::now();
        let (kind, at) = next_wake(
            origin + Duration::from_secs(60),
            origin + Duration::from_secs(300),
            Some(origin + Duration::from_secs(12)),
            origin + Duration::from_secs(600),
        );
        assert_eq!(kind, SchedulerWake::ResetBoundary);
        assert_eq!(at, origin + Duration::from_secs(12));
    }

    /// A reset is caught for the provider it belongs to, judged against that provider's own
    /// next tick: Codex's clock is not Claude's.
    #[test]
    fn a_reset_before_its_own_providers_tick_is_caught_for_that_provider() {
        let now = utc(1_000);
        let quota = json!({
            "results": [
                {"snapshots": [{"provider": "codex", "windows": [
                    {"resets_at": "1970-01-01T00:17:20Z"},
                    {"resets_at": "1970-01-01T01:00:00Z"}
                ]}]},
                {"snapshots": [{"provider": "claude", "windows": [
                    {"resets_at": "1970-01-01T00:17:10Z"}
                ]}]}
            ]
        });
        // Codex is next due at 1_300 and Claude at 1_020, before its 1_032 reset.
        let next_due = |provider| match provider {
            ProviderId::Claude => utc(1_020),
            _ => utc(1_300),
        };
        let (wake, providers) =
            next_reset_boundary(&quota, now, next_due, &HashSet::new()).expect("wake");
        assert_eq!(wake, utc(1_040 + 2));
        assert_eq!(providers, BTreeSet::from([ProviderId::Codex]));
    }

    #[test]
    fn a_reset_is_judged_against_the_scheduled_tick_not_completion_time() {
        let collection_finished = utc(1_020);
        let next_quota = |_| utc(1_060);
        // 17:35 + 2s slack = 1_057, before the scheduled tick at 1_060, after completion at 1_020.
        assert_eq!(
            next_reset_boundary(
                &resetting("codex", &["1970-01-01T00:17:35Z"]),
                collection_finished,
                next_quota,
                &HashSet::new()
            )
            .map(|(wake, _)| wake),
            Some(utc(1_057))
        );
        // A reset at 1_070 is left to the 1_060 tick; judging from completion + interval (1_080)
        // would wrongly catch it.
        let later = resetting("codex", &["1970-01-01T00:17:48Z"]);
        assert_eq!(
            next_reset_boundary(&later, collection_finished, next_quota, &HashSet::new()),
            None
        );
    }

    /// Account, collection and status poll all due at once: the collection runs (it reads the
    /// Account too) and the status poll waits.
    #[test]
    fn a_tie_goes_to_the_collection_over_an_account_read_and_a_status_poll() {
        let origin = Instant::now();
        let due = origin + Duration::from_secs(60);
        let (kind, at) = next_wake(due, due, None, due);
        assert_eq!(kind, SchedulerWake::Quota);
        assert_eq!(at, due);
    }

    #[test]
    fn a_sooner_status_poll_runs_when_nothing_else_is_due() {
        let origin = Instant::now();
        let (kind, at) = next_wake(
            origin + Duration::from_secs(60),
            origin + Duration::from_secs(300),
            None,
            origin + Duration::from_secs(12),
        );
        assert_eq!(kind, SchedulerWake::ProviderStatus);
        assert_eq!(at, origin + Duration::from_secs(12));
    }

    #[test]
    fn an_attempted_boundary_is_not_scheduled_again() {
        let mut attempted = HashSet::new();
        attempted.insert((1_040 + 2) as i64);
        assert_eq!(
            next_reset_boundary(
                &resetting("codex", &["1970-01-01T00:17:20Z"]),
                utc(1_000),
                |_| utc(1_300),
                &attempted
            ),
            None
        );
    }

    /// Clocks a few seconds apart ride one pass; one a minute out waits for its own.
    #[test]
    fn a_pass_takes_the_providers_due_within_the_slack() {
        let now = Instant::now();
        let next_due = BTreeMap::from([
            (ProviderId::Codex, now),
            (ProviderId::Grok, now + Duration::from_secs(20)),
            (ProviderId::Claude, now + Duration::from_secs(60)),
        ]);
        assert_eq!(
            due_providers(&next_due, now),
            [ProviderId::Codex, ProviderId::Grok]
        );
    }

    /// Codex is due now and Claude's floor ends nine seconds later: the pass waits for Claude
    /// rather than leave it to a pass of its own. Nobody held means no wait.
    #[test]
    fn a_pass_waits_for_a_due_provider_its_floor_holds_for_a_few_seconds() {
        let now = Instant::now();
        let due = [ProviderId::Codex, ProviderId::Claude];
        let earliest = BTreeMap::from([
            (ProviderId::Codex, now - Duration::from_secs(5)),
            (ProviderId::Claude, now + Duration::from_secs(9)),
        ]);
        assert_eq!(
            shared_pass_at(&due, &earliest, now),
            Some(now + Duration::from_secs(9))
        );
        let free = BTreeMap::from([(ProviderId::Codex, now - Duration::from_secs(5))]);
        assert_eq!(shared_pass_at(&due, &free, now), None);
    }
}
