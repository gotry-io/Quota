//! The installed provider CLI's version, for the two request headers that identify as one.
//!
//! Claude's usage endpoint and Codex's WHAM endpoint answer the official CLI, so this build
//! sends that CLI's `User-Agent`. Hard-coding a version means every install claims the same
//! one; reading it from the binary that is actually installed here makes the header true.
//!
//! Reading it costs a process, and a scheduled refresh must not start one. So the version is
//! a property of the *binary*, not of the refresh: the real path, size, and mtime fingerprint
//! it, and `<binary> --version` runs only when that fingerprint is absent or has changed.
//! An unchanged binary is answered from `cache.sqlite` with nothing but a `stat`.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, atomic::AtomicBool};
use std::time::Duration;

use super::io::run_bounded_command;

/// How long a provider CLI this build starts may run by default, and how much a `--version`
/// read may print. Every spawn shares one deadline, and this is it unless the caller states a
/// longer one: the Claude renewal does, because it waits on a network round trip.
pub const CLI_TIMEOUT: Duration = Duration::from_secs(5);
pub const VERSION_OUTPUT_LIMIT: usize = 4_096;

/// The floor between two runs for the same CLI, however often its fingerprint changes.
/// A binary that rewrites itself must not be able to turn a refresh into a spawn.
pub const REPROBE_FLOOR_SECONDS: i64 = 3_600;

/// The longest version string this build will put in a header.
const VERSION_LIMIT: usize = 64;

/// The user locations a CLI installs into that a service `PATH` frequently omits. Kept short
/// and explicit: nvm's shims live under a version directory and finding them means globbing,
/// which is not worth a spawn's worth of `stat` calls on every refresh.
const USER_BIN_DIRECTORIES: &[&str] = &[
    ".local/bin",
    ".npm-global/bin",
    ".volta/bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
];

/// A CLI whose installed version this build reads.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum CliTool {
    Claude,
    Codex,
}

impl CliTool {
    /// The program name, which is also the key its record is stored under.
    pub const fn binary(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

/// What one `--version` run found, and about which binary.
///
/// A run that produced no version is recorded like one that did: it is a fact about this
/// binary, and repeating it every five minutes would be the spawn this module exists to avoid.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProbeRecord {
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    pub probed_at: i64,
}

/// Every CLI's last run, keyed by [`CliTool::binary`]. Rebuildable: a cache reset re-probes once.
pub type ProbeCache = BTreeMap<String, ProbeRecord>;

/// Where a probe looks and what it runs in: the directories searched for the binary, the
/// minimal environment `<binary> --version` is handed, and how long it may take.
#[derive(Clone, Debug)]
pub struct ProbeEnvironment {
    /// Searched in order.  Stated rather than derived, so a test never reaches the host's.
    pub directories: Vec<PathBuf>,
    pub home: PathBuf,
    pub path: Option<String>,
    /// The deadline every spawn under this environment shares.
    pub timeout: Duration,
}

impl ProbeEnvironment {
    /// `PATH` first, then the user locations a service `PATH` frequently omits.
    pub fn new(home: PathBuf, path: Option<String>) -> Self {
        let directories = path
            .as_deref()
            .unwrap_or_default()
            .split(':')
            .filter(|entry| !entry.is_empty())
            .map(PathBuf::from)
            .chain(USER_BIN_DIRECTORIES.iter().map(|entry| {
                let entry = Path::new(entry);
                if entry.is_absolute() {
                    entry.to_path_buf()
                } else {
                    home.join(entry)
                }
            }))
            .collect();
        Self {
            directories,
            home,
            path,
            timeout: CLI_TIMEOUT,
        }
    }
}

/// The versions to present this refresh, and the records to store back.
#[derive(Clone, Debug, Default)]
pub struct CliVersionResolution {
    pub versions: BTreeMap<CliTool, String>,
    pub cache: ProbeCache,
    pub changed: bool,
}

/// The installed version of each named CLI, spawning `--version` only where a `stat` says
/// this build has not read this exact binary before.
pub fn resolve(
    tools: &[CliTool],
    cached: &ProbeCache,
    environment: &ProbeEnvironment,
    now: i64,
    cancel: Option<&Arc<AtomicBool>>,
) -> CliVersionResolution {
    let mut resolution = CliVersionResolution {
        cache: cached.clone(),
        ..CliVersionResolution::default()
    };
    for tool in tools.iter().copied() {
        let stored = cached.get(tool.binary());
        // A binary that cannot be resolved right now says nothing about the one that was
        // read before, so its record stays: a `PATH` that momentarily lost the install must
        // not buy a fresh spawn when it comes back unchanged.
        let Some(binary) = resolve_binary(tool.binary(), environment) else {
            continue;
        };
        let Some(fingerprint) = fingerprint(&binary) else {
            continue;
        };
        if let Some(record) = stored
            && (record.fingerprint == fingerprint
                || (record.probed_at <= now && now - record.probed_at < REPROBE_FLOOR_SECONDS))
        {
            if let Some(version) = record.version.clone() {
                resolution.versions.insert(tool, version);
            }
            continue;
        }
        if cancel.is_some_and(|cancel| cancel.load(std::sync::atomic::Ordering::Acquire)) {
            continue;
        }
        let version = probe(&binary, environment, cancel);
        if let Some(version) = version.clone() {
            resolution.versions.insert(tool, version);
        }
        resolution.cache.insert(
            tool.binary().to_owned(),
            ProbeRecord {
                fingerprint,
                version,
                probed_at: now,
            },
        );
        resolution.changed = true;
    }
    resolution
}

/// Runs `<binary> --version` once.
///
/// One of the two functions in `src/providers` allowed to start a program a variable names,
/// and [`resolve`] is its only caller: it runs at most once per installed binary, never once
/// per refresh. The child gets no stdin, no stderr, a bounded stdout, a deadline, and an
/// `env -i`-style environment holding only `HOME` and `PATH`.
pub fn probe(
    binary: &Path,
    environment: &ProbeEnvironment,
    cancel: Option<&Arc<AtomicBool>>,
) -> Option<String> {
    let mut command = Command::new(binary);
    command.arg("--version").env_clear();
    command.env("HOME", &environment.home);
    if let Some(path) = environment.path.as_deref() {
        command.env("PATH", path);
    }
    // A CLI reads the directory it is started in. `--version` has no business seeing a
    // project, and the refresh worker's own directory is not one this build chose.
    if environment.home.is_dir() {
        command.current_dir(&environment.home);
    }
    let output = run_bounded_command(command, environment.timeout, cancel, VERSION_OUTPUT_LIMIT)?;
    parse_version(&String::from_utf8_lossy(&output))
}

/// The real file behind `<name>` in the first of [`ProbeEnvironment::directories`] that holds
/// one. Symlinks are followed, because the shim is not what changes when the install is
/// upgraded.
///
/// Every provider CLI this build starts is found this way, so there is one answer to "which
/// `grok` is that" and one list of places a service `PATH` is allowed to be missing.
pub fn resolve_binary(name: &str, environment: &ProbeEnvironment) -> Option<PathBuf> {
    environment
        .directories
        .iter()
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable_file(candidate))
        .and_then(|candidate| std::fs::canonicalize(candidate).ok())
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    metadata.is_file() && is_executable(&metadata)
}

#[cfg(unix)]
fn is_executable(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_metadata: &std::fs::Metadata) -> bool {
    true
}

/// Real path, size, and mtime. Enough to tell one installed build from the next without
/// reading the binary, which is the whole point: this runs on every refresh.
pub fn fingerprint(path: &Path) -> Option<String> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?;
    let stamp = match modified.duration_since(std::time::UNIX_EPOCH) {
        Ok(since) => since.as_nanos() as i128,
        Err(before) => -(before.duration().as_nanos() as i128),
    };
    Some(format!(
        "{}\u{1f}{}\u{1f}{stamp}",
        path.display(),
        metadata.len()
    ))
}

/// The first semver-looking token in the output, so `2.1.0 (Claude Code)`, a bare `2.1.0`,
/// and `codex-cli 0.42.1` all answer. Anything else is no version rather than a guess: this
/// string goes out in a header, and a guess would be a header field this build invented.
pub fn parse_version(output: &str) -> Option<String> {
    output.split_whitespace().find_map(semver_token)
}

fn semver_token(token: &str) -> Option<String> {
    let token = token.trim_matches(|value: char| {
        matches!(
            value,
            '(' | ')' | '[' | ']' | '{' | '}' | ',' | ';' | ':' | '"' | '\''
        )
    });
    let token = token.strip_prefix('v').unwrap_or(token);
    if token.is_empty() || token.len() > VERSION_LIMIT {
        return None;
    }
    if !token
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+'))
    {
        return None;
    }
    let core = token.split(['-', '+']).next()?;
    let mut parts = core.split('.');
    let numbers = [parts.next()?, parts.next()?, parts.next()?];
    if parts.next().is_some() {
        return None;
    }
    numbers
        .iter()
        .all(|part| {
            !part.is_empty() && part.len() <= 9 && part.bytes().all(|byte| byte.is_ascii_digit())
        })
        .then(|| token.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_directory(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("quota-cli-version-{name}-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&path).expect("directory");
        path
    }

    /// A fake CLI that records each invocation, so a test can count the spawns a refresh made.
    fn install_fake(directory: &Path, name: &str, body: &str) -> PathBuf {
        let binary = directory.join(name);
        fs::write(&binary, body).expect("binary");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).expect("mode");
        }
        binary
    }

    fn recording_script(log: &Path, output: &str) -> String {
        format!(
            "#!/bin/sh\necho ran >> {}\nprintf '%s\\n' '{output}'\n",
            log.display()
        )
    }

    fn spawn_count(log: &Path) -> usize {
        fs::read_to_string(log)
            .map(|text| text.lines().count())
            .unwrap_or(0)
    }

    /// Only the temporary directory is searched, so no test can reach an install on the host.
    fn environment(directory: &Path) -> ProbeEnvironment {
        ProbeEnvironment {
            directories: vec![directory.to_path_buf()],
            home: directory.to_path_buf(),
            path: Some(directory.to_string_lossy().into_owned()),
            timeout: Duration::from_secs(5),
        }
    }

    #[test]
    fn reads_the_version_forms_the_two_clis_print() {
        assert_eq!(
            parse_version("2.1.0 (Claude Code)").as_deref(),
            Some("2.1.0")
        );
        assert_eq!(parse_version("2.1.0\n").as_deref(), Some("2.1.0"));
        assert_eq!(
            parse_version("codex-cli 0.42.1\n").as_deref(),
            Some("0.42.1")
        );
        assert_eq!(parse_version("v1.2.3").as_deref(), Some("1.2.3"));
        assert_eq!(
            parse_version("1.2.3-beta.1 (build)").as_deref(),
            Some("1.2.3-beta.1")
        );
        // Nothing that is not a version becomes one, because this goes out in a header.
        for output in [
            "",
            "claude",
            "2.1",
            "1.2.3.4",
            "not a version",
            "usage: claude [options]",
            "12345678901.0.0",
        ] {
            assert_eq!(parse_version(output), None, "{output:?}");
        }
        assert_eq!(parse_version(&format!("{}.0.0", "9".repeat(10))), None);
        // A token this build would have to escape is not a version it will send.
        assert_eq!(parse_version("2.1.0\u{7}bell"), None);
        assert_eq!(parse_version("2.1.0/../x"), None);
    }

    #[test]
    fn an_unchanged_binary_is_never_probed_twice() {
        #[cfg(unix)]
        {
            let directory = temp_directory("unchanged");
            let log = directory.join("spawns.log");
            install_fake(
                &directory,
                "claude",
                &recording_script(&log, "2.1.0 (Claude Code)"),
            );
            let environment = environment(&directory);

            let first = resolve(
                &[CliTool::Claude],
                &ProbeCache::new(),
                &environment,
                1_000,
                None,
            );
            assert_eq!(
                first.versions.get(&CliTool::Claude).map(String::as_str),
                Some("2.1.0")
            );
            assert!(first.changed);
            assert_eq!(spawn_count(&log), 1);

            // A second refresh a minute later stats the binary and stops there.
            let second = resolve(&[CliTool::Claude], &first.cache, &environment, 1_060, None);
            assert_eq!(
                second.versions.get(&CliTool::Claude).map(String::as_str),
                Some("2.1.0")
            );
            assert!(!second.changed);
            assert_eq!(spawn_count(&log), 1);

            // An upgraded binary is a different binary, and is read once.
            install_fake(
                &directory,
                "claude",
                &recording_script(&log, "2.2.0 (Claude Code)  padded to a new size"),
            );
            let third = resolve(
                &[CliTool::Claude],
                &second.cache,
                &environment,
                1_000 + 3_600,
                None,
            );
            assert_eq!(
                third.versions.get(&CliTool::Claude).map(String::as_str),
                Some("2.2.0")
            );
            assert!(third.changed);
            assert_eq!(spawn_count(&log), 2);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// A binary that rewrites itself would otherwise turn every refresh into a spawn.
    #[test]
    fn a_binary_that_keeps_changing_is_read_once_an_hour() {
        #[cfg(unix)]
        {
            let directory = temp_directory("churn");
            let log = directory.join("spawns.log");
            install_fake(&directory, "claude", &recording_script(&log, "2.1.0"));
            let environment = environment(&directory);
            let first = resolve(
                &[CliTool::Claude],
                &ProbeCache::new(),
                &environment,
                1_000,
                None,
            );
            assert_eq!(spawn_count(&log), 1);

            install_fake(
                &directory,
                "claude",
                &recording_script(&log, "2.1.0 rewritten"),
            );
            let within = resolve(
                &[CliTool::Claude],
                &first.cache,
                &environment,
                1_000 + 3_599,
                None,
            );
            assert_eq!(spawn_count(&log), 1);
            // The version already known is still the one presented.
            assert_eq!(
                within.versions.get(&CliTool::Claude).map(String::as_str),
                Some("2.1.0")
            );
            assert!(!within.changed);

            let after = resolve(
                &[CliTool::Claude],
                &within.cache,
                &environment,
                1_000 + 3_600,
                None,
            );
            assert_eq!(spawn_count(&log), 2);
            assert!(after.changed);

            let _ = fs::remove_dir_all(&directory);
        }
    }

    /// The probe is best-effort: a CLI that hangs, fails, or prints nothing usable leaves the
    /// caller with no version, and the caller falls back to its constant.
    #[test]
    fn a_probe_that_hangs_or_fails_yields_no_version() {
        #[cfg(unix)]
        {
            let directory = temp_directory("hangs");
            let binary = install_fake(&directory, "claude", "#!/bin/sh\nsleep 30\n");
            let mut environment = environment(&directory);
            environment.timeout = Duration::from_millis(150);
            let started = std::time::Instant::now();
            assert_eq!(probe(&binary, &environment, None), None);
            assert!(started.elapsed() < Duration::from_secs(5));

            install_fake(&directory, "claude", "#!/bin/sh\necho 2.1.0\nexit 3\n");
            assert_eq!(probe(&binary, &environment, None), None);

            install_fake(&directory, "claude", "#!/bin/sh\necho no version here\n");
            assert_eq!(probe(&binary, &environment, None), None);

            // A failed read is remembered, so a broken install cannot cost a spawn per refresh.
            let resolution = resolve(
                &[CliTool::Claude],
                &ProbeCache::new(),
                &environment,
                1_000,
                None,
            );
            assert!(resolution.versions.is_empty());
            assert_eq!(
                resolution
                    .cache
                    .get("claude")
                    .map(|record| record.version.clone()),
                Some(None)
            );

            let _ = fs::remove_dir_all(&directory);
        }
    }

    #[test]
    fn a_cli_this_device_does_not_have_is_not_probed_and_keeps_what_was_read() {
        #[cfg(unix)]
        {
            let directory = temp_directory("absent");
            let environment = environment(&directory);
            let stored = ProbeCache::from([(
                "codex".to_owned(),
                ProbeRecord {
                    fingerprint: "gone".to_owned(),
                    version: Some("0.42.1".to_owned()),
                    probed_at: 10,
                },
            )]);
            let resolution = resolve(&[CliTool::Codex], &stored, &environment, 100_000, None);
            assert!(resolution.versions.is_empty());
            assert!(!resolution.changed);
            assert_eq!(resolution.cache, stored);
            let _ = fs::remove_dir_all(&directory);
        }
    }

    #[test]
    fn a_cancelled_refresh_starts_nothing() {
        #[cfg(unix)]
        {
            let directory = temp_directory("cancelled");
            let log = directory.join("spawns.log");
            install_fake(&directory, "claude", &recording_script(&log, "2.1.0"));
            let cancel = Arc::new(AtomicBool::new(true));
            let resolution = resolve(
                &[CliTool::Claude],
                &ProbeCache::new(),
                &environment(&directory),
                1_000,
                Some(&cancel),
            );
            assert!(resolution.versions.is_empty());
            assert!(!resolution.changed);
            assert_eq!(spawn_count(&log), 0);
            let _ = fs::remove_dir_all(&directory);
        }
    }
}
