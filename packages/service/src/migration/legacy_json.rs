//! One-time local import for the QuotaBar 0.0.6/0.0.7 native cutover.
//!
//! This module reads the released 0.0.5 JSON artifacts under `state.lock`, writes them into the
//! SQLite owner, and removes each source only after the transaction is readable. It is scheduled
//! for removal with the compatibility module in QuotaBar 0.0.8.

use std::fs::{self, OpenOptions, Permissions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::Value;
use uuid::Uuid;

use crate::state::StateError;

const CURRENT_SCHEMA: i64 = 1;
const MAX_LEGACY_ARTIFACT_BYTES: usize = 1_048_576;
const MAX_LEGACY_CONTEXTS: usize = 32;
const MAX_LEGACY_OUTBOX_ENTRIES: usize = 64;
const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

struct ImportedFile {
    path: PathBuf,
    device: u64,
    inode: u64,
}

/// The released QuotaCLI protects all legacy JSON artifacts with this directory lock.  The
/// first native service open must take the same lock before it reads or removes those artifacts;
/// the service lifetime `flock` is a different boundary and cannot coordinate with the shipped
/// CLI process.
struct LegacyStateLock {
    path: PathBuf,
}

impl LegacyStateLock {
    fn acquire(root: &Path) -> Result<Self, StateError> {
        let path = root.join("state.lock");
        let owner = path.join("owner");
        let reclaim = root.join("state.lock.reclaim");
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            match fs::create_dir(&path) {
                Ok(()) => {
                    fs::set_permissions(&path, Permissions::from_mode(0o700))?;
                    let mut file = OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .mode(0o600)
                        .open(&owner)?;
                    writeln!(file, "{}", std::process::id())?;
                    file.sync_all()?;
                    return Ok(Self { path });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    if legacy_lock_is_stale(&path, &owner) && acquire_reclaim_guard(&reclaim, root)
                    {
                        let discarded =
                            root.join(format!(".state.lock.discarded.{}", uuid::Uuid::new_v4()));
                        if fs::rename(&path, &discarded).is_ok() {
                            let _ = fs::remove_dir_all(discarded);
                            let _ = fs::remove_dir(&reclaim);
                            continue;
                        }
                        let _ = fs::remove_dir(&reclaim);
                    }
                    if std::time::Instant::now() >= deadline {
                        return Err(StateError::Unavailable);
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                Err(_) => return Err(StateError::Unavailable),
            }
        }
    }
}

impl Drop for LegacyStateLock {
    fn drop(&mut self) {
        let Some(root) = self.path.parent() else {
            return;
        };
        let discarded = root.join(format!(".state.lock.discarded.{}", uuid::Uuid::new_v4()));
        if fs::rename(&self.path, &discarded).is_ok() {
            let _ = fs::remove_dir_all(discarded);
        }
    }
}

fn acquire_reclaim_guard(path: &Path, root: &Path) -> bool {
    match fs::create_dir(path) {
        Ok(()) => true,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let stale = fs::symlink_metadata(path)
                .ok()
                .and_then(|metadata| metadata.modified().ok())
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age > Duration::from_secs(1));
            if stale {
                let discarded = root.join(format!(
                    ".state.lock.reclaim.discarded.{}",
                    uuid::Uuid::new_v4()
                ));
                if fs::rename(path, &discarded).is_ok() {
                    let _ = fs::remove_dir_all(discarded);
                }
            }
            false
        }
        Err(_) => false,
    }
}

fn legacy_lock_is_stale(path: &Path, owner: &Path) -> bool {
    let Some(metadata) = fs::symlink_metadata(path).ok() else {
        return false;
    };
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return false;
    }
    let pid = fs::read_to_string(owner)
        .ok()
        .and_then(|value| value.trim().parse::<libc::pid_t>().ok());
    if let Some(pid) = pid.filter(|pid| *pid > 0) {
        let result = unsafe { libc::kill(pid, 0) };
        if result == 0 {
            return false;
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
            return false;
        }
        return true;
    }
    metadata
        .modified()
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age > Duration::from_secs(1))
}

pub fn apply(conn: &mut Connection, root: &Path) -> Result<(), StateError> {
    // Hold the published directory lock for schema creation, JSON import, source cleanup, and
    // marker commit.  A crashed importer is reclaimed by the next opener before retrying.
    let _legacy_lock = LegacyStateLock::acquire(root)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );",
    )?;

    let current: i64 = conn.query_row(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
        [],
        |row| row.get(0),
    )?;
    if current > CURRENT_SCHEMA {
        return Err(StateError::ClientUpgradeRequired);
    }
    if current < CURRENT_SCHEMA {
        let tx = conn.transaction()?;
        create_schema(&tx)?;
        tx.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?1, ?2)",
            params![CURRENT_SCHEMA, crate::state::now_rfc3339()],
        )?;
        tx.commit()?;
    }

    // Import only once.  This marker also makes a failed import retryable without duplicating
    // outbox entries.  Files are removed only after the transaction and a fresh read succeed.
    let imported = metadata(conn, "legacy_import_complete")?;
    if imported.as_deref() != Some("1") {
        let paths = import_legacy(conn, root)?;
        for path in paths {
            remove_imported_file(&path)?;
        }
        conn.execute(
            "INSERT INTO metadata(key, value) VALUES ('legacy_import_complete', '1')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )?;
    }
    ensure_installation(conn)?;
    Ok(())
}

fn create_schema(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS components (
            name TEXT PRIMARY KEY NOT NULL,
            status TEXT NOT NULL,
            value_json TEXT,
            updated_at TEXT,
            last_error_code TEXT,
            last_error_action TEXT,
            refreshing INTEGER NOT NULL DEFAULT 0 CHECK (refreshing IN (0, 1))
        );
        CREATE TABLE IF NOT EXISTS installation (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            installation_id TEXT NOT NULL,
            payload_json TEXT
        );
        CREATE TABLE IF NOT EXISTS session (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload_json TEXT NOT NULL,
            epoch INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS legacy_artifacts (
            name TEXT PRIMARY KEY NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_outbox (
            submission_id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            generation INTEGER NOT NULL,
            sequence INTEGER NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS usage_outbox_order
            ON usage_outbox(account_id, device_id, generation, sequence);
        CREATE TABLE IF NOT EXISTS usage_file_index (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            identity TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_ns TEXT NOT NULL,
            parser_revision TEXT NOT NULL,
            PRIMARY KEY(agent, source_file_id)
        );
        CREATE TABLE IF NOT EXISTS usage_file_records (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            record_index INTEGER NOT NULL,
            occurred_at TEXT NOT NULL,
            event_json TEXT NOT NULL,
            PRIMARY KEY(agent, source_file_id, record_index)
        );
        CREATE INDEX IF NOT EXISTS usage_file_records_time
            ON usage_file_records(agent, occurred_at);
        CREATE TABLE IF NOT EXISTS usage_upload_context (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            account_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            generation INTEGER NOT NULL,
            aggregation_timezone TEXT NOT NULL,
            lower_bound TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_dirty_ranges (
            agent TEXT NOT NULL,
            start_at TEXT NOT NULL,
            end_at TEXT NOT NULL,
            PRIMARY KEY(agent, start_at, end_at)
        );
        INSERT INTO metadata(key, value) VALUES ('revision', '0')
            ON CONFLICT(key) DO NOTHING;",
    )?;
    Ok(())
}

fn import_legacy(conn: &mut Connection, root: &Path) -> Result<Vec<ImportedFile>, StateError> {
    let names = [
        "installation.json",
        "session.json",
        "usage-cache.json",
        "usage-outbox.json",
        "pricing-catalog.json",
    ];
    let mut imported = Vec::new();
    let tx = conn.transaction()?;

    for name in names {
        let path = root.join(name);
        let Some((value, source)) = read_legacy_file(path)? else {
            continue;
        };
        match name {
            "installation.json" => import_installation(&tx, &value)?,
            "session.json" => {
                tx.execute(
                    "INSERT INTO session(id, payload_json, epoch) VALUES (1, ?1, 0)
                     ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json",
                    params![serde_json::to_string(&value).map_err(|_| StateError::InvalidState)?],
                )?;
            }
            "usage-outbox.json" => import_usage_outbox(&tx, &value)?,
            _ => {
                tx.execute(
                    "INSERT INTO legacy_artifacts(name, payload_json) VALUES (?1, ?2)
                     ON CONFLICT(name) DO NOTHING",
                    params![
                        name,
                        serde_json::to_string(&value).map_err(|_| StateError::InvalidState)?
                    ],
                )?;
                if name == "pricing-catalog.json"
                    && let Some(etag) = value
                        .get("etag")
                        .and_then(Value::as_str)
                        .filter(|etag| etag.len() <= 256 && etag.trim() == *etag)
                {
                    tx.execute(
                        "INSERT INTO metadata(key, value) VALUES ('pricing_etag', ?1)
                         ON CONFLICT(key) DO NOTHING",
                        params![etag],
                    )?;
                }
            }
        }
        imported.push(source);
    }

    tx.commit()?;
    Ok(imported)
}

fn import_installation(tx: &Transaction<'_>, value: &Value) -> Result<(), StateError> {
    let installation_id = value
        .get("installation_id")
        .and_then(Value::as_str)
        .filter(|v| Uuid::parse_str(v).is_ok())
        .ok_or(StateError::InvalidState)?;
    tx.execute(
        "INSERT INTO installation(id, installation_id, payload_json) VALUES (1, ?1, ?2)
         ON CONFLICT(id) DO UPDATE SET installation_id = excluded.installation_id,
         payload_json = excluded.payload_json",
        params![
            installation_id,
            serde_json::to_string(value).map_err(|_| StateError::InvalidState)?
        ],
    )?;
    Ok(())
}

fn import_usage_outbox(tx: &Transaction<'_>, value: &Value) -> Result<(), StateError> {
    let artifact = value.as_object().ok_or(StateError::InvalidState)?;
    if artifact.len() != 2
        || artifact.get("schema_version").and_then(Value::as_i64) != Some(1)
        || !artifact.contains_key("queues")
    {
        return Err(StateError::InvalidState);
    }
    let queues = value
        .get("queues")
        .and_then(Value::as_array)
        .filter(|queues| queues.len() <= MAX_LEGACY_CONTEXTS)
        .ok_or(StateError::InvalidState)?;
    for queue in queues {
        let queue_object = queue.as_object().ok_or(StateError::InvalidState)?;
        if queue_object.len() != 4
            || ["account_id", "device_id", "generation", "entries"]
                .iter()
                .any(|key| !queue_object.contains_key(*key))
        {
            return Err(StateError::InvalidState);
        }
        let account_id = queue
            .get("account_id")
            .and_then(Value::as_str)
            .filter(|value| valid_legacy_id(value))
            .ok_or(StateError::InvalidState)?;
        let device_id = queue
            .get("device_id")
            .and_then(Value::as_str)
            .filter(|value| valid_legacy_id(value))
            .ok_or(StateError::InvalidState)?;
        let generation = queue
            .get("generation")
            .and_then(Value::as_i64)
            .filter(|value| (1..=MAX_SAFE_INTEGER).contains(value))
            .ok_or(StateError::InvalidState)?;
        let entries = queue
            .get("entries")
            .and_then(Value::as_array)
            .filter(|entries| entries.len() <= MAX_LEGACY_OUTBOX_ENTRIES)
            .ok_or(StateError::InvalidState)?;
        for entry in entries {
            crate::relay::validate_usage_submission(entry).map_err(|_| StateError::InvalidState)?;
            let submission_id = entry
                .get("submission_id")
                .and_then(Value::as_str)
                .filter(|value| valid_legacy_id(value))
                .ok_or(StateError::InvalidState)?;
            let sequence = entry
                .get("sequence")
                .and_then(Value::as_i64)
                .filter(|value| (0..=MAX_SAFE_INTEGER).contains(value))
                .ok_or(StateError::InvalidState)?;
            if entry.get("device_id").and_then(Value::as_str) != Some(device_id)
                || entry.get("generation").and_then(Value::as_i64) != Some(generation)
            {
                return Err(StateError::InvalidState);
            }
            tx.execute(
                "INSERT INTO usage_outbox(submission_id, account_id, device_id, generation, sequence, payload_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(submission_id) DO NOTHING",
                params![
                    submission_id,
                    account_id,
                    device_id,
                    generation,
                    sequence,
                    serde_json::to_string(entry).map_err(|_| StateError::InvalidState)?
                ],
            )?;
        }
    }
    Ok(())
}

fn ensure_installation(conn: &Connection) -> Result<(), StateError> {
    let existing: Option<String> = conn
        .query_row(
            "SELECT installation_id FROM installation WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if existing.is_none() {
        conn.execute(
            "INSERT INTO installation(id, installation_id) VALUES (1, ?1)",
            params![Uuid::new_v4().to_string()],
        )?;
    }
    Ok(())
}

fn metadata(conn: &Connection, key: &str) -> Result<Option<String>, StateError> {
    conn.query_row(
        "SELECT value FROM metadata WHERE key = ?1",
        params![key],
        |row| row.get(0),
    )
    .optional()
    .map_err(StateError::from)
}

fn read_legacy_file(path: PathBuf) -> Result<Option<(Value, ImportedFile)>, StateError> {
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) if error.raw_os_error() == Some(libc::ELOOP) => {
            return Err(StateError::InvalidState);
        }
        Err(_) => return Err(StateError::Unavailable),
    };
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.permissions().mode() & 0o777 != 0o600
        || metadata.len() > MAX_LEGACY_ARTIFACT_BYTES as u64
    {
        return Err(StateError::InvalidState);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    Read::take(&mut file, (MAX_LEGACY_ARTIFACT_BYTES + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > MAX_LEGACY_ARTIFACT_BYTES {
        return Err(StateError::InvalidState);
    }
    let value = serde_json::from_slice(&bytes).map_err(|_| StateError::InvalidState)?;
    let imported = ImportedFile {
        path,
        device: metadata.dev(),
        inode: metadata.ino(),
    };
    Ok(Some((value, imported)))
}

fn remove_imported_file(source: &ImportedFile) -> Result<(), StateError> {
    let metadata = match fs::symlink_metadata(&source.path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(StateError::Unavailable),
    };
    if !metadata.is_file() || metadata.dev() != source.device || metadata.ino() != source.inode {
        return Err(StateError::InvalidState);
    }
    match fs::remove_file(&source.path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(StateError::Unavailable),
    }
    if let Some(parent) = source.path.parent() {
        let _ = fs::File::open(parent).and_then(|file| file.sync_all());
    }
    Ok(())
}

fn valid_legacy_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && value.trim() == value
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn migration_lock_uses_released_state_lock_name_and_releases_safely() {
        let root = std::env::temp_dir().join(format!("quota-migration-lock-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let lock = LegacyStateLock::acquire(&root).expect("lock");
        assert!(root.join("state.lock").is_dir());
        assert!(root.join("state.lock/owner").is_file());
        drop(lock);
        assert!(!root.join("state.lock").exists());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn legacy_import_rejects_symlinks_and_permissive_files() {
        let root = std::env::temp_dir().join(format!("quota-migration-file-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let target = root.join("target.json");
        fs::write(&target, "{}").expect("target");
        fs::set_permissions(&target, Permissions::from_mode(0o600)).expect("target permissions");
        let linked = root.join("session.json");
        symlink(&target, &linked).expect("symlink");
        assert!(matches!(
            read_legacy_file(linked),
            Err(StateError::InvalidState)
        ));

        let permissive = root.join("installation.json");
        fs::write(&permissive, "{}").expect("permissive");
        fs::set_permissions(&permissive, Permissions::from_mode(0o644))
            .expect("permissive permissions");
        assert!(matches!(
            read_legacy_file(permissive),
            Err(StateError::InvalidState)
        ));
        fs::remove_dir_all(root).expect("cleanup");
    }
}
