//! How often each provider may be asked, and what Automatic asks for (ADR 0063).
//!
//! Everything here is a pure decision over instants the caller supplies. The scheduler decides
//! which providers are due; the collection itself passes them through [`gate`], which is where
//! the per-provider floor, a 429 backoff, and another Mac's fresh reading say no. A manual
//! refresh waits out only [`MANUAL_FLOOR`].

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::catalog::ProviderId;
use crate::observation::instant;
use crate::protocol::{QuotaRefreshMode, QuotaRefreshTier, QuotaRefreshTierReason};

/// What a manual refresh still waits for: one ask per provider per minute.
pub const MANUAL_FLOOR: Duration = Duration::from_secs(60);
/// Automatic tiers.
pub const ACTIVE_INTERVAL: Duration = Duration::from_secs(60);
pub const NORMAL_INTERVAL: Duration = Duration::from_secs(300);
pub const IDLE_INTERVAL: Duration = Duration::from_secs(600);
/// Local agent writes this recent make its provider active.
pub const ACTIVE_WINDOW: Duration = Duration::from_secs(5 * 60);
/// No local activity and no demand for this long makes a provider idle.
pub const IDLE_AFTER: Duration = Duration::from_secs(60 * 60);
/// A window with less than this share left makes its provider active.
pub const LOW_REMAINING_PERCENT: f64 = 20.0;
/// A request another client made is answered only while it is this fresh.
pub const DEMAND_LIFETIME: Duration = Duration::from_secs(10 * 60);
/// Backoff without a usable `Retry-After`: five minutes, doubling, at most thirty.
pub const BACKOFF_START: Duration = Duration::from_secs(5 * 60);
pub const BACKOFF_CAP: Duration = Duration::from_secs(30 * 60);
/// The longest `Retry-After` honoured.
pub const RETRY_AFTER_CAP: Duration = Duration::from_secs(60 * 60);
/// After a 429, the account it was earned on is asked no more often than this…
pub const RATE_LIMITED_FLOOR: Duration = Duration::from_secs(5 * 60);
/// …for this long after the latest 429, whatever it answers in between.
pub const RATE_LIMITED_FLOOR_SPAN: Duration = Duration::from_secs(24 * 60 * 60);
/// Periodic ticks move by up to this share of their interval either way.
pub const JITTER: f64 = 0.1;

/// The catalog's floor for this provider.
pub const fn min_interval(provider: ProviderId) -> Duration {
    Duration::from_secs(provider.metadata().min_interval_seconds)
}

/// The floor this Mac holds `provider` to for `account`: the catalog's, raised to
/// [`RATE_LIMITED_FLOOR`] while a 429 on that account is less than [`RATE_LIMITED_FLOOR_SPAN`]
/// old.
pub fn floor(
    provider: ProviderId,
    record: Option<&CadenceRecord>,
    account: &str,
    now: DateTime<Utc>,
) -> Duration {
    let raised = record
        .and_then(|record| record.raised_floor.as_ref())
        .is_some_and(|raised| raised.account == account && raised.until > now);
    if raised {
        min_interval(provider).max(RATE_LIMITED_FLOOR)
    } else {
        min_interval(provider)
    }
}

/// The local agent whose logs say its provider is in use, read from the Usage scanner's roots.
/// Only these map one to one; an agent that can talk to any provider (OpenCode, Pi, Kilo) would
/// need its logs parsed to say which, and activity is an mtime check, so they do not take part.
pub const fn activity_agent(provider: ProviderId) -> Option<crate::usage::UsageAgent> {
    use crate::usage::UsageAgent;
    match provider {
        ProviderId::Claude => Some(UsageAgent::ClaudeCode),
        ProviderId::Codex => Some(UsageAgent::Codex),
        ProviderId::Gemini => Some(UsageAgent::Gemini),
        ProviderId::Cursor => Some(UsageAgent::Cursor),
        ProviderId::Grok => Some(UsageAgent::Grok),
        ProviderId::Copilot => Some(UsageAgent::Copilot),
        ProviderId::Antigravity => Some(UsageAgent::Antigravity),
        _ => None,
    }
}

/// What Automatic knows about one provider.
#[derive(Debug, Clone, Copy, Default)]
pub struct Activity {
    /// Newest write under the provider's agent logs.
    pub last_write: Option<DateTime<Utc>>,
    /// A window of this Mac's last reading has less than 20 % left.
    pub low_remaining: bool,
    /// The last collection another client asked for.
    pub last_demand: Option<DateTime<Utc>>,
}

pub fn tier(
    provider: ProviderId,
    activity: &Activity,
    now: DateTime<Utc>,
) -> (QuotaRefreshTier, Option<QuotaRefreshTierReason>) {
    if activity_agent(provider).is_none() {
        return (QuotaRefreshTier::Normal, None);
    }
    let within = |at: Option<DateTime<Utc>>, span: Duration| {
        at.is_some_and(|at| {
            now.signed_duration_since(at)
                .to_std()
                .map_or(true, |age| age <= span)
        })
    };
    if within(activity.last_write, ACTIVE_WINDOW) {
        return (
            QuotaRefreshTier::Active,
            Some(QuotaRefreshTierReason::AgentActive),
        );
    }
    if activity.low_remaining {
        return (
            QuotaRefreshTier::Active,
            Some(QuotaRefreshTierReason::LowRemaining),
        );
    }
    if !within(activity.last_write, IDLE_AFTER) && !within(activity.last_demand, IDLE_AFTER) {
        return (QuotaRefreshTier::Idle, None);
    }
    (QuotaRefreshTier::Normal, None)
}

/// The first instant anything but a manual refresh may ask `provider` for `account`: its floor
/// after the last ask, or the end of a backoff on that account when that is later. The scheduler
/// waits for it, so a tick that jitter or a shared pass brings early is not spent on a provider
/// the gate would refuse.
pub fn not_before(
    provider: ProviderId,
    record: Option<&CadenceRecord>,
    account: &str,
    now: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    let record = record?;
    let floor_ends = record.last_attempt_at.map(|last| {
        last + chrono::Duration::from_std(floor(provider, Some(record), account, now))
            .unwrap_or_default()
    });
    let backoff_ends = record
        .backoff
        .as_ref()
        .filter(|backoff| backoff.account == account)
        .map(|backoff| backoff.until);
    floor_ends.max(backoff_ends)
}

/// How long a provider held to `floor` waits between periodic collections, before jitter.
pub fn interval(
    floor: Duration,
    mode: QuotaRefreshMode,
    fixed: Duration,
    tier: QuotaRefreshTier,
) -> Duration {
    let base = match mode {
        QuotaRefreshMode::Fixed => fixed,
        QuotaRefreshMode::Automatic => match tier {
            QuotaRefreshTier::Active => ACTIVE_INTERVAL,
            QuotaRefreshTier::Normal => NORMAL_INTERVAL,
            QuotaRefreshTier::Idle => IDLE_INTERVAL,
        },
    };
    base.max(floor)
}

/// `interval` moved by `unit` (in `[-1, 1]`) times [`JITTER`].
pub fn jittered(interval: Duration, unit: f64) -> Duration {
    interval.mul_f64(1.0 + JITTER * unit.clamp(-1.0, 1.0))
}

/// Whether any percentage window of this provider's reading has less than 20 % left.
pub fn low_remaining(quota: Option<&Value>, provider: ProviderId) -> bool {
    report_snapshots(quota, provider).any(|snapshot| {
        snapshot
            .get("windows")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|window| window.get("duration_seconds").is_some())
            .filter_map(|window| window.get("used_percent").and_then(Value::as_f64))
            .any(|used| 100.0 - used < LOW_REMAINING_PERCENT)
    })
}

fn report_snapshots(quota: Option<&Value>, provider: ProviderId) -> impl Iterator<Item = &Value> {
    quota
        .and_then(|quota| quota.get("results"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(move |result| {
            result.get("provider").and_then(Value::as_str) == Some(provider.as_str())
        })
        .filter_map(|result| result.get("snapshots").and_then(Value::as_array))
        .flatten()
}

/// The accounts this Mac last read for `provider`. What a backoff and a cross-device skip are
/// keyed on, because the account a credential answers for is only known from a reading.
pub fn accounts(quota: Option<&Value>, provider: ProviderId) -> BTreeSet<String> {
    report_snapshots(quota, provider)
        .filter_map(|snapshot| {
            snapshot
                .get("account")
                .and_then(|account| account.get("fingerprint"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect()
}

/// Whether the provider has been set up here at all: its last result named a source.
pub fn in_use(quota: Option<&Value>, provider: ProviderId) -> bool {
    quota
        .and_then(|quota| quota.get("results"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .any(|result| {
            result.get("provider").and_then(Value::as_str) == Some(provider.as_str())
                && result
                    .get("sources")
                    .and_then(Value::as_array)
                    .is_some_and(|sources| !sources.is_empty())
        })
}

/// What `cache.sqlite` keeps per provider.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CadenceRecord {
    /// When this Mac last asked the provider (a source was tried, whatever it answered).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_attempt_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backoff: Option<Backoff>,
    /// The raised floor the latest 429 earned. Unlike `backoff`, a success does not clear it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raised_floor: Option<RaisedFloor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RaisedFloor {
    /// The account the 429 was earned on, or empty when this Mac had no reading yet.
    pub account: String,
    pub until: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Backoff {
    /// The account the 429 was earned on, or empty when this Mac had no reading yet.
    pub account: String,
    pub until: DateTime<Utc>,
    /// Consecutive 429s, which is what doubles the wait.
    pub strikes: u32,
}

pub type CadenceRecords = BTreeMap<String, CadenceRecord>;

/// The wait a 429 earns. A positive `Retry-After` is honoured up to an hour; without one the
/// wait starts at five minutes and doubles to thirty.
pub fn backoff_after_429(
    previous: Option<&Backoff>,
    account: &str,
    retry_after_seconds: Option<u64>,
    now: DateTime<Utc>,
) -> Backoff {
    let strikes = previous
        .filter(|previous| previous.account == account)
        .map_or(1, |previous| previous.strikes.saturating_add(1));
    let wait = match retry_after_seconds.filter(|seconds| *seconds > 0) {
        Some(seconds) => Duration::from_secs(seconds).min(RETRY_AFTER_CAP),
        None => BACKOFF_START
            .saturating_mul(1 << strikes.saturating_sub(1).min(8))
            .min(BACKOFF_CAP),
    };
    Backoff {
        account: account.to_owned(),
        until: now + chrono::Duration::from_std(wait).unwrap_or_default(),
        strikes,
    }
}

/// What a 429 on `account` at `now` raises the floor to, and for how long.
pub fn raised_floor_after_429(account: &str, now: DateTime<Utc>) -> RaisedFloor {
    RaisedFloor {
        account: account.to_owned(),
        until: now + chrono::Duration::from_std(RATE_LIMITED_FLOOR_SPAN).unwrap_or_default(),
    }
}

/// The account a backoff is judged against: the one this Mac last read, or none.
pub fn backoff_account(accounts: &BTreeSet<String>) -> String {
    accounts.iter().next().cloned().unwrap_or_default()
}

/// Whether a collection is someone asking in person, which only waits out [`MANUAL_FLOOR`].
pub const fn is_manual(trigger: crate::protocol::DiagnosticAttemptTrigger) -> bool {
    matches!(
        trigger,
        crate::protocol::DiagnosticAttemptTrigger::Manual
            | crate::protocol::DiagnosticAttemptTrigger::Recheck
    )
}

/// What one provider looks like to the gate.
#[derive(Debug, Clone, Default)]
pub struct GateInput<'a> {
    pub record: Option<&'a CadenceRecord>,
    /// The account this Mac last read for the provider.
    pub account: String,
    /// Every account this Mac reads for the provider was observed by another Mac within the
    /// provider's floor.
    pub read_elsewhere: bool,
}

/// Which of `candidates` this collection may actually ask.
pub fn gate<'a>(
    candidates: &[ProviderId],
    manual: bool,
    now: DateTime<Utc>,
    input: impl Fn(ProviderId) -> GateInput<'a>,
) -> Vec<ProviderId> {
    candidates
        .iter()
        .copied()
        .filter(|provider| {
            let input = input(*provider);
            let since_last = input
                .record
                .and_then(|record| record.last_attempt_at)
                .and_then(|at| now.signed_duration_since(at).to_std().ok());
            if manual {
                return since_last.is_none_or(|age| age >= MANUAL_FLOOR);
            }
            if since_last
                .is_some_and(|age| age < floor(*provider, input.record, &input.account, now))
            {
                return false;
            }
            let backing_off = input
                .record
                .and_then(|record| record.backoff.as_ref())
                .is_some_and(|backoff| backoff.account == input.account && backoff.until > now);
            !backing_off && !input.read_elsewhere
        })
        .collect()
}

/// Whether another Mac read every account this one reads for `provider` within its floor.
///
/// `summary` is the Account summary this device last read; its subscriptions carry each source's
/// device and observation instant.
pub fn read_elsewhere(
    summary: Option<&Value>,
    provider: ProviderId,
    accounts: &BTreeSet<String>,
    this_device: Option<&str>,
    now: DateTime<Utc>,
) -> bool {
    if accounts.is_empty() {
        return false;
    }
    let floor = min_interval(provider);
    let subscriptions = summary
        .and_then(|summary| summary.get("subscriptions"))
        .and_then(Value::as_array);
    accounts.iter().all(|account| {
        subscriptions.into_iter().flatten().any(|subscription| {
            subscription.get("provider").and_then(Value::as_str) == Some(provider.as_str())
                && subscription
                    .get("snapshot")
                    .and_then(|snapshot| snapshot.get("account"))
                    .and_then(|account| account.get("fingerprint"))
                    .and_then(Value::as_str)
                    == Some(account.as_str())
                && subscription
                    .get("sources")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .any(|source| {
                        source.get("device_id").and_then(Value::as_str) != this_device
                            && instant(source.get("observed_at")).is_some_and(|observed| {
                                now.signed_duration_since(observed)
                                    .to_std()
                                    .is_ok_and(|age| age < floor)
                            })
                    })
        })
    })
}

/// The collection request this Mac should answer now, if any.
///
/// A request is answered once, only while it is ten minutes fresh, and only when it asks for
/// something newer than this Mac's last complete collection.
pub fn demand_to_answer(
    requested_at: Option<DateTime<Utc>>,
    last_complete_collection: Option<DateTime<Utc>>,
    answered: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    let requested = requested_at?;
    let fresh = now
        .signed_duration_since(requested)
        .to_std()
        .map_or(true, |age| age <= DEMAND_LIFETIME);
    (fresh
        && last_complete_collection.is_none_or(|collected| requested > collected)
        && answered.is_none_or(|answered| requested > answered))
    .then_some(requested)
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
    fn a_provider_is_active_idle_or_normal_from_its_agent_and_its_windows() {
        let now = utc(100_000);
        let active = Activity {
            last_write: Some(now - chrono::Duration::minutes(4)),
            ..Activity::default()
        };
        let low = Activity {
            last_write: Some(now - chrono::Duration::minutes(30)),
            low_remaining: true,
            ..Activity::default()
        };
        let quiet = Activity {
            last_write: Some(now - chrono::Duration::minutes(61)),
            ..Activity::default()
        };
        let asked = Activity {
            last_demand: Some(now - chrono::Duration::minutes(59)),
            ..quiet
        };
        assert_eq!(
            tier(ProviderId::Codex, &active, now),
            (
                QuotaRefreshTier::Active,
                Some(QuotaRefreshTierReason::AgentActive)
            )
        );
        assert_eq!(
            tier(ProviderId::Codex, &low, now),
            (
                QuotaRefreshTier::Active,
                Some(QuotaRefreshTierReason::LowRemaining)
            )
        );
        assert_eq!(
            tier(ProviderId::Codex, &quiet, now).0,
            QuotaRefreshTier::Idle
        );
        assert_eq!(
            tier(ProviderId::Codex, &asked, now).0,
            QuotaRefreshTier::Normal
        );
        // A provider no local agent maps to stays normal whatever its windows say.
        assert_eq!(
            tier(ProviderId::OpenRouter, &low, now).0,
            QuotaRefreshTier::Normal
        );
    }

    /// The catalog floor wins over every tier and every fixed interval: an active Claude is
    /// still asked every three minutes, and a one-minute fixed cadence asks it no faster.
    #[test]
    fn the_catalog_floor_bounds_every_tier_and_fixed_interval() {
        let automatic = |provider, tier| {
            interval(
                min_interval(provider),
                QuotaRefreshMode::Automatic,
                Duration::ZERO,
                tier,
            )
        };
        assert_eq!(
            automatic(ProviderId::Codex, QuotaRefreshTier::Active),
            Duration::from_secs(60)
        );
        assert_eq!(
            automatic(ProviderId::Claude, QuotaRefreshTier::Active),
            Duration::from_secs(180)
        );
        assert_eq!(
            automatic(ProviderId::Gemini, QuotaRefreshTier::Active),
            Duration::from_secs(120)
        );
        assert_eq!(
            interval(
                min_interval(ProviderId::Claude),
                QuotaRefreshMode::Fixed,
                Duration::from_secs(60),
                QuotaRefreshTier::Active
            ),
            Duration::from_secs(180)
        );
    }

    /// Every non-manual trigger respects the floor; a manual one waits a minute and nothing
    /// else, backoff and another Mac's reading included.
    #[test]
    fn the_gate_holds_the_floor_and_a_backoff_and_lets_a_manual_refresh_through_once_a_minute() {
        let now = utc(1_000_000);
        let asked = |seconds_ago: i64| CadenceRecord {
            last_attempt_at: Some(now - chrono::Duration::seconds(seconds_ago)),
            ..CadenceRecord::default()
        };
        let records = BTreeMap::from([
            ("claude", asked(170)),
            ("codex", asked(61)),
            (
                "gemini",
                CadenceRecord {
                    last_attempt_at: Some(now - chrono::Duration::seconds(3_000)),
                    backoff: Some(Backoff {
                        account: "acct".to_owned(),
                        until: now + chrono::Duration::seconds(10),
                        strikes: 1,
                    }),
                    ..CadenceRecord::default()
                },
            ),
            ("cursor", asked(3_000)),
        ]);
        let input = |provider: ProviderId| GateInput {
            record: records.get(provider.as_str()),
            account: "acct".to_owned(),
            read_elsewhere: provider == ProviderId::Cursor,
        };
        let candidates = [
            ProviderId::Claude,
            ProviderId::Codex,
            ProviderId::Gemini,
            ProviderId::Cursor,
            ProviderId::Grok,
        ];
        assert_eq!(
            gate(&candidates, false, now, input),
            [ProviderId::Codex, ProviderId::Grok]
        );
        assert_eq!(
            gate(&candidates, true, now, input),
            candidates.to_vec(),
            "manual passes everything asked more than a minute ago"
        );
        let just_asked = BTreeMap::from([("claude", asked(30))]);
        assert!(
            gate(&[ProviderId::Claude], true, now, |provider| GateInput {
                record: just_asked.get(provider.as_str()),
                ..GateInput::default()
            })
            .is_empty()
        );
    }

    #[test]
    fn a_retry_after_is_honoured_up_to_an_hour_and_without_one_the_wait_doubles_to_thirty_minutes()
    {
        let now = utc(0);
        let wait = |backoff: &Backoff| (backoff.until - now).num_seconds();
        assert_eq!(wait(&backoff_after_429(None, "a", Some(120), now)), 120);
        assert_eq!(wait(&backoff_after_429(None, "a", Some(7_200), now)), 3_600);
        let mut previous = None;
        let mut waits = Vec::new();
        for _ in 0..5 {
            let next = backoff_after_429(previous.as_ref(), "a", None, now);
            waits.push(wait(&next));
            previous = Some(next);
        }
        assert_eq!(waits, [300, 600, 1_200, 1_800, 1_800]);
        // A 429 on another account starts over.
        assert_eq!(
            wait(&backoff_after_429(previous.as_ref(), "b", None, now)),
            300
        );
    }

    /// A 429 holds that account to five minutes for a day, even once it answers again; another
    /// account of the provider, and the same one a day later, are back on the catalog floor.
    #[test]
    fn a_429_raises_the_accounts_floor_to_five_minutes_for_a_day() {
        let now = utc(1_000_000);
        let record = CadenceRecord {
            last_attempt_at: Some(now - chrono::Duration::seconds(120)),
            backoff: None,
            raised_floor: Some(raised_floor_after_429(
                "acct",
                now - chrono::Duration::hours(23),
            )),
        };
        let asks = |account: &str, at: DateTime<Utc>| {
            !gate(&[ProviderId::Codex], false, at, |_| GateInput {
                record: Some(&record),
                account: account.to_owned(),
                read_elsewhere: false,
            })
            .is_empty()
        };
        assert!(
            !asks("acct", now),
            "120 s is past Codex's 60 s but inside five minutes"
        );
        assert!(asks("other", now));
        assert!(asks("acct", now + chrono::Duration::hours(1)));
        assert_eq!(
            not_before(ProviderId::Codex, Some(&record), "acct", now),
            Some(now + chrono::Duration::seconds(180)),
            "the scheduler waits for the raised floor"
        );
    }

    #[test]
    fn a_fresh_reading_from_another_mac_skips_the_provider_and_this_macs_own_does_not() {
        let now = utc(10_000);
        let summary = |device: &str, age: i64| {
            json!({"subscriptions": [{
                "provider": "claude",
                "snapshot": {"account": {"fingerprint": "org-1"}},
                "sources": [{
                    "device_id": device,
                    "observed_at": (now - chrono::Duration::seconds(age)).to_rfc3339()
                }]
            }]})
        };
        let accounts = BTreeSet::from(["org-1".to_owned()]);
        let skip = |summary: Value| {
            read_elsewhere(
                Some(&summary),
                ProviderId::Claude,
                &accounts,
                Some("mine"),
                now,
            )
        };
        assert!(skip(summary("other", 120)));
        assert!(
            !skip(summary("other", 181)),
            "outside Claude's three-minute floor"
        );
        assert!(!skip(summary("mine", 10)), "this Mac's own reading");
        assert!(
            !read_elsewhere(
                Some(&summary("other", 10)),
                ProviderId::Claude,
                &BTreeSet::new(),
                Some("mine"),
                now
            ),
            "a Mac that has never read the provider reads it"
        );
    }

    #[test]
    fn a_request_is_answered_once_and_only_while_it_is_fresh() {
        let now = utc(100_000);
        let requested = now - chrono::Duration::minutes(2);
        let collected = now - chrono::Duration::minutes(4);
        assert_eq!(
            demand_to_answer(Some(requested), Some(collected), None, now),
            Some(requested)
        );
        assert_eq!(
            demand_to_answer(Some(requested), Some(collected), Some(requested), now),
            None,
            "already answered"
        );
        assert_eq!(
            demand_to_answer(
                Some(requested),
                Some(now - chrono::Duration::minutes(1)),
                None,
                now
            ),
            None,
            "a collection already finished after it"
        );
        assert_eq!(
            demand_to_answer(Some(now - chrono::Duration::minutes(11)), None, None, now),
            None,
            "expired, e.g. while this Mac slept"
        );
    }
}
