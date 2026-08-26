//! The record that rate-limits asking a provider's own CLI to renew this device's sign-in.
//!
//! Two providers hold a token only their own program can renew — Grok's `auth.json` and Claude
//! Code's credential entry — and both renewals are bounded the same way: they run on the
//! refresh worker before collection, only when the token on disk is already out of time, and at
//! most once an hour whatever the last attempt produced. That hour is what keeps a CLI which
//! cannot renew off the five-minute timer, so it has to outlive the process. It is kept for
//! every provider in one map, so a refresh reads it once and writes it once however many
//! providers asked.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The floor between two renewal attempts for the same provider, whatever the last one
/// produced.
///
/// On time alone, not on the binary: an install that rewrites itself must not be able to buy
/// an earlier spawn, for the same reason `cli_version` puts a floor under a churning binary.
/// The fingerprint is recorded because it says *which* program ran, not to shorten this.
pub const RENEWAL_FLOOR_SECONDS: i64 = 3_600;

/// Everything a CLI may print across one renewal.
///
/// Nothing is read from it — the credential the CLI wrote is the answer — so this only bounds
/// what a child can make this process hold. Grok's `initialize` reply is the big one, about
/// 4 KiB of capabilities and model listings on 1.0.5, and this leaves room for a build that
/// says more without leaving room for one that never stops.
pub const RENEWAL_OUTPUT_LIMIT: usize = 65_536;

/// What one renewal attempt produced, for the record that rate-limits the next one.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RenewalOutcome {
    /// The credential now holds a token this refresh can use.
    Renewed,
    /// The CLI emptied its own credential instead of renewing it, which is how Claude Code
    /// records that the refresh token it held was rejected. Only a person at a terminal can
    /// undo that, and no number of further attempts would.
    SignedOut,
    /// Neither. Whether the CLI refused, hung, or was killed does not change what the next
    /// hour is allowed to do.
    Failed,
}

/// The last time this device asked one provider's CLI to renew, against which binary, and how
/// it went.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RenewalAttempt {
    pub fingerprint: String,
    pub attempted_at: i64,
    pub outcome: RenewalOutcome,
}

/// Every provider's last attempt, keyed by `ProviderId::as_str`. Rebuildable: losing it to a
/// cache reset costs one extra attempt per provider and nothing else.
pub type RenewalAttempts = BTreeMap<String, RenewalAttempt>;

/// Whether the hour the last attempt bought has not run out yet.
///
/// An attempt stamped in the future is a clock that moved rather than an hour spent, and buys
/// nothing: a device whose time jumped forward and back would otherwise stop renewing.
pub fn within_renewal_floor(attempted: Option<&RenewalAttempt>, now: i64) -> bool {
    attempted.is_some_and(|attempt| {
        attempt.attempted_at <= now && now - attempt.attempted_at < RENEWAL_FLOOR_SECONDS
    })
}
