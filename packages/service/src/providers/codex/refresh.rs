//! Asking the Codex CLI to renew this device's sign-in.
//!
//! Codex's access token lives about ten days and only the Codex CLI can renew it: it holds the
//! refresh token, and it owns `auth.json`. A Mac that has not opened Codex in a fortnight
//! therefore reports an expired sign-in until someone does, which is a true statement about a
//! file and a useless one about the account.
//!
//! So an expired grant — and nothing else — earns one bounded `codex app-server`, run by the
//! shared renewal in [`crate::providers::common`], which owns every bound this has: the
//! private working directory, the minimal environment, the one spawn, the hourly floor, and
//! the verdict read back off `auth.json`. What is here is the part only Codex has — what it
//! takes to make the CLI renew.
//!
//! Which is: starting it. Measured against codex-cli 0.149.0 on a fixture `CODEX_HOME`, the
//! renewal is on the program's startup path, not on any request — a run that sent nothing at
//! all still made the token round trip about 2.2 s in. `initialize` is sent anyway, and its
//! reply read, because that is how this build knows the program came up and is speaking the
//! protocol rather than printing an error; stdin then closes, and the CLI finishes the refresh
//! it has already started before it leaves. Whole thing: 2.6–2.9 s observed.
//!
//! What it does not do: submit the refresh token itself, or write `auth.json`. Codex's refresh
//! tokens are single-use, so a second program redeeming one strands the CLI with a token the
//! server has already retired — the reason this asks rather than does.

use serde_json::json;
use std::time::Duration;

use crate::providers::common::{
    BoundedExchange, CollectionContext, ProbeEnvironment, RenewalAttempt, RenewalPlan,
    json_rpc_reply, renew_sign_in,
};

/// The program asked, and the arguments that put it on stdio with no ability to run anything.
///
/// `-s read-only` and `-a never` are the CLI's own words for a sandbox that cannot write and
/// an approval policy that never asks: a renewal has no business being handed either.
const CODEX_BINARY: &str = "codex";
const APP_SERVER: [&str; 5] = ["-s", "read-only", "-a", "never", "app-server"];

/// The variable the CLI finds `auth.json` through, and so does the collector that reads it
/// back. A renewal that dropped it would renew a different sign-in than the one this refresh
/// found expired.
const CODEX_HOME: [&str; 1] = ["CODEX_HOME"];

const INITIALIZE_ID: u64 = 1;

/// How long the whole renewal may take.
///
/// The CLI makes a network round trip to the token endpoint on its way up, and pulls a model
/// list and a plugin catalog besides. Measured against a fixture with codex-cli 0.149.0 on an
/// Apple Silicon Mac, the `initialize` reply arrived at 1.3–1.4 s, the token round trip
/// finished at 2.2–2.6 s, and the process left at 2.6–2.9 s. Eight seconds is about three
/// times that — the same figure CodexBar allows its own `initialize` — and still short enough
/// that a hung CLI cannot hold a five-minute refresh.
pub const RENEWAL_TIMEOUT: Duration = Duration::from_secs(8);

/// Renews an expired Codex sign-in through the CLI that owns it, at most once an hour.
///
/// Returns the attempt to persist, and `None` when no attempt was made — a token with days
/// left, no OAuth grant on this Mac, no Codex CLI on this Mac, a cancelled refresh, or an
/// attempt already made this hour.
pub fn renew_expired_sign_in(
    context: &mut CollectionContext,
    environment: &ProbeEnvironment,
    attempted: Option<&RenewalAttempt>,
    now: i64,
) -> Option<RenewalAttempt> {
    // What the file said before the CLI ran, so a renewal is still recognised when the token
    // it wrote carries no readable expiry of its own.
    let stamped = super::last_refresh(context);
    let usable = |context: &CollectionContext| {
        super::sign_in_usable(context) || super::rewritten_since(context, stamped)
    };
    let request = initialize_request(context);
    let drive = |exchange: &mut BoundedExchange| {
        if exchange.send(&request) {
            let _ = json_rpc_reply(exchange, INITIALIZE_ID);
        }
    };
    let plan = RenewalPlan {
        binary: CODEX_BINARY,
        args: &APP_SERVER,
        inherited: &CODEX_HOME,
        fixed: &[],
        expiring: &super::sign_in_expiring,
        // Not the negation: an `auth.json` the CLI removed, or emptied of its tokens, is
        // neither, and that third answer is a Codex that signed itself out.
        usable: &usable,
        rewrites_keychain: false,
        drive: &drive,
    };
    renew_sign_in(&plan, context, environment, attempted, now)
}

/// The handshake, naming this build rather than pretending to be an editor.
///
/// The name travels: the app-server puts it in the `User-Agent` of the requests it makes on
/// its own account, so saying "Quota" there is the honest answer to a server asking who woke
/// the CLI up.
fn initialize_request(context: &CollectionContext) -> String {
    json!({
        "jsonrpc": "2.0",
        "id": INITIALIZE_ID,
        "method": "initialize",
        "params": {
            "clientInfo": { "name": context.client_name, "version": context.client_version }
        }
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::common::{RENEWAL_FLOOR_SECONDS, RenewalOutcome};
    use base64::Engine as _;
    use std::collections::HashMap;
    use std::fs;
    use std::path::{Path, PathBuf};

    fn temp_directory(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "quota-codex-renewal-{name}-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&path).expect("directory");
        path
    }

    /// An access token shaped the way Codex writes one: three dot-separated parts whose middle
    /// is a base64url payload. The signature is never checked here, and this never carries one
    /// that would verify.
    fn access_token(expires_at: i64) -> String {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&serde_json::json!({ "exp": expires_at })).unwrap());
        format!("header.{payload}.signature")
    }

    fn auth_json(access: &str, last_refresh: &str) -> String {
        format!(
            "{{\"auth_mode\": \"chatgpt\", \"tokens\": {{\"access_token\": \"{access}\", \
             \"id_token\": \"header.e30.signature\", \"refresh_token\": \"refresh\", \
             \"account_id\": \"acct-fixture\"}}, \"last_refresh\": \"{last_refresh}\"}}"
        )
    }

    /// Noon on 2026-08-26 plus an offset in hours, which is what the fixtures call now.
    fn hours_from_now(hours: i64) -> i64 {
        1_787_745_600 + hours * 3_600
    }

    /// A stand-in for the Codex CLI: it answers the handshake, then takes a moment over the
    /// token round trip the way the real one does, and only rewrites `auth.json` on its way
    /// out — after stdin has closed. A caller that stopped at the reply would read the stale
    /// file, which is exactly the mistake this rung has to not make.
    fn renewing_script(log: &Path, auth: &Path, rewritten: &str) -> String {
        format!(
            "#!/bin/sh\n\
             echo \"ran $* home=${{CODEX_HOME:-none}} cwd=$(pwd)\" >> {log}\n\
             ls -A . >> {log}\n\
             read -r first || exit 1\n\
             case \"$first\" in *'\"initialize\"'*) ;; *) exit 2 ;; esac\n\
             printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"method\":\"remoteControl/status/changed\"}}'\n\
             printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"platformOs\":\"macos\"}}}}'\n\
             read -r rest\n\
             sleep 0.3\n\
             cat > {auth} <<'AUTHJSON'\n\
             {rewritten}\n\
             AUTHJSON\n",
            log = log.display(),
            auth = auth.display(),
        )
    }

    fn install(directory: &Path, body: &str) {
        let binary = directory.join(CODEX_BINARY);
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

    /// Only the temporary directory is searched, so no test can reach the Codex install on the
    /// host, and `CODEX_HOME` is the temporary one for the same reason: nothing here may read
    /// or rewrite this machine's own `~/.codex/auth.json`.
    fn fixture(name: &str, document: &str) -> (PathBuf, CollectionContext, ProbeEnvironment) {
        let directory = temp_directory(name);
        let codex_home = directory.join("codex-home");
        fs::create_dir_all(&codex_home).expect("codex home");
        fs::write(codex_home.join("auth.json"), document).expect("auth");
        let context = CollectionContext {
            home_directory: directory.clone(),
            environment: HashMap::from([(
                "CODEX_HOME".to_owned(),
                codex_home.to_string_lossy().into_owned(),
            )]),
            now: Some("2026-08-26T12:00:00Z".to_owned()),
            ..CollectionContext::default()
        };
        let environment = ProbeEnvironment {
            directories: vec![directory.clone()],
            home: directory.clone(),
            path: Some(format!("{}:/usr/bin:/bin", directory.display())),
            timeout: RENEWAL_TIMEOUT,
        };
        (directory, context, environment)
    }

    /// The whole rung in one pass: an expired access token buys exactly one `codex app-server`,
    /// started read-only with the `CODEX_HOME` this refresh found the sign-in under, and the
    /// token the usage request will be built from is the one the CLI wrote on its way out.
    #[test]
    fn an_expired_sign_in_is_renewed_once_and_collection_gets_the_new_token() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "renewed",
                &auth_json(&access_token(hours_from_now(-1)), "2026-08-16T12:00:00Z"),
            );
            let log = directory.join("spawns.log");
            let auth = directory.join("codex-home/auth.json");
            install(
                &directory,
                &renewing_script(
                    &log,
                    &auth,
                    &auth_json(&access_token(hours_from_now(240)), "2026-08-26T12:00:00Z"),
                ),
            );

            assert!(super::super::sign_in_expiring(&context));
            // Claude Code's Keychain memo is not this renewal's to drop: `auth.json` is read
            // fresh either way, and forgetting it buys a second `/usr/bin/security` for
            // nothing.
            context.keychain_secret(|| {
                crate::providers::common::KeychainSecret::Found(b"memoized".to_vec())
            });
            let attempt = renew_expired_sign_in(&mut context, &environment, None, 10_000)
                .expect("an expired sign-in earns an attempt");
            assert!(matches!(
                context.keychain_secret(|| panic!("the Keychain read was forgotten")),
                crate::providers::common::KeychainSecret::Found(secret) if secret == b"memoized"
            ));
            assert_eq!(attempt.outcome, RenewalOutcome::Renewed);
            assert_eq!(attempt.attempted_at, 10_000);
            assert_eq!(spawns(&log), 1);

            let recorded = fs::read_to_string(&log).expect("log");
            assert!(
                recorded.contains("ran -s read-only -a never app-server"),
                "{recorded}"
            );
            assert!(
                recorded.contains(&format!("home={}", directory.join("codex-home").display())),
                "{recorded}"
            );
            // Started in an empty directory of this build's own, so no project's `AGENTS.md`
            // or config is in reach: `ls -A` printed nothing after the one `ran` line.
            assert_eq!(recorded.lines().count(), 1, "{recorded}");

            // The collector reads `auth.json` afterwards, so this is the token the usage
            // request goes out with.
            assert!(super::super::sign_in_usable(&context));
            assert!(!super::super::sign_in_expiring(&context));

            // A successful renewal resets no clock of its own: the next attempt is gated by
            // the token's own expiry, which is now days away.
            assert!(
                renew_expired_sign_in(&mut context, &environment, Some(&attempt), 10_001).is_none()
            );
            assert_eq!(spawns(&log), 1);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// A token with days left is not a sign-in problem, and a refresh that spawned anyway would
    /// be the five-minute timer this rung is bounded to stay off.
    ///
    /// A `last_refresh` a month old is not one either, whatever it looks like: codex-cli
    /// 0.149.0 renews on the access token's own expiry and ignores that stamp entirely, so a
    /// spawn bought with it would be a spawn the CLI declines to act on.
    #[test]
    fn a_live_token_starts_nothing_however_stale_the_stamp() {
        #[cfg(unix)]
        {
            for (name, document) in [
                (
                    "live",
                    auth_json(&access_token(hours_from_now(240)), "2026-08-26T11:00:00Z"),
                ),
                (
                    "stale-stamp",
                    auth_json(&access_token(hours_from_now(48)), "2026-07-27T12:00:00Z"),
                ),
                // Nothing renews a personal access token, and an `auth.json` holding only one
                // has no OAuth grant to renew.
                (
                    "pat-only",
                    "{\"personal_access_token\": \"pat-token\"}".to_owned(),
                ),
                ("no-tokens", "{\"auth_mode\": \"chatgpt\"}".to_owned()),
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

    /// A token this build cannot date is one it cannot spend with any confidence, so it is
    /// treated as expiring and the CLI is asked — it is the thing that can tell.
    #[test]
    fn an_undatable_token_is_treated_as_expiring() {
        #[cfg(unix)]
        {
            for (name, token) in [
                ("opaque", "not-a-jwt"),
                ("no-exp", "header.e30.signature"),
                ("unreadable-payload", "header.!!!!.signature"),
            ] {
                let (directory, mut context, environment) =
                    fixture(name, &auth_json(token, "2026-08-26T11:00:00Z"));
                let log = directory.join("spawns.log");
                let auth = directory.join("codex-home/auth.json");
                assert!(super::super::sign_in_expiring(&context), "{name}");
                assert!(!super::super::sign_in_usable(&context), "{name}");
                install(
                    &directory,
                    // Rewrites the file with the same undatable token and a later stamp, which
                    // is the only signal left that the renewal landed.
                    &renewing_script(&log, &auth, &auth_json(token, "2026-08-26T11:59:00Z")),
                );
                let attempt = renew_expired_sign_in(&mut context, &environment, None, 10_000)
                    .expect("attempt");
                assert_eq!(attempt.outcome, RenewalOutcome::Renewed, "{name}");
                assert_eq!(spawns(&log), 1, "{name}");
                let _ = fs::remove_dir_all(&directory);
            }
        }
    }

    /// A Codex that cannot renew must not be started every five minutes for the rest of the
    /// day, and the hour it costs is the same hour whatever the failure was.
    #[test]
    fn a_cli_that_cannot_renew_is_asked_once_an_hour() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "floor",
                &auth_json(&access_token(hours_from_now(-1)), "2026-08-26T11:00:00Z"),
            );
            let log = directory.join("spawns.log");
            // Answers the handshake and leaves `auth.json` exactly as it was, which is what
            // codex-cli does when the refresh token it holds is rejected.
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

    /// A CLI that never answers holds the refresh for its deadline and no longer, a CLI that
    /// dies is a failed attempt rather than a stuck one, and either way collection reports the
    /// sign-in it actually has.
    #[test]
    fn a_cli_that_hangs_or_fails_is_bounded_and_leaves_the_sign_in_needing_one() {
        #[cfg(unix)]
        {
            let (directory, mut context, mut environment) = fixture(
                "hangs",
                &auth_json(&access_token(hours_from_now(-1)), "2026-08-26T11:00:00Z"),
            );
            // Well under the eight seconds a renewal allows, and well over the time macOS
            // spends checking a freshly written executable the first time — which on a loaded
            // machine running the rest of this suite is over a second.
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

            install(
                &directory,
                &format!("#!/bin/sh\necho \"ran $*\" >> {}\nexit 3\n", log.display()),
            );
            let attempt =
                renew_expired_sign_in(&mut context, &environment, None, 20_000).expect("attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::Failed);
            assert_eq!(spawns(&log), 2);

            // The sign-in is what it was, so collection sends the reader to renew it rather
            // than spending a token that is already out of time.
            assert!(super::super::sign_in_expiring(&context));
            let session = super::super::discover(&context)
                .into_iter()
                .next()
                .expect("a session was discovered");
            let error = super::super::collect(&session, &context).expect_err("expired");
            assert_eq!(
                error.category,
                crate::providers::common::ErrorCategory::AuthRequired
            );
            assert_eq!(error.source_id, super::super::SOURCE_API);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// An `auth.json` the CLI emptied is a Codex that signed itself out, which no number of
    /// further attempts would restore — a different thing to record than a renewal that failed.
    #[test]
    fn a_cli_that_empties_the_credential_reports_a_signed_out_codex() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "signed-out",
                &auth_json(&access_token(hours_from_now(-1)), "2026-08-26T11:00:00Z"),
            );
            let log = directory.join("spawns.log");
            let auth = directory.join("codex-home/auth.json");
            install(&directory, &renewing_script(&log, &auth, "{}"));

            let attempt =
                renew_expired_sign_in(&mut context, &environment, None, 10_000).expect("attempt");
            assert_eq!(attempt.outcome, RenewalOutcome::SignedOut);
            assert_eq!(spawns(&log), 1);
            assert!(super::super::discover(&context).is_empty());

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// Without the CLI there is nothing to ask and nothing to rate-limit, so the next refresh
    /// after an install is free to try immediately.
    #[test]
    fn a_mac_without_the_codex_cli_starts_nothing_and_records_nothing() {
        #[cfg(unix)]
        {
            let (directory, mut context, environment) = fixture(
                "absent",
                &auth_json(&access_token(hours_from_now(-1)), "2026-08-26T11:00:00Z"),
            );
            assert!(renew_expired_sign_in(&mut context, &environment, None, 10_000).is_none());
            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// The handshake names this build, because the app-server puts that name in the
    /// `User-Agent` of the requests it then makes on its own account.
    #[test]
    fn the_handshake_names_this_build_and_asks_for_nothing_else() {
        let context = CollectionContext {
            client_name: "Quota".to_owned(),
            client_version: "1.2.3".to_owned(),
            ..CollectionContext::default()
        };
        let request = initialize_request(&context);
        assert!(request.contains("\"method\":\"initialize\""), "{request}");
        assert!(request.contains("\"name\":\"Quota\""), "{request}");
        assert!(request.contains("\"version\":\"1.2.3\""), "{request}");
        assert!(!request.contains("login"), "{request}");
        // Read-only, never asking: the flags are the argument list, not a config file.
        assert_eq!(APP_SERVER, ["-s", "read-only", "-a", "never", "app-server"]);
    }
}
