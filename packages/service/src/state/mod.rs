//! The sole local persistence owner.
//!
//! Two SQLite files sit side by side in one owner-only directory. `identity.sqlite` holds what
//! this device cannot regenerate: who it is, who it is signed in as, what it still owes an
//! Account, and the preferences a person set. `cache.sqlite` holds everything derived from
//! somewhere else. A cache this service cannot read is deleted and rebuilt from the next refresh;
//! an identity it cannot read means this device starts over as a new installation. Neither file
//! is ever salvaged, and nothing is ever copied out of a damaged one.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::{self, File, OpenOptions, Permissions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Duration, SecondsFormat, Timelike};
use rusqlite::{
    Connection, ErrorCode as SqliteErrorCode, OpenFlags, OptionalExtension, Transaction, params,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

use crate::protocol::{
    BrowserAccessDenialReason, CacheState, ComponentName, ComponentState, ComponentStatus,
    DiagnosticAttempt, DiagnosticAttemptCode, DiagnosticAttemptKind, DiagnosticAttemptOutcome,
    DiagnosticAttemptTrigger, DiagnosticReport, ErrorCode, IPC_VERSION, IpcError,
    MAXIMUM_DIAGNOSTIC_RECENT, ProviderBrowserSessionView, ProviderConfigView, QuotaOverviewItem,
    RecoveryAction, StateSnapshot, UsagePeriod, UsagePeriodCache, UsageSource,
};
use crate::usage::{
    DatedUsageRow, NormalizedUsageEvent, UsageAgent, UsageFileIndex, UsageRow, UsageScanResult,
};

mod legacy_import;

use legacy_import::LegacyImport;

const PROVIDER_CONFIG_NAME: &str = "providers.json";
const IDENTITY_NAME: &str = "identity.sqlite";
const CACHE_NAME: &str = "cache.sqlite";
const CACHE_RESET_KEY: &str = "cache_reset_at";
const IDENTITY_RESET_KEY: &str = "identity_reset_at";
const REBUILDING_KEY: &str = "rebuilding";
/// The browsers this Mac was refused, by provider.
const BROWSER_ACCESS_DENIED_KEY: &str = "browser_access_denied";
/// The monotonic revision each rescanned hour is stamped with.
const USAGE_SCAN_VERSION_KEY: &str = "usage_scan_version";
/// The last `--version` this device read out of each installed provider CLI.
const CLI_VERSION_KEY: &str = "provider_cli_versions";
/// The last time this device asked each provider's own CLI to renew the sign-in it owns.
const RENEWAL_ATTEMPT_KEY: &str = "provider_refresh_attempts";
const PROVEN_CREDENTIAL_KEY: &str = "provider_proven_credentials";
const MAX_DIAGNOSTIC_ATTEMPTS: i64 = 5_000;
const DIAGNOSTIC_ATTEMPT_RETENTION_DAYS: i64 = 7;
const ATTEMPT_PRUNE_INTERVAL_SECONDS: u64 = 3_600;
/// The write-ahead log is truncated back to this after each checkpoint. Without a limit the file
/// keeps whatever high-water mark one large transaction reached, for the life of the image: a
/// rescan of this device's Usage had left 213MB of empty log on disk.
const MAXIMUM_WAL_BYTES: i64 = 16 * 1024 * 1024;
/// Pages freed by deletes are handed back to the filesystem once this much has accumulated.
/// Re-scanning a Usage file deletes and reinserts every record it holds, so an image that is
/// never compacted keeps growing: this device reached 411MB holding 218MB of records.
const COMPACT_FREE_BYTES: i64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiagnosticAttemptHandle(i64);

#[derive(Debug, Clone)]
pub struct DiagnosticAttemptCompletion {
    pub outcome: DiagnosticAttemptOutcome,
    pub code: Option<DiagnosticAttemptCode>,
}

impl DiagnosticAttemptCompletion {
    pub const fn new(
        outcome: DiagnosticAttemptOutcome,
        code: Option<DiagnosticAttemptCode>,
    ) -> Self {
        Self { outcome, code }
    }
}

/// What the journal knows about one kind of work.
#[derive(Debug, Clone, Default)]
pub struct DiagnosticAttemptFacts {
    pub last_attempt_at: Option<String>,
    pub last_outcome: Option<DiagnosticAttemptOutcome>,
    pub last_success_at: Option<String>,
    /// The newest failure, partial run, or interruption that no later success has answered.
    pub unresolved_at: Option<String>,
    pub unresolved_code: Option<DiagnosticAttemptCode>,
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error("local state is invalid")]
    InvalidState,
    #[error("local state is unavailable")]
    Unavailable,
    #[error("local state was written by a newer client")]
    ClientUpgradeRequired,
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderSecret {
    pub api_key: String,
    #[serde(default)]
    pub base_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderBrowserSession {
    pub cookie_header: String,
    pub account_fingerprint: String,
    pub account_label: Option<String>,
}

/// One browser cookie store this Mac was refused, and when.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct BrowserAccessDenial {
    pub browser: String,
    pub reason: BrowserAccessDenialReason,
    pub denied_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderFile {
    schema_version: u32,
    providers: BTreeMap<String, ProviderSecret>,
}

#[derive(Debug, Clone)]
pub struct ComponentRecord {
    pub status: ComponentStatus,
    pub value: Option<Value>,
    pub updated_at: Option<String>,
    pub last_error: Option<IpcError>,
    pub refreshing: bool,
}

impl ComponentRecord {
    pub fn to_wire(&self) -> ComponentState {
        ComponentState {
            status: self.status,
            value: self.value.clone(),
            updated_at: self.updated_at.clone(),
            last_error: self.last_error.clone(),
            refreshing: self.refreshing,
        }
    }
}

/// A process-lifetime service lock.  It intentionally does not use the `state.lock` directory
/// name, which the provider-config writer below still creates for short mutations.
/// `flock` makes ownership kernel-backed and is released by the kernel on crash/SIGKILL.
pub struct OwnerLock {
    file: File,
}

impl OwnerLock {
    pub fn acquire(root: &Path) -> Result<Self, StateError> {
        let path = root.join("service-owner.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        if !file.metadata()?.is_file() {
            return Err(StateError::InvalidState);
        }
        file.set_permissions(Permissions::from_mode(0o600))?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
                return Err(StateError::Unavailable);
            }
            return Err(error.into());
        }
        Ok(Self { file })
    }
}

impl Drop for OwnerLock {
    fn drop(&mut self) {
        let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

/// Short critical-section lock over the owner-only `providers.json`.  The directory/owner shape
/// is retained at this published file boundary; only this tiny config mutation uses stale-owner
/// recovery, while the service lifetime lock above remains flock-backed.
struct ProviderConfigLock {
    path: PathBuf,
}

impl ProviderConfigLock {
    fn acquire(root: &Path) -> Result<Self, StateError> {
        let path = root.join("providers.json.lock");
        let reclaim = root.join("providers.json.lock.reclaim");
        let owner = path.join("owner");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            match fs::create_dir(&path) {
                Ok(()) => {
                    set_owner_permissions(&path)?;
                    let mut file = OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&owner)?;
                    file.set_permissions(Permissions::from_mode(0o600))?;
                    writeln!(file, "{}", std::process::id())?;
                    file.sync_all()?;
                    return Ok(Self { path });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    if provider_lock_is_stale(&path, &owner)? {
                        // Reclamation has a single mkdir winner.  Rename the stale lock to a
                        // unique discarded path before deleting it so a contender can never
                        // remove a replacement owner that won the original mkdir race.
                        if acquire_reclaim_guard(&reclaim, root)? {
                            let discarded = root
                                .join(format!(".providers.json.lock.discarded.{}", Uuid::new_v4()));
                            let result = (|| {
                                if !provider_lock_is_stale(&path, &owner)? {
                                    return Ok(false);
                                }
                                match fs::rename(&path, &discarded) {
                                    Ok(()) => {
                                        let _ = fs::remove_dir_all(&discarded);
                                        Ok(true)
                                    }
                                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                                        Ok(false)
                                    }
                                    Err(error) => Err(StateError::Io(error)),
                                }
                            })();
                            let _ = fs::remove_dir(&reclaim);
                            if result? {
                                continue;
                            }
                        }
                    }
                    if std::time::Instant::now() >= deadline {
                        return Err(StateError::Unavailable);
                    }
                    thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(_) => return Err(StateError::Unavailable),
            }
        }
    }
}

fn acquire_reclaim_guard(path: &Path, root: &Path) -> Result<bool, StateError> {
    match fs::create_dir(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let stale = fs::symlink_metadata(path)
                .ok()
                .and_then(|metadata| metadata.modified().ok())
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age > std::time::Duration::from_secs(1));
            if !stale {
                return Ok(false);
            }
            let discarded = root.join(format!(
                ".providers.json.lock.reclaim.discarded.{}",
                Uuid::new_v4()
            ));
            if fs::rename(path, &discarded).is_ok() {
                let _ = fs::remove_dir_all(discarded);
            }
            Ok(false)
        }
        Err(error) => Err(StateError::Io(error)),
    }
}

impl Drop for ProviderConfigLock {
    fn drop(&mut self) {
        let Some(root) = self.path.parent() else {
            return;
        };
        let discarded = root.join(format!(".providers.json.lock.discarded.{}", Uuid::new_v4()));
        if fs::rename(&self.path, &discarded).is_ok() {
            let _ = fs::remove_dir_all(discarded);
        }
    }
}

fn provider_lock_is_stale(path: &Path, owner: &Path) -> Result<bool, StateError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(StateError::InvalidState);
    }
    let pid = fs::read_to_string(owner)
        .ok()
        .and_then(|value| value.trim().parse::<libc::pid_t>().ok());
    if let Some(pid) = pid.filter(|pid| *pid > 0) {
        let result = unsafe { libc::kill(pid, 0) };
        if result == 0 {
            return Ok(false);
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            return Ok(false);
        }
        return Ok(true);
    }
    Ok(metadata
        .modified()
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age > std::time::Duration::from_secs(1)))
}

pub struct StateStore {
    root: PathBuf,
    identity: Mutex<Connection>,
    cache: Mutex<Connection>,
    // Kept in this object for the entire service lifetime.
    _owner_lock: OwnerLock,
    /// The last change counter this process saw. A rebuilt cache starts above it so QuotaBar,
    /// which ignores an event whose revision is not newer than the state it holds, keeps
    /// following along instead of going quiet until the count catches up.
    remembered_revision: AtomicU64,
    /// Unix seconds of the last attempt-journal prune. Retention runs at open and hourly, never
    /// inside the transaction that records a refresh.
    last_attempt_prune: AtomicU64,
}

impl StateStore {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, StateError> {
        let root = root.as_ref().to_path_buf();
        ensure_owner_only_directory(&root)?;
        // SQLite's NOFOLLOW flag rejects symlinks in ancestor components too (for example macOS
        // `/var` -> `/private/var`).  Resolve ancestors once after rejecting a symlink at the
        // state-root boundary; the database filename itself remains protected by NOFOLLOW.
        let root = fs::canonicalize(root)?;
        let owner_lock = OwnerLock::acquire(&root)?;
        let identity = open_identity(&root)?;
        let (cache, rebuilt) = open_cache(&root, 0)?;
        if rebuilt {
            write_preference(&identity, CACHE_RESET_KEY, &now_rfc3339())?;
            write_metadata_flag(&cache, REBUILDING_KEY, true)?;
        }
        checkpoint(&identity);
        let store = Self {
            root,
            identity: Mutex::new(identity),
            cache: Mutex::new(cache),
            _owner_lock: owner_lock,
            remembered_revision: AtomicU64::new(0),
            last_attempt_prune: AtomicU64::new(unix_seconds()),
        };
        store.recover_interrupted_work()?;
        let _ = store.current_revision();
        Ok(store)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Finishes what a previous run was in the middle of.
    ///
    /// A process that went away mid-refresh leaves two marks behind, and neither can clear
    /// itself: components still flagged as refreshing, and attempts with no outcome. Both are
    /// process-local claims, so the only run that can retire them is the next one.
    fn recover_interrupted_work(&self) -> Result<(), StateError> {
        let completed_at = now_rfc3339();
        self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute(
                "UPDATE components SET refreshing = 0 WHERE refreshing = 1",
                [],
            )?;
            tx.execute(
                "UPDATE diagnostic_attempts SET
                   completed_at = ?1,
                   duration_ms = MIN(86400000, MAX(0,
                     CAST((julianday(?1) - julianday(started_at)) * 86400000 AS INTEGER))),
                   outcome = 'interrupted', code = 'process_interrupted'
                 WHERE outcome IS NULL",
                params![completed_at],
            )?;
            prune_diagnostic_attempts(&tx)?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Throws the cache away at the person's request and rebuilds it empty.
    pub fn reset_cache(&self) {
        self.rebuild_cache();
    }

    /// Deletes the cache and builds an empty one in its place.
    ///
    /// The reset marker is written to identity first so the lock order is always identity then
    /// cache, and so a crash between the two leaves a device that says it rebuilt rather than one
    /// silently missing history.
    fn rebuild_cache(&self) {
        let seed = self
            .remembered_revision
            .load(Ordering::Acquire)
            .saturating_add(1);
        let reset_at = now_rfc3339();
        let _ = self.with_identity_mut(|conn| write_preference(conn, CACHE_RESET_KEY, &reset_at));
        let Ok(mut guard) = self.cache.lock() else {
            return;
        };
        let Ok(placeholder) = Connection::open_in_memory() else {
            return;
        };
        drop(std::mem::replace(&mut *guard, placeholder));
        remove_sqlite_image(&self.root.join(CACHE_NAME));
        if let Ok((conn, _)) = open_cache(&self.root, seed) {
            let _ = write_metadata_flag(&conn, REBUILDING_KEY, true);
            *guard = conn;
        }
    }

    fn with_identity<T>(
        &self,
        f: impl FnOnce(&Connection) -> Result<T, StateError>,
    ) -> Result<T, StateError> {
        let conn = lock_with_deadline(&self.identity)?;
        f(&conn)
    }

    fn with_identity_mut<T>(
        &self,
        f: impl FnOnce(&mut Connection) -> Result<T, StateError>,
    ) -> Result<T, StateError> {
        let mut conn = self.identity.lock().map_err(|_| StateError::Unavailable)?;
        let result = f(&mut conn);
        if result.is_ok() {
            // The file is a few kilobytes and is written rarely, so the log is folded back in
            // immediately.
            checkpoint(&conn);
        }
        result
    }

    fn with_cache<T>(
        &self,
        f: impl FnOnce(&Connection) -> Result<T, StateError>,
    ) -> Result<T, StateError> {
        let result = {
            let conn = lock_with_deadline(&self.cache)?;
            f(&conn)
        };
        self.answer_for_cache(result)
    }

    fn with_cache_mut<T>(
        &self,
        f: impl FnOnce(&mut Connection) -> Result<T, StateError>,
    ) -> Result<T, StateError> {
        let result = {
            let mut conn = self.cache.lock().map_err(|_| StateError::Unavailable)?;
            f(&mut conn)
        };
        self.answer_for_cache(result)
    }

    /// A cache SQLite cannot read is not a cache worth keeping.
    ///
    /// A full disk or an I/O error is the machine, not the file, so the caller is told to retry.
    /// Anything else means the image no longer describes what this device collected, and the only
    /// honest answer is to throw it away rather than guess which rows survived.
    fn answer_for_cache<T>(&self, result: Result<T, StateError>) -> Result<T, StateError> {
        match result {
            Ok(value) => Ok(value),
            Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
            Err(error) if cache_needs_rebuild(&error) => {
                self.rebuild_cache();
                Err(StateError::Unavailable)
            }
            Err(error) => Err(error),
        }
    }

    pub fn snapshot(&self) -> Result<StateSnapshot, StateError> {
        self.snapshot_with_provider_policy(false)
    }

    pub fn snapshot_for_diagnostics(&self) -> Result<StateSnapshot, StateError> {
        self.snapshot_with_provider_policy(true)
    }

    fn snapshot_with_provider_policy(
        &self,
        tolerate_invalid_provider_config: bool,
    ) -> Result<StateSnapshot, StateError> {
        let usage_upload_enabled = self.usage_upload_enabled()?;
        let provider_browser_sessions = self.with_identity(read_provider_browser_session_views)?;
        let cache_reset_at = self.with_identity(|conn| preference(conn, CACHE_RESET_KEY))?;
        self.with_cache(|conn| {
            let revision = metadata_u64(conn, "revision")?;
            self.remembered_revision.store(revision, Ordering::Release);
            let quota = read_component(conn, ComponentName::Quota)?;
            let usage = read_component(conn, ComponentName::Usage)?;
            let account =
                read_component(conn, ComponentName::Account)?.unwrap_or_else(|| ComponentRecord {
                    status: ComponentStatus::SignedOut,
                    value: Some(serde_json::json!({
                        "auth_status": "signed_out",
                        "account_id": null,
                        "display_label": null,
                        "device_id": null,
                        "device_generation": null,
                        "account_summary": null
                    })),
                    updated_at: None,
                    last_error: None,
                    refreshing: false,
                });
            let mut usage_periods = read_usage_periods(conn)?;
            let account_usage_available = usage_upload_enabled
                && account
                    .value
                    .as_ref()
                    .and_then(|value| value.get("auth_status"))
                    .and_then(Value::as_str)
                    == Some("signed_in");
            if !account_usage_available {
                usage_periods.account = Default::default();
            }
            let pricing = read_component(conn, ComponentName::Pricing)?;
            let providers = match read_provider_views(&self.root) {
                Ok(providers) => providers,
                Err(_) if tolerate_invalid_provider_config => Vec::new(),
                Err(error) => return Err(error),
            };
            let overview = read_overview(conn)?;
            Ok(StateSnapshot {
                ipc_version: IPC_VERSION,
                revision,
                usage_upload_enabled,
                usage_periods,
                quota: quota
                    .unwrap_or_else(|| ComponentRecord::empty(ComponentStatus::Unavailable))
                    .to_wire(),
                usage: usage
                    .unwrap_or_else(|| ComponentRecord::empty(ComponentStatus::Unavailable))
                    .to_wire(),
                account: account.to_wire(),
                pricing: pricing
                    .unwrap_or_else(|| ComponentRecord::empty(ComponentStatus::Unavailable))
                    .to_wire(),
                providers,
                provider_browser_sessions,
                overview,
                cache: CacheState {
                    rebuilding: metadata_flag(conn, REBUILDING_KEY)?,
                    reset_at: cache_reset_at.clone(),
                },
            })
        })
    }

    /// When this device last had to start over as a new installation, if that is recent enough
    /// for the person in front of it to still be missing what it lost.
    pub fn identity_reset_at(&self) -> Result<Option<String>, StateError> {
        self.with_identity(|conn| preference(conn, IDENTITY_RESET_KEY))
    }

    pub fn provider_config_status(&self) -> (bool, bool) {
        match fs::symlink_metadata(self.root.join(PROVIDER_CONFIG_NAME)) {
            Ok(_) => (true, read_provider_file(&self.root).is_ok()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (false, true),
            Err(_) => (true, false),
        }
    }

    pub fn component(&self, name: ComponentName) -> Result<Option<ComponentRecord>, StateError> {
        self.with_cache(|conn| read_component(conn, name))
    }

    pub fn replace_usage_periods(
        &self,
        source: UsageSource,
        values: &[(UsagePeriod, Value)],
    ) -> Result<u64, StateError> {
        if values.is_empty()
            || values.len() > 4
            || values
                .iter()
                .map(|(period, _)| period)
                .collect::<HashSet<_>>()
                .len()
                != values.len()
        {
            return Err(StateError::InvalidState);
        }
        self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            let source = usage_source_key(source);
            tx.execute("DELETE FROM usage_period_cache WHERE source = ?1", [source])?;
            for (period, value) in values {
                let raw = serde_json::to_string(value)?;
                if raw.len() > crate::protocol::MAXIMUM_LINE_BYTES {
                    return Err(StateError::InvalidState);
                }
                tx.execute(
                    "INSERT INTO usage_period_cache(source, period, value_json)
                 VALUES (?1, ?2, ?3)",
                    params![source, usage_period_key(*period), raw],
                )?;
            }
            let revision = bump_revision(&tx)?;
            tx.commit()?;
            Ok(revision)
        })
    }

    /// The stored answer to one Account read, if this installation already holds one.
    pub fn account_read_cache(
        &self,
        account_id: &str,
        query: &str,
    ) -> Result<Option<(String, Value)>, StateError> {
        self.with_cache(|conn| {
            let row: Option<(String, String)> = conn
                .query_row(
                    "SELECT etag, body_json FROM account_read_cache
                     WHERE account_id = ?1 AND query = ?2",
                    params![account_id, query],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            row.map(|(etag, raw)| Ok((etag, serde_json::from_str(&raw)?)))
                .transpose()
        })
    }

    /// Records the response and the validator it is current at together.
    ///
    /// One row, one statement: a stored validator that does not describe the stored body would
    /// make the next 304 answer with the wrong summary, which is worse than not caching at all.
    /// A response the server did not tag drops any row we held, so the next read is
    /// unconditional rather than validated against something stale.
    pub fn commit_account_read(
        &self,
        account_id: &str,
        query: &str,
        etag: Option<&str>,
        body: &Value,
    ) -> Result<(), StateError> {
        if account_id.is_empty() || account_id.len() > 128 || query.len() > 512 {
            return Err(StateError::InvalidState);
        }
        let Some(etag) = etag else {
            return self.forget_account_read(account_id, query);
        };
        if etag.len() > 256 || etag.trim() != etag {
            return Err(StateError::InvalidState);
        }
        let raw = serde_json::to_string(body)?;
        if raw.len() > crate::protocol::MAXIMUM_LINE_BYTES {
            return Err(StateError::InvalidState);
        }
        self.with_cache_mut(|conn| {
            conn.execute(
                "INSERT INTO account_read_cache(account_id, query, etag, body_json, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(account_id, query) DO UPDATE SET etag = excluded.etag,
                 body_json = excluded.body_json, updated_at = excluded.updated_at",
                params![account_id, query, etag, raw, now_rfc3339()],
            )?;
            Ok(())
        })
    }

    fn forget_account_read(&self, account_id: &str, query: &str) -> Result<(), StateError> {
        self.with_cache_mut(|conn| {
            conn.execute(
                "DELETE FROM account_read_cache WHERE account_id = ?1 AND query = ?2",
                params![account_id, query],
            )?;
            Ok(())
        })
    }

    pub fn write_usage_scan_diagnostics(
        &self,
        agent: UsageAgent,
        value: &Value,
    ) -> Result<(), StateError> {
        let raw = serde_json::to_string(value)?;
        if raw.len() > 64 * 1024 {
            return Err(StateError::InvalidState);
        }
        self.with_cache_mut(|conn| {
            conn.execute(
                "INSERT INTO usage_scan_diagnostics(agent, payload_json, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(agent) DO UPDATE SET payload_json = excluded.payload_json,
             updated_at = excluded.updated_at",
                params![agent.as_str(), raw, now_rfc3339()],
            )?;
            Ok(())
        })
    }

    pub fn usage_scan_diagnostics(&self) -> Result<Vec<(UsageAgent, Value, String)>, StateError> {
        self.with_cache(|conn| {
            let mut statement = conn.prepare(
                "SELECT agent, payload_json, updated_at FROM usage_scan_diagnostics ORDER BY agent",
            )?;
            let rows = statement.query_map([], |row| {
                let agent: String = row.get(0)?;
                let agent = parse_usage_agent(&agent).ok_or_else(|| {
                    rusqlite::Error::InvalidColumnType(
                        0,
                        "agent".to_owned(),
                        rusqlite::types::Type::Text,
                    )
                })?;
                let value: String = row.get(1)?;
                let value = serde_json::from_str(&value).map_err(|_| {
                    rusqlite::Error::InvalidColumnType(
                        1,
                        "payload_json".to_owned(),
                        rusqlite::types::Type::Text,
                    )
                })?;
                Ok((agent, value, row.get(2)?))
            })?;
            let mut diagnostics = Vec::new();
            for row in rows {
                diagnostics.push(row?);
            }
            Ok(diagnostics)
        })
    }

    pub fn write_diagnostic_snapshot(&self, report: &DiagnosticReport) -> Result<(), StateError> {
        let raw = serde_json::to_string(report)?;
        if raw.len() > crate::protocol::MAXIMUM_LINE_BYTES {
            return Err(StateError::InvalidState);
        }
        self.with_cache_mut(|conn| {
            conn.execute(
                "INSERT INTO diagnostic_snapshot(id, payload_json, completed_at)
             VALUES (1, ?1, ?2)
             ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json,
             completed_at = excluded.completed_at",
                params![raw, report.generated_at],
            )?;
            Ok(())
        })
    }

    pub fn diagnostic_snapshot(&self) -> Result<Option<DiagnosticReport>, StateError> {
        self.with_cache(|conn| {
            let raw: Option<String> = conn
                .query_row(
                    "SELECT payload_json FROM diagnostic_snapshot WHERE id = 1",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            raw.map(|value| serde_json::from_str(&value).map_err(StateError::from))
                .transpose()
        })
    }

    /// Records that a piece of work started, or says it could not.
    ///
    /// The journal is evidence, not a permit. A cache that cannot take the row still has to let
    /// the collection, scan, upload, or sync run, so the caller gets `None` and carries on
    /// without a handle to finish.
    pub fn begin_diagnostic_attempt(
        &self,
        kind: DiagnosticAttemptKind,
        trigger: DiagnosticAttemptTrigger,
        subject: Option<&str>,
        parent_refresh: Option<DiagnosticAttemptHandle>,
    ) -> Option<DiagnosticAttemptHandle> {
        if subject.is_some_and(|value| !valid_diagnostic_subject(value)) {
            return None;
        }
        let prune = self.attempt_prune_is_due();
        let written = self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            if prune {
                prune_diagnostic_attempts(&tx)?;
            }
            tx.execute(
                "INSERT INTO diagnostic_attempts(
               parent_refresh_id, kind, trigger, subject, started_at
             ) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    parent_refresh.map(|value| value.0),
                    diagnostic_attempt_kind_key(kind),
                    diagnostic_attempt_trigger_key(trigger),
                    subject,
                    now_rfc3339(),
                ],
            )?;
            let handle = DiagnosticAttemptHandle(tx.last_insert_rowid());
            tx.commit()?;
            Ok(handle)
        });
        match written {
            Ok(handle) => Some(handle),
            Err(error) => {
                report_journal_write_failure(&error);
                None
            }
        }
    }

    /// True at most once an hour. Retention is housekeeping; it does not belong in the path a
    /// refresh takes to record that it started.
    fn attempt_prune_is_due(&self) -> bool {
        let now = unix_seconds();
        let last = self.last_attempt_prune.load(Ordering::Acquire);
        now.saturating_sub(last) >= ATTEMPT_PRUNE_INTERVAL_SECONDS
            && self
                .last_attempt_prune
                .compare_exchange(last, now, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
    }

    pub fn running_refresh_attempt(
        &self,
    ) -> Result<Option<(DiagnosticAttemptHandle, DiagnosticAttemptTrigger)>, StateError> {
        self.with_cache(|conn| {
            conn.query_row(
                "SELECT id, trigger FROM diagnostic_attempts
             WHERE kind = 'refresh' AND outcome IS NULL ORDER BY id DESC LIMIT 1",
                [],
                |row| {
                    let handle = DiagnosticAttemptHandle(row.get(0)?);
                    let trigger = parse_diagnostic_attempt_trigger(&row.get::<_, String>(1)?)?;
                    Ok((handle, trigger))
                },
            )
            .optional()
            .map_err(StateError::from)
        })
    }

    pub fn finish_diagnostic_attempt(
        &self,
        handle: Option<DiagnosticAttemptHandle>,
        completion: &DiagnosticAttemptCompletion,
    ) {
        self.finish_diagnostic_attempt_internal(handle, completion, false);
    }

    pub fn finish_diagnostic_attempt_with_interrupted_children(
        &self,
        handle: Option<DiagnosticAttemptHandle>,
        completion: &DiagnosticAttemptCompletion,
    ) {
        self.finish_diagnostic_attempt_internal(handle, completion, true);
    }

    fn finish_diagnostic_attempt_internal(
        &self,
        handle: Option<DiagnosticAttemptHandle>,
        completion: &DiagnosticAttemptCompletion,
        interrupt_running_children: bool,
    ) {
        let Some(handle) = handle else { return };
        if completion.outcome == DiagnosticAttemptOutcome::Running {
            return;
        }
        let completed_at = now_rfc3339();
        let written = self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            if interrupt_running_children {
                tx.execute(
                    "UPDATE diagnostic_attempts SET
                   completed_at = ?2,
                   duration_ms = MIN(86400000, MAX(0,
                     CAST((julianday(?2) - julianday(started_at)) * 86400000 AS INTEGER))),
                   outcome = 'interrupted', code = 'process_interrupted'
                 WHERE parent_refresh_id = ?1 AND outcome IS NULL",
                    params![handle.0, completed_at],
                )?;
            }
            tx.execute(
                "UPDATE diagnostic_attempts SET
               completed_at = ?2,
               duration_ms = MIN(86400000, MAX(0,
                 CAST((julianday(?2) - julianday(started_at)) * 86400000 AS INTEGER))),
               outcome = ?3, code = ?4
             WHERE id = ?1 AND outcome IS NULL",
                params![
                    handle.0,
                    completed_at,
                    diagnostic_attempt_outcome_key(completion.outcome),
                    completion.code.map(diagnostic_attempt_code_key),
                ],
            )?;
            tx.commit()?;
            Ok(())
        });
        if let Err(error) = written {
            report_journal_write_failure(&error);
        }
    }

    /// The newest work this device did, oldest first, for the copied report.
    pub fn diagnostic_recent_attempts(&self) -> Result<Vec<DiagnosticAttempt>, StateError> {
        self.with_cache(|conn| {
            let mut statement = conn.prepare(
                "SELECT kind, subject, started_at, duration_ms, outcome, code
             FROM diagnostic_attempts ORDER BY id DESC LIMIT ?1",
            )?;
            let rows = statement.query_map(
                [MAXIMUM_DIAGNOSTIC_RECENT as i64],
                diagnostic_attempt_from_row,
            )?;
            let mut attempts = Vec::new();
            for row in rows {
                attempts.push(row?);
            }
            attempts.reverse();
            Ok(attempts)
        })
    }

    /// What the journal knows about one kind of work: when it last ran, when it last worked, and
    /// the newest problem no later success has answered.
    pub fn diagnostic_attempt_facts(
        &self,
        kind: DiagnosticAttemptKind,
        subject: Option<&str>,
    ) -> Result<DiagnosticAttemptFacts, StateError> {
        if subject.is_some_and(|value| !valid_diagnostic_subject(value)) {
            return Err(StateError::InvalidState);
        }
        let kind = diagnostic_attempt_kind_key(kind);
        self.with_cache(|conn| {
            let latest = conn
                .query_row(
                    "SELECT completed_at, started_at, outcome, code FROM diagnostic_attempts
                 WHERE kind = ?1 AND ((?2 IS NULL AND subject IS NULL) OR subject = ?2)
                   AND outcome IS NOT NULL
                 ORDER BY id DESC LIMIT 1",
                    params![kind, subject],
                    diagnostic_attempt_outcome_row,
                )
                .optional()?;
            let last_success_at = conn
                .query_row(
                    "SELECT completed_at, started_at FROM diagnostic_attempts
                 WHERE kind = ?1 AND ((?2 IS NULL AND subject IS NULL) OR subject = ?2)
                   AND outcome = 'success'
                 ORDER BY id DESC LIMIT 1",
                    params![kind, subject],
                    |row| {
                        Ok(row
                            .get::<_, Option<String>>(0)?
                            .unwrap_or(row.get::<_, String>(1)?))
                    },
                )
                .optional()?;
            let unresolved = conn
                .query_row(
                    "SELECT completed_at, started_at, outcome, code FROM diagnostic_attempts
                 WHERE kind = ?1 AND ((?2 IS NULL AND subject IS NULL) OR subject = ?2)
                   AND outcome IN ('partial', 'failed', 'interrupted')
                   AND id > COALESCE((
                     SELECT MAX(id) FROM diagnostic_attempts
                     WHERE kind = ?1 AND ((?2 IS NULL AND subject IS NULL) OR subject = ?2)
                       AND outcome = 'success'
                   ), 0)
                 ORDER BY id DESC LIMIT 1",
                    params![kind, subject],
                    diagnostic_attempt_outcome_row,
                )
                .optional()?;
            Ok(DiagnosticAttemptFacts {
                last_attempt_at: latest.as_ref().map(|value| value.0.clone()),
                last_outcome: latest.as_ref().map(|value| value.1),
                last_success_at,
                unresolved_at: unresolved.as_ref().map(|value| value.0.clone()),
                unresolved_code: unresolved.and_then(|value| value.2),
            })
        })
    }

    pub fn pricing_etag(&self) -> Result<Option<String>, StateError> {
        self.with_cache(|conn| metadata_value(conn, "pricing_etag"))
    }

    pub fn commit_pricing_catalog(
        &self,
        value: &Value,
        etag: Option<&str>,
    ) -> Result<u64, StateError> {
        if etag.is_some_and(|value| value.len() > 256 || value.trim() != value) {
            return Err(StateError::InvalidState);
        }
        let raw = serde_json::to_string(value)?;
        if raw.len() > crate::protocol::MAXIMUM_LINE_BYTES {
            return Err(StateError::InvalidState);
        }
        self.with_cache_mut(|conn| {
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO components(name,status,value_json,updated_at,last_error_code,last_error_action,refreshing)
             VALUES ('pricing','ready',?1,?2,NULL,NULL,0)
             ON CONFLICT(name) DO UPDATE SET status=excluded.status,value_json=excluded.value_json,
             updated_at=excluded.updated_at,last_error_code=NULL,last_error_action=NULL,refreshing=0",
            params![raw, now_rfc3339()],
        )?;
        match etag {
            Some(etag) => {
                tx.execute(
                    "INSERT INTO metadata(key, value) VALUES ('pricing_etag', ?1)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params![etag],
                )?;
            }
            None => {
                tx.execute("DELETE FROM metadata WHERE key = 'pricing_etag'", [])?;
            }
        }
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
        })
    }

    pub fn model_catalog_etag(&self) -> Result<Option<String>, StateError> {
        self.with_cache(|conn| {
            conn.query_row(
                "SELECT etag FROM model_catalog_cache WHERE id = 1",
                [],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(StateError::from)
        })
    }

    pub fn model_catalog(&self) -> Result<Option<Value>, StateError> {
        self.with_cache(|conn| {
            let raw: Option<String> = conn
                .query_row(
                    "SELECT payload_json FROM model_catalog_cache WHERE id = 1",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            raw.map(|value| serde_json::from_str(&value).map_err(StateError::from))
                .transpose()
        })
    }

    /// Atomically replace the model catalog payload and its validator cache tag. An invalid
    /// payload is rejected before this transaction, so the previous last-known-good value stays
    /// available after a failed fetch.
    pub fn commit_model_catalog(
        &self,
        value: &Value,
        etag: Option<&str>,
    ) -> Result<u64, StateError> {
        if !crate::model_catalog::validate_model_catalog_value(value).valid {
            return Err(StateError::InvalidState);
        }
        if etag.is_some_and(|value| value.len() > 256 || value.trim() != value) {
            return Err(StateError::InvalidState);
        }
        let raw = serde_json::to_string(value)?;
        if raw.len() > crate::protocol::MAXIMUM_LINE_BYTES {
            return Err(StateError::InvalidState);
        }
        self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute(
                "INSERT INTO model_catalog_cache(id, payload_json, etag)
             VALUES (1, ?1, ?2)
             ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json,
             etag = excluded.etag",
                params![raw, etag],
            )?;
            let revision = bump_revision(&tx)?;
            tx.commit()?;
            Ok(revision)
        })
    }

    pub fn set_component(
        &self,
        name: ComponentName,
        status: ComponentStatus,
        value: Option<Value>,
        updated_at: Option<String>,
        last_error: Option<IpcError>,
        refreshing: bool,
    ) -> Result<u64, StateError> {
        self.with_cache_mut(|conn| {
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO components(name,status,value_json,updated_at,last_error_code,last_error_action,refreshing)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(name) DO UPDATE SET status=excluded.status,value_json=excluded.value_json,
             updated_at=excluded.updated_at,last_error_code=excluded.last_error_code,
             last_error_action=excluded.last_error_action,refreshing=excluded.refreshing",
            params![
                component_key(name),
                status_key(status),
                value.map(|v| serde_json::to_string(&v)).transpose()?,
                updated_at,
                last_error.as_ref().map(|e| error_code_key(e.code)),
                last_error.as_ref().map(|e| recovery_key(e.recovery_action)),
                i64::from(refreshing),
            ],
        )?;
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
        })
    }

    pub fn set_refreshing(&self, name: ComponentName, refreshing: bool) -> Result<u64, StateError> {
        let current = self.component(name)?.unwrap_or_else(|| {
            ComponentRecord::empty(if name == ComponentName::Account {
                ComponentStatus::SignedOut
            } else {
                ComponentStatus::Unavailable
            })
        });
        self.set_component(
            name,
            current.status,
            current.value,
            current.updated_at,
            current.last_error,
            refreshing,
        )
    }

    pub fn set_overview(&self, overview: &[QuotaOverviewItem]) -> Result<u64, StateError> {
        let value = serde_json::to_string(overview)?;
        self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute(
                "INSERT INTO metadata(key,value) VALUES ('overview_json',?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                params![value],
            )?;
            let revision = bump_revision(&tx)?;
            tx.commit()?;
            Ok(revision)
        })
    }

    pub fn current_revision(&self) -> Result<u64, StateError> {
        self.with_cache(|conn| {
            let revision = metadata_u64(conn, "revision")?;
            self.remembered_revision.store(revision, Ordering::Release);
            Ok(revision)
        })
    }

    /// The change counter every surface reads. It lives in the cache because almost everything
    /// that moves it does; identity writes reach it through here rather than through a
    /// transaction that would have to span both files.
    fn bump_revision(&self) -> Result<u64, StateError> {
        let revision = self.with_cache_mut(|conn| bump_revision(conn))?;
        self.remembered_revision.store(revision, Ordering::Release);
        Ok(revision)
    }

    #[cfg(test)]
    pub(crate) fn mark_cache_rebuilding_for_test(&self, value: bool) -> Result<(), StateError> {
        self.with_cache_mut(|conn| write_metadata_flag(conn, REBUILDING_KEY, value))
    }

    /// The last revision this process observed, without touching SQLite.
    pub fn remembered_revision(&self) -> u64 {
        self.remembered_revision.load(Ordering::Acquire)
    }

    /// Folds the cache's write-ahead log back into the image and hands freed pages back to the
    /// filesystem. A refresh rewrites every Usage record it re-reads, so without this the file
    /// keeps whatever size its largest transaction reached.
    pub fn checkpoint_cache(&self) {
        let _ = self.with_cache(reclaim_unused_pages);
    }

    pub fn usage_upload_enabled(&self) -> Result<bool, StateError> {
        self.with_identity(
            |conn| match preference(conn, "usage_upload_enabled")?.as_deref() {
                Some("1") => Ok(true),
                Some("0") => Ok(false),
                _ => Err(StateError::InvalidState),
            },
        )
    }

    pub fn set_usage_upload_enabled(&self, enabled: bool) -> Result<u64, StateError> {
        if self.usage_upload_enabled()? == enabled {
            return self.current_revision();
        }
        self.with_identity_mut(|conn| {
            write_preference(
                conn,
                "usage_upload_enabled",
                if enabled { "1" } else { "0" },
            )
        })?;
        self.bump_revision()
    }

    pub fn session_json(&self) -> Result<Option<Value>, StateError> {
        self.with_identity(|conn| {
            let raw: Option<String> = conn
                .query_row("SELECT payload_json FROM session WHERE id = 1", [], |row| {
                    row.get::<_, String>(0)
                })
                .optional()?;
            raw.map(|value| serde_json::from_str(&value).map_err(StateError::from))
                .transpose()
        })
    }

    /// Reads the session together with the SQLite compare-and-swap epoch.  The epoch is kept
    /// outside the JSON payload so imported released sessions remain wire-compatible while every
    /// local transition gets a monotonic identity.
    pub fn session_snapshot(&self) -> Result<Option<(Value, u64)>, StateError> {
        self.with_identity(|conn| {
            let raw: Option<(String, i64)> = conn
                .query_row(
                    "SELECT payload_json, epoch FROM session WHERE id = 1",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            raw.map(|(value, epoch)| {
                let epoch = u64::try_from(epoch).map_err(|_| StateError::InvalidState)?;
                Ok((serde_json::from_str(&value)?, epoch))
            })
            .transpose()
        })
    }

    /// Returns true only while the same active session is still installed.  Callers use this
    /// immediately before a Relay write so a logout transition cannot revive an old session.
    pub fn active_session_at_epoch(&self, expected_epoch: u64) -> Result<bool, StateError> {
        self.with_identity(|conn| {
            let raw: Option<(String, i64)> = conn
                .query_row(
                    "SELECT payload_json, epoch FROM session WHERE id = 1",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let Some((payload, epoch)) = raw else {
                return Ok(false);
            };
            if u64::try_from(epoch).ok() != Some(expected_epoch) {
                return Ok(false);
            }
            Ok(serde_json::from_str::<Value>(&payload)
                .ok()
                .and_then(|value| {
                    value
                        .get("status")
                        .and_then(Value::as_str)
                        .map(|status| status == "active")
                })
                .unwrap_or(false))
        })
    }

    pub fn write_session_json(&self, value: &Value) -> Result<u64, StateError> {
        let raw = serde_json::to_string(value)?;
        self.with_identity_mut(|conn| {
        let tx = conn.transaction()?;
        let epoch: Option<i64> = tx
            .query_row("SELECT epoch FROM session WHERE id = 1", [], |row| {
                row.get(0)
            })
            .optional()?;
        let next_epoch = epoch
            .map(|value| u64::try_from(value).map_err(|_| StateError::InvalidState))
            .transpose()?
            .unwrap_or(0)
            .checked_add(1)
            .ok_or(StateError::InvalidState)?;
        tx.execute(
            "INSERT INTO session(id,payload_json,epoch) VALUES (1,?1,?2)
             ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json, epoch=excluded.epoch",
            params![raw, i64::try_from(next_epoch).map_err(|_| StateError::InvalidState)?],
        )?;
        // Signing in again is the recovery this device asked for after starting over, so the
        // notice retires itself rather than waiting out a clock.
        tx.execute("DELETE FROM preferences WHERE key = ?1", params![IDENTITY_RESET_KEY])?;
        tx.commit()?;
        Ok(())
        })?;
        self.bump_revision()
    }

    /// Replaces the session only if its epoch is unchanged.  The returned epoch is the new
    /// session identity; `None` means a logout/login transition won the race.
    pub fn write_session_json_if_epoch(
        &self,
        value: &Value,
        expected_epoch: u64,
    ) -> Result<Option<u64>, StateError> {
        let raw = serde_json::to_string(value)?;
        let next = self.with_identity_mut(|conn| {
            let tx = conn.transaction()?;
            let next_epoch = expected_epoch
                .checked_add(1)
                .ok_or(StateError::InvalidState)?;
            let changed = tx.execute(
                "UPDATE session SET payload_json = ?1, epoch = ?2 WHERE id = 1 AND epoch = ?3",
                params![
                    raw,
                    i64::try_from(next_epoch).map_err(|_| StateError::InvalidState)?,
                    i64::try_from(expected_epoch).map_err(|_| StateError::InvalidState)?
                ],
            )?;
            if changed == 0 {
                tx.rollback()?;
                return Ok(None);
            }
            tx.commit()?;
            Ok(Some(next_epoch))
        })?;
        if next.is_some() {
            let _ = self.bump_revision();
        }
        Ok(next)
    }

    /// Deletes the session only if the caller still owns the pending epoch.
    pub fn clear_session_if_epoch(&self, expected_epoch: u64) -> Result<bool, StateError> {
        let cleared = self.with_identity_mut(|conn| {
            Ok(conn.execute(
                "DELETE FROM session WHERE id = 1 AND epoch = ?1",
                params![i64::try_from(expected_epoch).map_err(|_| StateError::InvalidState)?],
            )? > 0)
        })?;
        if cleared {
            self.forget_account_reads();
            let _ = self.bump_revision();
        }
        Ok(cleared)
    }

    /// Stored Account responses end with the session that was allowed to read them. They are a
    /// cache, so a cache this service cannot write is not a reason to refuse the sign-out.
    fn forget_account_reads(&self) {
        let _ = self.with_cache_mut(|conn| {
            conn.execute("DELETE FROM account_read_cache", [])?;
            Ok(())
        });
    }

    pub fn installation_id(&self) -> Result<String, StateError> {
        self.with_identity(|conn| {
            conn.query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .map_err(StateError::from)
        })
    }

    /// Reserves the per-installation Usage privacy lower bound for an account.  The first account
    /// may backfill retained history; every later account starts at its login instant.
    pub fn upload_lower_bound(
        &self,
        account_id: &str,
        login_at: &str,
    ) -> Result<String, StateError> {
        let login_at = DateTime::parse_from_rfc3339(login_at)
            .map_err(|_| StateError::InvalidState)?
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        if account_id.is_empty() {
            return Err(StateError::InvalidState);
        }
        self.with_identity_mut(|conn| {
            let tx = conn.transaction()?;
            let (installation_id, payload_json): (String, Option<String>) = tx.query_row(
                "SELECT installation_id, payload_json FROM installation WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            let mut payload = payload_json
                .map(|value| serde_json::from_str::<Value>(&value))
                .transpose()?
                .unwrap_or_else(|| {
                    serde_json::json!({
                        "schema_version": 1,
                        "installation_id": installation_id,
                        "account_bindings": []
                    })
                });
            let bindings = payload
                .get_mut("account_bindings")
                .and_then(Value::as_array_mut)
                .ok_or(StateError::InvalidState)?;
            if let Some(existing) = bindings.iter().find(|binding| {
                binding.get("account_id").and_then(Value::as_str) == Some(account_id)
            }) {
                let lower_bound = existing
                    .get("upload_not_before")
                    .and_then(Value::as_str)
                    .ok_or(StateError::InvalidState)?;
                let lower_bound = DateTime::parse_from_rfc3339(lower_bound)
                    .map_err(|_| StateError::InvalidState)?
                    .to_rfc3339_opts(SecondsFormat::AutoSi, true);
                tx.commit()?;
                return Ok(lower_bound);
            }
            if bindings.len() >= 32 {
                return Err(StateError::InvalidState);
            }
            let lower_bound = if bindings.is_empty() {
                "1970-01-01T00:00:00Z".to_owned()
            } else {
                login_at
            };
            bindings.push(serde_json::json!({
                "account_id": account_id,
                "upload_not_before": lower_bound,
            }));
            tx.execute(
                "UPDATE installation SET payload_json = ?1 WHERE id = 1",
                params![serde_json::to_string(&payload)?],
            )?;
            tx.commit()?;
            let _ = self.bump_revision();
            Ok(lower_bound)
        })
    }

    pub fn provider_config(&self, provider: &str) -> Result<Option<ProviderSecret>, StateError> {
        let file = read_provider_file(&self.root)?;
        Ok(file.providers.get(provider).cloned())
    }

    pub fn set_provider_config(
        &self,
        provider: &str,
        api_key: &str,
        base_url: Option<&str>,
    ) -> Result<u64, StateError> {
        let api_key = api_key.trim();
        if api_key.is_empty() || api_key.len() > 2_048 {
            return Err(StateError::InvalidState);
        }
        let _lock = ProviderConfigLock::acquire(&self.root)?;
        let mut file = read_provider_file(&self.root)?;
        file.providers.insert(
            provider.to_owned(),
            ProviderSecret {
                api_key: api_key.to_owned(),
                base_url: base_url
                    .map(str::trim)
                    .filter(|v| !v.is_empty())
                    .map(str::to_owned),
            },
        );
        write_provider_file(&self.root, &file)?;
        self.bump_revision()
    }

    pub fn remove_provider_config(&self, provider: &str) -> Result<u64, StateError> {
        let _lock = ProviderConfigLock::acquire(&self.root)?;
        let mut file = read_provider_file(&self.root)?;
        let removed = file.providers.remove(provider).is_some();
        if removed {
            write_provider_file(&self.root, &file)?;
            return self.bump_revision();
        }
        self.current_revision()
    }

    pub fn provider_browser_session(
        &self,
        provider: &str,
    ) -> Result<Option<ProviderBrowserSession>, StateError> {
        self.with_identity(|conn| {
            let session = conn
                .query_row(
                    "SELECT cookie_header, account_fingerprint, account_label
             FROM provider_browser_sessions WHERE provider = ?1",
                    [provider],
                    |row| {
                        Ok(ProviderBrowserSession {
                            cookie_header: row.get(0)?,
                            account_fingerprint: row.get(1)?,
                            account_label: row.get(2)?,
                        })
                    },
                )
                .optional()?;
            session
                .map(|session| validate_browser_session(provider, session))
                .transpose()
        })
    }

    pub fn provider_browser_sessions(
        &self,
    ) -> Result<Vec<(crate::catalog::ProviderId, ProviderBrowserSession)>, StateError> {
        self.with_identity(read_provider_browser_sessions)
    }

    pub fn set_provider_browser_session(
        &self,
        provider: &str,
        session: &ProviderBrowserSession,
    ) -> Result<u64, StateError> {
        validate_browser_session(provider, session.clone())?;
        self.with_identity_mut(|conn| {
            conn.execute(
                "INSERT INTO provider_browser_sessions(
                provider, cookie_header,
                account_fingerprint, account_label, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(provider) DO UPDATE SET
                cookie_header = excluded.cookie_header,
                account_fingerprint = excluded.account_fingerprint,
                account_label = excluded.account_label,
                updated_at = excluded.updated_at",
                params![
                    provider,
                    session.cookie_header,
                    session.account_fingerprint,
                    session.account_label,
                    now_rfc3339()
                ],
            )?;
            Ok(())
        })?;
        self.bump_revision()
    }

    pub fn remove_provider_browser_session(&self, provider: &str) -> Result<u64, StateError> {
        let removed = self.with_identity_mut(|conn| {
            Ok(conn.execute(
                "DELETE FROM provider_browser_sessions WHERE provider = ?1",
                [provider],
            )? > 0)
        })?;
        if removed {
            self.bump_revision()
        } else {
            self.current_revision()
        }
    }

    /// Records that macOS refused this Mac a browser's cookie store.
    ///
    /// This lives in the cache, not in identity: it is a fact about the last attempt, and the
    /// next attempt produces it again. Losing it to a cache rebuild costs nothing.
    pub fn set_browser_access_denial(
        &self,
        provider: &str,
        denial: &BrowserAccessDenial,
    ) -> Result<u64, StateError> {
        let mut denials = self.browser_access_denials()?;
        denials.insert(provider.to_owned(), denial.clone());
        self.write_browser_access_denials(&denials)?;
        self.bump_revision()
    }

    /// What the last `--version` read out of each installed provider CLI, as the collection
    /// layer wrote it.  Derived from binaries this device can re-read, so it lives in the
    /// disposable cache: a reset costs one `--version` per installed CLI and nothing else.
    pub fn provider_cli_versions(&self) -> Result<Option<String>, StateError> {
        self.with_cache(|conn| metadata_value(conn, CLI_VERSION_KEY))
    }

    pub fn write_provider_cli_versions(&self, encoded: &str) -> Result<(), StateError> {
        self.write_cache_metadata(CLI_VERSION_KEY, encoded)
    }

    /// The last time this device asked each provider's own CLI to renew its sign-in, against
    /// which binary, and how it went.  This is what keeps a CLI that cannot renew from being
    /// started every five minutes, so it must outlive the process; it lives in the disposable
    /// cache because losing it costs one extra attempt per provider and nothing else.  One
    /// map rather than one key each, so a refresh reads and writes it once.
    pub fn provider_refresh_attempts(&self) -> Result<Option<String>, StateError> {
        self.with_cache(|conn| metadata_value(conn, RENEWAL_ATTEMPT_KEY))
    }

    pub fn write_provider_refresh_attempts(&self, encoded: &str) -> Result<(), StateError> {
        self.write_cache_metadata(RENEWAL_ATTEMPT_KEY, encoded)
    }

    /// For each provider, the irreversible name of the credential that last produced a
    /// reading on this device.  It is what tells a token this build cannot judge on its own —
    /// an access token whose expiry it cannot decode — from one that has never worked; without
    /// it, an undatable token bought a provider CLI spawn every hour forever.  Disposable:
    /// losing it to a cache reset costs one extra renewal attempt per provider.
    pub fn proven_provider_credentials(&self) -> Result<Option<String>, StateError> {
        self.with_cache(|conn| metadata_value(conn, PROVEN_CREDENTIAL_KEY))
    }

    pub fn write_proven_provider_credentials(&self, encoded: &str) -> Result<(), StateError> {
        self.write_cache_metadata(PROVEN_CREDENTIAL_KEY, encoded)
    }

    fn write_cache_metadata(&self, key: &str, encoded: &str) -> Result<(), StateError> {
        if encoded.len() > crate::protocol::MAXIMUM_LINE_BYTES {
            return Err(StateError::InvalidState);
        }
        self.with_cache_mut(|conn| {
            conn.execute(
                "INSERT INTO metadata(key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, encoded],
            )?;
            Ok(())
        })
    }

    /// Clears a recorded refusal. A stored session, or a disconnect, both answer it.
    pub fn clear_browser_access_denial(&self, provider: &str) -> Result<(), StateError> {
        let mut denials = self.browser_access_denials()?;
        if denials.remove(provider).is_none() {
            return Ok(());
        }
        self.write_browser_access_denials(&denials)
    }

    pub fn browser_access_denials(
        &self,
    ) -> Result<BTreeMap<String, BrowserAccessDenial>, StateError> {
        let raw = self.with_cache(|conn| metadata_value(conn, BROWSER_ACCESS_DENIED_KEY))?;
        let Some(raw) = raw else {
            return Ok(BTreeMap::new());
        };
        // A cache row this process cannot read is a cache row: it is thrown away, not salvaged.
        Ok(serde_json::from_str(&raw).unwrap_or_default())
    }

    fn write_browser_access_denials(
        &self,
        denials: &BTreeMap<String, BrowserAccessDenial>,
    ) -> Result<(), StateError> {
        let encoded = serde_json::to_string(denials)?;
        self.with_cache_mut(|conn| {
            conn.execute(
                "INSERT INTO metadata(key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![BROWSER_ACCESS_DENIED_KEY, encoded],
            )?;
            Ok(())
        })
    }

    /// Everything this device still owes an Account, oldest hour first.
    pub fn outbox_entries(&self) -> Result<Vec<UsageOutboxEntry>, StateError> {
        self.with_identity(|conn| read_outbox(conn, None))
    }

    /// How many hours are staged. Counted in SQL, because the callers that ask this were
    /// deserializing every staged hour's rows to call `len()` on the result.
    pub fn outbox_len(&self) -> Result<i64, StateError> {
        self.with_identity(|conn| {
            conn.query_row("SELECT COUNT(*) FROM usage_outbox", [], |row| row.get(0))
                .map_err(StateError::from)
        })
    }

    pub fn outbox_entries_for(
        &self,
        account_id: &str,
        device_id: &str,
        generation: u64,
    ) -> Result<Vec<UsageOutboxEntry>, StateError> {
        self.with_identity(|conn| read_outbox(conn, Some((account_id, device_id, generation))))
    }

    /// Stages the hours a scan changed and retires the dirty marks that produced them.
    ///
    /// The entries are written before the marks are cleared. A crash in between leaves the hour
    /// dirty, so the next refresh stages the same key again with the same or a newer scan
    /// version — an hour is replaced by version, so restaging it is not a second write.
    pub fn stage_outbox_entries(
        &self,
        account_id: &str,
        device_id: &str,
        generation: u64,
        entries: &[UsageOutboxEntry],
    ) -> Result<bool, StateError> {
        if account_id.is_empty() || device_id.is_empty() || generation == 0 {
            return Err(StateError::InvalidState);
        }
        if entries.is_empty() {
            return Ok(false);
        }
        self.with_identity_mut(|conn| {
            let tx = conn.transaction()?;
            for entry in entries {
                let rows = serde_json::to_string(&entry.rows)?;
                if rows.len() > crate::relay::MAXIMUM_REQUEST_BYTES {
                    return Err(StateError::InvalidState);
                }
                tx.execute(
                    "INSERT INTO usage_outbox(
                        agent, bucket_start_utc, account_id, device_id, generation,
                        scan_version, partial, rows_json
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                     ON CONFLICT(agent, bucket_start_utc) DO UPDATE SET
                        account_id = excluded.account_id,
                        device_id = excluded.device_id,
                        generation = excluded.generation,
                        scan_version = excluded.scan_version,
                        partial = excluded.partial,
                        rows_json = excluded.rows_json",
                    params![
                        entry.agent.as_str(),
                        entry.bucket_start_utc,
                        account_id,
                        device_id,
                        generation as i64,
                        entry.scan_version as i64,
                        i64::from(entry.partial),
                        rows,
                    ],
                )?;
            }
            tx.commit()?;
            Ok(())
        })?;
        self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            for entry in entries {
                tx.execute(
                    "DELETE FROM usage_dirty_hours
                     WHERE agent = ?1 AND bucket_start_utc = ?2 AND scan_version <= ?3",
                    params![
                        entry.agent.as_str(),
                        entry.bucket_start_utc,
                        entry.scan_version as i64
                    ],
                )?;
            }
            tx.commit()?;
            Ok(())
        })?;
        self.bump_revision()?;
        Ok(true)
    }

    /// Forgets hours Relay has answered for. Accepted and ignored are the same move here: an
    /// ignored hour is one a newer scan already replaced or one before this device's deletion
    /// watermark, and either way this device is done with it.
    pub fn forget_outbox_hours(
        &self,
        agent: UsageAgent,
        buckets: &[String],
    ) -> Result<bool, StateError> {
        if buckets.is_empty() {
            return Ok(false);
        }
        let removed = self.with_identity_mut(|conn| {
            let tx = conn.transaction()?;
            let mut removed = 0usize;
            for bucket in buckets {
                removed += tx.execute(
                    "DELETE FROM usage_outbox WHERE agent = ?1 AND bucket_start_utc = ?2",
                    params![agent.as_str(), bucket],
                )?;
            }
            tx.commit()?;
            Ok(removed > 0)
        })?;
        if removed {
            let _ = self.bump_revision();
        }
        Ok(removed)
    }

    pub fn usage_file_index(
        &self,
        agent: UsageAgent,
    ) -> Result<HashMap<String, UsageFileIndex>, StateError> {
        self.with_cache(|conn| {
            let mut statement = conn.prepare(
                "SELECT source_file_id, identity, size, modified_ns, parser_revision,
                        parsed_offset, prefix_hash
             FROM usage_file_index WHERE agent = ?1",
            )?;
            let rows = statement.query_map(params![agent.as_str()], |row| {
                let source_file_id: String = row.get(0)?;
                let modified_ns: String = row.get(3)?;
                let modified_ns = modified_ns.parse::<u128>().map_err(|_| {
                    rusqlite::Error::InvalidColumnType(
                        3,
                        "modified_ns".to_owned(),
                        rusqlite::types::Type::Text,
                    )
                })?;
                Ok((
                    source_file_id.clone(),
                    UsageFileIndex {
                        source_file_id,
                        identity: row.get(1)?,
                        size: row.get::<_, i64>(2)? as u64,
                        modified_ns,
                        parser_revision: row.get(4)?,
                        parsed_offset: row.get::<_, i64>(5)? as u64,
                        prefix_hash: row.get(6)?,
                    },
                ))
            })?;
            let mut result = HashMap::new();
            for row in rows {
                let (id, index) = row?;
                result.insert(id, index);
            }
            Ok(result)
        })
    }

    #[cfg(test)]
    /// Removes the attempt journal so every journal write fails.
    ///
    /// Used to prove that collection, scanning, uploading, and syncing do not depend on the
    /// journal being writable.
    pub fn make_diagnostic_journal_unwritable_for_test(&self) -> Result<(), StateError> {
        self.with_cache_mut(|conn| {
            conn.execute("DROP TABLE diagnostic_attempts", [])?;
            Ok(())
        })
    }

    pub fn make_usage_file_index_unreadable_for_test(&self) -> Result<(), StateError> {
        self.with_cache_mut(|conn| {
            conn.execute("DROP TABLE usage_file_index", [])?;
            Ok(())
        })
    }

    pub fn usage_event_count(&self) -> Result<u64, StateError> {
        self.with_cache(|conn| {
            let count = conn.query_row("SELECT COUNT(*) FROM usage_file_records", [], |row| {
                row.get::<_, i64>(0)
            })?;
            u64::try_from(count).map_err(|_| StateError::InvalidState)
        })
    }

    /// UTC hours whose indexed source came up short, so every read of them says so.
    pub fn partial_usage_hours(&self) -> Result<HashSet<(UsageAgent, String)>, StateError> {
        self.with_cache(|conn| {
            let mut statement = conn.prepare(
                "SELECT agent, start_at FROM usage_partial_sources ORDER BY agent, start_at",
            )?;
            let rows = statement.query_map([], |row| {
                let agent: String = row.get(0)?;
                let agent = parse_usage_agent(&agent).ok_or_else(|| {
                    rusqlite::Error::InvalidColumnType(
                        0,
                        "agent".to_owned(),
                        rusqlite::types::Type::Text,
                    )
                })?;
                Ok((agent, row.get::<_, String>(1)?))
            })?;
            let mut hours = HashSet::new();
            for row in rows {
                hours.insert(row?);
            }
            Ok(hours)
        })
    }

    /// The hours this device still owes its Account, oldest first, with the rows each is made
    /// of.
    ///
    /// One transaction, and bounded. Reading the list of dirty hours and then reading each
    /// hour's rows under a lock of its own let a cache reset land in between: the hour was
    /// staged empty under the scan version that produced it, and an hour is replaced by
    /// version, so the Account applied the emptiness.
    ///
    /// `lower_bound` is the privacy watermark this device may not upload before and
    /// `upper_bound` the hour still being written to. Both are canonical UTC hours, which is
    /// the form `bucket_start_utc` holds, so the comparison is the column's own order.
    pub fn dirty_usage_hour_batch(
        &self,
        lower_bound: &str,
        upper_bound: &str,
        limit: usize,
    ) -> Result<Vec<UsageOutboxEntry>, StateError> {
        self.with_cache(|conn| {
            let tx = conn.unchecked_transaction()?;
            let hours = {
                let mut statement = tx.prepare(
                    "SELECT agent, bucket_start_utc, scan_version, partial FROM usage_dirty_hours
                     WHERE bucket_start_utc >= ?1 AND bucket_start_utc < ?2
                     ORDER BY bucket_start_utc, agent LIMIT ?3",
                )?;
                let rows = statement.query_map(
                    params![lower_bound, upper_bound, limit as i64],
                    |row| {
                        let agent: String = row.get(0)?;
                        let agent = parse_usage_agent(&agent).ok_or_else(|| {
                            rusqlite::Error::InvalidColumnType(
                                0,
                                "agent".to_owned(),
                                rusqlite::types::Type::Text,
                            )
                        })?;
                        Ok((
                            agent,
                            row.get::<_, String>(1)?,
                            row.get::<_, i64>(2)? as u64,
                            row.get::<_, i64>(3)? != 0,
                        ))
                    },
                )?;
                rows.collect::<Result<Vec<_>, _>>()?
            };
            let mut entries = Vec::with_capacity(hours.len());
            {
                let mut statement = tx.prepare(FACT_ROW_QUERY)?;
                for (agent, bucket_start_utc, scan_version, partial) in hours {
                    let rows = statement
                        .query_map(params![agent.as_str(), &bucket_start_utc], read_fact_row)?
                        .collect::<Result<Vec<_>, _>>()?;
                    entries.push(UsageOutboxEntry {
                        agent,
                        bucket_start_utc,
                        scan_version,
                        partial,
                        rows,
                    });
                }
            }
            tx.commit()?;
            Ok(entries)
        })
    }

    /// How many recomputed hours are ready to leave, under the same bounds that decide what
    /// [`Self::dirty_usage_hour_batch`] stages. Counted in SQL: the answer is a number for a
    /// diagnostic line, not a reason to read a year of rows.
    pub fn uploadable_dirty_hour_count(
        &self,
        lower_bound: &str,
        upper_bound: &str,
    ) -> Result<i64, StateError> {
        self.with_cache(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM usage_dirty_hours
                 WHERE bucket_start_utc >= ?1 AND bucket_start_utc < ?2",
                params![lower_bound, upper_bound],
                |row| row.get(0),
            )
            .map_err(StateError::from)
        })
    }

    /// Retires the dirty marks for hours this device may never upload.
    ///
    /// An hour before the privacy watermark is not waiting for anything: staging skips it, so
    /// left alone its mark would sit in the cache forever and count as work owed.
    pub fn forget_dirty_usage_hours_before(&self, lower_bound: &str) -> Result<bool, StateError> {
        let removed = self.with_cache_mut(|conn| {
            Ok(conn.execute(
                "DELETE FROM usage_dirty_hours WHERE bucket_start_utc < ?1",
                params![lower_bound],
            )?)
        })?;
        Ok(removed > 0)
    }

    /// Marks an hour dirty without a scan behind it, for tests that only need the mark.
    pub fn insert_usage_dirty_hour_for_test(
        &self,
        agent: UsageAgent,
        bucket_start_utc: &str,
        scan_version: u64,
    ) -> Result<(), StateError> {
        self.with_cache_mut(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO usage_dirty_hours(
                    agent, bucket_start_utc, scan_version, partial
                 ) VALUES (?1, ?2, ?3, 0)",
                params![agent.as_str(), bucket_start_utc, scan_version as i64],
            )?;
            Ok(())
        })
    }

    /// The rows of one hour, as the upload carries them.
    pub fn usage_hour_rows(
        &self,
        agent: UsageAgent,
        bucket_start_utc: &str,
    ) -> Result<Vec<UsageRow>, StateError> {
        self.with_cache(|conn| {
            let mut statement = conn.prepare(FACT_ROW_QUERY)?;
            let rows = statement
                .query_map(params![agent.as_str(), bucket_start_utc], read_fact_row)?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }

    /// Folds the stored hours into the rows one period is computed from.
    ///
    /// `range` is the half-open instant span the period covers — a local day begins at local
    /// midnight, not at a UTC one — and `None` is everything retained. An hour is the finest
    /// fact stored, so comparing its start against the span rounds an edge that falls inside an
    /// hour up to the next one, which keeps two periods from claiming the same hour.
    ///
    /// The date each row carries is still the UTC date of the hours behind it, because that is
    /// what prices a row and resolves a model alias, not what the period names.
    pub fn usage_period_rows(
        &self,
        range: Option<(&str, &str)>,
    ) -> Result<(Vec<DatedUsageRow>, bool), StateError> {
        self.with_cache(|conn| {
            let (clause, from, to) = match range {
                Some((start, end)) => (
                    "WHERE bucket_start_utc >= ?1 AND bucket_start_utc < ?2",
                    start.to_owned(),
                    end.to_owned(),
                ),
                None => ("WHERE ?1 = ?1 AND ?2 = ?2", String::new(), String::new()),
            };
            let mut statement = conn.prepare(&format!(
                "SELECT substr(bucket_start_utc, 1, 10) AS date, agent, billing_channel,
                        channel_source, model, context_bucket, service_tier, speed, inference_geo,
                        SUM(input_tokens), SUM(cache_read_tokens), SUM(cache_write_5m_tokens),
                        SUM(cache_write_1h_tokens), SUM(cache_write_inferred_tokens),
                        SUM(output_tokens), SUM(reasoning_tokens), SUM(requests),
                        SUM(web_search_requests), SUM(web_fetch_requests),
                        SUM(source_cost_microusd), SUM(source_cost_covered_requests),
                        MAX(partial)
                 FROM usage_hourly_facts {clause}
                 GROUP BY date, agent, billing_channel, channel_source, model, context_bucket,
                          service_tier, speed, inference_geo
                 ORDER BY date, agent, billing_channel, model"
            ))?;
            let mut partial = false;
            let mut rows = Vec::new();
            let mapped = statement.query_map(params![from, to], |row| {
                let date: String = row.get(0)?;
                let hour_partial: i64 = row.get(21)?;
                Ok((date, read_grouped_row(row)?, hour_partial != 0))
            })?;
            for entry in mapped {
                let (date, row, row_partial) = entry?;
                partial = partial || row_partial;
                rows.push(DatedUsageRow { date, row });
            }
            Ok((rows, partial))
        })
    }

    /// Switches the upload identity atomically.
    ///
    /// A new account or device generation owes that Account every hour this device still holds
    /// at or after its privacy lower bound, so the dirty set is rebuilt from the stored facts
    /// and the old queue is dropped: requests staged for one identity cannot be replayed under
    /// another.
    pub fn ensure_usage_context(
        &self,
        account_id: &str,
        device_id: &str,
        generation: u64,
        lower_bound: &str,
    ) -> Result<u64, StateError> {
        let lower_bound =
            DateTime::parse_from_rfc3339(lower_bound).map_err(|_| StateError::InvalidState)?;
        if account_id.is_empty() || device_id.is_empty() || generation == 0 {
            return Err(StateError::InvalidState);
        }
        let unchanged = self.with_identity(|conn| {
            let current: Option<(String, String, i64, String)> = conn
                .query_row(
                    "SELECT account_id, device_id, generation, lower_bound
                     FROM usage_upload_context WHERE id = 1",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .optional()?;
            Ok(current.is_some_and(|current| {
                current.0 == account_id
                    && current.1 == device_id
                    && current.2 == generation as i64
                    && current.3 == lower_bound.to_rfc3339_opts(SecondsFormat::AutoSi, true)
            }))
        })?;
        if unchanged {
            let removed = self.with_identity_mut(|conn| {
                Ok(conn.execute(
                    "DELETE FROM usage_outbox
                     WHERE account_id != ?1 OR device_id != ?2 OR generation != ?3",
                    params![account_id, device_id, generation as i64],
                )? > 0)
            })?;
            return if removed {
                self.bump_revision()
            } else {
                self.current_revision()
            };
        }
        // The dirty set is re-seeded before the identity that owns it is written. A crash in
        // between leaves the old identity in place, and the next call sees it unchanged and does
        // both steps again; the other order would leave a new identity pointing at an old queue.
        let floor = floor_hour(lower_bound).to_rfc3339_opts(SecondsFormat::Secs, true);
        self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute("DELETE FROM usage_dirty_hours", [])?;
            tx.execute(
                "INSERT INTO usage_dirty_hours(agent, bucket_start_utc, scan_version, partial)
                 SELECT agent, bucket_start_utc, MAX(scan_version), MAX(partial)
                 FROM usage_hourly_facts WHERE bucket_start_utc >= ?1
                 GROUP BY agent, bucket_start_utc",
                params![floor],
            )?;
            tx.commit()?;
            Ok(())
        })?;
        self.with_identity_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute("DELETE FROM usage_outbox", [])?;
            tx.execute(
                "INSERT INTO usage_upload_context(
                id, account_id, device_id, generation, lower_bound
             ) VALUES (1, ?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET
                account_id = excluded.account_id,
                device_id = excluded.device_id,
                generation = excluded.generation,
                lower_bound = excluded.lower_bound",
                params![
                    account_id,
                    device_id,
                    generation,
                    lower_bound.to_rfc3339_opts(SecondsFormat::AutoSi, true)
                ],
            )?;
            tx.commit()?;
            Ok(())
        })?;
        self.bump_revision()
    }

    /// The revision this scan's hours are stamped with.
    ///
    /// Relay keeps the version of the scan behind each stored hour and replaces an hour only
    /// for a strictly newer one, so this counter has to keep climbing across a cache rebuild.
    /// It lives in identity, which is the file this device never regenerates.
    pub fn next_usage_scan_version(&self) -> Result<u64, StateError> {
        self.with_identity_mut(|conn| {
            let current = preference(conn, USAGE_SCAN_VERSION_KEY)?
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(0);
            let next = current.saturating_add(1);
            write_preference(conn, USAGE_SCAN_VERSION_KEY, &next.to_string())?;
            Ok(next)
        })
    }

    /// Applies one agent's scan and recomputes only the hours it changed.
    ///
    /// A source is replaced whole, or appended to when the bytes already parsed are still
    /// there. Either way the hours whose events moved are recomputed from the retained record
    /// history, which is what makes an hour a single fact rather than a running merge.
    pub fn apply_usage_scan(
        &self,
        agent: UsageAgent,
        scan: &UsageScanResult,
        scan_version: u64,
    ) -> Result<u64, StateError> {
        self.with_cache_mut(|conn| {
            let tx = conn.transaction()?;
            let mut changed = 0usize;
            let mut dirty_hours: BTreeSet<String> = BTreeSet::new();
            for source in &scan.sources {
                if source.coverage.status != crate::usage::CoverageStatus::Complete {
                    // Preserve the last successful rows and merge newly valid records. This keeps
                    // data useful without allowing an incomplete scan to delete facts. The old file
                    // index remains untouched so the source is retried on the next refresh.
                    let mut hours = Vec::new();
                    for (record_index, event) in source.records.iter().enumerate() {
                        let key = source_record_key(source, record_index);
                        hours.push(insert_record(
                            &tx,
                            agent,
                            &source.source.source_file_id,
                            &key,
                            event,
                        )?);
                    }
                    if source.coverage.reasons.iter().any(|reason| {
                        reason.code == crate::usage::CoverageReasonCode::InvalidTimestamp
                    }) && let Ok(start) = event_hour(&source.coverage.start_at)
                    {
                        // A malformed record without a usable timestamp cannot be assigned to its
                        // true hour. Keep one bounded conservative partial marker rather than
                        // falsely declaring the whole source complete.
                        hours.push(start);
                    }
                    mark_partial_source_hours_tx(
                        &tx,
                        agent,
                        &source.source.source_file_id,
                        hours.clone(),
                    )?;
                    remember_partial_progress(&tx, agent, source)?;
                    dirty_hours.extend(hours);
                    changed += 1;
                    continue;
                }
                // A complete rescan also restores replace semantics for every hour that was
                // previously merged as partial, so those hours are recomputed once more.
                dirty_hours.extend(partial_source_hours_tx(
                    &tx,
                    agent,
                    &source.source.source_file_id,
                )?);
                tx.execute(
                    "DELETE FROM usage_partial_sources WHERE agent = ?1 AND source_file_id = ?2",
                    params![agent.as_str(), source.source.source_file_id],
                )?;
                if !source.append {
                    dirty_hours.extend(record_hours(&tx, agent, &source.source.source_file_id)?);
                    tx.execute(
                        "DELETE FROM usage_file_records WHERE agent = ?1 AND source_file_id = ?2",
                        params![agent.as_str(), source.source.source_file_id],
                    )?;
                }
                for (record_index, event) in source.records.iter().enumerate() {
                    let key = source_record_key(source, record_index);
                    dirty_hours.insert(insert_record(
                        &tx,
                        agent,
                        &source.source.source_file_id,
                        &key,
                        event,
                    )?);
                }
                changed += tx.execute(
                    "INSERT INTO usage_file_index(
                    agent, source_file_id, identity, size, modified_ns, parser_revision,
                    parsed_offset, prefix_hash
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(agent, source_file_id) DO UPDATE SET
                    identity = excluded.identity,
                    size = excluded.size,
                    modified_ns = excluded.modified_ns,
                    parser_revision = excluded.parser_revision,
                    parsed_offset = excluded.parsed_offset,
                    prefix_hash = excluded.prefix_hash",
                    params![
                        agent.as_str(),
                        source.source.source_file_id,
                        source.source.identity,
                        source.source.size as i64,
                        source.source.modified_ns.to_string(),
                        source.index.parser_revision,
                        source.index.parsed_offset as i64,
                        source.index.prefix_hash,
                    ],
                )?;
            }
            for source_file_id in &scan.deleted_source_file_ids {
                dirty_hours.extend(record_hours(&tx, agent, source_file_id)?);
                tx.execute(
                    "DELETE FROM usage_partial_sources WHERE agent = ?1 AND source_file_id = ?2",
                    params![agent.as_str(), source_file_id],
                )?;
                tx.execute(
                    "DELETE FROM usage_file_records WHERE agent = ?1 AND source_file_id = ?2",
                    params![agent.as_str(), source_file_id],
                )?;
                changed += tx.execute(
                    "DELETE FROM usage_file_index WHERE agent = ?1 AND source_file_id = ?2",
                    params![agent.as_str(), source_file_id],
                )?;
            }
            let mut recomputed = 0usize;
            for hour in &dirty_hours {
                if recompute_hour(&tx, agent, hour, scan_version)? {
                    recomputed += 1;
                }
            }
            // One complete scan is what the cache was waiting for: from here on the local Usage
            // it reports is this device's own history again, not a hole left by a rebuild.
            if scan.coverage.status == crate::usage::CoverageStatus::Complete {
                write_metadata_flag(&tx, REBUILDING_KEY, false)?;
            }
            if changed == 0 && recomputed == 0 {
                let revision = metadata_u64(&tx, "revision")?;
                tx.commit()?;
                return Ok(revision);
            }
            let revision = bump_revision(&tx)?;
            tx.commit()?;
            Ok(revision)
        })
    }
}

/// Remembers how far a source this scan could not finish was read.
///
/// The size and modification time are deliberately not stored: they are what makes the next
/// scan skip a source it already read, and a source that came up short has to be tried again.
/// What is worth keeping is the byte the last clean record ended on and the digest of
/// everything before it, so the retry reads the part that was never read rather than the whole
/// log, every refresh, forever.
fn remember_partial_progress(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    source: &crate::usage::UsageSourceScan,
) -> Result<(), StateError> {
    if source.index.parsed_offset == 0 || source.index.prefix_hash.is_empty() {
        return Ok(());
    }
    tx.execute(
        "INSERT INTO usage_file_index(
            agent, source_file_id, identity, size, modified_ns, parser_revision,
            parsed_offset, prefix_hash
         ) VALUES (?1, ?2, ?3, 0, '0', ?4, ?5, ?6)
         ON CONFLICT(agent, source_file_id) DO UPDATE SET
            identity = excluded.identity,
            size = 0,
            modified_ns = '0',
            parser_revision = excluded.parser_revision,
            parsed_offset = excluded.parsed_offset,
            prefix_hash = excluded.prefix_hash",
        params![
            agent.as_str(),
            source.source.source_file_id,
            source.source.identity,
            source.index.parser_revision,
            source.index.parsed_offset as i64,
            source.index.prefix_hash,
        ],
    )?;
    Ok(())
}

fn validate_browser_session(
    provider: &str,
    session: ProviderBrowserSession,
) -> Result<ProviderBrowserSession, StateError> {
    let provider_id = crate::catalog::ProviderId::parse(provider)
        .filter(|id| id.metadata().browser_session.is_some())
        .ok_or(StateError::InvalidState)?;
    if !crate::providers::common::normalize_browser_cookie_header(
        provider_id,
        &session.cookie_header,
    )
    .is_ok_and(|value| value == session.cookie_header)
        || session.cookie_header.is_empty()
        || session.cookie_header.len() > crate::providers::common::BROWSER_COOKIE_HEADER_LIMIT
        || session.cookie_header.chars().any(char::is_control)
        || session.account_fingerprint.len() != 64
        || !session
            .account_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || session.account_label.as_ref().is_some_and(|label| {
            label.is_empty() || label.len() > 128 || label.chars().any(char::is_control)
        })
    {
        return Err(StateError::InvalidState);
    }
    Ok(session)
}

/// One staged upload: an hour, the version of the scan behind it, and its rows.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UsageOutboxEntry {
    pub agent: UsageAgent,
    pub bucket_start_utc: String,
    pub scan_version: u64,
    pub partial: bool,
    pub rows: Vec<UsageRow>,
}

const FACT_ROW_QUERY: &str = "SELECT agent, billing_channel, channel_source, model, context_bucket,
            service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
            cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
            output_tokens, reasoning_tokens, requests, web_search_requests, web_fetch_requests,
            source_cost_microusd, source_cost_covered_requests
     FROM usage_hourly_facts WHERE agent = ?1 AND bucket_start_utc = ?2
     ORDER BY billing_channel, model, context_bucket, service_tier, speed, inference_geo";

fn read_outbox(
    conn: &Connection,
    scope: Option<(&str, &str, u64)>,
) -> Result<Vec<UsageOutboxEntry>, StateError> {
    let (clause, account_id, device_id, generation) = match scope {
        Some((account_id, device_id, generation)) => (
            "WHERE account_id = ?1 AND device_id = ?2 AND generation = ?3",
            account_id.to_owned(),
            device_id.to_owned(),
            generation as i64,
        ),
        None => (
            "WHERE ?1 = ?1 AND ?2 = ?2 AND ?3 = ?3",
            String::new(),
            String::new(),
            0,
        ),
    };
    let mut statement = conn.prepare(&format!(
        "SELECT agent, bucket_start_utc, scan_version, partial, rows_json FROM usage_outbox
         {clause} ORDER BY bucket_start_utc, agent"
    ))?;
    let rows = statement.query_map(params![account_id, device_id, generation], |row| {
        let agent: String = row.get(0)?;
        let agent = parse_usage_agent(&agent).ok_or_else(|| {
            rusqlite::Error::InvalidColumnType(0, "agent".to_owned(), rusqlite::types::Type::Text)
        })?;
        Ok((
            agent,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)? as u64,
            row.get::<_, i64>(3)? != 0,
            row.get::<_, String>(4)?,
        ))
    })?;
    let mut entries = Vec::new();
    for row in rows {
        let (agent, bucket_start_utc, scan_version, partial, rows_json) = row?;
        entries.push(UsageOutboxEntry {
            agent,
            bucket_start_utc,
            scan_version,
            partial,
            rows: serde_json::from_str(&rows_json)?,
        });
    }
    Ok(entries)
}

fn read_fact_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<UsageRow> {
    read_row_at(row, 0)
}

/// The grouped period projection names the date first, so its row columns start one later.
fn read_grouped_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<UsageRow> {
    read_row_at(row, 1)
}

fn read_row_at(row: &rusqlite::Row<'_>, offset: usize) -> rusqlite::Result<UsageRow> {
    let column = |index: usize, name: &str| {
        rusqlite::Error::InvalidColumnType(index, name.to_owned(), rusqlite::types::Type::Text)
    };
    let agent: String = row.get(offset)?;
    let agent = parse_usage_agent(&agent).ok_or_else(|| column(offset, "agent"))?;
    let billing_channel: String = row.get(offset + 1)?;
    let billing_channel = crate::usage::BillingChannel::ALL
        .into_iter()
        .find(|value| value.as_str() == billing_channel)
        .ok_or_else(|| column(offset + 1, "billing_channel"))?;
    let channel_source: String = row.get(offset + 2)?;
    let channel_source = match channel_source.as_str() {
        "explicit" => crate::usage::ChannelSource::Explicit,
        "agent_default" => crate::usage::ChannelSource::AgentDefault,
        "unknown" => crate::usage::ChannelSource::Unknown,
        _ => return Err(column(offset + 2, "channel_source")),
    };
    let context_bucket: String = row.get(offset + 4)?;
    let context_bucket = [
        crate::usage::ContextBucket::Le128k,
        crate::usage::ContextBucket::Gt128kLe200k,
        crate::usage::ContextBucket::Gt200kLe256k,
        crate::usage::ContextBucket::Gt256kLe272k,
        crate::usage::ContextBucket::Gt272k,
    ]
    .into_iter()
    .find(|value| value.as_str() == context_bucket)
    .ok_or_else(|| column(offset + 4, "context_bucket"))?;
    let count = |index: usize| -> rusqlite::Result<u64> {
        Ok(row.get::<_, i64>(offset + index)?.max(0) as u64)
    };
    Ok(UsageRow {
        agent,
        billing_channel,
        channel_source,
        model: row.get(offset + 3)?,
        context_bucket,
        service_tier: row.get(offset + 5)?,
        speed: row.get(offset + 6)?,
        inference_geo: row.get(offset + 7)?,
        input_tokens: count(8)?,
        cache_read_tokens: count(9)?,
        cache_write_5m_tokens: count(10)?,
        cache_write_1h_tokens: count(11)?,
        cache_write_inferred_tokens: count(12)?,
        output_tokens: count(13)?,
        reasoning_tokens: count(14)?,
        requests: count(15)?,
        web_search_requests: count(16)?,
        web_fetch_requests: count(17)?,
        source_cost_microusd: row
            .get::<_, Option<i64>>(offset + 18)?
            .map(|value| value.max(0).to_string()),
        source_cost_covered_requests: count(19)?,
    })
}

fn parse_usage_agent(value: &str) -> Option<UsageAgent> {
    Some(match value {
        "codex" => UsageAgent::Codex,
        "claude_code" => UsageAgent::ClaudeCode,
        "grok" => UsageAgent::Grok,
        "opencode" => UsageAgent::OpenCode,
        "pi" => UsageAgent::Pi,
        "cursor" => UsageAgent::Cursor,
        _ => return None,
    })
}

/// Stores one parsed record and answers the UTC hour it belongs to.
fn insert_record(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    source_file_id: &str,
    record_key: &str,
    event: &NormalizedUsageEvent,
) -> Result<String, StateError> {
    let event_json = serde_json::to_string(event)?;
    if event_json.len() > crate::relay::MAXIMUM_REQUEST_BYTES {
        return Err(StateError::InvalidState);
    }
    let occurred_at =
        crate::usage::canonical_instant(&event.occurred_at).ok_or(StateError::InvalidState)?;
    tx.execute(
        "INSERT INTO usage_file_records(
            agent, source_file_id, record_key, occurred_at, event_json
         ) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(agent, source_file_id, record_key) DO UPDATE SET
            occurred_at = excluded.occurred_at,
            event_json = excluded.event_json",
        params![
            agent.as_str(),
            source_file_id,
            record_key,
            occurred_at,
            event_json
        ],
    )?;
    event_hour(&occurred_at)
}

/// Every UTC hour one source currently has records in.
fn record_hours(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    source_file_id: &str,
) -> Result<Vec<String>, StateError> {
    let mut statement = tx.prepare(
        "SELECT DISTINCT substr(occurred_at, 1, 13) FROM usage_file_records
         WHERE agent = ?1 AND source_file_id = ?2",
    )?;
    let rows = statement.query_map(params![agent.as_str(), source_file_id], |row| {
        row.get::<_, String>(0)
    })?;
    let mut hours = Vec::new();
    for row in rows {
        hours.push(format!("{}:00:00Z", row?));
    }
    Ok(hours)
}

/// Rebuilds one hour's facts from the records this device currently retains for it.
///
/// The hour is the unit: what is stored is replaced outright rather than merged, so a record
/// that moved out of the hour leaves no trace of itself behind.
fn recompute_hour(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    bucket_start_utc: &str,
    scan_version: u64,
) -> Result<bool, StateError> {
    let start =
        DateTime::parse_from_rfc3339(bucket_start_utc).map_err(|_| StateError::InvalidState)?;
    let end = (start + Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Millis, true);
    let start_key = start.to_rfc3339_opts(SecondsFormat::Millis, true);
    let mut statement = tx.prepare(
        "SELECT event_json FROM usage_file_records
         WHERE agent = ?1 AND occurred_at >= ?2 AND occurred_at < ?3",
    )?;
    let stored = statement
        .query_map(params![agent.as_str(), start_key, end], |row| {
            row.get::<_, String>(0)
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    let mut events = Vec::with_capacity(stored.len());
    for value in &stored {
        events.push(serde_json::from_str::<NormalizedUsageEvent>(value)?);
    }
    let rows = crate::usage::aggregate_hour_rows(&events)
        .and_then(|rows| {
            crate::usage::fold_rows_into_other(rows, crate::usage::MAX_USAGE_ROWS_PER_HOUR)
        })
        .map_err(|_| StateError::InvalidState)?;
    let partial: i64 = tx.query_row(
        "SELECT COUNT(*) FROM usage_partial_sources WHERE agent = ?1 AND start_at = ?2",
        params![agent.as_str(), bucket_start_utc],
        |row| row.get(0),
    )?;
    let partial = partial > 0;
    // An hour whose facts came out the same is the same hour. Restamping it would spend a
    // scan version and send an upload that says nothing.
    let mut stored = tx.prepare(FACT_ROW_QUERY)?;
    let previous = stored
        .query_map(params![agent.as_str(), bucket_start_utc], read_fact_row)?
        .collect::<Result<Vec<_>, _>>()?;
    drop(stored);
    let previous_partial: Option<i64> = tx
        .query_row(
            "SELECT MAX(partial) FROM usage_hourly_facts WHERE agent = ?1 AND bucket_start_utc = ?2",
            params![agent.as_str(), bucket_start_utc],
            |row| row.get(0),
        )
        .optional()?
        .flatten();
    if previous == rows && previous_partial.map(|value| value != 0).unwrap_or(false) == partial {
        return Ok(false);
    }
    tx.execute(
        "DELETE FROM usage_hourly_facts WHERE agent = ?1 AND bucket_start_utc = ?2",
        params![agent.as_str(), bucket_start_utc],
    )?;
    for row in &rows {
        let source_cost = match &row.source_cost_microusd {
            Some(value) => Some(value.parse::<i64>().map_err(|_| StateError::InvalidState)?),
            None => None,
        };
        tx.execute(
            "INSERT INTO usage_hourly_facts(
                agent, bucket_start_utc, billing_channel, channel_source, model, context_bucket,
                service_tier, speed, inference_geo, input_tokens, cache_read_tokens,
                cache_write_5m_tokens, cache_write_1h_tokens, cache_write_inferred_tokens,
                output_tokens, reasoning_tokens, requests, web_search_requests,
                web_fetch_requests, source_cost_microusd, source_cost_covered_requests,
                partial, scan_version
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16,
                       ?17, ?18, ?19, ?20, ?21, ?22, ?23)",
            params![
                agent.as_str(),
                bucket_start_utc,
                row.billing_channel.as_str(),
                serde_json::to_value(row.channel_source)?
                    .as_str()
                    .unwrap_or_default(),
                row.model,
                row.context_bucket.as_str(),
                row.service_tier,
                row.speed,
                row.inference_geo,
                row.input_tokens as i64,
                row.cache_read_tokens as i64,
                row.cache_write_5m_tokens as i64,
                row.cache_write_1h_tokens as i64,
                row.cache_write_inferred_tokens as i64,
                row.output_tokens as i64,
                row.reasoning_tokens as i64,
                row.requests as i64,
                row.web_search_requests as i64,
                row.web_fetch_requests as i64,
                source_cost,
                row.source_cost_covered_requests as i64,
                i64::from(partial),
                scan_version as i64,
            ],
        )?;
    }
    tx.execute(
        "INSERT INTO usage_dirty_hours(agent, bucket_start_utc, scan_version, partial)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(agent, bucket_start_utc) DO UPDATE SET
            scan_version = excluded.scan_version,
            partial = excluded.partial",
        params![
            agent.as_str(),
            bucket_start_utc,
            scan_version as i64,
            i64::from(partial)
        ],
    )?;
    Ok(true)
}

fn source_record_key(source: &crate::usage::UsageSourceScan, record_index: usize) -> String {
    source
        .record_keys
        .get(record_index)
        .filter(|key| !key.is_empty())
        .cloned()
        .unwrap_or_else(|| format!("record:{record_index}"))
}

fn event_hour(value: &str) -> Result<String, StateError> {
    let instant = DateTime::parse_from_rfc3339(value).map_err(|_| StateError::InvalidState)?;
    Ok(floor_hour(instant).to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn mark_partial_source_hours_tx(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    source_file_id: &str,
    hours: Vec<String>,
) -> Result<(), StateError> {
    let mut hours = hours;
    hours.sort_unstable();
    hours.dedup();
    for hour in hours {
        let start = DateTime::parse_from_rfc3339(&hour).map_err(|_| StateError::InvalidState)?;
        let end = start + Duration::hours(1);
        tx.execute(
            "INSERT OR IGNORE INTO usage_partial_sources(
                agent, source_file_id, start_at, end_at
             ) VALUES (?1, ?2, ?3, ?4)",
            params![
                agent.as_str(),
                source_file_id,
                start.to_rfc3339_opts(SecondsFormat::Secs, true),
                end.to_rfc3339_opts(SecondsFormat::Secs, true),
            ],
        )?;
    }
    Ok(())
}

fn partial_source_hours_tx(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    source_file_id: &str,
) -> Result<Vec<String>, StateError> {
    let mut statement = tx.prepare(
        "SELECT start_at FROM usage_partial_sources
         WHERE agent = ?1 AND source_file_id = ?2 ORDER BY start_at",
    )?;
    let rows = statement.query_map(params![agent.as_str(), source_file_id], |row| row.get(0))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(StateError::from)
}

fn floor_hour(value: DateTime<chrono::FixedOffset>) -> DateTime<chrono::FixedOffset> {
    value
        .with_minute(0)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .unwrap_or(value)
}

impl ComponentRecord {
    fn empty(status: ComponentStatus) -> Self {
        Self {
            status,
            value: None,
            updated_at: None,
            last_error: None,
            refreshing: false,
        }
    }
}

fn read_component(
    conn: &Connection,
    name: ComponentName,
) -> Result<Option<ComponentRecord>, StateError> {
    conn.query_row(
        "SELECT status,value_json,updated_at,last_error_code,last_error_action,refreshing
         FROM components WHERE name = ?1",
        params![component_key(name)],
        |row| {
            let status: String = row.get(0)?;
            let value: Option<String> = row.get(1)?;
            let code: Option<String> = row.get(3)?;
            let action: Option<String> = row.get(4)?;
            let last_error = match (code, action) {
                (Some(code), Some(action)) => Some(IpcError::new(
                    parse_error_code(&code).ok_or_else(|| {
                        rusqlite::Error::InvalidColumnType(
                            3,
                            "last_error_code".to_owned(),
                            rusqlite::types::Type::Text,
                        )
                    })?,
                    parse_recovery_action(&action).ok_or_else(|| {
                        rusqlite::Error::InvalidColumnType(
                            4,
                            "last_error_action".to_owned(),
                            rusqlite::types::Type::Text,
                        )
                    })?,
                )),
                (None, None) => None,
                _ => {
                    return Err(rusqlite::Error::InvalidColumnType(
                        3,
                        "last_error".to_owned(),
                        rusqlite::types::Type::Text,
                    ));
                }
            };
            Ok(ComponentRecord {
                status: parse_status(&status).ok_or_else(|| {
                    rusqlite::Error::InvalidColumnType(
                        0,
                        "status".to_owned(),
                        rusqlite::types::Type::Text,
                    )
                })?,
                value: value
                    .map(|raw| serde_json::from_str(&raw))
                    .transpose()
                    .map_err(|_| {
                        rusqlite::Error::InvalidColumnType(
                            1,
                            "value_json".to_owned(),
                            rusqlite::types::Type::Text,
                        )
                    })?,
                updated_at: row.get(2)?,
                last_error,
                refreshing: row.get::<_, i64>(5)? != 0,
            })
        },
    )
    .optional()
    .map_err(StateError::from)
}

fn read_usage_periods(conn: &Connection) -> Result<UsagePeriodCache, StateError> {
    let mut statement = conn.prepare(
        "SELECT source, period, value_json FROM usage_period_cache ORDER BY source, period",
    )?;
    let rows = statement.query_map([], |row| {
        let source: String = row.get(0)?;
        let period: String = row.get(1)?;
        let raw: String = row.get(2)?;
        let source = parse_usage_source(&source).ok_or_else(|| {
            rusqlite::Error::InvalidColumnType(0, "source".to_owned(), rusqlite::types::Type::Text)
        })?;
        let period = parse_usage_period(&period).ok_or_else(|| {
            rusqlite::Error::InvalidColumnType(1, "period".to_owned(), rusqlite::types::Type::Text)
        })?;
        let value = serde_json::from_str(&raw).map_err(|_| {
            rusqlite::Error::InvalidColumnType(
                2,
                "value_json".to_owned(),
                rusqlite::types::Type::Text,
            )
        })?;
        Ok((source, period, value))
    })?;
    let mut cache = UsagePeriodCache::default();
    for row in rows {
        let (source, period, value) = row?;
        match source {
            UsageSource::Local => cache.local.set(period, value),
            UsageSource::Account => cache.account.set(period, value),
        }
    }
    Ok(cache)
}

/// The Overview rows the last refresh wrote, or none.
///
/// A row this build cannot read is answered the way [`read_component`] answers one: as a
/// statement about the image rather than about this query, so the cache is thrown away and
/// rebuilt. Returning the decode error instead left `get_state` failing on every call with
/// nothing able to clear it.
fn read_overview(conn: &Connection) -> Result<Vec<QuotaOverviewItem>, StateError> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT value FROM metadata WHERE key = 'overview_json'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let Some(raw) = raw else {
        return Ok(Vec::new());
    };
    serde_json::from_str(&raw).map_err(|_| {
        StateError::Sql(rusqlite::Error::InvalidColumnType(
            0,
            "overview_json".to_owned(),
            rusqlite::types::Type::Text,
        ))
    })
}

fn read_provider_views(root: &Path) -> Result<Vec<ProviderConfigView>, StateError> {
    let file = read_provider_file(root)?;
    Ok(file
        .providers
        .iter()
        .map(|(provider, secret)| ProviderConfigView {
            provider: provider.clone(),
            configured: !secret.api_key.is_empty(),
            masked_api_key: (!secret.api_key.is_empty()).then(|| {
                let label = crate::catalog::ProviderId::parse(provider)
                    .and_then(|id| {
                        id.metadata()
                            .credential_config
                            .map(|config| config.mask_label)
                    })
                    .unwrap_or("API");
                mask_api_key(label, &secret.api_key)
            }),
            base_url: secret.base_url.clone(),
        })
        .collect())
}

fn read_provider_browser_session_views(
    conn: &Connection,
) -> Result<Vec<ProviderBrowserSessionView>, StateError> {
    Ok(read_provider_browser_sessions(conn)?
        .into_iter()
        .map(|(provider, session)| ProviderBrowserSessionView {
            provider: provider.as_str().to_owned(),
            configured: true,
            account_fingerprint: Some(session.account_fingerprint),
            account_label: session.account_label,
        })
        .collect())
}

fn read_provider_browser_sessions(
    conn: &Connection,
) -> Result<Vec<(crate::catalog::ProviderId, ProviderBrowserSession)>, StateError> {
    let mut statement = conn.prepare(
        "SELECT provider, cookie_header, account_fingerprint, account_label
         FROM provider_browser_sessions ORDER BY provider",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
        ))
    })?;
    let mut sessions = Vec::new();
    for row in rows {
        let (provider, cookie_header, account_fingerprint, account_label) = row?;
        let session = validate_browser_session(
            &provider,
            ProviderBrowserSession {
                cookie_header,
                account_fingerprint,
                account_label,
            },
        )?;
        let id = crate::catalog::ProviderId::parse(&provider).ok_or(StateError::InvalidState)?;
        sessions.push((id, session));
    }
    Ok(sessions)
}

fn read_provider_file(root: &Path) -> Result<ProviderFile, StateError> {
    let path = root.join(PROVIDER_CONFIG_NAME);
    let mut options = OpenOptions::new();
    options.read(true).custom_flags(libc::O_NOFOLLOW);
    let file = match options.open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(ProviderFile {
                schema_version: 1,
                providers: BTreeMap::new(),
            });
        }
        Err(error) => return Err(error.into()),
    };
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o777 != 0o600 {
        return Err(StateError::InvalidState);
    }
    if metadata.len() > crate::protocol::MAXIMUM_LINE_BYTES as u64 {
        return Err(StateError::InvalidState);
    }
    let mut raw = Vec::with_capacity(metadata.len() as usize);
    file.take((crate::protocol::MAXIMUM_LINE_BYTES + 1) as u64)
        .read_to_end(&mut raw)?;
    if raw.len() > crate::protocol::MAXIMUM_LINE_BYTES {
        return Err(StateError::InvalidState);
    }
    let value: ProviderFile = serde_json::from_slice(&raw)?;
    if value.schema_version != 1 {
        return Err(StateError::ClientUpgradeRequired);
    }
    validate_provider_file(&value)?;
    Ok(value)
}

fn validate_provider_file(value: &ProviderFile) -> Result<(), StateError> {
    for (provider, secret) in &value.providers {
        let Some(id) = crate::catalog::ProviderId::parse(provider) else {
            return Err(StateError::InvalidState);
        };
        let Some(config) = id.metadata().credential_config else {
            return Err(StateError::InvalidState);
        };
        if secret.api_key.is_empty() || secret.api_key.len() > 2_048 {
            return Err(StateError::InvalidState);
        }
        if config.requires_base_url && secret.base_url.is_none() {
            return Err(StateError::InvalidState);
        }
        if !config.supports_base_url && secret.base_url.is_some() {
            return Err(StateError::InvalidState);
        }
        if let Some(base_url) = secret.base_url.as_deref() {
            validate_provider_base_url(base_url, config.allow_private_http)?;
        }
    }
    Ok(())
}

fn validate_provider_base_url(value: &str, allow_private_http: bool) -> Result<(), StateError> {
    let parsed = reqwest::Url::parse(value.trim()).map_err(|_| StateError::InvalidState)?;
    if parsed.username() != "" || parsed.password().is_some() || parsed.fragment().is_some() {
        return Err(StateError::InvalidState);
    }
    if parsed.scheme() == "https" {
        return Ok(());
    }
    let host = parsed.host_str().unwrap_or_default().trim_end_matches('.');
    let private = host == "localhost"
        || host.ends_with(".local")
        || host.parse::<std::net::IpAddr>().is_ok_and(|ip| match ip {
            std::net::IpAddr::V4(ip) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
            std::net::IpAddr::V6(ip) => {
                ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local()
            }
        });
    if allow_private_http && parsed.scheme() == "http" && private {
        return Ok(());
    }
    Err(StateError::InvalidState)
}

fn write_provider_file(root: &Path, value: &ProviderFile) -> Result<(), StateError> {
    validate_provider_file(value)?;
    ensure_owner_only_directory(root)?;
    let path = root.join(PROVIDER_CONFIG_NAME);
    let temporary = root.join(format!(".providers.{}.tmp", Uuid::new_v4()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    file.set_permissions(Permissions::from_mode(0o600))?;
    file.write_all(serde_json::to_string(value)?.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&temporary, &path)?;
    set_owner_permissions(&path)?;
    let _ = File::open(root).and_then(|directory| directory.sync_all());
    Ok(())
}

pub(super) fn metadata_u64(conn: &Connection, key: &str) -> Result<u64, StateError> {
    let raw: String = conn.query_row(
        "SELECT value FROM metadata WHERE key = ?1",
        params![key],
        |row| row.get(0),
    )?;
    raw.parse().map_err(|_| StateError::InvalidState)
}

pub(super) fn metadata_value(conn: &Connection, key: &str) -> Result<Option<String>, StateError> {
    conn.query_row(
        "SELECT value FROM metadata WHERE key = ?1",
        params![key],
        |row| row.get(0),
    )
    .optional()
    .map_err(StateError::from)
}

pub(super) fn metadata_flag(conn: &Connection, key: &str) -> Result<bool, StateError> {
    match metadata_value(conn, key)?.as_deref() {
        Some("1") => Ok(true),
        Some("0") | None => Ok(false),
        Some(_) => Err(StateError::InvalidState),
    }
}

pub(super) fn write_metadata_flag(
    conn: &Connection,
    key: &str,
    value: bool,
) -> Result<(), StateError> {
    conn.execute(
        "INSERT INTO metadata(key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, if value { "1" } else { "0" }],
    )?;
    Ok(())
}

pub(super) fn bump_revision(conn: &Connection) -> Result<u64, StateError> {
    let current = metadata_u64(conn, "revision")?;
    let next = current.checked_add(1).ok_or(StateError::InvalidState)?;
    conn.execute(
        "UPDATE metadata SET value = ?1 WHERE key = 'revision'",
        params![next.to_string()],
    )?;
    Ok(next)
}

fn component_key(value: ComponentName) -> &'static str {
    match value {
        ComponentName::Quota => "quota",
        ComponentName::Usage => "usage",
        ComponentName::Account => "account",
        ComponentName::Pricing => "pricing",
        ComponentName::Providers => "providers",
    }
}

fn usage_source_key(value: UsageSource) -> &'static str {
    match value {
        UsageSource::Local => "local",
        UsageSource::Account => "account",
    }
}

fn parse_usage_source(value: &str) -> Option<UsageSource> {
    match value {
        "local" => Some(UsageSource::Local),
        "account" => Some(UsageSource::Account),
        _ => None,
    }
}

fn usage_period_key(value: UsagePeriod) -> &'static str {
    match value {
        UsagePeriod::Today => "today",
        UsagePeriod::Last7Days => "last_7_days",
        UsagePeriod::Last30Days => "last_30_days",
        UsagePeriod::All => "all",
    }
}

fn parse_usage_period(value: &str) -> Option<UsagePeriod> {
    match value {
        "today" => Some(UsagePeriod::Today),
        "last_7_days" => Some(UsagePeriod::Last7Days),
        "last_30_days" => Some(UsagePeriod::Last30Days),
        "all" => Some(UsagePeriod::All),
        _ => None,
    }
}

fn status_key(value: ComponentStatus) -> &'static str {
    match value {
        ComponentStatus::Ready => "ready",
        ComponentStatus::Stale => "stale",
        ComponentStatus::AuthRequired => "auth_required",
        ComponentStatus::Unavailable => "unavailable",
        ComponentStatus::Unsupported => "unsupported",
        ComponentStatus::Error => "error",
        ComponentStatus::SignedOut => "signed_out",
    }
}

fn parse_status(value: &str) -> Option<ComponentStatus> {
    Some(match value {
        "ready" => ComponentStatus::Ready,
        "stale" => ComponentStatus::Stale,
        "auth_required" => ComponentStatus::AuthRequired,
        "unavailable" => ComponentStatus::Unavailable,
        "unsupported" => ComponentStatus::Unsupported,
        "error" => ComponentStatus::Error,
        "signed_out" => ComponentStatus::SignedOut,
        _ => return None,
    })
}

fn error_code_key(value: ErrorCode) -> &'static str {
    match value {
        ErrorCode::InvalidRequest => "invalid_request",
        ErrorCode::UnsupportedOperation => "unsupported_operation",
        ErrorCode::InvalidState => "invalid_state",
        ErrorCode::ClientUpgradeRequired => "client_upgrade_required",
        ErrorCode::Busy => "busy",
        ErrorCode::Cancelled => "cancelled",
        ErrorCode::AuthenticationRequired => "authentication_required",
        ErrorCode::DeviceDeleted => "device_deleted",
        ErrorCode::StaleGeneration => "stale_generation",
        ErrorCode::Unavailable => "unavailable",
        ErrorCode::ProviderError => "provider_error",
        ErrorCode::NetworkError => "network_error",
        ErrorCode::InvalidResponse => "invalid_response",
        ErrorCode::Internal => "internal",
    }
}

fn parse_error_code(value: &str) -> Option<ErrorCode> {
    Some(match value {
        "invalid_request" => ErrorCode::InvalidRequest,
        "unsupported_operation" => ErrorCode::UnsupportedOperation,
        "invalid_state" => ErrorCode::InvalidState,
        "client_upgrade_required" => ErrorCode::ClientUpgradeRequired,
        "busy" => ErrorCode::Busy,
        "cancelled" => ErrorCode::Cancelled,
        "authentication_required" => ErrorCode::AuthenticationRequired,
        "device_deleted" => ErrorCode::DeviceDeleted,
        "stale_generation" => ErrorCode::StaleGeneration,
        "unavailable" => ErrorCode::Unavailable,
        "provider_error" => ErrorCode::ProviderError,
        "network_error" => ErrorCode::NetworkError,
        "invalid_response" => ErrorCode::InvalidResponse,
        "internal" => ErrorCode::Internal,
        _ => return None,
    })
}

fn recovery_key(value: RecoveryAction) -> &'static str {
    match value {
        RecoveryAction::None => "none",
        RecoveryAction::Retry => "retry",
        RecoveryAction::Login => "login",
        RecoveryAction::ConfigureProvider => "configure_provider",
        RecoveryAction::Upgrade => "upgrade",
        RecoveryAction::Reinstall => "reinstall",
    }
}

fn parse_recovery_action(value: &str) -> Option<RecoveryAction> {
    Some(match value {
        "none" => RecoveryAction::None,
        "retry" => RecoveryAction::Retry,
        "login" => RecoveryAction::Login,
        "configure_provider" => RecoveryAction::ConfigureProvider,
        "upgrade" => RecoveryAction::Upgrade,
        "reinstall" => RecoveryAction::Reinstall,
        _ => return None,
    })
}

fn mask_api_key(label: &str, value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() <= 8 {
        return format!("{label} key");
    }
    let suffix: String = trimmed
        .chars()
        .rev()
        .take(4)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    format!("{label} ···{suffix}")
}

fn ensure_owner_only_directory(path: &Path) -> Result<(), StateError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(StateError::InvalidState);
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(path)?;
        }
        Err(error) => return Err(error.into()),
    }
    set_owner_permissions(path)?;
    Ok(())
}

/// Opens `identity.sqlite`, starting this device over if it cannot be read.
///
/// There is no salvage: a partially readable identity is a device that could claim to be one
/// installation while owing an Account work under another. A fresh installation id and a signed-out
/// device is the smaller loss, and it is one the person in front of the app can undo by signing in.
fn open_identity(root: &Path) -> Result<Connection, StateError> {
    let path = root.join(IDENTITY_NAME);
    let existed = fs::symlink_metadata(&path).is_ok_and(|value| value.is_file() && value.len() > 0);
    let opened = match open_identity_image(&path) {
        Ok(conn) => conn,
        Err(error) if sqlite_io_or_full_error(&error) => return Err(StateError::Unavailable),
        Err(StateError::ClientUpgradeRequired) => return Err(StateError::ClientUpgradeRequired),
        Err(_) => {
            remove_sqlite_image(&path);
            let conn = open_identity_image(&path)?;
            write_preference(&conn, IDENTITY_RESET_KEY, &now_rfc3339())?;
            return Ok(conn);
        }
    };
    if existed {
        return Ok(opened);
    }
    let mut opened = opened;
    if legacy_import::take(root, &mut opened) == LegacyImport::Unreadable {
        write_preference(&opened, IDENTITY_RESET_KEY, &now_rfc3339())?;
    }
    Ok(opened)
}

/// Folds the identity log back into the image. Every write transaction ends this way, including
/// the ones that build the schema, so a crash never leaves a log this device has to replay.
fn checkpoint(conn: &Connection) {
    let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
}

fn open_identity_image(path: &Path) -> Result<Connection, StateError> {
    create_owner_only_file_if_missing(path)?;
    let mut connection = open_writable_connection(path)?;
    crate::migration::identity::apply(&mut connection)?;
    // The one row that makes this an identity at all.  Its absence is the same answer as a file
    // SQLite refuses to read: this device does not know who it is.
    let _: String = connection.query_row(
        "SELECT installation_id FROM installation WHERE id = 1",
        [],
        |row| row.get(0),
    )?;
    Ok(connection)
}

/// Opens `cache.sqlite`, replacing it with an empty one if it cannot be read.
///
/// Returns whether the file had to be replaced. `revision_seed` only applies to a schema this
/// call creates.
fn open_cache(root: &Path, revision_seed: u64) -> Result<(Connection, bool), StateError> {
    let path = root.join(CACHE_NAME);
    let existed = fs::symlink_metadata(&path).is_ok_and(|value| value.is_file() && value.len() > 0);
    match open_cache_image(&path, revision_seed) {
        Ok(connection) => Ok((connection, false)),
        Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
        Err(_) => {
            remove_sqlite_image(&path);
            let seed = revision_seed.max(unix_seconds());
            Ok((open_cache_image(&path, seed)?, existed))
        }
    }
}

fn open_cache_image(path: &Path, revision_seed: u64) -> Result<Connection, StateError> {
    create_owner_only_file_if_missing(path)?;
    let mut connection = open_writable_connection(path)?;
    crate::migration::cache::apply(&mut connection, revision_seed)?;
    metadata_u64(&connection, "revision")?;
    reclaim_unused_pages(&connection)?;
    Ok(connection)
}

fn open_writable_connection(path: &Path) -> Result<Connection, StateError> {
    let connection =
        Connection::open_with_flags(path, OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    connection.execute_batch(&format!(
        "PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = {BUSY_TIMEOUT_MS};
         PRAGMA journal_mode = WAL;"
    ))?;
    connection.pragma_update(None, "journal_size_limit", MAXIMUM_WAL_BYTES)?;
    Ok(connection)
}

/// Returns free pages to the filesystem, converting the image to incremental reclaim the first
/// time so later deletes cost a truncation rather than a full rewrite.
///
/// The full rewrite runs only for an image that predates the conversion and has already grown past
/// the threshold, so it happens once, and it is the price of never paying it again: measured at
/// 3.2s on a 411MB image holding 193MB of free pages, against 1.9s for the incremental pass that
/// replaces it.  Neither step is required for correctness, and an image that cannot be compacted
/// right now is left exactly as it is.
fn reclaim_unused_pages(conn: &Connection) -> Result<(), StateError> {
    let free_bytes = conn.query_row(
        "SELECT (SELECT * FROM pragma_freelist_count()) * (SELECT * FROM pragma_page_size())",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    let incremental = conn.query_row("PRAGMA auto_vacuum", [], |row| row.get::<_, i64>(0))? == 2;
    if incremental {
        // Each step of this pragma moves one page, so it has to be run to completion rather than
        // executed once.
        if let Ok(mut statement) = conn.prepare("PRAGMA incremental_vacuum")
            && let Ok(mut rows) = statement.query([])
        {
            while matches!(rows.next(), Ok(Some(_))) {}
        }
    } else if free_bytes >= COMPACT_FREE_BYTES {
        let _ = conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;");
    }
    let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    Ok(())
}

fn create_owner_only_file_if_missing(path: &Path) -> Result<(), StateError> {
    match OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => {
            if !file.metadata()?.is_file() {
                return Err(StateError::InvalidState);
            }
            file.set_permissions(Permissions::from_mode(0o600))?;
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            set_owner_permissions(path)
        }
        Err(error) => Err(error.into()),
    }
}

/// How long a connection waits behind another writer before answering busy.
///
/// Shortened under test so the case proving that a busy image is not a damaged one does not
/// spend the whole wait proving it.
const BUSY_TIMEOUT_MS: u64 = if cfg!(test) { 100 } else { 5_000 };

fn remove_sqlite_image(path: &Path) {
    let _ = fs::remove_file(path);
    for suffix in ["-wal", "-shm"] {
        let mut raw = path.as_os_str().to_os_string();
        raw.push(suffix);
        let _ = fs::remove_file(PathBuf::from(raw));
    }
}

/// A cache error the service answers by throwing the file away.
///
/// Contention, a machine that cannot write right now, and a statement this build got wrong are
/// not the file's fault, so they are reported as they are. A read-only image, a refused
/// permission, an allocation that failed, a row over a limit, and a violated constraint all say
/// something about this moment or about what was being written, never that the bytes on disk
/// stopped describing what this device collected. Everything else does mean exactly that.
fn cache_needs_rebuild(error: &StateError) -> bool {
    match error {
        StateError::Sql(rusqlite::Error::SqliteFailure(code, _)) => !matches!(
            code.code,
            SqliteErrorCode::DatabaseBusy
                | SqliteErrorCode::DatabaseLocked
                | SqliteErrorCode::DiskFull
                | SqliteErrorCode::SystemIoFailure
                | SqliteErrorCode::CannotOpen
                | SqliteErrorCode::OperationInterrupted
                | SqliteErrorCode::ReadOnly
                | SqliteErrorCode::OutOfMemory
                | SqliteErrorCode::PermissionDenied
                | SqliteErrorCode::TooBig
                | SqliteErrorCode::ConstraintViolation
        ),
        // The image no longer holds the shape this build reads: a column of the wrong type or
        // name, or a statement SQLite will not prepare against it.
        StateError::Sql(
            rusqlite::Error::InvalidColumnType(..)
            | rusqlite::Error::InvalidColumnName(_)
            | rusqlite::Error::InvalidQuery
            | rusqlite::Error::SqlInputError { .. },
        ) => true,
        // A row that is simply not there, and a value this build could not convert, are answers
        // about one query. They are not a verdict on the file.
        StateError::Sql(_) => false,
        _ => false,
    }
}

/// A failure that is about this machine right now rather than about the image.
///
/// Contention is the reason `DatabaseBusy` and `DatabaseLocked` are here: a second helper
/// holding the write lock is not a damaged file, and deleting one because another process was
/// mid-write is how a working device loses its cache.  The caller retries instead.
fn sqlite_io_or_full_error(error: &StateError) -> bool {
    match error {
        StateError::Io(_) => true,
        StateError::Sql(rusqlite::Error::SqliteFailure(code, _)) => matches!(
            code.code,
            SqliteErrorCode::DatabaseBusy
                | SqliteErrorCode::DatabaseLocked
                | SqliteErrorCode::DiskFull
                | SqliteErrorCode::SystemIoFailure
                | SqliteErrorCode::CannotOpen
        ),
        _ => false,
    }
}

/// Waits a request's worth of time for a connection and no longer.  A reader that blocks behind a
/// refresh is a panel that never opens.
fn lock_with_deadline(lock: &Mutex<Connection>) -> Result<MutexGuard<'_, Connection>, StateError> {
    let deadline = Instant::now() + std::time::Duration::from_millis(150);
    loop {
        match lock.try_lock() {
            Ok(conn) => return Ok(conn),
            Err(TryLockError::Poisoned(_)) => return Err(StateError::Unavailable),
            Err(TryLockError::WouldBlock) => {
                if Instant::now() >= deadline {
                    return Err(StateError::Unavailable);
                }
                thread::sleep(std::time::Duration::from_millis(10));
            }
        }
    }
}

fn preference(conn: &Connection, key: &str) -> Result<Option<String>, StateError> {
    conn.query_row(
        "SELECT value FROM preferences WHERE key = ?1",
        params![key],
        |row| row.get(0),
    )
    .optional()
    .map_err(StateError::from)
}

fn write_preference(conn: &Connection, key: &str, value: &str) -> Result<(), StateError> {
    conn.execute(
        "INSERT INTO preferences(key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn prune_diagnostic_attempts(tx: &Transaction<'_>) -> Result<(), StateError> {
    let cutoff = (chrono::Utc::now() - Duration::days(DIAGNOSTIC_ATTEMPT_RETENTION_DAYS))
        .to_rfc3339_opts(SecondsFormat::Secs, true);
    tx.execute(
        "DELETE FROM diagnostic_attempts WHERE outcome IS NOT NULL AND started_at < ?1",
        [cutoff],
    )?;
    tx.execute(
        "DELETE FROM diagnostic_attempts WHERE id IN (
           SELECT id FROM diagnostic_attempts WHERE outcome IS NOT NULL
           ORDER BY id DESC LIMIT -1 OFFSET ?1
         )",
        [MAX_DIAGNOSTIC_ATTEMPTS],
    )?;
    Ok(())
}

/// A journal write that failed is counted on stderr and nowhere else. The work it was recording
/// has already happened, or is about to, and neither depends on the row landing.
fn report_journal_write_failure(error: &StateError) {
    let kind = match error {
        StateError::Unavailable => "unavailable",
        StateError::InvalidState => "invalid_state",
        StateError::ClientUpgradeRequired => "client_upgrade_required",
        _ => "error",
    };
    eprintln!("quota-service: diagnostic attempt journal write skipped ({kind})");
}

fn diagnostic_attempt_from_row(
    row: &rusqlite::Row<'_>,
) -> Result<DiagnosticAttempt, rusqlite::Error> {
    let kind = parse_diagnostic_attempt_kind(&row.get::<_, String>(0)?)?;
    let subject = row.get::<_, Option<String>>(1)?;
    if subject
        .as_deref()
        .is_some_and(|value| !valid_diagnostic_subject(value))
    {
        return Err(invalid_diagnostic_column(1, "subject"));
    }
    let started_at = row.get::<_, String>(2)?;
    if DateTime::parse_from_rfc3339(&started_at).is_err() {
        return Err(invalid_diagnostic_column(2, "started_at"));
    }
    let duration_ms = row
        .get::<_, Option<i64>>(3)?
        .map(|value| {
            u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(3, value))
        })
        .transpose()?;
    let outcome = match row.get::<_, Option<String>>(4)? {
        Some(value) => parse_diagnostic_attempt_outcome(&value)?,
        None => DiagnosticAttemptOutcome::Running,
    };
    let code = row
        .get::<_, Option<String>>(5)?
        .map(|value| parse_diagnostic_attempt_code(&value))
        .transpose()?;
    if (outcome == DiagnosticAttemptOutcome::Running) != duration_ms.is_none() {
        return Err(invalid_diagnostic_column(4, "outcome"));
    }
    Ok(DiagnosticAttempt {
        kind,
        subject,
        started_at,
        duration_ms,
        outcome,
        code,
    })
}

/// `(completed_at or started_at, outcome, code)` for a finished attempt.
fn diagnostic_attempt_outcome_row(
    row: &rusqlite::Row<'_>,
) -> Result<
    (
        String,
        DiagnosticAttemptOutcome,
        Option<DiagnosticAttemptCode>,
    ),
    rusqlite::Error,
> {
    let at = row
        .get::<_, Option<String>>(0)?
        .unwrap_or(row.get::<_, String>(1)?);
    let outcome = parse_diagnostic_attempt_outcome(&row.get::<_, String>(2)?)?;
    let code = row
        .get::<_, Option<String>>(3)?
        .map(|value| parse_diagnostic_attempt_code(&value))
        .transpose()?;
    Ok((at, outcome, code))
}

fn valid_diagnostic_subject(value: &str) -> bool {
    let identity = value
        .strip_prefix("provider:")
        .or_else(|| value.strip_prefix("agent:"));
    identity.is_some_and(|identity| {
        !identity.is_empty()
            && value.len() <= 96
            && identity
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    })
}

fn invalid_diagnostic_column(index: usize, value: &str) -> rusqlite::Error {
    rusqlite::Error::InvalidColumnType(index, value.into(), rusqlite::types::Type::Text)
}

fn diagnostic_attempt_kind_key(value: DiagnosticAttemptKind) -> &'static str {
    match value {
        DiagnosticAttemptKind::Refresh => "refresh",
        DiagnosticAttemptKind::QuotaCollection => "quota_collection",
        DiagnosticAttemptKind::UsageScan => "usage_scan",
        DiagnosticAttemptKind::UsageUpload => "usage_upload",
        DiagnosticAttemptKind::AccountSync => "account_sync",
        DiagnosticAttemptKind::PricingRefresh => "pricing_refresh",
    }
}

fn parse_diagnostic_attempt_kind(value: &str) -> Result<DiagnosticAttemptKind, rusqlite::Error> {
    match value {
        "refresh" => Ok(DiagnosticAttemptKind::Refresh),
        "quota_collection" => Ok(DiagnosticAttemptKind::QuotaCollection),
        "usage_scan" => Ok(DiagnosticAttemptKind::UsageScan),
        "usage_upload" => Ok(DiagnosticAttemptKind::UsageUpload),
        "account_sync" => Ok(DiagnosticAttemptKind::AccountSync),
        "pricing_refresh" => Ok(DiagnosticAttemptKind::PricingRefresh),
        _ => Err(invalid_diagnostic_column(0, value)),
    }
}

fn diagnostic_attempt_trigger_key(value: DiagnosticAttemptTrigger) -> &'static str {
    match value {
        DiagnosticAttemptTrigger::Manual => "manual",
        DiagnosticAttemptTrigger::Scheduled => "scheduled",
        DiagnosticAttemptTrigger::Startup => "startup",
        DiagnosticAttemptTrigger::Recheck => "recheck",
        DiagnosticAttemptTrigger::SettingsChange => "settings_change",
        DiagnosticAttemptTrigger::AccountChange => "account_change",
    }
}

fn parse_diagnostic_attempt_trigger(
    value: &str,
) -> Result<DiagnosticAttemptTrigger, rusqlite::Error> {
    match value {
        "manual" => Ok(DiagnosticAttemptTrigger::Manual),
        "scheduled" => Ok(DiagnosticAttemptTrigger::Scheduled),
        "startup" => Ok(DiagnosticAttemptTrigger::Startup),
        "recheck" => Ok(DiagnosticAttemptTrigger::Recheck),
        "settings_change" => Ok(DiagnosticAttemptTrigger::SettingsChange),
        "account_change" => Ok(DiagnosticAttemptTrigger::AccountChange),
        _ => Err(invalid_diagnostic_column(1, value)),
    }
}

fn diagnostic_attempt_outcome_key(value: DiagnosticAttemptOutcome) -> &'static str {
    match value {
        DiagnosticAttemptOutcome::Running => "running",
        DiagnosticAttemptOutcome::Success => "success",
        DiagnosticAttemptOutcome::Partial => "partial",
        DiagnosticAttemptOutcome::NoWork => "no_work",
        DiagnosticAttemptOutcome::Failed => "failed",
        DiagnosticAttemptOutcome::Interrupted => "interrupted",
        DiagnosticAttemptOutcome::Cancelled => "cancelled",
    }
}

fn parse_diagnostic_attempt_outcome(
    value: &str,
) -> Result<DiagnosticAttemptOutcome, rusqlite::Error> {
    match value {
        "success" => Ok(DiagnosticAttemptOutcome::Success),
        "partial" => Ok(DiagnosticAttemptOutcome::Partial),
        "no_work" => Ok(DiagnosticAttemptOutcome::NoWork),
        "failed" => Ok(DiagnosticAttemptOutcome::Failed),
        "interrupted" => Ok(DiagnosticAttemptOutcome::Interrupted),
        "cancelled" => Ok(DiagnosticAttemptOutcome::Cancelled),
        _ => Err(invalid_diagnostic_column(8, value)),
    }
}

fn diagnostic_attempt_code_key(value: DiagnosticAttemptCode) -> &'static str {
    match value {
        DiagnosticAttemptCode::ProcessInterrupted => "process_interrupted",
        DiagnosticAttemptCode::Cancelled => "cancelled",
        DiagnosticAttemptCode::NoWork => "no_work",
        DiagnosticAttemptCode::AuthenticationRequired => "authentication_required",
        DiagnosticAttemptCode::NetworkError => "network_error",
        DiagnosticAttemptCode::Unavailable => "unavailable",
        DiagnosticAttemptCode::InvalidResponse => "invalid_response",
        DiagnosticAttemptCode::InvalidState => "invalid_state",
        DiagnosticAttemptCode::AccessDenied => "access_denied",
        DiagnosticAttemptCode::ClientUpgradeRequired => "client_upgrade_required",
        DiagnosticAttemptCode::ProviderError => "provider_error",
        DiagnosticAttemptCode::PartialSource => "partial_source",
        DiagnosticAttemptCode::MalformedData => "malformed_data",
        DiagnosticAttemptCode::TruncatedActiveSource => "truncated_active_source",
        DiagnosticAttemptCode::DeviceDeleted => "device_deleted",
        DiagnosticAttemptCode::UploadDisabled => "upload_disabled",
        DiagnosticAttemptCode::SignedOut => "signed_out",
    }
}

fn parse_diagnostic_attempt_code(value: &str) -> Result<DiagnosticAttemptCode, rusqlite::Error> {
    match value {
        "process_interrupted" => Ok(DiagnosticAttemptCode::ProcessInterrupted),
        "cancelled" => Ok(DiagnosticAttemptCode::Cancelled),
        "no_work" => Ok(DiagnosticAttemptCode::NoWork),
        "authentication_required" => Ok(DiagnosticAttemptCode::AuthenticationRequired),
        "network_error" => Ok(DiagnosticAttemptCode::NetworkError),
        "unavailable" => Ok(DiagnosticAttemptCode::Unavailable),
        "invalid_response" => Ok(DiagnosticAttemptCode::InvalidResponse),
        "invalid_state" => Ok(DiagnosticAttemptCode::InvalidState),
        "access_denied" => Ok(DiagnosticAttemptCode::AccessDenied),
        "client_upgrade_required" => Ok(DiagnosticAttemptCode::ClientUpgradeRequired),
        "provider_error" => Ok(DiagnosticAttemptCode::ProviderError),
        "partial_source" => Ok(DiagnosticAttemptCode::PartialSource),
        "malformed_data" => Ok(DiagnosticAttemptCode::MalformedData),
        "truncated_active_source" => Ok(DiagnosticAttemptCode::TruncatedActiveSource),
        "device_deleted" => Ok(DiagnosticAttemptCode::DeviceDeleted),
        "upload_disabled" => Ok(DiagnosticAttemptCode::UploadDisabled),
        "signed_out" => Ok(DiagnosticAttemptCode::SignedOut),
        _ => Err(invalid_diagnostic_column(9, value)),
    }
}

fn set_owner_permissions(path: &Path) -> Result<(), StateError> {
    #[cfg(unix)]
    {
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() {
            return Err(StateError::InvalidState);
        }
        let mode = if metadata.is_dir() { 0o700 } else { 0o600 };
        fs::set_permissions(path, Permissions::from_mode(mode))?;
    }
    Ok(())
}

pub fn now_rfc3339() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let days = seconds.div_euclid(86_400);
    let day_seconds = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = day_seconds / 3_600;
    let minute = (day_seconds % 3_600) / 60;
    let second = day_seconds % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

// Howard Hinnant's civil-from-days conversion; this avoids another date dependency in the service.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::{
        BillableTools, BillingChannel, ChannelSource, ContextBucket, CoverageStatus,
        LocalUsageFile, NormalizedUsageEvent, ScanCoverage, UsageSourceScan,
    };

    #[test]
    fn timestamp_is_canonical() {
        let value = now_rfc3339();
        assert!(value.ends_with('Z'));
        assert_eq!(value.len(), 20);
    }

    #[test]
    fn diagnostic_attempts_recover_running_and_keep_canonical_success_facts() {
        let root = std::env::temp_dir().join(format!("quota-attempts-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        assert!(
            store
                .begin_diagnostic_attempt(
                    DiagnosticAttemptKind::UsageScan,
                    DiagnosticAttemptTrigger::Scheduled,
                    Some("agent:/Users/private"),
                    None,
                )
                .is_none()
        );
        let account = store.begin_diagnostic_attempt(
            DiagnosticAttemptKind::AccountSync,
            DiagnosticAttemptTrigger::Startup,
            None,
            None,
        );
        assert!(account.is_some());
        store.finish_diagnostic_attempt(
            account,
            &DiagnosticAttemptCompletion::new(DiagnosticAttemptOutcome::Success, None),
        );
        let failed = store.begin_diagnostic_attempt(
            DiagnosticAttemptKind::UsageUpload,
            DiagnosticAttemptTrigger::Scheduled,
            None,
            None,
        );
        store.finish_diagnostic_attempt(
            failed,
            &DiagnosticAttemptCompletion::new(
                DiagnosticAttemptOutcome::Failed,
                Some(DiagnosticAttemptCode::NetworkError),
            ),
        );

        let facts = store
            .diagnostic_attempt_facts(DiagnosticAttemptKind::AccountSync, None)
            .expect("facts");
        assert!(facts.last_success_at.is_some());
        assert_eq!(facts.unresolved_code, None);
        let upload = store
            .diagnostic_attempt_facts(DiagnosticAttemptKind::UsageUpload, None)
            .expect("upload facts");
        assert_eq!(upload.last_success_at, None);
        assert_eq!(
            upload.unresolved_code,
            Some(DiagnosticAttemptCode::NetworkError)
        );

        store.begin_diagnostic_attempt(
            DiagnosticAttemptKind::Refresh,
            DiagnosticAttemptTrigger::Manual,
            None,
            None,
        );
        drop(store);

        let reopened = StateStore::open(&root).expect("reopen");
        let recent = reopened
            .diagnostic_recent_attempts()
            .expect("recovered activity");
        assert!(recent.iter().any(|attempt| {
            attempt.kind == DiagnosticAttemptKind::Refresh
                && attempt.outcome == DiagnosticAttemptOutcome::Interrupted
                && attempt.code == Some(DiagnosticAttemptCode::ProcessInterrupted)
        }));
        assert!(
            reopened
                .running_refresh_attempt()
                .expect("running")
                .is_none()
        );
        let conn = reopened.cache.lock().expect("database");
        conn.execute("PRAGMA ignore_check_constraints = ON", [])
            .expect("test corruption mode");
        conn.execute(
            "INSERT INTO diagnostic_attempts(
                   kind, trigger, subject, started_at, completed_at, duration_ms, outcome, code
                 ) VALUES ('usage_scan','scheduled','agent:/Users/private',?1,?1,0,'failed',
                   'malformed_data')",
            [now_rfc3339()],
        )
        .expect("corrupt unsafe subject");
        conn.execute("PRAGMA ignore_check_constraints = OFF", [])
            .expect("restore constraints");
        drop(conn);
        assert!(reopened.diagnostic_recent_attempts().is_err());
        drop(reopened);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_journal_this_device_cannot_write_never_blocks_the_work_it_describes() {
        let root = std::env::temp_dir().join(format!("quota-journal-ro-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        // A cache that refuses the insert is the machine, not the file: the store answers with
        // no handle and the caller carries on.
        {
            let conn = store.cache.lock().expect("database");
            conn.execute("DROP TABLE diagnostic_attempts", [])
                .expect("remove the journal");
        }
        assert!(
            store
                .begin_diagnostic_attempt(
                    DiagnosticAttemptKind::QuotaCollection,
                    DiagnosticAttemptTrigger::Manual,
                    Some("provider:codex"),
                    None,
                )
                .is_none()
        );
        store.finish_diagnostic_attempt(
            None,
            &DiagnosticAttemptCompletion::new(DiagnosticAttemptOutcome::Success, None),
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn diagnostic_retention_keeps_running_rows_and_detaches_children() {
        let root = std::env::temp_dir().join(format!("quota-attempt-cap-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let old = (chrono::Utc::now() - Duration::days(DIAGNOSTIC_ATTEMPT_RETENTION_DAYS + 1))
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        let current = now_rfc3339();
        let child_id;
        {
            let conn = store.cache.lock().expect("database");
            conn.execute(
                "INSERT INTO diagnostic_attempts(
                   kind, trigger, subject, started_at, completed_at, duration_ms, outcome, code
                 ) VALUES ('refresh','scheduled',NULL,?1,?1,0,'success',NULL)",
                [&old],
            )
            .expect("old parent");
            let parent_id = conn.last_insert_rowid();
            conn.execute(
                "INSERT INTO diagnostic_attempts(
                   kind, trigger, subject, started_at, completed_at, duration_ms, outcome, code
                 ) VALUES ('refresh','manual',NULL,?1,NULL,NULL,NULL,NULL)",
                [&old],
            )
            .expect("old running");
            conn.execute(
                "WITH RECURSIVE counter(value) AS (
                   VALUES(1) UNION ALL SELECT value + 1 FROM counter WHERE value < 5001
                 )
                 INSERT INTO diagnostic_attempts(
                   kind, trigger, subject, started_at, completed_at, duration_ms, outcome, code
                 ) SELECT 'quota_collection','scheduled','provider:codex',?1,?1,0,'success',NULL
                 FROM counter",
                [&current],
            )
            .expect("bounded history seed");
            conn.execute(
                "INSERT INTO diagnostic_attempts(
                   parent_refresh_id, kind, trigger, subject, started_at,
                   completed_at, duration_ms, outcome, code
                 ) VALUES (?1,'pricing_refresh','scheduled',NULL,?2,?2,0,'success',NULL)",
                params![parent_id, current],
            )
            .expect("current child");
            child_id = conn.last_insert_rowid();
        }

        // Retention runs at open and hourly, so an insert only prunes once the clock says so.
        store.last_attempt_prune.store(0, Ordering::Release);
        store.begin_diagnostic_attempt(
            DiagnosticAttemptKind::Refresh,
            DiagnosticAttemptTrigger::Scheduled,
            None,
            None,
        );
        let conn = store.cache.lock().expect("database");
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM diagnostic_attempts WHERE outcome IS NOT NULL",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("completed count"),
            MAX_DIAGNOSTIC_ATTEMPTS
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM diagnostic_attempts WHERE outcome IS NULL",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("running count"),
            2
        );
        assert_eq!(
            conn.query_row(
                "SELECT parent_refresh_id FROM diagnostic_attempts WHERE id = ?1",
                [child_id],
                |row| row.get::<_, Option<i64>>(0),
            )
            .expect("detached child"),
            None
        );
        drop(conn);
        assert!(
            store.diagnostic_recent_attempts().expect("recent").len() <= MAXIMUM_DIAGNOSTIC_RECENT
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn lock_is_exclusive() {
        let root = std::env::temp_dir().join(format!("quota-state-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let first = OwnerLock::acquire(&root).expect("first lock");
        assert!(matches!(
            OwnerLock::acquire(&root),
            Err(StateError::Unavailable)
        ));
        drop(first);
        let second = OwnerLock::acquire(&root).expect("released lock");
        drop(second);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn browser_session_replace_remove_and_wire_redaction_are_atomic() {
        let root = std::env::temp_dir().join(format!("quota-browser-session-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let original = ProviderBrowserSession {
            cookie_header: "wos-session=first-secret".into(),
            account_fingerprint: "a".repeat(64),
            account_label: Some("ad***@example.com".into()),
        };
        store
            .set_provider_browser_session("cursor", &original)
            .expect("store session");
        let snapshot = serde_json::to_string(&store.snapshot().expect("snapshot")).expect("wire");
        assert!(!snapshot.contains("first-secret"));
        assert!(!snapshot.contains("cookie_header"));
        assert!(snapshot.contains("ad***@example.com"));

        let invalid = ProviderBrowserSession {
            cookie_header: "wos-session=bad value".into(),
            account_fingerprint: "b".repeat(64),
            account_label: None,
        };
        assert!(
            store
                .set_provider_browser_session("cursor", &invalid)
                .is_err()
        );
        assert_eq!(
            store
                .provider_browser_session("cursor")
                .expect("read")
                .expect("retained"),
            original
        );

        store
            .remove_provider_browser_session("cursor")
            .expect("remove");
        assert!(
            store
                .provider_browser_session("cursor")
                .expect("read")
                .is_none()
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn malformed_browser_session_rows_fail_closed() {
        let root = std::env::temp_dir().join(format!("quota-browser-invalid-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        {
            let conn = store.identity.lock().expect("db");
            conn.execute(
                "INSERT INTO provider_browser_sessions(
                    provider, cookie_header, account_fingerprint, account_label, updated_at
                 ) VALUES ('cursor', 'wos-session=secret', 'raw-user-id', 'raw@example.com', ?1)",
                [now_rfc3339()],
            )
            .expect("invalid row");
        }
        assert!(matches!(store.snapshot(), Err(StateError::InvalidState)));
        assert!(matches!(
            store.provider_browser_session("cursor"),
            Err(StateError::InvalidState)
        ));

        {
            let conn = store.identity.lock().expect("db");
            conn.execute("DELETE FROM provider_browser_sessions", [])
                .expect("clear invalid row");
            conn.execute(
                "INSERT INTO provider_browser_sessions(
                    provider, cookie_header, account_fingerprint, account_label, updated_at
                 ) VALUES ('cursor', ' wos-session=secret ', ?1, NULL, ?2)",
                ["a".repeat(64), now_rfc3339()],
            )
            .expect("noncanonical row");
        }
        assert!(matches!(store.snapshot(), Err(StateError::InvalidState)));

        {
            let conn = store.identity.lock().expect("db");
            conn.execute("DELETE FROM provider_browser_sessions", [])
                .expect("clear noncanonical row");
            conn.execute(
                "INSERT INTO provider_browser_sessions(
                    provider, cookie_header, account_fingerprint, account_label, updated_at
                 ) VALUES ('unknown', 'wos-session=secret', ?1, NULL, ?2)",
                ["a".repeat(64), now_rfc3339()],
            )
            .expect("unknown provider row");
        }
        assert!(matches!(store.snapshot(), Err(StateError::InvalidState)));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn session_epoch_cas_blocks_refresh_after_logout_pending() {
        let root = std::env::temp_dir().join(format!("quota-session-cas-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .write_session_json(&serde_json::json!({
                "status": "active",
                "account_id": "account",
                "device_id": "device"
            }))
            .expect("active");
        let (_, epoch) = store
            .session_snapshot()
            .expect("snapshot")
            .expect("session");
        store
            .write_session_json(&serde_json::json!({
                "status": "logout_pending",
                "account_id": "account",
                "device_id": "device",
                "refresh_token": "session-refresh"
            }))
            .expect("pending");
        assert!(
            store
                .write_session_json_if_epoch(
                    &serde_json::json!({
                        "status": "active",
                        "account_id": "account",
                        "device_id": "device",
                        "access_token": "stale"
                    }),
                    epoch,
                )
                .expect("cas")
                .is_none()
        );
        assert!(!store.clear_session_if_epoch(epoch).expect("stale clear"));
        assert_eq!(
            store.session_json().expect("read").and_then(|value| value
                .get("status")
                .and_then(Value::as_str)
                .map(str::to_owned)),
            Some("logout_pending".to_owned())
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn pricing_catalog_and_etag_commit_together() {
        let root = std::env::temp_dir().join(format!("quota-pricing-state-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let catalog = serde_json::json!({"revision": "2026-08-10", "models": []});

        assert_eq!(
            store
                .commit_pricing_catalog(&catalog, Some("\"catalog-v1\""))
                .expect("commit"),
            1
        );
        let pricing = store
            .component(ComponentName::Pricing)
            .expect("component")
            .expect("pricing");
        assert_eq!(pricing.status, ComponentStatus::Ready);
        assert_eq!(pricing.value, Some(catalog.clone()));
        assert_eq!(
            store.pricing_etag().expect("etag"),
            Some("\"catalog-v1\"".into())
        );
        assert_eq!(store.snapshot().expect("snapshot").revision, 1);

        assert_eq!(
            store
                .commit_pricing_catalog(&catalog, None)
                .expect("clear etag"),
            2
        );
        assert_eq!(store.pricing_etag().expect("cleared etag"), None);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn account_usage_period_cache_keeps_available_windows_without_all_four() {
        let root = std::env::temp_dir().join(format!("quota-account-usage-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .set_component(
                ComponentName::Account,
                ComponentStatus::Ready,
                Some(serde_json::json!({
                    "auth_status": "signed_in",
                    "account_id": "account_test",
                    "device_id": "device_test",
                    "device_generation": 1,
                    "account_summary": null
                })),
                Some("2026-08-13T00:00:00Z".into()),
                None,
                false,
            )
            .expect("signed in");
        let detail = serde_json::json!({
            "range": {"from": "2026-08-13", "to": "2026-08-13"},
            "usage": {"totals": {"total_tokens": 1}, "cost": {"status": "unavailable"}, "agents": []},
            "incomplete": false,
            "details_truncated": false
        });
        store
            .replace_usage_periods(
                crate::protocol::UsageSource::Account,
                &[
                    (UsagePeriod::Today, detail.clone()),
                    (UsagePeriod::Last7Days, detail.clone()),
                    (UsagePeriod::All, detail),
                ],
            )
            .expect("partial account windows");
        let account = store.snapshot().expect("snapshot").usage_periods.account;
        assert!(account.today.is_some());
        assert!(account.last_7_days.is_some());
        assert!(account.last_30_days.is_none());
        assert!(account.all.is_some());
        assert!(
            store
                .replace_usage_periods(crate::protocol::UsageSource::Account, &[])
                .is_err()
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn model_catalog_cache_is_atomic_and_keeps_lkg_on_invalid_payload() {
        let root =
            std::env::temp_dir().join(format!("quota-model-catalog-state-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let value = serde_json::json!({
            "schema_version": 2,
            "revision": "model-test-1",
            "models": [{
                "canonical_id": "gpt-5.5",
                "aliases": [{"reported_model":"gpt-5.5-alias","provider":"openai"}]
            }]
        });
        store
            .commit_model_catalog(&value, None)
            .expect("catalog without etag");
        assert_eq!(store.model_catalog_etag().expect("etag"), None);
        assert_eq!(store.model_catalog().expect("catalog"), Some(value.clone()));

        let invalid = serde_json::json!({
            "schema_version": 2,
            "revision": "model-test-2",
            "models": [{
                "canonical_id": "gpt-5.5",
                "aliases": []
            }]
        });
        assert!(matches!(
            store.commit_model_catalog(&invalid, Some("\"model-test-2\"")),
            Err(StateError::InvalidState)
        ));
        assert_eq!(store.model_catalog().expect("lkg"), Some(value));
        assert_eq!(store.model_catalog_etag().expect("lkg etag"), None);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// Every dirty hour, whatever its bound, as the tests below read them.
    fn dirty_hours(store: &StateStore) -> Vec<UsageOutboxEntry> {
        store
            .dirty_usage_hour_batch("1970-01-01T00:00:00Z", "9999-12-31T23:00:00Z", 1_000)
            .expect("dirty")
    }

    fn outbox_entry(bucket: &str, scan_version: u64) -> UsageOutboxEntry {
        UsageOutboxEntry {
            agent: UsageAgent::Codex,
            bucket_start_utc: bucket.into(),
            scan_version,
            partial: false,
            rows: Vec::new(),
        }
    }

    /// Staging is keyed by the hour, so restaging one replaces what stood there.
    #[test]
    fn staging_an_hour_again_replaces_the_entry_and_retires_its_dirty_mark() {
        let root = std::env::temp_dir().join(format!("quota-outbox-stage-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                7,
            )
            .expect("initial scan");
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].bucket_start_utc, "2026-08-10T12:00:00Z");
        assert_eq!(dirty[0].scan_version, 7);

        let rows = store
            .usage_hour_rows(UsageAgent::Codex, "2026-08-10T12:00:00Z")
            .expect("rows");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].input_tokens, 1);

        let entry = UsageOutboxEntry {
            agent: UsageAgent::Codex,
            bucket_start_utc: "2026-08-10T12:00:00Z".into(),
            scan_version: 7,
            partial: false,
            rows,
        };
        assert!(
            store
                .stage_outbox_entries("account_test", "device_test", 1, &[entry])
                .expect("stage")
        );
        assert!(dirty_hours(&store).is_empty());
        assert_eq!(store.outbox_entries().expect("entries").len(), 1);

        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 9)], 2),
                8,
            )
            .expect("rescan");
        let rows = store
            .usage_hour_rows(UsageAgent::Codex, "2026-08-10T12:00:00Z")
            .expect("rows");
        assert!(
            store
                .stage_outbox_entries(
                    "account_test",
                    "device_test",
                    1,
                    &[UsageOutboxEntry {
                        agent: UsageAgent::Codex,
                        bucket_start_utc: "2026-08-10T12:00:00Z".into(),
                        scan_version: 8,
                        partial: false,
                        rows,
                    }]
                )
                .expect("restage")
        );
        let entries = store.outbox_entries().expect("entries");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].scan_version, 8);
        assert_eq!(entries[0].rows[0].input_tokens, 9);

        // Accepted and ignored are the same move: both mean the hour is answered for.
        assert!(
            store
                .forget_outbox_hours(UsageAgent::Codex, &["2026-08-10T12:00:00Z".to_owned()])
                .expect("forget")
        );
        assert!(store.outbox_entries().expect("entries").is_empty());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn unchanged_usage_context_removes_foreign_outbox_entries() {
        let root = std::env::temp_dir().join(format!("quota-outbox-context-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .ensure_usage_context("account_test", "device_test", 1, "2026-08-10T00:00:00Z")
            .expect("context");
        store
            .stage_outbox_entries(
                "account_test",
                "device_test",
                1,
                &[outbox_entry("2026-08-10T12:00:00Z", 1)],
            )
            .expect("current entry");
        {
            let conn = store.identity.lock().expect("database");
            conn.execute(
                "INSERT INTO usage_outbox(
                    agent, bucket_start_utc, account_id, device_id, generation,
                    scan_version, partial, rows_json
                 ) VALUES ('codex', '2026-08-10T13:00:00Z', 'account_old', 'device_old', 1,
                           1, 0, '[]')",
                [],
            )
            .expect("foreign entry");
        }

        let revision = store
            .ensure_usage_context("account_test", "device_test", 1, "2026-08-10T00:00:00Z")
            .expect("unchanged context");
        assert!(revision > 0);
        let entries = store.outbox_entries().expect("entries");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].bucket_start_utc, "2026-08-10T12:00:00Z");
        assert_eq!(
            store
                .outbox_entries_for("account_test", "device_test", 1)
                .expect("current entries"),
            entries
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A new upload identity owes the Account every hour this device still holds after its
    /// privacy lower bound, and nothing it staged for the previous one.
    #[test]
    fn a_new_upload_identity_reseeds_every_retained_hour() {
        let root = std::env::temp_dir().join(format!("quota-outbox-reseed-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(
                    vec![
                        usage_event("2026-08-09T12:15:00Z", 1),
                        usage_event("2026-08-10T12:15:00Z", 2),
                    ],
                    1,
                ),
                3,
            )
            .expect("scan");
        store
            .ensure_usage_context("account_a", "device_a", 1, "2026-08-10T00:00:00Z")
            .expect("first identity");
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].bucket_start_utc, "2026-08-10T12:00:00Z");
        store
            .stage_outbox_entries(
                "account_a",
                "device_a",
                1,
                &[outbox_entry("2026-08-10T12:00:00Z", 3)],
            )
            .expect("stage");

        store
            .ensure_usage_context("account_b", "device_b", 2, "1970-01-01T00:00:00Z")
            .expect("second identity");
        assert!(store.outbox_entries().expect("entries").is_empty());
        assert_eq!(dirty_hours(&store).len(), 2);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A rescan recomputes only the hours whose records moved, and leaves the rest alone.
    #[test]
    fn a_rescan_recomputes_only_the_hours_it_changed() {
        let root = std::env::temp_dir().join(format!("quota-usage-state-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let first = usage_event("2026-08-10T12:15:00Z", 1);
        let second = usage_event("2026-08-10T13:15:00Z", 2);
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![first.clone(), second.clone()], 1),
                1,
            )
            .expect("initial scan");
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 2);
        store
            .stage_outbox_entries(
                "account_test",
                "device_test",
                1,
                &dirty
                    .iter()
                    .map(|hour| outbox_entry(&hour.bucket_start_utc, hour.scan_version))
                    .collect::<Vec<_>>(),
            )
            .expect("clear initial");
        assert!(dirty_hours(&store).is_empty());

        let appended = usage_event("2026-08-10T14:15:00Z", 3);
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![first.clone(), second.clone(), appended.clone()], 2),
                2,
            )
            .expect("append scan");
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].bucket_start_utc, "2026-08-10T14:00:00Z");
        assert_eq!(dirty[0].scan_version, 2);
        store
            .stage_outbox_entries(
                "account_test",
                "device_test",
                1,
                &[outbox_entry("2026-08-10T14:00:00Z", 2)],
            )
            .expect("clear append");

        // The same bytes again: every record lands where it already was, and nothing is dirty.
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![first, second.clone(), appended], 3),
                3,
            )
            .expect("equivalent rewrite");
        assert!(dirty_hours(&store).is_empty());

        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(
                    vec![
                        usage_event("2026-08-10T12:15:00Z", 9),
                        second,
                        usage_event("2026-08-10T14:15:00Z", 3),
                    ],
                    4,
                ),
                4,
            )
            .expect("old hour edit");
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].bucket_start_utc, "2026-08-10T12:00:00Z");
        assert_eq!(
            store
                .usage_hour_rows(UsageAgent::Codex, "2026-08-10T12:00:00Z")
                .expect("rows")[0]
                .input_tokens,
            9
        );
        assert_eq!(
            store
                .usage_hour_rows(UsageAgent::Codex, "2026-08-10T14:00:00Z")
                .expect("rows")[0]
                .input_tokens,
            3
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// An appended tail adds to what is stored instead of replacing it, and the hours it lands
    /// in are the only ones recomputed.
    #[test]
    fn an_appended_tail_keeps_the_records_already_indexed() {
        let root = std::env::temp_dir().join(format!("quota-usage-append-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                1,
            )
            .expect("initial scan");
        let mut appended = usage_scan(vec![usage_event("2026-08-10T13:15:00Z", 2)], 2);
        appended.sources[0].append = true;
        appended.sources[0].record_keys = vec!["line:64:0".into()];
        store
            .apply_usage_scan(UsageAgent::Codex, &appended, 2)
            .expect("append scan");
        assert_eq!(store.usage_event_count().expect("count"), 2);
        let (rows, _) = store.usage_period_rows(None).expect("rows");
        assert_eq!(
            rows.iter().map(|row| row.input_tokens).sum::<u64>(),
            3,
            "{rows:?}"
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn partial_source_keeps_last_good_rows_and_marks_partial_hours() {
        let root = std::env::temp_dir().join(format!("quota-partial-source-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let first = usage_event("2026-08-10T12:15:00Z", 1);
        store
            .apply_usage_scan(UsageAgent::Codex, &usage_scan(vec![first.clone()], 1), 1)
            .expect("initial scan");
        store
            .stage_outbox_entries(
                "account_test",
                "device_test",
                1,
                &[outbox_entry("2026-08-10T12:00:00Z", 1)],
            )
            .expect("clear initial");

        let second = usage_event("2026-08-10T13:15:00Z", 2);
        let mut partial = usage_scan(vec![first.clone(), second], 2);
        partial.coverage.status = CoverageStatus::Partial;
        partial.sources[0].coverage.status = CoverageStatus::Partial;
        partial.sources[0].coverage.reasons = vec![crate::usage::CoverageReason {
            code: crate::usage::CoverageReasonCode::MalformedJson,
            count: 1,
        }];
        store
            .apply_usage_scan(UsageAgent::Codex, &partial, 2)
            .expect("partial scan");
        assert_eq!(store.usage_event_count().expect("count"), 2);
        assert!(
            store
                .partial_usage_hours()
                .expect("partial hours")
                .contains(&(UsageAgent::Codex, "2026-08-10T12:00:00Z".into()))
        );
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 2);
        assert!(dirty.iter().all(|hour| hour.partial));
        store
            .stage_outbox_entries(
                "account_test",
                "device_test",
                1,
                &dirty
                    .iter()
                    .map(|hour| outbox_entry(&hour.bucket_start_utc, hour.scan_version))
                    .collect::<Vec<_>>(),
            )
            .expect("clear partial upload");

        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![first, usage_event("2026-08-10T13:15:00Z", 2)], 3),
                3,
            )
            .expect("complete repair");
        assert!(
            store
                .partial_usage_hours()
                .expect("partial hours")
                .is_empty()
        );
        // A repaired source restates its hours once so the reader stops calling them partial,
        // even when the numbers behind them did not move.
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 2);
        assert!(dirty.iter().all(|hour| !hour.partial));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A source that came up short still says how far it was read, so the next refresh reads
    /// the part that was never read instead of the whole log again, every five minutes,
    /// forever. What it must not say is that the file is unchanged: that is what would make
    /// the next scan skip it.
    #[test]
    fn a_partial_source_remembers_how_far_it_was_read_without_claiming_to_be_finished() {
        let root = std::env::temp_dir().join(format!("quota-partial-resume-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let mut partial = usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 7);
        partial.coverage.status = CoverageStatus::Partial;
        partial.sources[0].coverage.status = CoverageStatus::Partial;
        partial.sources[0].coverage.reasons = vec![crate::usage::CoverageReason {
            code: crate::usage::CoverageReasonCode::MalformedJson,
            count: 1,
        }];
        partial.sources[0].index.parsed_offset = 4_096;
        partial.sources[0].index.prefix_hash = "a".repeat(64);

        store
            .apply_usage_scan(UsageAgent::Codex, &partial, 1)
            .expect("partial scan");

        let index = store
            .usage_file_index(UsageAgent::Codex)
            .expect("file index");
        let entry = index.get("source-1").expect("row for the partial source");
        assert_eq!(entry.parsed_offset, 4_096);
        assert_eq!(entry.prefix_hash, "a".repeat(64));
        // Not the size or the modification time the scan saw: the next scan has to look again.
        assert_eq!(entry.size, 0);
        assert_eq!(entry.modified_ns, 0);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn partial_source_replaces_by_line_identity_without_deduplicating_or_dropping_rows() {
        let root = std::env::temp_dir().join(format!("quota-partial-identity-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let first = usage_event("2026-08-10T12:15:00Z", 1);
        let second = usage_event("2026-08-10T12:30:00Z", 2);
        store
            .apply_usage_scan(UsageAgent::Codex, &usage_scan(vec![first, second], 1), 1)
            .expect("initial scan");

        let updated = usage_event("2026-08-10T12:15:00Z", 9);
        let added = usage_event("2026-08-10T12:45:00Z", 3);
        let mut partial = usage_scan(vec![updated, added], 2);
        partial.coverage.status = CoverageStatus::Partial;
        partial.sources[0].coverage.status = CoverageStatus::Partial;
        partial.sources[0].coverage.reasons = vec![crate::usage::CoverageReason {
            code: crate::usage::CoverageReasonCode::MalformedJson,
            count: 1,
        }];
        // Line 1 is the malformed record. Its previous value must survive while line 0 is
        // replaced and line 2 is inserted.
        partial.sources[0].record_keys = vec!["line:0:0".into(), "line:2:0".into()];
        store
            .apply_usage_scan(UsageAgent::Codex, &partial, 2)
            .expect("partial scan");

        let (rows, _) = store.usage_period_rows(None).expect("rows");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].input_tokens, 14);
        assert_eq!(rows[0].requests, 3);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// Today begins at local midnight, so the hours it folds depend on where this Mac is.
    ///
    /// The three events are 23:30 and 00:30 by a Singapore clock on either side of its own
    /// midnight, and midday after it. A device keeping that calendar leaves the first out of
    /// Today and takes the other two; a device keeping UTC does the opposite with the first.
    #[test]
    fn today_folds_the_hours_its_local_day_covers() {
        let root = std::env::temp_dir().join(format!("quota-usage-period-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(
                    vec![
                        usage_event("2026-08-09T15:30:00Z", 1),
                        usage_event("2026-08-09T16:30:00Z", 2),
                        usage_event("2026-08-10T04:15:00Z", 4),
                    ],
                    1,
                ),
                1,
            )
            .expect("scan");
        let now = DateTime::parse_from_rfc3339("2026-08-10T06:00:00Z")
            .expect("instant")
            .with_timezone(&chrono::Utc);
        let today = |timezone: &str| {
            let span = crate::service::backend::usage_period_window(
                crate::protocol::UsagePeriod::Today,
                timezone,
                now,
            )
            .expect("window")
            .1
            .expect("span");
            store
                .usage_period_rows(Some((&span.start, &span.end)))
                .expect("today")
                .0
        };

        let local = today("Asia/Singapore");
        assert_eq!(local.iter().map(|row| row.input_tokens).sum::<u64>(), 6);
        assert_eq!(local.iter().map(|row| row.requests).sum::<u64>(), 2);
        let utc = today("UTC");
        assert_eq!(utc.iter().map(|row| row.input_tokens).sum::<u64>(), 4);
        assert_eq!(utc.iter().map(|row| row.requests).sum::<u64>(), 1);

        let (all, partial) = store.usage_period_rows(None).expect("all");
        assert!(!partial);
        assert_eq!(all.iter().map(|row| row.input_tokens).sum::<u64>(), 7);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A stored record body this build can no longer read is replaced by the rescan that
    /// found it, and the hour it belongs to is folded from the readable value.
    #[test]
    fn a_rescan_replaces_a_record_body_this_build_cannot_read() {
        let root = std::env::temp_dir().join(format!("quota-usage-upgrade-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                1,
            )
            .expect("initial scan");
        store
            .stage_outbox_entries(
                "account_test",
                "device_test",
                1,
                &[outbox_entry("2026-08-10T12:00:00Z", 1)],
            )
            .expect("clear initial");
        store
            .cache
            .lock()
            .expect("database")
            .execute(
                "UPDATE usage_file_records SET event_json = '{\"legacy\":true}'",
                [],
            )
            .expect("corrupt old wire value");

        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 9)], 2),
                2,
            )
            .expect("parser upgrade");
        let dirty = dirty_hours(&store);
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].bucket_start_utc, "2026-08-10T12:00:00Z");
        let (rows, _) = store.usage_period_rows(None).expect("rows");
        assert_eq!(rows[0].input_tokens, 9);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn usage_event_count_does_not_load_or_decode_event_bodies() {
        let root = std::env::temp_dir().join(format!("quota-usage-count-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                1,
            )
            .expect("initial scan");
        store
            .cache
            .lock()
            .expect("database")
            .execute(
                "UPDATE usage_file_records SET event_json = '{\"legacy\":true}'",
                [],
            )
            .expect("replace event body");

        assert_eq!(store.usage_event_count().expect("count"), 1);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// `NOFOLLOW` rejects a symlink anywhere in the path and the macOS temporary directory
    /// reaches through one, so a test root is resolved the way the service resolves its own.
    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("quota-{name}-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        fs::canonicalize(&root).expect("canonical root")
    }

    fn active_session() -> Value {
        serde_json::json!({
            "status": "active",
            "account_id": "account",
            "device_id": "device"
        })
    }

    /// The whole point of the split: a cache nothing can read costs this device its history for
    /// one refresh, and costs it nothing else.
    #[test]
    fn a_cache_written_over_with_garbage_is_rebuilt_and_identity_is_untouched() {
        let root = temp_root("cache-garbage");
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        store
            .write_session_json(&active_session())
            .expect("session");
        store
            .set_usage_upload_enabled(false)
            .expect("upload preference");
        store
            .set_provider_browser_session(
                "cursor",
                &ProviderBrowserSession {
                    cookie_header: "wos-session=secret".into(),
                    account_fingerprint: "a".repeat(64),
                    account_label: None,
                },
            )
            .expect("browser session");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                1,
            )
            .expect("scan");
        let revision = store.current_revision().expect("revision");
        drop(store);

        fs::write(root.join(CACHE_NAME), b"this is not a database").expect("garbage");
        let store = StateStore::open(&root).expect("reopen");

        let snapshot = store.snapshot().expect("snapshot");
        assert!(snapshot.cache.rebuilding);
        assert!(snapshot.cache.reset_at.is_some());
        // The change counter keeps climbing, so a panel that is already following along does not
        // go quiet waiting for a count that restarted.
        assert!(snapshot.revision > revision);
        assert_eq!(store.installation_id().expect("installation"), installation);
        assert!(store.session_json().expect("session").is_some());
        assert!(!store.usage_upload_enabled().expect("upload preference"));
        assert!(
            store
                .provider_browser_session("cursor")
                .expect("browser session")
                .is_some()
        );
        assert_eq!(store.usage_event_count().expect("records"), 0);

        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                1,
            )
            .expect("rebuild scan");
        assert!(!store.snapshot().expect("snapshot").cache.rebuilding);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A cache that breaks while the service is running gets the same answer as one that was
    /// already broken at launch: the caller is told to retry, and the retry finds an empty cache.
    #[test]
    fn a_cache_that_breaks_mid_run_is_rebuilt_on_the_spot() {
        let root = temp_root("cache-midrun");
        let store = StateStore::open(&root).expect("state");
        store
            .write_session_json(&active_session())
            .expect("session");
        store
            .cache
            .lock()
            .expect("cache")
            .execute("DROP TABLE components", [])
            .expect("break the cache");

        assert!(matches!(store.snapshot(), Err(StateError::Unavailable)));

        let snapshot = store.snapshot().expect("rebuilt");
        assert!(snapshot.cache.rebuilding);
        assert!(store.session_json().expect("session").is_some());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// An Overview row this build cannot read is a cache row: thrown away, not carried as an
    /// error every `get_state` call answers with.
    #[test]
    fn an_unreadable_overview_row_rebuilds_the_cache_rather_than_wedging_state() {
        let root = temp_root("overview-garbage");
        let store = StateStore::open(&root).expect("state");
        store
            .write_session_json(&active_session())
            .expect("session");
        store.snapshot().expect("snapshot");
        store
            .with_cache_mut(|conn| {
                conn.execute(
                    "INSERT INTO metadata(key, value) VALUES ('overview_json', ?1)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params!["not json"],
                )?;
                Ok(())
            })
            .expect("garbage row");

        assert!(matches!(store.snapshot(), Err(StateError::Unavailable)));

        let snapshot = store.snapshot().expect("rebuilt");
        assert!(snapshot.overview.is_empty());
        assert!(snapshot.cache.rebuilding);
        assert!(store.session_json().expect("session").is_some());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// Contention is not corruption (ADR 0021). A second process holding the write lock costs
    /// this one a retry; it must never cost the device the file.
    #[test]
    fn an_open_another_writer_holds_leaves_both_images_where_they_are() {
        let root = temp_root("open-busy");
        let store = StateStore::open(&root).expect("state");
        store
            .write_session_json(&active_session())
            .expect("session");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                1,
            )
            .expect("scan");
        drop(store);

        for name in [CACHE_NAME, IDENTITY_NAME] {
            let path = root.join(name);
            let before = fs::metadata(&path).expect("image").len();
            let blocker = Connection::open(&path).expect("second writer");
            blocker
                .execute_batch("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE;")
                .expect("write lock");

            let answer = if name == CACHE_NAME {
                open_cache(&root, 0).map(|_| ())
            } else {
                open_identity(&root).map(|_| ())
            };
            assert!(matches!(answer, Err(StateError::Unavailable)), "{name}");
            assert_eq!(
                fs::metadata(&path).expect("image is still there").len(),
                before,
                "{name}"
            );
            drop(blocker);
        }

        // And the device that waited its turn still holds everything it had.
        let store = StateStore::open(&root).expect("reopen");
        assert!(store.session_json().expect("session").is_some());
        assert_eq!(store.usage_event_count().expect("records"), 1);
        assert!(!store.snapshot().expect("snapshot").cache.rebuilding);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A statement SQLite refused is an answer about that statement. The cache is only thrown
    /// away when the bytes on disk stopped describing what this device collected.
    #[test]
    fn a_refused_write_is_never_a_verdict_on_the_cache() {
        let root = temp_root("cache-refused");
        let store = StateStore::open(&root).expect("state");
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![usage_event("2026-08-10T12:15:00Z", 1)], 1),
                1,
            )
            .expect("scan");

        // An outcome the journal's CHECK constraint refuses.
        let refused = store.with_cache_mut(|conn| {
            conn.execute(
                "INSERT INTO diagnostic_attempts(kind, trigger, started_at, outcome)
                 VALUES ('refresh', 'manual', '2026-08-10T00:00:00Z', 'nonsense')",
                [],
            )?;
            Ok(())
        });
        assert!(matches!(refused, Err(StateError::Sql(_))));
        assert_eq!(store.usage_event_count().expect("records"), 1);
        assert!(!store.snapshot().expect("snapshot").cache.rebuilding);

        // The codes a test cannot provoke on demand, answered from the same rule.
        for code in [
            SqliteErrorCode::ReadOnly,
            SqliteErrorCode::OutOfMemory,
            SqliteErrorCode::PermissionDenied,
            SqliteErrorCode::TooBig,
            SqliteErrorCode::ConstraintViolation,
        ] {
            let error = StateError::Sql(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error {
                    code,
                    extended_code: 0,
                },
                None,
            ));
            assert!(!cache_needs_rebuild(&error), "{code:?}");
            assert!(!sqlite_io_or_full_error(&error), "{code:?}");
        }
        // A shape this build cannot read still is.
        assert!(cache_needs_rebuild(&StateError::Sql(
            rusqlite::Error::InvalidQuery
        )));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// There is no salvage. A device that cannot read who it is becomes a new installation, and
    /// says so, because signing in again is the only thing that puts it back.
    #[test]
    fn an_identity_written_over_with_garbage_starts_this_device_over() {
        let root = temp_root("identity-garbage");
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        store
            .write_session_json(&active_session())
            .expect("session");
        drop(store);

        fs::write(root.join(IDENTITY_NAME), b"not a database").expect("garbage");
        let store = StateStore::open(&root).expect("reopen");

        assert_ne!(store.installation_id().expect("installation"), installation);
        assert!(store.session_json().expect("session").is_none());
        assert!(store.identity_reset_at().expect("marker").is_some());
        // Signing in again is the recovery the notice asks for, so it retires itself.
        store
            .write_session_json(&active_session())
            .expect("sign in");
        assert!(store.identity_reset_at().expect("marker").is_none());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A device upgrading from the released single-file image keeps who it is and who it is
    /// signed in as. What it still owes an Account is recomputed rather than carried across.
    #[test]
    fn a_released_image_is_imported_once_and_then_gone() {
        let root = temp_root("released-image");
        let legacy = root.join("state.sqlite");
        let conn = Connection::open(&legacy).expect("released image");
        conn.execute_batch(
            "CREATE TABLE installation(id INTEGER PRIMARY KEY, installation_id TEXT NOT NULL,
                payload_json TEXT);
             CREATE TABLE session(id INTEGER PRIMARY KEY, payload_json TEXT NOT NULL,
                epoch INTEGER NOT NULL);
             CREATE TABLE usage_upload_context(id INTEGER PRIMARY KEY, account_id TEXT NOT NULL,
                device_id TEXT NOT NULL, generation INTEGER NOT NULL,
                aggregation_timezone TEXT NOT NULL, lower_bound TEXT NOT NULL);
             CREATE TABLE provider_browser_sessions(provider TEXT PRIMARY KEY,
                cookie_header TEXT NOT NULL, account_fingerprint TEXT NOT NULL,
                account_label TEXT, updated_at TEXT NOT NULL);
             CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO installation VALUES (1, 'released-installation', NULL);
             INSERT INTO session VALUES (1, '{\"status\":\"active\"}', 4);
             INSERT INTO metadata VALUES ('usage_upload_enabled', '0');",
        )
        .expect("released rows");
        drop(conn);

        let store = StateStore::open(&root).expect("state");
        assert_eq!(
            store.installation_id().expect("installation"),
            "released-installation"
        );
        assert!(store.session_json().expect("session").is_some());
        assert!(store.outbox_entries().expect("outbox").is_empty());
        assert!(!store.usage_upload_enabled().expect("upload preference"));
        assert!(store.identity_reset_at().expect("marker").is_none());
        assert!(!legacy.exists());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A process that went away mid-refresh leaves marks only its successor can retire.
    #[test]
    fn reopening_clears_leftover_refreshing_flags_and_finishes_running_attempts() {
        let root = temp_root("interrupted");
        let store = StateStore::open(&root).expect("state");
        store
            .set_component(
                ComponentName::Quota,
                ComponentStatus::Ready,
                Some(serde_json::json!({})),
                None,
                None,
                true,
            )
            .expect("refreshing component");
        store.begin_diagnostic_attempt(
            DiagnosticAttemptKind::Refresh,
            DiagnosticAttemptTrigger::Manual,
            None,
            None,
        );
        drop(store);

        let store = StateStore::open(&root).expect("reopen");
        assert!(!store.snapshot().expect("snapshot").quota.refreshing);
        assert!(
            store
                .running_refresh_attempt()
                .expect("running attempt")
                .is_none()
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    fn usage_event(occurred_at: &str, input_tokens: u64) -> NormalizedUsageEvent {
        NormalizedUsageEvent {
            occurred_at: occurred_at.into(),
            agent: UsageAgent::Codex,
            model: "gpt-5".into(),
            billing_channel: BillingChannel::OpenaiDirect,
            channel_source: ChannelSource::Explicit,
            input_tokens,
            cache_read_tokens: 0,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: 0,
            output_tokens: 1,
            reasoning_tokens: 0,
            requests: 1,
            context_bucket: ContextBucket::Le128k,
            service_tier: "standard".into(),
            speed: "standard".into(),
            inference_geo: "global".into(),
            billable_tools: BillableTools::default(),
            source_cost_microusd: None,
            source_cost_covered_requests: 0,
        }
    }

    fn usage_scan(events: Vec<NormalizedUsageEvent>, modified_ns: u128) -> UsageScanResult {
        let source = LocalUsageFile {
            path: PathBuf::from("/tmp/usage.jsonl"),
            source_file_id: "source-1".into(),
            size: events.len() as u64,
            modified_ns,
            identity: "identity-1".into(),
        };
        UsageScanResult {
            records: Vec::new(),
            coverage: ScanCoverage {
                agent: UsageAgent::Codex,
                start_at: "1970-01-01T00:00:00Z".into(),
                end_at: "2026-08-11T00:00:00Z".into(),
                status: CoverageStatus::Complete,
                reasons: Vec::new(),
            },
            scanned_source_count: 1,
            skipped_source_count: 0,
            ignored_empty_records: 0,
            unchanged_source_file_ids: Vec::new(),
            deleted_source_file_ids: Vec::new(),
            sources: vec![UsageSourceScan {
                append: false,
                index: UsageFileIndex {
                    source_file_id: "source-1".into(),
                    identity: "identity-1".into(),
                    size: events.len() as u64,
                    modified_ns,
                    parser_revision: "usage-rust-v4".into(),
                    ..UsageFileIndex::default()
                },
                source,
                record_keys: (0..events.len())
                    .map(|index| format!("line:{index}:0"))
                    .collect(),
                records: events,
                coverage: ScanCoverage {
                    agent: UsageAgent::Codex,
                    start_at: "1970-01-01T00:00:00Z".into(),
                    end_at: "2026-08-11T00:00:00Z".into(),
                    status: CoverageStatus::Complete,
                    reasons: Vec::new(),
                },
            }],
        }
    }
}
