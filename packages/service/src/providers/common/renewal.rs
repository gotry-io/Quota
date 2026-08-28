//! The one way this build asks a provider's own CLI to renew this device's sign-in.
//!
//! Three providers hold a token only their own program can renew — Grok's `auth.json`, Claude
//! Code's credential entry, Codex's `auth.json` — and all three renewals are the same renewal.
//! It runs on the refresh worker before collection, only when the credential on disk is
//! already out of time, and at most once an hour whatever the last attempt produced. That hour
//! is what keeps a CLI which cannot renew off the five-minute timer, so it has to outlive the
//! process; it is kept for every provider in one map, so a refresh reads it once and writes it
//! once however many providers asked.
//!
//! A provider supplies a [`RenewalPlan`] and nothing else: which program, which arguments,
//! which of this device's variables the child inherits, whether the sign-in is expiring,
//! whether it is usable, a fingerprint of the credential, and how to talk to the child.
//! Everything around that — resolving the binary, the private empty working directory, the
//! minimal environment, the one bounded spawn, the hourly floor, and the verdict — is here,
//! once.
//!
//! What no plan may do: submit a refresh token, write a provider's credential, or ask for an
//! authentication method that waits for a person. Only the CLI that owns a token may spend it,
//! and only it writes what it gets back.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::process::Command;

use super::cli_version::{ProbeEnvironment, resolve_binary};
use super::io::{BoundedExchange, private_directory};
use super::types::CollectionContext;

/// The floor between two renewal attempts for the same provider, whatever the last one
/// produced.
///
/// On time alone, not on the binary: an install that rewrites itself must not be able to buy
/// an earlier spawn, for the same reason `cli_version` puts a floor under a churning binary.
pub const RENEWAL_FLOOR_SECONDS: i64 = 3_600;

/// Everything a CLI may print across one renewal.
///
/// Nothing is read from it for the verdict — the credential the CLI wrote is the answer — so
/// this only bounds what a child can make this process hold. Grok's `initialize` reply is the
/// big one, about 4 KiB of capabilities and model listings on 1.0.5, and this leaves room for
/// a build that says more without leaving room for one that never stops.
pub const RENEWAL_OUTPUT_LIMIT: usize = 65_536;

/// What one renewal attempt produced, for the record that rate-limits the next one.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RenewalOutcome {
    /// The credential now holds a token this refresh can use.
    Renewed,
    /// The CLI emptied or removed its own credential instead of renewing it, which is how
    /// Claude Code records that the refresh token it held was rejected. Only a person at a
    /// terminal can undo that, and no number of further attempts would.
    SignedOut,
    /// Neither. Whether the CLI refused, hung, or was killed does not change what the next
    /// hour is allowed to do.
    Failed,
}

/// The last time this device asked one provider's CLI to renew, and how it went.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RenewalAttempt {
    pub attempted_at: i64,
    pub outcome: RenewalOutcome,
}

/// Every provider's last attempt, keyed by `ProviderId::as_str`. Rebuildable: losing it to a
/// cache reset costs one extra attempt per provider and nothing else.
pub type RenewalAttempts = BTreeMap<String, RenewalAttempt>;

/// What one provider hands the renewal, and the only thing that differs between them.
///
/// The two predicates are asked about the credential on disk, not about each other. A sign-in
/// that is neither expiring nor usable is one the CLI emptied or removed: that is the third
/// answer, and reading `usable` as `!expiring` would lose it.
pub struct RenewalPlan<'a> {
    /// Resolved by the rules in [`super::cli_version`], so there is one answer to "which
    /// `grok` is that" wherever this build starts one.
    pub binary: &'static str,
    pub args: &'static [&'static str],
    /// Names copied from the collection environment when this device sets one, so the CLI
    /// renews the same sign-in this refresh found expiring rather than a different one.
    pub inherited: &'static [&'static str],
    /// Names given to the child whatever this device's environment holds.
    pub fixed: &'static [(&'static str, &'static str)],
    /// Whether this device's sign-in is the thing standing between the refresh and a reading,
    /// and the CLI holds what it would need to renew it. The gate before the spawn, and half
    /// the verdict after it.
    pub expiring: &'a dyn Fn(&CollectionContext) -> bool,
    /// Whether the credential now holds a token this refresh can use.
    pub usable: &'a dyn Fn(&CollectionContext) -> bool,
    /// A fingerprint of the credential as it stands. Captured before the spawn and compared
    /// afterwards so a forced run on a grant that still looks in date is `Renewed` only when
    /// the CLI actually rewrote it.
    pub identity: &'a dyn Fn(&CollectionContext) -> Option<String>,
    /// Whether the CLI rewrites the Keychain entry this refresh memoized. Only Claude Code's
    /// does; a provider whose credential is a file on disk is read fresh either way, and
    /// dropping the memo for it would buy a second `/usr/bin/security` for nothing.
    pub rewrites_keychain: bool,
    /// The conversation, if the CLI wants one. This is the one place providers differ: a
    /// handshake that has to name something the first reply carried cannot be a one-shot run.
    /// Called once, with the exchange already bounded and about to be closed.
    pub drive: &'a dyn Fn(&mut BoundedExchange),
}

/// Whether the hour the last attempt bought has not run out yet.
///
/// An attempt stamped in the future is a clock that moved rather than an hour spent, and buys
/// nothing: a device whose time jumped forward and back would otherwise stop renewing.
pub fn within_renewal_floor(attempted: Option<&RenewalAttempt>, now: i64) -> bool {
    attempted.is_some_and(|attempt| {
        attempt.attempted_at <= now && now - attempt.attempted_at < RENEWAL_FLOOR_SECONDS
    })
}

/// Renews an expiring sign-in through the CLI that owns it, at most once an hour on the
/// scheduled path.
///
/// Returns the attempt to persist, and `None` when no attempt was made — a sign-in with time
/// left, nothing to renew from, no such CLI on this Mac, a cancelled refresh, or an attempt
/// already made this hour. Those are not failures to record: nothing was started, so nothing
/// needs rate-limiting. A Recheck or a manual refresh skips that hour; the spawn is still
/// recorded, and the next scheduled refresh waits the hour.
///
/// `force` is the other gate: an official collection that came back `auth_required` even
/// though the credential on disk still looks in date. The local clock is not the account.
/// A forced run still will not start a CLI when this Mac holds nothing that CLI could
/// renew — no grant, or a grant that is neither expiring nor usable.
///
/// Takes the context by `&mut` so a plan that says its CLI rewrites the Keychain can forget
/// this refresh's one Keychain read. That memo is the only one; every renewal runs before any
/// collector holds a clone, so dropping it costs nothing until something asks again.
///
/// Runs on the refresh worker before collection, so the collector that reads the credential
/// afterwards neither knows nor waits for any of this.
pub fn renew_sign_in(
    plan: &RenewalPlan<'_>,
    context: &mut CollectionContext,
    environment: &ProbeEnvironment,
    attempted: Option<&RenewalAttempt>,
    now: i64,
    force: bool,
) -> Option<RenewalAttempt> {
    if context.cancelled() {
        return None;
    }
    let expiring = (plan.expiring)(context);
    if !force && !expiring {
        return None;
    }
    // Forced by a rejected reading, but this Mac has no grant the CLI could spend: a PAT-only
    // Codex, a signed-out Claude Code with no Keychain item, a Grok file that is gone.
    if force && !expiring && !(plan.usable)(context) {
        return None;
    }
    // A Mac without the CLI has nothing to ask, and reports the sign-in it has.
    let binary = resolve_binary(plan.binary, environment)?;
    if within_renewal_floor(attempted, now) {
        return None;
    }
    let before = (plan.identity)(context);
    renew(plan, &binary, context, environment);
    if plan.rewrites_keychain {
        context.forget_keychain();
    }
    // The CLI's exit status is not the answer; the credential is. A build that leaves non-zero
    // after rewriting the token has still renewed it, and one that leaves cleanly without
    // touching it has not. A forced run on a grant that still looks in date is `Renewed` only
    // when that fingerprint moved: Claude Code's `mcp list` makes no API call for one, and
    // recording a renewal that never happened would hide a token the server already rejected.
    let outcome = if (plan.usable)(context) {
        if force && !expiring && (plan.identity)(context) == before {
            RenewalOutcome::Failed
        } else {
            RenewalOutcome::Renewed
        }
    } else if (plan.expiring)(context) {
        RenewalOutcome::Failed
    } else {
        RenewalOutcome::SignedOut
    };
    Some(RenewalAttempt {
        attempted_at: now,
        outcome,
    })
}

/// Runs one provider CLI once, under every bound a renewal has.
///
/// One of the two functions in `src/providers` allowed to start a program a variable names,
/// and [`renew_sign_in`] is its only caller. The child gets a bounded stdout that is read only
/// to bound it unless the plan says otherwise, no stderr, one deadline for the whole exchange,
/// an empty directory of this build's own making, and an `env -i`-style environment holding
/// `HOME`, `PATH`, and what the plan named.
fn renew(
    plan: &RenewalPlan<'_>,
    binary: &Path,
    context: &CollectionContext,
    environment: &ProbeEnvironment,
) {
    // Without a directory of this build's own there is nowhere safe to start the CLI, and
    // starting it in the refresh worker's own directory is not the fallback.
    let Some(directory) = private_directory() else {
        return;
    };
    let mut command = Command::new(binary);
    command.args(plan.args).env_clear();
    command.env("HOME", &environment.home);
    if let Some(path) = environment.path.as_deref() {
        command.env("PATH", path);
    }
    for name in plan.inherited {
        if let Some(value) = context.env(name).filter(|value| !value.trim().is_empty()) {
            command.env(name, value);
        }
    }
    for (name, value) in plan.fixed {
        command.env(name, value);
    }
    command.current_dir(&directory);
    if let Some(mut exchange) = BoundedExchange::start(
        command,
        environment.timeout,
        context.cancel.as_ref(),
        RENEWAL_OUTPUT_LIMIT,
    ) {
        (plan.drive)(&mut exchange);
        // Dropping the exchange closes stdin, which is how a CLI is told the conversation is
        // over, and gives it what is left of the deadline to act on that before it is killed.
        // Codex renews on its way out, so the wait is part of the renewal rather than tidying
        // up after it.
        drop(exchange);
    }
    let _ = fs::remove_dir_all(&directory);
}

/// The reply to one JSON-RPC request, or `None` once the exchange ends or the CLI answers
/// with an error.
///
/// Two of the three CLIs this build renews through speak JSON-RPC over stdio, and both have
/// to read past the same two things: notifications, and whatever a CLI prints before it starts
/// speaking the protocol. Neither is the answer to the request in flight.
pub fn json_rpc_reply(exchange: &mut BoundedExchange, id: u64) -> Option<Value> {
    loop {
        let line = exchange.receive()?;
        if let Ok(value) = serde_json::from_slice::<Value>(&line)
            && value.get("id").and_then(Value::as_u64) == Some(id)
        {
            return value.get("error").is_none().then_some(value);
        }
    }
}
