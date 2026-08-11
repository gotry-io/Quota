//! The sole local persistence owner.

use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File, OpenOptions, Permissions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Duration, SecondsFormat, Timelike};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

use crate::migration;
use crate::protocol::{
    ComponentName, ComponentState, ComponentStatus, ErrorCode, IPC_VERSION, IpcError,
    ProviderConfigView, QuotaOverviewItem, RecoveryAction, StateSnapshot,
};
use crate::usage::{NormalizedUsageEvent, UsageAgent, UsageFileIndex, UsageScanResult};

const STATE_DB_NAME: &str = "state.sqlite";
const PROVIDER_CONFIG_NAME: &str = "providers.json";
const MAX_USAGE_OUTBOX_ENTRIES: i64 = 64;

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

/// A process-lifetime service lock.  It intentionally does not use the released `state.lock`
/// directory name: QuotaCLI still creates that directory for short provider/config mutations.
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

/// Short critical-section lock shared with the released QuotaCLI providers.json writer.  The
/// directory/owner shape is retained at this published file boundary; only this tiny config
/// mutation uses stale-owner recovery, while the service lifetime lock above remains flock-backed.
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
    db: Mutex<Connection>,
    // Kept in this object for the entire service lifetime.
    _owner_lock: OwnerLock,
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
        let database_path = root.join(STATE_DB_NAME);
        let database_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&database_path)?;
        if !database_file.metadata()?.is_file() {
            return Err(StateError::InvalidState);
        }
        database_file.set_permissions(Permissions::from_mode(0o600))?;
        drop(database_file);
        let mut connection = Connection::open_with_flags(
            &database_path,
            OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        connection.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA busy_timeout = 5000;
             PRAGMA journal_mode = WAL;",
        )?;
        migration::apply(&mut connection, &root)?;
        Ok(Self {
            root,
            db: Mutex::new(connection),
            _owner_lock: owner_lock,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn snapshot(&self) -> Result<StateSnapshot, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let revision = metadata_u64(&conn, "revision")?;
        let quota = read_component(&conn, ComponentName::Quota)?;
        let usage = read_component(&conn, ComponentName::Usage)?;
        let account =
            read_component(&conn, ComponentName::Account)?.unwrap_or_else(|| ComponentRecord {
                status: ComponentStatus::SignedOut,
                value: Some(serde_json::json!({
                    "auth_status": "signed_out",
                    "account_id": null,
                    "device_id": null,
                    "device_generation": null,
                    "account_summary": null
                })),
                updated_at: None,
                last_error: None,
                refreshing: false,
            });
        let pricing = read_component(&conn, ComponentName::Pricing)?;
        let providers = read_provider_views(&self.root)?;
        let overview = read_overview(&conn)?;
        Ok(StateSnapshot {
            ipc_version: IPC_VERSION,
            revision,
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
            overview,
        })
    }

    pub fn component(&self, name: ComponentName) -> Result<Option<ComponentRecord>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        read_component(&conn, name)
    }

    pub fn pricing_etag(&self) -> Result<Option<String>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        metadata_value(&conn, "pricing_etag")
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
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
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
        tx.execute(
            "DELETE FROM legacy_artifacts WHERE name = 'pricing-catalog.json'",
            [],
        )?;
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
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
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
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
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO metadata(key,value) VALUES ('overview_json',?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![value],
        )?;
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
    }

    pub fn current_revision(&self) -> Result<u64, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        metadata_u64(&conn, "revision")
    }

    pub fn session_json(&self) -> Result<Option<Value>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let raw: Option<String> = conn
            .query_row("SELECT payload_json FROM session WHERE id = 1", [], |row| {
                row.get::<_, String>(0)
            })
            .optional()?;
        raw.map(|value| serde_json::from_str(&value).map_err(StateError::from))
            .transpose()
    }

    /// Reads the session together with the SQLite compare-and-swap epoch.  The epoch is kept
    /// outside the JSON payload so imported released sessions remain wire-compatible while every
    /// local transition gets a monotonic identity.
    pub fn session_snapshot(&self) -> Result<Option<(Value, u64)>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
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
    }

    /// Returns true only while the same active session is still installed.  Callers use this
    /// immediately before a Relay write so a logout transition cannot revive an old session.
    pub fn active_session_at_epoch(&self, expected_epoch: u64) -> Result<bool, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
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
    }

    pub fn write_session_json(&self, value: &Value) -> Result<u64, StateError> {
        let raw = serde_json::to_string(value)?;
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
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
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
    }

    /// Replaces the session only if its epoch is unchanged.  The returned epoch is the new
    /// session identity; `None` means a logout/login transition won the race.
    pub fn write_session_json_if_epoch(
        &self,
        value: &Value,
        expected_epoch: u64,
    ) -> Result<Option<u64>, StateError> {
        let raw = serde_json::to_string(value)?;
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
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
        let _ = bump_revision(&tx)?;
        tx.commit()?;
        Ok(Some(next_epoch))
    }

    /// Deletes the session only if the caller still owns the pending epoch.
    pub fn clear_session_if_epoch(&self, expected_epoch: u64) -> Result<bool, StateError> {
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        let changed = tx.execute(
            "DELETE FROM session WHERE id = 1 AND epoch = ?1",
            params![i64::try_from(expected_epoch).map_err(|_| StateError::InvalidState)?],
        )?;
        if changed == 0 {
            tx.rollback()?;
            return Ok(false);
        }
        let _ = bump_revision(&tx)?;
        tx.commit()?;
        Ok(true)
    }

    pub fn clear_session(&self) -> Result<u64, StateError> {
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM session WHERE id = 1", [])?;
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
    }

    pub fn installation_id(&self) -> Result<String, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        conn.query_row(
            "SELECT installation_id FROM installation WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .map_err(StateError::from)
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
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
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
        if let Some(existing) = bindings
            .iter()
            .find(|binding| binding.get("account_id").and_then(Value::as_str) == Some(account_id))
        {
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
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(lower_bound)
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
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        bump_revision(&conn)
    }

    pub fn remove_provider_config(&self, provider: &str) -> Result<u64, StateError> {
        let _lock = ProviderConfigLock::acquire(&self.root)?;
        let mut file = read_provider_file(&self.root)?;
        let removed = file.providers.remove(provider).is_some();
        if removed {
            write_provider_file(&self.root, &file)?;
            let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
            return bump_revision(&conn);
        }
        self.current_revision()
    }

    #[cfg(test)]
    pub fn outbox_entries(&self) -> Result<Vec<Value>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let mut statement = conn.prepare(
            "SELECT payload_json FROM usage_outbox ORDER BY account_id, device_id, generation, sequence",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut values = Vec::new();
        for row in rows {
            values.push(serde_json::from_str(&row?)?);
        }
        Ok(values)
    }

    pub fn outbox_entries_for(
        &self,
        account_id: &str,
        device_id: &str,
        generation: u64,
    ) -> Result<Vec<Value>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let mut statement = conn.prepare(
            "SELECT payload_json FROM usage_outbox
             WHERE account_id = ?1 AND device_id = ?2 AND generation = ?3
             ORDER BY sequence, submission_id",
        )?;
        let rows = statement.query_map(params![account_id, device_id, generation], |row| {
            row.get::<_, String>(0)
        })?;
        let mut values = Vec::new();
        for row in rows {
            values.push(serde_json::from_str(&row?)?);
        }
        Ok(values)
    }

    pub fn legacy_artifact(&self, name: &str) -> Result<Option<Value>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT payload_json FROM legacy_artifacts WHERE name = ?1",
                params![name],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        raw.map(|value| serde_json::from_str(&value).map_err(StateError::from))
            .transpose()
    }

    /// Reads and removes a migrated artifact in one transaction.  The service calls this after it
    /// has restored the payload into live component/index state; migration artifacts are not a
    /// second, forever-growing source of truth.
    pub fn consume_legacy_artifact(&self, name: &str) -> Result<Option<Value>, StateError> {
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        let raw: Option<String> = tx
            .query_row(
                "SELECT payload_json FROM legacy_artifacts WHERE name = ?1",
                params![name],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(raw) = raw else {
            tx.commit()?;
            return Ok(None);
        };
        tx.execute(
            "DELETE FROM legacy_artifacts WHERE name = ?1",
            params![name],
        )?;
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(Some(serde_json::from_str(&raw)?))
    }

    /// Atomically reserves an immutable Usage submission and consumes the exact dirty range that
    /// produced it.  A crash can therefore leave either both rows or neither row; a retry with the
    /// same deterministic submission id is idempotent and still consumes any range left by an
    /// earlier version of the service.
    pub fn stage_outbox_entry(
        &self,
        account_id: &str,
        value: &Value,
        consumed: &UsageDirtyRange,
    ) -> Result<bool, StateError> {
        if account_id.is_empty() {
            return Err(StateError::InvalidState);
        }
        let object = value.as_object().ok_or(StateError::InvalidState)?;
        let submission_id = object
            .get("submission_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or(StateError::InvalidState)?;
        let device_id = object
            .get("device_id")
            .and_then(Value::as_str)
            .ok_or(StateError::InvalidState)?;
        let generation = object
            .get("generation")
            .and_then(Value::as_i64)
            .filter(|value| *value > 0)
            .ok_or(StateError::InvalidState)?;
        let sequence = object
            .get("sequence")
            .and_then(Value::as_i64)
            .filter(|value| *value >= 0)
            .ok_or(StateError::InvalidState)?;
        let raw = serde_json::to_string(value)?;
        if raw.len() > crate::relay::MAXIMUM_REQUEST_BYTES {
            return Err(StateError::InvalidState);
        }
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        let existing: Option<(String, String, i64, i64, String)> = tx
            .query_row(
                "SELECT account_id, device_id, generation, sequence, payload_json
                 FROM usage_outbox WHERE submission_id = ?1",
                params![submission_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .optional()?;
        if let Some((
            stored_account,
            stored_device,
            stored_generation,
            stored_sequence,
            stored_raw,
        )) = existing
        {
            if stored_account != account_id
                || stored_device != device_id
                || stored_generation != generation
                || stored_sequence != sequence
                || stored_raw != raw
            {
                return Err(StateError::InvalidState);
            }
            let changed = consume_dirty_usage_range_tx(&tx, consumed)?;
            if changed > 0 {
                bump_revision(&tx)?;
            }
            tx.commit()?;
            return Ok(false);
        }
        let count: i64 = tx.query_row("SELECT COUNT(*) FROM usage_outbox", [], |row| row.get(0))?;
        if count >= MAX_USAGE_OUTBOX_ENTRIES {
            return Err(StateError::Unavailable);
        }
        tx.execute(
            "INSERT INTO usage_outbox(submission_id,account_id,device_id,generation,sequence,payload_json)
             VALUES (?1,?2,?3,?4,?5,?6)",
            params![submission_id, account_id, device_id, generation, sequence, raw],
        )?;
        consume_dirty_usage_range_tx(&tx, consumed)?;
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(true)
    }

    /// Acknowledges a successful/duplicate Relay response and removes the immutable request in one
    /// SQLite transaction.  Relay deduplicates retries by the immutable submission id.
    pub fn acknowledge_outbox_entry(&self, submission_id: &str) -> Result<bool, StateError> {
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        let row: Option<String> = tx
            .query_row(
                "SELECT submission_id
                 FROM usage_outbox WHERE submission_id = ?1",
                params![submission_id],
                |row| row.get(0),
            )
            .optional()?;
        let Some(_) = row else {
            tx.commit()?;
            return Ok(false);
        };
        tx.execute(
            "DELETE FROM usage_outbox WHERE submission_id = ?1",
            params![submission_id],
        )?;
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(true)
    }

    pub fn usage_file_index(
        &self,
        agent: UsageAgent,
    ) -> Result<HashMap<String, UsageFileIndex>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let mut statement = conn.prepare(
            "SELECT source_file_id, identity, size, modified_ns, parser_revision
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
                },
            ))
        })?;
        let mut result = HashMap::new();
        for row in rows {
            let (id, index) = row?;
            result.insert(id, index);
        }
        Ok(result)
    }

    pub fn usage_events(&self) -> Result<Vec<NormalizedUsageEvent>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let mut statement = conn.prepare(
            "SELECT event_json FROM usage_file_records ORDER BY occurred_at, agent, source_file_id, record_index",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut events = Vec::new();
        for row in rows {
            events.push(serde_json::from_str(&row?)?);
        }
        Ok(events)
    }

    pub fn dirty_usage_ranges(&self) -> Result<Vec<UsageDirtyRange>, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let mut statement = conn.prepare(
            "SELECT agent, start_at, end_at FROM usage_dirty_ranges ORDER BY start_at, end_at, agent",
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
            Ok(UsageDirtyRange {
                agent,
                start_at: row.get(1)?,
                end_at: row.get(2)?,
            })
        })?;
        let mut ranges = Vec::new();
        for row in rows {
            ranges.push(row?);
        }
        Ok(ranges)
    }

    /// Switches the upload identity atomically.  A new account/device generation gets a fresh
    /// sequence stream and is seeded only with retained local events at or after its privacy lower
    /// bound; old account requests and receipts cannot be replayed under the new identity.
    pub fn ensure_usage_context(
        &self,
        account_id: &str,
        device_id: &str,
        generation: u64,
        aggregation_timezone: &str,
        lower_bound: &str,
    ) -> Result<u64, StateError> {
        let lower_bound =
            DateTime::parse_from_rfc3339(lower_bound).map_err(|_| StateError::InvalidState)?;
        if account_id.is_empty() || device_id.is_empty() || generation == 0 {
            return Err(StateError::InvalidState);
        }
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        let current: Option<(String, String, i64, String, String)> = tx
            .query_row(
                "SELECT account_id, device_id, generation, aggregation_timezone, lower_bound
                 FROM usage_upload_context WHERE id = 1",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .optional()?;
        let unchanged = current.as_ref().is_some_and(|current| {
            current.0 == account_id
                && current.1 == device_id
                && current.2 == generation as i64
                && current.3 == aggregation_timezone
                && current.4 == lower_bound.to_rfc3339_opts(SecondsFormat::AutoSi, true)
        });
        if unchanged {
            let revision = metadata_u64(&tx, "revision")?;
            tx.commit()?;
            return Ok(revision);
        }
        crate::compatibility::retain_released_outbox(
            &tx,
            current.is_none(),
            account_id,
            device_id,
            generation,
        )?;
        tx.execute("DELETE FROM usage_dirty_ranges", [])?;
        tx.execute(
            "INSERT INTO usage_upload_context(
                id, account_id, device_id, generation, aggregation_timezone, lower_bound
             ) VALUES (1, ?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET
                account_id = excluded.account_id,
                device_id = excluded.device_id,
                generation = excluded.generation,
                aggregation_timezone = excluded.aggregation_timezone,
                lower_bound = excluded.lower_bound",
            params![
                account_id,
                device_id,
                generation,
                aggregation_timezone,
                lower_bound.to_rfc3339_opts(SecondsFormat::AutoSi, true)
            ],
        )?;
        let mut statement = tx.prepare("SELECT agent, occurred_at FROM usage_file_records")?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        let mut hours_by_agent: BTreeMap<UsageAgent, Vec<String>> = BTreeMap::new();
        for (agent_raw, occurred_at) in rows {
            let Some(agent) = parse_usage_agent(&agent_raw) else {
                continue;
            };
            let Ok(occurred_at) = DateTime::parse_from_rfc3339(&occurred_at) else {
                continue;
            };
            if occurred_at < lower_bound {
                continue;
            }
            hours_by_agent
                .entry(agent)
                .or_default()
                .push(floor_hour(occurred_at).to_rfc3339_opts(SecondsFormat::Secs, true));
        }
        for (agent, mut hours) in hours_by_agent {
            hours.sort_unstable();
            hours.dedup();
            mark_dirty_hours(&tx, agent, hours)?;
        }
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
    }

    /// Removes only an uploaded portion of a dirty range.  Any not-yet-complete tail is put back
    /// in the table so a refresh before the next UTC hour cannot lose the active hour.
    #[cfg(test)]
    pub fn consume_dirty_usage_range(&self, consumed: &UsageDirtyRange) -> Result<u64, StateError> {
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        let changed = consume_dirty_usage_range_tx(&tx, consumed)?;
        if changed == 0 {
            let revision = metadata_u64(&tx, "revision")?;
            tx.commit()?;
            return Ok(revision);
        }
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
    }

    pub fn apply_usage_scan(
        &self,
        agent: UsageAgent,
        scan: &UsageScanResult,
    ) -> Result<u64, StateError> {
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        let tx = conn.transaction()?;
        let mut changed = 0usize;
        for source in &scan.sources {
            let old_events = record_events(&tx, agent, &source.source.source_file_id)?;
            tx.execute(
                "DELETE FROM usage_file_records WHERE agent = ?1 AND source_file_id = ?2",
                params![agent.as_str(), source.source.source_file_id],
            )?;
            for (record_index, event) in source.records.iter().enumerate() {
                let event_json = serde_json::to_string(event)?;
                if event_json.len() > crate::relay::MAXIMUM_REQUEST_BYTES {
                    return Err(StateError::InvalidState);
                }
                tx.execute(
                    "INSERT INTO usage_file_records(
                        agent, source_file_id, record_index, occurred_at, event_json
                     ) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![
                        agent.as_str(),
                        source.source.source_file_id,
                        record_index as i64,
                        event.occurred_at,
                        event_json,
                    ],
                )?;
            }
            changed += tx.execute(
                "INSERT INTO usage_file_index(
                    agent, source_file_id, identity, size, modified_ns, parser_revision
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(agent, source_file_id) DO UPDATE SET
                    identity = excluded.identity,
                    size = excluded.size,
                    modified_ns = excluded.modified_ns,
                    parser_revision = excluded.parser_revision",
                params![
                    agent.as_str(),
                    source.source.source_file_id,
                    source.source.identity,
                    source.source.size as i64,
                    source.source.modified_ns.to_string(),
                    source.index.parser_revision,
                ],
            )?;
            mark_dirty_hours(
                &tx,
                agent,
                changed_event_hours(&old_events, &source.records)?,
            )?;
        }
        for source_file_id in &scan.deleted_source_file_ids {
            let old_events = record_events(&tx, agent, source_file_id)?;
            tx.execute(
                "DELETE FROM usage_file_records WHERE agent = ?1 AND source_file_id = ?2",
                params![agent.as_str(), source_file_id],
            )?;
            changed += tx.execute(
                "DELETE FROM usage_file_index WHERE agent = ?1 AND source_file_id = ?2",
                params![agent.as_str(), source_file_id],
            )?;
            mark_dirty_hours(&tx, agent, changed_event_hours(&old_events, &[])?)?;
        }
        if changed == 0 {
            let revision = metadata_u64(&tx, "revision")?;
            tx.commit()?;
            return Ok(revision);
        }
        let revision = bump_revision(&tx)?;
        tx.commit()?;
        Ok(revision)
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct UsageDirtyRange {
    pub agent: UsageAgent,
    pub start_at: String,
    pub end_at: String,
}

fn consume_dirty_usage_range_tx(
    tx: &rusqlite::Transaction<'_>,
    consumed: &UsageDirtyRange,
) -> Result<usize, StateError> {
    let consumed_start =
        DateTime::parse_from_rfc3339(&consumed.start_at).map_err(|_| StateError::InvalidState)?;
    let consumed_end =
        DateTime::parse_from_rfc3339(&consumed.end_at).map_err(|_| StateError::InvalidState)?;
    if consumed_start >= consumed_end {
        return Ok(0);
    }
    let mut changed = 0usize;
    let mut statement =
        tx.prepare("SELECT start_at, end_at FROM usage_dirty_ranges WHERE agent = ?1")?;
    let rows = statement
        .query_map(params![consumed.agent.as_str()], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for (old_start_raw, old_end_raw) in rows {
        let (Ok(old_start), Ok(old_end)) = (
            DateTime::parse_from_rfc3339(&old_start_raw),
            DateTime::parse_from_rfc3339(&old_end_raw),
        ) else {
            continue;
        };
        if old_end <= consumed_start || old_start >= consumed_end {
            continue;
        }
        tx.execute(
            "DELETE FROM usage_dirty_ranges WHERE agent = ?1 AND start_at = ?2 AND end_at = ?3",
            params![consumed.agent.as_str(), old_start_raw, old_end_raw],
        )?;
        changed += 1;
        let overlap_start = old_start.max(consumed_start);
        let overlap_end = old_end.min(consumed_end);
        if old_start < overlap_start {
            tx.execute(
                "INSERT OR IGNORE INTO usage_dirty_ranges(agent, start_at, end_at) VALUES (?1, ?2, ?3)",
                params![
                    consumed.agent.as_str(),
                    old_start.to_rfc3339_opts(SecondsFormat::Secs, true),
                    overlap_start.to_rfc3339_opts(SecondsFormat::Secs, true)
                ],
            )?;
        }
        if overlap_end < old_end {
            tx.execute(
                "INSERT OR IGNORE INTO usage_dirty_ranges(agent, start_at, end_at) VALUES (?1, ?2, ?3)",
                params![
                    consumed.agent.as_str(),
                    overlap_end.to_rfc3339_opts(SecondsFormat::Secs, true),
                    old_end.to_rfc3339_opts(SecondsFormat::Secs, true)
                ],
            )?;
        }
    }
    Ok(changed)
}

fn parse_usage_agent(value: &str) -> Option<UsageAgent> {
    Some(match value {
        "codex" => UsageAgent::Codex,
        "claude_code" => UsageAgent::ClaudeCode,
        "grok" => UsageAgent::Grok,
        "opencode" => UsageAgent::OpenCode,
        "pi" => UsageAgent::Pi,
        _ => return None,
    })
}

fn record_events(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    source_file_id: &str,
) -> Result<Vec<(String, String)>, StateError> {
    let mut statement = tx.prepare(
        "SELECT occurred_at, event_json FROM usage_file_records
         WHERE agent = ?1 AND source_file_id = ?2",
    )?;
    let rows = statement.query_map(params![agent.as_str(), source_file_id], |row| {
        Ok((row.get(0)?, row.get(1)?))
    })?;
    let mut events = Vec::new();
    for row in rows {
        events.push(row?);
    }
    Ok(events)
}

fn changed_event_hours(
    old_events: &[(String, String)],
    new_events: &[NormalizedUsageEvent],
) -> Result<Vec<String>, StateError> {
    let mut old_by_hour: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut new_by_hour: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (occurred_at, event_json) in old_events {
        let hour = event_hour(occurred_at)?;
        old_by_hour
            .entry(hour)
            .or_default()
            .push(event_json.clone());
    }
    for event in new_events {
        let event_json = serde_json::to_string(event)?;
        let hour = event_hour(&event.occurred_at)?;
        new_by_hour.entry(hour).or_default().push(event_json);
    }
    for values in old_by_hour.values_mut() {
        values.sort_unstable();
    }
    for values in new_by_hour.values_mut() {
        values.sort_unstable();
    }
    let mut hours = old_by_hour
        .keys()
        .chain(new_by_hour.keys())
        .cloned()
        .collect::<Vec<_>>();
    hours.sort_unstable();
    hours.dedup();
    Ok(hours
        .into_iter()
        .filter(|hour| old_by_hour.get(hour) != new_by_hour.get(hour))
        .collect())
}

fn event_hour(value: &str) -> Result<String, StateError> {
    let instant = DateTime::parse_from_rfc3339(value).map_err(|_| StateError::InvalidState)?;
    Ok(floor_hour(instant).to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn mark_dirty_hours(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    hours: Vec<String>,
) -> Result<(), StateError> {
    for hour in hours {
        let start = DateTime::parse_from_rfc3339(&hour).map_err(|_| StateError::InvalidState)?;
        merge_dirty_range(tx, agent, start, start + Duration::hours(1))?;
    }
    Ok(())
}

fn merge_dirty_range(
    tx: &rusqlite::Transaction<'_>,
    agent: UsageAgent,
    mut start: DateTime<chrono::FixedOffset>,
    mut end: DateTime<chrono::FixedOffset>,
) -> Result<(), StateError> {
    let mut statement =
        tx.prepare("SELECT start_at, end_at FROM usage_dirty_ranges WHERE agent = ?1")?;
    let rows = statement.query_map(params![agent.as_str()], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut overlaps = Vec::new();
    for row in rows {
        let (old_start, old_end) = row?;
        let (Ok(old_start), Ok(old_end)) = (
            DateTime::parse_from_rfc3339(&old_start),
            DateTime::parse_from_rfc3339(&old_end),
        ) else {
            continue;
        };
        if old_end >= start && old_start <= end {
            start = start.min(old_start);
            end = end.max(old_end);
            overlaps.push((old_start, old_end));
        }
    }
    drop(statement);
    for (old_start, old_end) in &overlaps {
        tx.execute(
            "DELETE FROM usage_dirty_ranges WHERE agent = ?1 AND start_at = ?2 AND end_at = ?3",
            params![
                agent.as_str(),
                old_start.to_rfc3339_opts(SecondsFormat::Secs, true),
                old_end.to_rfc3339_opts(SecondsFormat::Secs, true)
            ],
        )?;
    }
    tx.execute(
        "INSERT OR IGNORE INTO usage_dirty_ranges(agent, start_at, end_at) VALUES (?1, ?2, ?3)",
        params![
            agent.as_str(),
            start.to_rfc3339_opts(SecondsFormat::Secs, true),
            end.to_rfc3339_opts(SecondsFormat::Secs, true)
        ],
    )?;
    Ok(())
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

fn read_overview(conn: &Connection) -> Result<Vec<QuotaOverviewItem>, StateError> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT value FROM metadata WHERE key = 'overview_json'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|value| serde_json::from_str(&value).map_err(StateError::from))
        .unwrap_or_else(|| Ok(Vec::new()))
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

fn metadata_u64(conn: &Connection, key: &str) -> Result<u64, StateError> {
    let raw: String = conn.query_row(
        "SELECT value FROM metadata WHERE key = ?1",
        params![key],
        |row| row.get(0),
    )?;
    raw.parse().map_err(|_| StateError::InvalidState)
}

fn metadata_value(conn: &Connection, key: &str) -> Result<Option<String>, StateError> {
    conn.query_row(
        "SELECT value FROM metadata WHERE key = ?1",
        params![key],
        |row| row.get(0),
    )
    .optional()
    .map_err(StateError::from)
}

fn bump_revision(conn: &Connection) -> Result<u64, StateError> {
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
                "account_refresh_token": "account-refresh",
                "device_refresh_token": "device-refresh"
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
    fn usage_outbox_is_bounded_without_consuming_more_dirty_state() {
        let root = std::env::temp_dir().join(format!("quota-outbox-cap-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let consumed = UsageDirtyRange {
            agent: UsageAgent::Codex,
            start_at: "2026-08-10T12:00:00Z".into(),
            end_at: "2026-08-10T13:00:00Z".into(),
        };

        for sequence in 0..MAX_USAGE_OUTBOX_ENTRIES {
            let value = serde_json::json!({
                "submission_id": format!("submission_{sequence}"),
                "device_id": "device_test",
                "generation": 1,
                "sequence": sequence
            });
            assert!(
                store
                    .stage_outbox_entry("account_test", &value, &consumed)
                    .expect("stage")
            );
        }
        let overflow = serde_json::json!({
            "submission_id": "submission_overflow",
            "device_id": "device_test",
            "generation": 1,
            "sequence": MAX_USAGE_OUTBOX_ENTRIES
        });
        assert!(matches!(
            store.stage_outbox_entry("account_test", &overflow, &consumed),
            Err(StateError::Unavailable)
        ));
        assert_eq!(
            store.outbox_entries().expect("entries").len(),
            MAX_USAGE_OUTBOX_ENTRIES as usize
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn usage_dirty_hours_compare_canonical_old_and_new_file_rows() {
        let root = std::env::temp_dir().join(format!("quota-usage-state-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let first = usage_event("2026-08-10T12:15:00Z", 1);
        let second = usage_event("2026-08-10T13:15:00Z", 2);
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![first.clone(), second.clone()], 1),
            )
            .expect("initial scan");
        assert_eq!(store.dirty_usage_ranges().expect("dirty").len(), 1);
        store
            .consume_dirty_usage_range(&UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-10T12:00:00Z".into(),
                end_at: "2026-08-10T14:00:00Z".into(),
            })
            .expect("clear initial");

        let appended = usage_event("2026-08-10T14:15:00Z", 3);
        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(vec![first.clone(), second.clone(), appended], 2),
            )
            .expect("append scan");
        assert_eq!(
            store.dirty_usage_ranges().expect("dirty"),
            vec![UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-10T14:00:00Z".into(),
                end_at: "2026-08-10T15:00:00Z".into(),
            }]
        );
        store
            .consume_dirty_usage_range(&UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-10T14:00:00Z".into(),
                end_at: "2026-08-10T15:00:00Z".into(),
            })
            .expect("clear append");

        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(
                    vec![
                        first.clone(),
                        second.clone(),
                        usage_event("2026-08-10T14:15:00Z", 3),
                    ],
                    2,
                ),
            )
            .expect("equivalent rewrite");
        assert!(store.dirty_usage_ranges().expect("dirty").is_empty());

        store
            .apply_usage_scan(
                UsageAgent::Codex,
                &usage_scan(
                    vec![
                        usage_event("2026-08-10T12:15:00Z", 9),
                        second,
                        usage_event("2026-08-10T14:15:00Z", 3),
                    ],
                    3,
                ),
            )
            .expect("old hour edit");
        assert_eq!(
            store.dirty_usage_ranges().expect("dirty"),
            vec![UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-10T12:00:00Z".into(),
                end_at: "2026-08-10T13:00:00Z".into(),
            }]
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn usage_parser_upgrade_replaces_unreadable_old_event_json() {
        let root = std::env::temp_dir().join(format!("quota-usage-upgrade-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let event = usage_event("2026-08-10T12:15:00Z", 1);
        store
            .apply_usage_scan(UsageAgent::Codex, &usage_scan(vec![event.clone()], 1))
            .expect("initial scan");
        store
            .consume_dirty_usage_range(&UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-10T12:00:00Z".into(),
                end_at: "2026-08-10T13:00:00Z".into(),
            })
            .expect("clear initial");
        store
            .db
            .lock()
            .expect("database")
            .execute(
                "UPDATE usage_file_records SET event_json = '{\"legacy\":true}'",
                [],
            )
            .expect("corrupt old wire value");

        store
            .apply_usage_scan(UsageAgent::Codex, &usage_scan(vec![event], 2))
            .expect("parser upgrade");
        assert_eq!(
            store.dirty_usage_ranges().expect("dirty"),
            vec![UsageDirtyRange {
                agent: UsageAgent::Codex,
                start_at: "2026-08-10T12:00:00Z".into(),
                end_at: "2026-08-10T13:00:00Z".into(),
            }]
        );
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn first_context_preserves_matching_released_outbox_until_acknowledged() {
        let root = std::env::temp_dir().join(format!("quota-legacy-outbox-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let installation_id = Uuid::new_v4().to_string();
        fs::write(
            root.join("installation.json"),
            serde_json::json!({
                "schema_version": 1,
                "installation_id": installation_id,
                "account_bindings": []
            })
            .to_string(),
        )
        .expect("installation");
        fs::set_permissions(
            root.join("installation.json"),
            Permissions::from_mode(0o600),
        )
        .expect("installation permissions");
        let entry = serde_json::json!({
            "protocol_version": 2,
            "submission_id": "submission_legacy_unknown",
            "device_id": "device_test",
            "generation": 3,
            "sequence": 0,
            "parser_revision": "quota-usage-4",
            "aggregation_timezone": "UTC",
            "coverage": {
                "agent": "codex",
                "start_at": "2026-08-09T10:00:00Z",
                "end_at": "2026-08-09T11:00:00Z",
                "status": "complete"
            },
            "rows": []
        });
        fs::write(
            root.join("usage-outbox.json"),
            serde_json::json!({
                "schema_version": 1,
                "queues": [{
                    "account_id": "account_test",
                    "device_id": "device_test",
                    "generation": 3,
                    "entries": [entry]
                }]
            })
            .to_string(),
        )
        .expect("outbox");
        fs::set_permissions(
            root.join("usage-outbox.json"),
            Permissions::from_mode(0o600),
        )
        .expect("outbox permissions");
        let store = StateStore::open(&root).expect("state");
        store
            .ensure_usage_context(
                "account_test",
                "device_test",
                3,
                "UTC",
                "1970-01-01T00:00:00Z",
            )
            .expect("context");
        assert_eq!(store.outbox_entries().expect("entries").len(), 1);
        assert!(
            store
                .acknowledge_outbox_entry("submission_legacy_unknown")
                .expect("ack")
        );
        assert!(store.outbox_entries().expect("entries").is_empty());
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
            unchanged_source_file_ids: Vec::new(),
            deleted_source_file_ids: Vec::new(),
            sources: vec![UsageSourceScan {
                index: UsageFileIndex {
                    source_file_id: "source-1".into(),
                    identity: "identity-1".into(),
                    size: events.len() as u64,
                    modified_ns,
                    parser_revision: "usage-rust-v3".into(),
                },
                source,
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
