//! Asking the Grok CLI to renew this device's sign-in.
//!
//! Grok's access token lives about six hours and only the Grok CLI can renew it: it holds the
//! refresh token, and it owns `auth.json`. A Mac that has not opened Grok since breakfast
//! therefore reports an expired sign-in for the rest of the day, which is a true statement
//! about a file and a useless one about the account.
//!
//! So an expired grant — and nothing else — earns one bounded `grok agent stdio`, run by the
//! shared renewal in [`crate::providers::common`], which owns every bound this has: the
//! private working directory, the minimal environment, the one spawn, the hourly floor, and
//! the verdict read back off `auth.json`. What is here is the part only Grok has — which
//! request renews.
//!
//! What it does not do: submit the refresh token itself, write `auth.json`, or ask for any
//! authentication method other than `cached_token`. The CLI's other method, `grok.com`, prints
//! a device code and waits for a person; a scheduled refresh must never start that.

use serde_json::json;
use std::time::Duration;

use crate::providers::common::{
    BoundedExchange, CollectionContext, ProbeEnvironment, RenewalAttempt, RenewalPlan,
    json_rpc_reply, renew_sign_in,
};

/// The program asked, and the arguments that put it on stdio instead of on a terminal.
const GROK_BINARY: &str = "grok";
const AGENT_STDIO: [&str; 2] = ["agent", "stdio"];

/// The variable the CLI finds `auth.json` through, and so does the collector that reads it
/// back. A renewal that dropped it would renew a different sign-in than the one this refresh
/// found expired.
const GROK_HOME: [&str; 1] = ["GROK_HOME"];

/// The one authentication method this build ever asks for, whatever `initialize` advertises.
///
/// It renews from the refresh token the CLI already holds, with no browser and no device code.
/// Grok 1.0.5 answers it without listing it — its `authMethods` offers only `grok.com`, "Sign
/// in with Grok", which prints a device code and waits for a person — so the list is not worth
/// consulting: a method this build does not know is not one it would ask for, and an
/// unsupported one comes back as a JSON-RPC error that costs a round trip and starts nothing.
const CACHED_TOKEN_METHOD: &str = "cached_token";

const INITIALIZE_ID: u64 = 1;
const AUTHENTICATE_ID: u64 = 2;

/// How long the whole renewal may take.
///
/// Two round trips: the handshake, then a token exchange against x.ai. Five seconds has been
/// enough for both against Grok 1.0.5, and it is short enough that a hung CLI cannot hold a
/// five-minute refresh.
pub const RENEWAL_TIMEOUT: Duration = Duration::from_secs(5);

/// Renews an expired Grok sign-in through the CLI that owns it, at most once an hour.
///
/// Returns the attempt to persist, and `None` when no attempt was made — an unexpired token,
/// no Grok CLI on this Mac, a cancelled refresh, or an attempt already made this hour.
pub fn renew_expired_sign_in(
    context: &mut CollectionContext,
    environment: &ProbeEnvironment,
    attempted: Option<&RenewalAttempt>,
    now: i64,
) -> Option<RenewalAttempt> {
    let plan = RenewalPlan {
        binary: GROK_BINARY,
        args: &AGENT_STDIO,
        inherited: &GROK_HOME,
        fixed: &[],
        expiring: &super::sign_in_expiring,
        // Not the negation: the Grok CLI leaves `auth.json` alone when it cannot renew, so a
        // file that is gone or unreadable afterwards is a sign-out rather than a refusal.
        usable: &super::sign_in_usable,
        rewrites_keychain: false,
        drive: &drive,
    };
    renew_sign_in(&plan, context, environment, attempted, now)
}

/// Asks the CLI to renew from the token already on disk.
///
/// Waits for the answer before letting the exchange go. Closing stdin is how a stdio agent is
/// told to shut down, and a renewal is a network round trip: the deleted version of this rung
/// stopped at the reply that named the method, which is how it managed to look like it had
/// asked for something. The exchange holds the pipe until it is dropped — through the wait
/// after stdin closes — so the CLI is never answering into a closed one.
fn drive(exchange: &mut BoundedExchange) {
    if !exchange.send(&initialize_request()) {
        return;
    }
    // The reply is not read for what it offers, only waited for: `authenticate` may not be
    // sent to a program that has not finished coming up.
    if json_rpc_reply(exchange, INITIALIZE_ID).is_none() {
        return;
    }
    if !exchange.send(&authenticate_request(CACHED_TOKEN_METHOD)) {
        return;
    }
    let _ = json_rpc_reply(exchange, AUTHENTICATE_ID);
}

fn initialize_request() -> String {
    json!({
        "jsonrpc": "2.0",
        "id": INITIALIZE_ID,
        "method": "initialize",
        "params": {
            "protocolVersion": "1",
            // This build reads a credential file the CLI writes. It does not offer the CLI a
            // filesystem or a terminal of its own.
            "clientCapabilities": {
                "fs": { "readTextFile": false, "writeTextFile": false },
                "terminal": false
            }
        }
    })
    .to_string()
}

fn authenticate_request(method: &str) -> String {
    json!({
        "jsonrpc": "2.0",
        "id": AUTHENTICATE_ID,
        "method": "authenticate",
        // `headless` is the CLI's word for "there is no browser here".
        "params": { "methodId": method, "_meta": { "headless": true } }
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::common::{RENEWAL_FLOOR_SECONDS, RenewalOutcome};
    use std::collections::HashMap;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    fn temp_directory(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "quota-grok-renewal-{name}-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&path).expect("directory");
        path
    }

    fn auth_json(expires_at: &str, token: &str) -> String {
        format!(
            "{{\"https://auth.x.ai::fixture\": {{\"key\": \"{token}\", \
             \"expires_at\": \"{expires_at}\", \"user_id\": \"fixture-user\"}}}}"
        )
    }

    /// A stand-in for the Grok CLI: it answers the handshake, takes a third of a second over
    /// `authenticate` the way a network round trip does, and only then rewrites `auth.json`.
    /// A caller that did not wait for the reply would read the stale file.
    fn renewing_script(log: &Path, auth: &Path, rewritten: &str) -> String {
        format!(
            "#!/bin/sh\n\
             echo \"ran $*\" >> {log}\n\
             read -r first || exit 1\n\
             case \"$first\" in *'\"initialize\"'*) ;; *) exit 2 ;; esac\n\
             printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"method\":\"ready\"}}'\n\
             printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"authMethods\":[{{\"id\":\"grok.com\",\"name\":\"Grok\"}}]}}}}'\n\
             read -r second || exit 1\n\
             case \"$second\" in *'\"{CACHED_TOKEN_METHOD}\"'*) ;; *) exit 3 ;; esac\n\
             sleep 0.3\n\
             printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{{}}}}'\n\
             cat > {auth} <<'AUTHJSON'\n\
             {rewritten}\n\
             AUTHJSON\n",
            log = log.display(),
            auth = auth.display(),
        )
    }

    fn install(directory: &Path, body: &str) {
        let binary = directory.join(GROK_BINARY);
        fs::write(&binary, body).expect("binary");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).expect("mode");
        }
    }

    fn spawns(log: &Path) -> usize {
        fs::read_to_string(log)
            .map(|text| text.lines().count())
            .unwrap_or(0)
    }

    /// Only the temporary directory is searched, so no test can reach the Grok install on the
    /// host, and the collection home is the temporary one for the same reason.
    fn fixture(name: &str, expires_at: &str) -> (PathBuf, CollectionContext, ProbeEnvironment) {
        let directory = temp_directory(name);
        let grok_home = directory.join("grok-home");
        fs::create_dir_all(&grok_home).expect("grok home");
        fs::write(grok_home.join("auth.json"), auth_json(expires_at, "stale")).expect("auth");
        let context = CollectionContext {
            home_directory: directory.clone(),
            environment: HashMap::from([(
                "GROK_HOME".to_owned(),
                grok_home.to_string_lossy().into_owned(),
            )]),
            now: Some("2026-08-26T12:00:00Z".to_owned()),
            ..CollectionContext::default()
        };
        let environment = ProbeEnvironment {
            // Only the temporary directory is searched for the binary, whatever `PATH` holds:
            // a test must not be able to start the Grok install on this machine.
            directories: vec![directory.clone()],
            home: directory.clone(),
            path: Some(format!("{}:/usr/bin:/bin", directory.display())),
            timeout: Duration::from_secs(5),
        };
        (directory, context, environment)
    }

    /// The whole rung in one pass: an expired token buys exactly one `grok agent stdio`, the
    /// handshake asks for `cached_token` and reads the reply to it, and the credentials the
    /// billing request will be built from are the ones the CLI just wrote.
    #[test]
    fn an_expired_sign_in_is_renewed_once_and_billing_gets_the_new_token() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture("renewed", "2026-08-26T11:00:00Z");
            let log = directory.join("spawns.log");
            let auth = directory.join("grok-home/auth.json");
            install(
                &directory,
                &renewing_script(&log, &auth, &auth_json("2026-08-26T18:00:00Z", "fresh")),
            );

            assert!(super::super::sign_in_expiring(&context));
            let attempt = renew_expired_sign_in(&mut context, &environment, None, 10_000)
                .expect("an expired sign-in earns an attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::Renewed);
            assert_eq!(attempt.attempted_at, 10_000);
            assert_eq!(spawns(&log), 1);
            assert_eq!(
                fs::read_to_string(&log).expect("log").trim(),
                "ran agent stdio"
            );

            // The collector reads the file afterwards, so this is the token the billing
            // request goes out with.
            let credentials = super::super::load_credentials(&context).expect("credentials");
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
            let (directory, mut context, environment) =
                fixture("unexpired", "2026-08-26T18:00:00Z");
            let log = directory.join("spawns.log");
            let auth = directory.join("grok-home/auth.json");
            install(
                &directory,
                &renewing_script(&log, &auth, &auth_json("2026-08-27T00:00:00Z", "fresh")),
            );
            assert!(renew_expired_sign_in(&mut context, &environment, None, 10_000).is_none());
            assert_eq!(spawns(&log), 0);
            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// A CLI that cannot renew must not be started every five minutes for the rest of the
    /// day, and the hour it costs is the same hour whatever the failure was.
    #[test]
    fn a_cli_that_cannot_renew_is_asked_once_an_hour() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture("floor", "2026-08-26T11:00:00Z");
            let log = directory.join("spawns.log");
            // Answers the handshake and leaves the credential file exactly as it was.
            install(
                &directory,
                &renewing_script(&log, &directory.join("ignored.json"), "{}"),
            );

            let first =
                renew_expired_sign_in(&mut context, &environment, None, 10_000).expect("first");
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

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// A CLI that never answers holds the refresh for its deadline and no longer, and a CLI
    /// that dies mid-handshake is a failed attempt rather than a stuck one.
    #[test]
    fn a_cli_that_hangs_or_fails_is_bounded_and_records_a_failure() {
        #[cfg(unix)]
        {
            let (directory, mut context, mut environment) =
                fixture("hangs", "2026-08-26T11:00:00Z");
            // Well under the thirty seconds the child would otherwise take, and well over
            // the time macOS spends checking a freshly written executable the first time —
            // which on a loaded machine running the rest of this suite is over a second.
            environment.timeout = Duration::from_secs(3);
            let log = directory.join("spawns.log");
            install(
                &directory,
                &format!("#!/bin/sh\necho ran >> {}\nsleep 30\n", log.display()),
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
                &format!("#!/bin/sh\necho ran >> {}\nexit 3\n", log.display()),
            );
            let attempt =
                renew_expired_sign_in(&mut context, &environment, None, 20_000).expect("attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::Failed);
            assert_eq!(spawns(&log), 2);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// Without the CLI there is nothing to ask and nothing to rate-limit, so the next refresh
    /// after an install is free to try immediately.
    #[test]
    fn a_mac_without_the_grok_cli_starts_nothing_and_records_nothing() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture("absent", "2026-08-26T11:00:00Z");
            assert!(renew_expired_sign_in(&mut context, &environment, None, 10_000).is_none());
            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// The method on offer is not the method this build asks for. `grok.com` prints a device
    /// code and waits for a person; nothing a scheduled refresh does may start that.
    #[test]
    fn the_only_method_ever_asked_for_is_cached_token() {
        let request = authenticate_request(CACHED_TOKEN_METHOD);
        assert!(request.contains(CACHED_TOKEN_METHOD));
        assert!(!request.contains("grok.com"));
    }
}
