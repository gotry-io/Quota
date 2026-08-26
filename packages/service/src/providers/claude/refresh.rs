//! Asking Claude Code to renew this device's sign-in.
//!
//! Claude Code's access token lives about eight hours, its refresh token about twenty-four
//! days, and only Claude Code renews either: it holds the refresh token and it owns the
//! credential — the macOS Keychain item where it can write one, the file otherwise. It renews
//! when it runs, and a Mac that has not opened it since breakfast therefore reports an expired
//! sign-in for the rest of the day, which is a true statement about a credential and a useless
//! one about the account.
//!
//! So an expired grant — and nothing else — earns one bounded `claude mcp list`, run by the
//! shared renewal in [`crate::providers::common`], which owns every bound this has: the empty
//! private working directory, the minimal environment, the one spawn, the hourly floor, the
//! Keychain memo this refresh has to forget because Claude Code rewrites that entry in place,
//! and the verdict read back off the credential. What is here is the part only Claude Code has
//! — which invocation renews.
//!
//! Why that command. Claude Code refreshes on its own startup path rather than on request, so
//! the question is which invocation reaches that path without doing anything else. `auth status
//! --json` does not: it reports the expired token and leaves it. `doctor` does, but only when
//! the environment already carries a running Claude Code session's variables, which a service
//! has no business synthesising. `mcp list` reaches it under the environment this build is
//! willing to hand a child — `HOME`, `PATH`, `TERM`, and `CLAUDE_CONFIG_DIR` where this device
//! sets one — and with an unexpired credential it leaves the credential untouched.
//!
//! Its one side effect is that it health-checks the MCP servers this device approved. Started
//! in an empty directory of this build's own making, that means the user-scoped servers in
//! `~/.claude.json` and no project's `.mcp.json`. It is stated rather than worked around: the
//! deadline is what keeps a slow server from holding the refresh.
//!
//! What it does not do: submit the refresh token itself, or write the credential file or the
//! Keychain item. Only Claude Code may spend that token, and only Claude Code writes what it
//! gets back.

use std::time::Duration;

use crate::providers::common::{
    BoundedExchange, CollectionContext, ProbeEnvironment, RenewalAttempt, RenewalPlan,
    renew_sign_in,
};

/// The program asked, and the arguments that reach its renewal path without asking it to do
/// anything else.
const CLAUDE_BINARY: &str = "claude";
const MCP_LIST: [&str; 2] = ["mcp", "list"];

/// The variable Claude Code finds the credential through, and so does the collector that reads
/// it back. A renewal that dropped it would renew a different sign-in than the one this
/// refresh found expired.
const CLAUDE_CONFIG_DIR: [&str; 1] = ["CLAUDE_CONFIG_DIR"];

/// A CLI that believes it has a terminal draws one. Nothing reads this output.
const DUMB_TERMINAL: [(&str, &str); 1] = [("TERM", "dumb")];

/// How long the whole renewal may take.
///
/// Longer than a `--version` read because it is not one: the CLI makes a network round trip to
/// the token endpoint and health-checks this device's MCP servers. Measured against a fixture
/// on an Apple Silicon Mac with Claude Code 2.1.246 and no MCP servers configured, the renewal
/// path took 2.97–3.46 s across three runs and the untouched path 2.05–2.44 s; ten seconds is
/// about three times the slowest of those, which is the room a Mac with servers to check
/// needs, and it is still short enough that a hung CLI cannot hold a five-minute refresh.
pub const RENEWAL_TIMEOUT: Duration = Duration::from_secs(10);

/// Renews an expired Claude Code sign-in through the CLI that owns it, at most once an hour.
///
/// Returns the attempt to persist, and `None` when no attempt was made — an unexpired token, a
/// credential with no refresh token in it, no Claude Code on this Mac, a cancelled refresh, or
/// an attempt already made this hour.
pub fn renew_expired_sign_in(
    context: &mut CollectionContext,
    environment: &ProbeEnvironment,
    attempted: Option<&RenewalAttempt>,
    now: i64,
) -> Option<RenewalAttempt> {
    let plan = RenewalPlan {
        binary: CLAUDE_BINARY,
        args: &MCP_LIST,
        inherited: &CLAUDE_CONFIG_DIR,
        fixed: &DUMB_TERMINAL,
        expiring: &super::sign_in_expiring,
        // Not the negation: an emptied entry is neither, which is how a Claude Code that
        // signed itself out is told apart from one that could not renew.
        usable: &super::sign_in_usable,
        drive: &drive,
    };
    renew_sign_in(&plan, context, environment, attempted, now)
}

/// Nothing to say. `claude mcp list` renews on its own startup path and then reports on MCP
/// servers, so the whole conversation is letting it run and reading the credential afterwards;
/// its stdout is read only to bound it.
fn drive(_exchange: &mut BoundedExchange) {}

#[cfg(test)]
mod tests {
    use super::super::{Credentials, Entry, collect_official, look_up_credentials};
    use super::*;
    use crate::providers::common::{RENEWAL_FLOOR_SECONDS, RenewalOutcome};
    use std::collections::HashMap;
    use std::fs;
    use std::path::{Path, PathBuf};

    /// The grant the collector would build its usage request from, once both stores have been
    /// read the way discovery reads them.
    fn grant(context: &CollectionContext) -> Option<Credentials> {
        look_up_credentials(context).entry.and_then(Entry::grant)
    }

    fn temp_directory(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "quota-claude-renewal-{name}-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&path).expect("directory");
        path
    }

    /// A Claude Code credential document. `expiresAt` is milliseconds, as Claude Code writes it.
    fn credentials(expires_at_ms: i64, access: &str, refresh: &str) -> String {
        format!(
            "{{\"claudeAiOauth\": {{\"accessToken\": \"{access}\", \
             \"refreshToken\": \"{refresh}\", \"expiresAt\": {expires_at_ms}, \
             \"scopes\": [\"user:profile\"], \"subscriptionType\": \"max\"}}}}"
        )
    }

    /// The document Claude Code leaves when the refresh token it holds is rejected: the tokens
    /// emptied in place and `expiresAt` zeroed. Observed from 2.1.246 against a fixture.
    const SIGNED_OUT: &str = "{\"claudeAiOauth\": {\"accessToken\": \"\", \
                              \"refreshToken\": \"\", \"expiresAt\": 0, \"scopes\": []}}";

    /// A stand-in for Claude Code: it records the run, takes a moment over it the way a
    /// network round trip does, and only then rewrites the credential. A caller that did not
    /// wait would read the stale one.
    fn renewing_script(log: &Path, credential: &Path, rewritten: &str) -> String {
        format!(
            "#!/bin/sh\n\
             echo \"ran $* cwd=$(pwd) config=${{CLAUDE_CONFIG_DIR:-none}} term=${{TERM:-none}}\" >> {log}\n\
             ls -A . >> {log}\n\
             sleep 0.2\n\
             cat > {credential} <<'CREDENTIAL'\n\
             {rewritten}\n\
             CREDENTIAL\n",
            log = log.display(),
            credential = credential.display(),
        )
    }

    fn install(directory: &Path, body: &str) {
        let binary = directory.join(CLAUDE_BINARY);
        fs::write(&binary, body).expect("binary");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).expect("mode");
        }
    }

    fn spawns(log: &Path) -> usize {
        fs::read_to_string(log)
            .map(|text| text.lines().filter(|line| line.starts_with("ran ")).count())
            .unwrap_or(0)
    }

    /// Only the temporary directory is searched, so no test can reach the Claude Code install
    /// on the host, and the config directory is the temporary one for the same reason. No
    /// `HOME` in the collection environment means `allows_host_keychain` is false, so no test
    /// reads the live Keychain either.
    fn fixture(name: &str, document: &str) -> (PathBuf, CollectionContext, ProbeEnvironment) {
        let directory = temp_directory(name);
        let config = directory.join("claude-config");
        fs::create_dir_all(&config).expect("config");
        fs::write(config.join(".credentials.json"), document).expect("credential");
        let context = CollectionContext {
            home_directory: directory.clone(),
            environment: HashMap::from([(
                "CLAUDE_CONFIG_DIR".to_owned(),
                config.to_string_lossy().into_owned(),
            )]),
            now: Some("2026-08-26T12:00:00Z".to_owned()),
            ..CollectionContext::default()
        };
        let environment = ProbeEnvironment {
            // Only the temporary directory is searched for the binary, whatever `PATH` holds:
            // a test must not be able to start the Claude Code install on this machine.
            directories: vec![directory.clone()],
            home: directory.clone(),
            path: Some(format!("{}:/usr/bin:/bin", directory.display())),
            timeout: Duration::from_secs(5),
        };
        (directory, context, environment)
    }

    /// Noon on 2026-08-26 in the milliseconds Claude Code writes, plus an offset in hours.
    fn hours_from_now(hours: i64) -> i64 {
        (1_787_745_600 + hours * 3_600) * 1_000
    }

    /// The whole rung in one pass: an expired credential buys exactly one `claude mcp list`,
    /// run in an empty directory with the config directory this refresh found the sign-in
    /// under, and the token the usage request will be built from is the one the CLI wrote.
    #[test]
    fn an_expired_sign_in_is_renewed_once_and_collection_gets_the_new_token() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "renewed",
                &credentials(hours_from_now(-1), "stale", "refresh"),
            );
            let log = directory.join("spawns.log");
            let credential = directory.join("claude-config/.credentials.json");
            install(
                &directory,
                &renewing_script(
                    &log,
                    &credential,
                    &credentials(hours_from_now(8), "fresh", "rotated"),
                ),
            );

            assert!(super::super::sign_in_expiring(&context));
            let attempt = renew_expired_sign_in(&mut context, &environment, None, 10_000)
                .expect("an expired sign-in earns an attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::Renewed);
            assert_eq!(attempt.attempted_at, 10_000);
            assert_eq!(spawns(&log), 1);

            let recorded = fs::read_to_string(&log).expect("log");
            assert!(recorded.contains("ran mcp list"), "{recorded}");
            assert!(recorded.contains("term=dumb"), "{recorded}");
            assert!(
                recorded.contains(&format!(
                    "config={}",
                    directory.join("claude-config").display()
                )),
                "{recorded}"
            );
            // Started in an empty directory of this build's own, so no project's `.mcp.json`
            // or settings are in reach: `ls -A` printed nothing between the two `ran` lines.
            assert_eq!(recorded.lines().count(), 1, "{recorded}");
            assert!(
                !recorded.contains(&format!("cwd={}", directory.display())),
                "{recorded}"
            );

            // The collector reads the credential afterwards, so this is the token the usage
            // request goes out with.
            let credentials = grant(&context).expect("credentials");
            assert_eq!(credentials.access_token, "fresh");
            assert!(!super::super::sign_in_expiring(&context));

            // A successful renewal resets no clock of its own: the next attempt is gated by
            // the token's own expiry, which is now hours away.
            assert!(
                renew_expired_sign_in(&mut context, &environment, Some(&attempt), 10_001).is_none()
            );
            assert_eq!(spawns(&log), 1);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// A token with hours left is not a sign-in problem, and a refresh that spawned anyway
    /// would be the five-minute timer this rung is bounded to stay off.
    #[test]
    fn an_unexpired_sign_in_starts_nothing() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "unexpired",
                &credentials(hours_from_now(8), "live", "refresh"),
            );
            let log = directory.join("spawns.log");
            install(
                &directory,
                &renewing_script(&log, &directory.join("ignored.json"), "{}"),
            );
            assert!(renew_expired_sign_in(&mut context, &environment, None, 10_000).is_none());
            assert_eq!(spawns(&log), 0);
            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// Nothing renews a credential that holds no refresh token, so nothing is started for one.
    /// Claude Code 2.1.x leaves a Keychain item holding only `mcpOAuth` behind, which is not a
    /// Claude sign-in at all, and an emptied entry is one no number of attempts would restore.
    #[test]
    fn a_credential_with_nothing_to_renew_from_starts_nothing() {
        #[cfg(unix)]
        {
            for (name, document) in [
                (
                    "mcp-only",
                    "{\"mcpOAuth\": {\"token\": \"mcp\"}}".to_owned(),
                ),
                ("no-refresh", credentials(hours_from_now(-1), "stale", "")),
                ("signed-out", SIGNED_OUT.to_owned()),
            ] {
                let (directory, mut context, environment) = fixture(name, &document);
                let log = directory.join("spawns.log");
                install(
                    &directory,
                    &renewing_script(&log, &directory.join("ignored.json"), "{}"),
                );
                assert!(
                    renew_expired_sign_in(&mut context, &environment, None, 10_000).is_none(),
                    "{name}"
                );
                assert_eq!(spawns(&log), 0, "{name}");
                let _ = fs::remove_dir_all(&directory);
            }
        }
    }

    /// A Claude Code that cannot renew must not be started every five minutes for the rest of
    /// the day, and the hour it costs is the same hour whatever the failure was.
    #[test]
    fn a_cli_that_cannot_renew_is_asked_once_an_hour() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "floor",
                &credentials(hours_from_now(-1), "stale", "refresh"),
            );
            let log = directory.join("spawns.log");
            // Runs and leaves the credential exactly as it was.
            install(
                &directory,
                &renewing_script(&log, &directory.join("ignored.json"), "{}"),
            );

            let first = renew_expired_sign_in(&mut context, &environment, None, 10_000)
                .expect("first attempt");
            assert_eq!(first.outcome, RenewalOutcome::Failed);
            assert_eq!(spawns(&log), 1);

            for later in [10_001, 10_000 + RENEWAL_FLOOR_SECONDS - 1] {
                assert!(
                    renew_expired_sign_in(&mut context, &environment, Some(&first), later)
                        .is_none()
                );
            }
            assert_eq!(spawns(&log), 1);

            let after = renew_expired_sign_in(
                &mut context,
                &environment,
                Some(&first),
                10_000 + RENEWAL_FLOOR_SECONDS,
            )
            .expect("the floor expires");
            assert_eq!(after.outcome, RenewalOutcome::Failed);
            assert_eq!(spawns(&log), 2);
            assert_eq!(after.fingerprint, first.fingerprint);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// A rejected refresh token is not a renewal that failed: Claude Code empties its own
    /// credential, and the reader has to sign in at a terminal. Recording that as `failed`
    /// would have this asking again every hour for something no attempt can produce.
    #[test]
    fn a_cli_that_empties_the_credential_reports_a_signed_out_claude_code() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "signed-out",
                &credentials(hours_from_now(-1), "stale", "rejected"),
            );
            let log = directory.join("spawns.log");
            let credential = directory.join("claude-config/.credentials.json");
            install(&directory, &renewing_script(&log, &credential, SIGNED_OUT));

            let attempt =
                renew_expired_sign_in(&mut context, &environment, None, 10_000).expect("attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::SignedOut);
            assert_eq!(spawns(&log), 1);
            // And the collector reads the same emptied entry, so the reader is told to sign
            // in rather than to open an app that would open onto this.
            assert!(grant(&context).is_none());
            assert_eq!(
                collect_official(&context)
                    .expect_err("signed out")
                    .source_id,
                super::super::SIGNED_OUT_SOURCE
            );

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// A CLI that never answers holds the refresh for its deadline and no longer, and a CLI
    /// that dies is a failed attempt rather than a stuck one.
    #[test]
    fn a_cli_that_hangs_or_fails_is_bounded_and_records_a_failure() {
        #[cfg(unix)]
        {
            let (directory, mut context, mut environment) = fixture(
                "hangs",
                &credentials(hours_from_now(-1), "stale", "refresh"),
            );
            // Well under the ten seconds a renewal allows, and well over the time macOS
            // spends checking a freshly written executable the first time — which on a
            // loaded machine running the rest of this suite is over a second.
            environment.timeout = Duration::from_secs(3);
            let log = directory.join("spawns.log");
            install(
                &directory,
                &format!(
                    "#!/bin/sh\necho \"ran $*\" >> {}\nsleep 30\n",
                    log.display()
                ),
            );
            let started = std::time::Instant::now();
            let attempt =
                renew_expired_sign_in(&mut context, &environment, None, 10_000).expect("attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::Failed);
            assert!(started.elapsed() < Duration::from_secs(10));
            assert_eq!(spawns(&log), 1);
            // The sign-in is what it was, so collection reports it as the sign-in it is.
            assert!(super::super::sign_in_expiring(&context));

            install(
                &directory,
                &format!("#!/bin/sh\necho \"ran $*\" >> {}\nexit 3\n", log.display()),
            );
            let attempt =
                renew_expired_sign_in(&mut context, &environment, None, 20_000).expect("attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::Failed);
            assert_eq!(spawns(&log), 2);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// Without Claude Code there is nothing to ask and nothing to rate-limit, so the next
    /// refresh after an install is free to try immediately.
    #[test]
    fn a_mac_without_claude_code_starts_nothing_and_records_nothing() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "absent",
                &credentials(hours_from_now(-1), "stale", "refresh"),
            );
            assert!(renew_expired_sign_in(&mut context, &environment, None, 10_000).is_none());
            let _ = fs::remove_dir_all(&directory);
        }
    }
}
