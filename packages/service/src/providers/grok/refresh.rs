//! Asking the Grok CLI to renew this device's sign-in.
//!
//! Grok's access token lives about six hours and only the Grok CLI can renew it: it holds the
//! refresh token, and it owns `auth.json`. A Mac that has not opened Grok since breakfast
//! therefore reports an expired sign-in for the rest of the day, which is a true statement
//! about a file and a useless one about the account.
//!
//! So an expired grant — and nothing else — earns one bounded `grok agent stdio`, and
//! collection re-reads the file the CLI wrote. This is the one collection path that starts a
//! provider's CLI, and every bound on it exists to keep it off the five-minute timer: it runs
//! only when the token on disk is already dead, at most once an hour whatever the last attempt
//! produced, and for at most five seconds.
//!
//! What it does not do: submit the refresh token itself, write `auth.json`, or ask for any
//! authentication method other than `cached_token`. The CLI's other method, `grok.com`, prints
//! a device code and waits for a person; a scheduled refresh must never start that.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::Path;
use std::process::Command;

use crate::providers::common::{
    BoundedExchange, CollectionContext, ProbeEnvironment, binary_fingerprint, resolve_binary,
};

/// The program asked, and the arguments that put it on stdio instead of on a terminal.
const GROK_BINARY: &str = "grok";
const AGENT_STDIO: [&str; 2] = ["agent", "stdio"];

/// Everything the CLI may print across the whole handshake. Its `initialize` reply is the big
/// one — about 4 KiB of capabilities and model listings on 1.0.5 — and this leaves room for a
/// build that says more without leaving room for a build that never stops.
pub const RENEWAL_OUTPUT_LIMIT: usize = 65_536;

/// The floor between two renewal attempts, whatever the last one produced.
///
/// On time alone, not on the binary: an install that rewrites itself must not be able to buy
/// an earlier spawn, for the same reason `cli_version` puts a floor under a churning binary.
/// The fingerprint is recorded because it says *which* program ran, not to shorten this.
pub const RENEWAL_FLOOR_SECONDS: i64 = 3_600;

/// The one authentication method this build ever asks for. It renews from the refresh token
/// the CLI already holds, with no browser and no device code.
const CACHED_TOKEN_METHOD: &str = "cached_token";

const INITIALIZE_ID: u64 = 1;
const AUTHENTICATE_ID: u64 = 2;

/// What one renewal attempt produced, for the record that rate-limits the next one.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RenewalOutcome {
    /// The file now holds a token this refresh can use.
    Renewed,
    /// It does not. Whether the CLI refused, hung, or was killed does not change what the
    /// next hour is allowed to do.
    Failed,
}

/// The last time this device asked the Grok CLI to renew, against which binary, and how it
/// went. Rebuildable: losing it to a cache reset costs one extra attempt.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RenewalAttempt {
    pub fingerprint: String,
    pub attempted_at: i64,
    pub outcome: RenewalOutcome,
}

/// Renews an expired Grok sign-in through the CLI that owns it, at most once an hour.
///
/// Returns the attempt to persist, and `None` when no attempt was made — an unexpired token,
/// no Grok CLI on this Mac, a cancelled refresh, or an attempt already made this hour. Those
/// are not failures to record: nothing was started, so nothing needs rate-limiting.
///
/// Runs on the refresh worker before collection, so the collector that reads `auth.json`
/// afterwards neither knows nor waits for any of this.
pub fn renew_expired_sign_in(
    context: &CollectionContext,
    environment: &ProbeEnvironment,
    attempted: Option<&RenewalAttempt>,
    now: i64,
) -> Option<RenewalAttempt> {
    if context.cancelled() || !super::sign_in_expiring(context) {
        return None;
    }
    // A Mac without the CLI has nothing to ask, and reports the sign-in it has.
    let binary = resolve_binary(GROK_BINARY, environment)?;
    let fingerprint = binary_fingerprint(&binary)?;
    if attempted.is_some_and(|attempt| {
        attempt.attempted_at <= now && now - attempt.attempted_at < RENEWAL_FLOOR_SECONDS
    }) {
        return None;
    }
    renew(&binary, context, environment);
    // The CLI's exit status is not the answer; the file is. A build that leaves non-zero
    // after rewriting the token has still renewed it, one that leaves cleanly without
    // touching it has not, and one that left no readable file at all has certainly not.
    Some(RenewalAttempt {
        fingerprint,
        attempted_at: now,
        outcome: if super::sign_in_usable(context) {
            RenewalOutcome::Renewed
        } else {
            RenewalOutcome::Failed
        },
    })
}

/// Runs `grok agent stdio` once and asks it to renew from the token already on disk.
///
/// One of the two functions in `src/providers` allowed to start a program a variable names,
/// and [`renew_expired_sign_in`] is its only caller. The child gets a bounded stdout, no
/// stderr, the one deadline the whole exchange shares, and an `env -i`-style environment
/// holding `HOME`, `PATH`, and `GROK_HOME` where this device sets one.
fn renew(binary: &Path, context: &CollectionContext, environment: &ProbeEnvironment) {
    let mut command = Command::new(binary);
    command.args(AGENT_STDIO).env_clear();
    command.env("HOME", &environment.home);
    if let Some(path) = environment.path.as_deref() {
        command.env("PATH", path);
    }
    // The CLI finds `auth.json` through this, and so does the collector that reads it back.
    // A renewal that dropped it would renew a different sign-in than the one this refresh
    // found expired.
    if let Some(home) = context
        .env("GROK_HOME")
        .filter(|value| !value.trim().is_empty())
    {
        command.env("GROK_HOME", home);
    }
    // A CLI reads the directory it is started in, and the refresh worker's own is not one
    // this build chose for it.
    if environment.home.is_dir() {
        command.current_dir(&environment.home);
    }
    let Some(mut exchange) = BoundedExchange::start(
        command,
        environment.timeout,
        context.cancel.as_ref(),
        RENEWAL_OUTPUT_LIMIT,
    ) else {
        return;
    };
    if !exchange.send(&initialize_request()) {
        return;
    }
    let Some(reply) = read_reply(&mut exchange, INITIALIZE_ID) else {
        return;
    };
    if !exchange.send(&authenticate_request(cached_token_method(&reply))) {
        return;
    }
    // Wait for the answer before letting the exchange go. Closing stdin is how a stdio agent
    // is told to shut down, and a renewal is a network round trip: the deleted version of
    // this rung stopped at the reply that named the method, which is how it managed to look
    // like it had asked for something. The exchange holds the pipe until it is dropped —
    // through the wait after stdin closes — so the CLI is never answering into a closed one.
    let _ = read_reply(&mut exchange, AUTHENTICATE_ID);
}

/// The method to ask for: the `cached_token` entry `initialize` advertised, or the name this
/// build knows when it advertises none.
///
/// Grok 1.0.5 answers `cached_token` without listing it — its `authMethods` offers only
/// `grok.com`, "Sign in with Grok", which prints a device code and waits — so an unlisted
/// method is still asked for, and an unsupported one comes back as a JSON-RPC error that
/// costs a round trip and starts nothing. What never happens is asking for a *different*
/// method because that is the one on offer.
fn cached_token_method(reply: &Value) -> &str {
    reply
        .pointer("/result/authMethods")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|method| method.get("id").and_then(Value::as_str))
        .find(|id| *id == CACHED_TOKEN_METHOD)
        .unwrap_or(CACHED_TOKEN_METHOD)
}

/// The reply to one request, or `None` once the exchange ends or the CLI answers with an
/// error. Notifications and startup text the CLI prints before it speaks JSON-RPC are not
/// the answer to the request in flight, and are read past.
fn read_reply(exchange: &mut BoundedExchange, id: u64) -> Option<Value> {
    loop {
        let line = exchange.receive()?;
        if let Ok(value) = serde_json::from_slice::<Value>(&line)
            && value.get("id").and_then(Value::as_u64) == Some(id)
        {
            return value.get("error").is_none().then_some(value);
        }
    }
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
    use std::collections::HashMap;
    use std::fs;
    use std::path::PathBuf;
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
            let (directory, context, environment) = fixture("renewed", "2026-08-26T11:00:00Z");
            let log = directory.join("spawns.log");
            let auth = directory.join("grok-home/auth.json");
            install(
                &directory,
                &renewing_script(&log, &auth, &auth_json("2026-08-26T18:00:00Z", "fresh")),
            );

            assert!(super::super::sign_in_expiring(&context));
            let attempt = renew_expired_sign_in(&context, &environment, None, 10_000)
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
                renew_expired_sign_in(&context, &environment, Some(&attempt), 10_001).is_none()
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
            let (directory, context, environment) = fixture("unexpired", "2026-08-26T18:00:00Z");
            let log = directory.join("spawns.log");
            let auth = directory.join("grok-home/auth.json");
            install(
                &directory,
                &renewing_script(&log, &auth, &auth_json("2026-08-27T00:00:00Z", "fresh")),
            );
            assert!(renew_expired_sign_in(&context, &environment, None, 10_000).is_none());
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
            let (directory, context, environment) = fixture("floor", "2026-08-26T11:00:00Z");
            let log = directory.join("spawns.log");
            // Answers the handshake and leaves the credential file exactly as it was.
            install(
                &directory,
                &renewing_script(&log, &directory.join("ignored.json"), "{}"),
            );

            let first = renew_expired_sign_in(&context, &environment, None, 10_000).expect("first");
            assert_eq!(first.outcome, RenewalOutcome::Failed);
            assert_eq!(spawns(&log), 1);

            for later in [10_001, 10_000 + RENEWAL_FLOOR_SECONDS - 1] {
                assert!(
                    renew_expired_sign_in(&context, &environment, Some(&first), later).is_none()
                );
            }
            assert_eq!(spawns(&log), 1);

            let after = renew_expired_sign_in(
                &context,
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

    /// A CLI that never answers holds the refresh for its deadline and no longer, and a CLI
    /// that dies mid-handshake is a failed attempt rather than a stuck one.
    #[test]
    fn a_cli_that_hangs_or_fails_is_bounded_and_records_a_failure() {
        #[cfg(unix)]
        {
            let (directory, context, mut environment) = fixture("hangs", "2026-08-26T11:00:00Z");
            // Well under the five seconds a refresh allows, and well over the third of a
            // second macOS spends checking a freshly written executable the first time.
            environment.timeout = Duration::from_millis(1_500);
            let log = directory.join("spawns.log");
            install(
                &directory,
                &format!("#!/bin/sh\necho ran >> {}\nsleep 30\n", log.display()),
            );
            let started = std::time::Instant::now();
            let attempt =
                renew_expired_sign_in(&context, &environment, None, 10_000).expect("attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::Failed);
            assert!(started.elapsed() < Duration::from_secs(5));
            assert_eq!(spawns(&log), 1);
            // The sign-in is what it was, so collection reports it as the sign-in it is.
            assert!(super::super::sign_in_expiring(&context));

            install(
                &directory,
                &format!("#!/bin/sh\necho ran >> {}\nexit 3\n", log.display()),
            );
            let attempt =
                renew_expired_sign_in(&context, &environment, None, 20_000).expect("attempt");
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
            let (directory, context, environment) = fixture("absent", "2026-08-26T11:00:00Z");
            assert!(renew_expired_sign_in(&context, &environment, None, 10_000).is_none());
            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// The method on offer is not the method this build asks for. `grok.com` prints a device
    /// code and waits for a person; nothing a scheduled refresh does may start that.
    #[test]
    fn the_only_method_ever_asked_for_is_cached_token() {
        let listed_elsewhere = json!({"result": {"authMethods": [
            {"id": "grok.com", "name": "Grok"},
            {"id": "xai.api_key"}
        ]}});
        assert_eq!(cached_token_method(&listed_elsewhere), CACHED_TOKEN_METHOD);

        let listed = json!({"result": {"authMethods": [
            {"id": "grok.com"},
            {"id": CACHED_TOKEN_METHOD, "name": "Cached token"}
        ]}});
        assert_eq!(cached_token_method(&listed), CACHED_TOKEN_METHOD);

        for reply in [json!({"result": {}}), json!({}), json!({"result": null})] {
            assert_eq!(cached_token_method(&reply), CACHED_TOKEN_METHOD);
        }
        assert!(authenticate_request(cached_token_method(&listed)).contains(CACHED_TOKEN_METHOD));
        assert!(!authenticate_request(cached_token_method(&listed)).contains("grok.com"));
    }
}
