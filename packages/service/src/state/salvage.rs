//! Durable-image salvage: copy identity and last-good rows, never Usage trees.

use std::fs::{self, OpenOptions, Permissions};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, params};

use super::{StateError, now_rfc3339};
use crate::migration;

const LIVE_NAME: &str = "state.sqlite";
const BROKEN_NAME: &str = "state.sqlite.broken";
const SALVAGE_NAME: &str = "state.sqlite.salvage";

const REQUIRED_COPY_TABLES: &[&str] = &[
    "installation",
    "session",
    "components",
    "metadata",
    "provider_browser_sessions",
    "usage_upload_context",
    "usage_outbox",
];

const BEST_EFFORT_COPY_TABLES: &[&str] = &[
    "model_catalog_cache",
    "diagnostic_attempts",
    "usage_period_cache",
];

const PROBE_TABLES: &[&str] = &["installation", "session", "metadata", "components"];

pub(super) fn sqlite_durable_corruption(error: &rusqlite::Error) -> bool {
    if let rusqlite::Error::SqliteFailure(code, _) = error {
        if matches!(
            code.code,
            ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase
        ) {
            return true;
        }
        if matches!(
            code.code,
            ErrorCode::SystemIoFailure | ErrorCode::CannotOpen | ErrorCode::DiskFull
        ) {
            return false;
        }
    }
    message_looks_like_durable_corruption(error)
}

pub(super) fn sqlite_io_or_full(error: &rusqlite::Error) -> bool {
    match error {
        rusqlite::Error::SqliteFailure(code, _) => matches!(
            code.code,
            ErrorCode::SystemIoFailure | ErrorCode::CannotOpen | ErrorCode::DiskFull
        ),
        _ => false,
    }
}

pub(super) fn sqlite_durable_corruption_error(error: &StateError) -> bool {
    match error {
        StateError::Sql(error) => sqlite_durable_corruption(error),
        _ => false,
    }
}

pub(super) fn sqlite_io_or_full_error(error: &StateError) -> bool {
    match error {
        StateError::Io(_) => true,
        StateError::Sql(error) => sqlite_io_or_full(error),
        _ => false,
    }
}

fn message_looks_like_durable_corruption(error: &rusqlite::Error) -> bool {
    let message = error.to_string().to_ascii_lowercase();
    message.contains("corrupt")
        || message.contains("malformed")
        || message.contains("database disk image")
        || message.contains("file is not a database")
}

pub(super) fn persist_probe_on(conn: &Connection) -> Result<(), StateError> {
    conn.execute(
        "INSERT INTO metadata(key, value) VALUES ('diagnostics_persist_probe', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![now_rfc3339()],
    )?;
    Ok(())
}

pub(super) fn open_or_salvage(root: &Path) -> Result<Connection, StateError> {
    let live_path = root.join(LIVE_NAME);
    remove_sqlite_image(&root.join(SALVAGE_NAME));
    match open_live_and_probe(&live_path) {
        Ok(connection) => Ok(connection),
        Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
        Err(error) if sqlite_durable_corruption_error(&error) => salvage_once(root, &live_path),
        Err(StateError::ClientUpgradeRequired) => Err(StateError::ClientUpgradeRequired),
        Err(error) => Err(map_open_failure(error)),
    }
}

fn map_open_failure(error: StateError) -> StateError {
    if sqlite_io_or_full_error(&error) {
        StateError::Unavailable
    } else if sqlite_durable_corruption_error(&error) {
        StateError::InvalidState
    } else {
        error
    }
}

fn open_live_and_probe(path: &Path) -> Result<Connection, StateError> {
    let mut connection = open_writable_connection(path)?;
    migration::apply(&mut connection)?;
    probe_small_image(&connection)?;
    Ok(connection)
}

fn open_writable_connection(path: &Path) -> Result<Connection, StateError> {
    let connection =
        Connection::open_with_flags(path, OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    connection.execute_batch(
        "PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = 5000;
         PRAGMA journal_mode = WAL;",
    )?;
    Ok(connection)
}

fn probe_small_image(conn: &Connection) -> Result<(), StateError> {
    persist_probe_on(conn)?;
    for table in PROBE_TABLES {
        count_probe_table(conn, table)?;
    }
    let _: Option<String> = conn
        .query_row(
            "SELECT installation_id FROM installation WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let _: Option<String> = conn
        .query_row("SELECT payload_json FROM session WHERE id = 1", [], |row| {
            row.get(0)
        })
        .optional()?;
    Ok(())
}

fn count_probe_table(conn: &Connection, table: &str) -> Result<i64, StateError> {
    let sql = match table {
        "installation" => "SELECT COUNT(*) FROM installation",
        "session" => "SELECT COUNT(*) FROM session",
        "metadata" => "SELECT COUNT(*) FROM metadata",
        "components" => "SELECT COUNT(*) FROM components",
        _ => return Err(StateError::InvalidState),
    };
    Ok(conn.query_row(sql, [], |row| row.get(0))?)
}

fn salvage_once(root: &Path, live_path: &Path) -> Result<Connection, StateError> {
    let salvage_path = root.join(SALVAGE_NAME);
    let broken_path = root.join(BROKEN_NAME);
    remove_sqlite_image(&salvage_path);
    park_live_image(live_path, &broken_path)?;
    match build_and_promote(live_path, &salvage_path, &broken_path) {
        Ok(connection) => Ok(connection),
        Err(error) if sqlite_io_or_full_error(&error) => {
            let _ = restore_parked_image(&broken_path, live_path);
            Err(StateError::Unavailable)
        }
        Err(_) => {
            let _ = restore_parked_image(&broken_path, live_path);
            Err(StateError::InvalidState)
        }
    }
}

fn build_and_promote(
    live_path: &Path,
    salvage_path: &Path,
    broken_path: &Path,
) -> Result<Connection, StateError> {
    create_owner_only_file(salvage_path)?;
    let mut salvage = open_writable_connection(salvage_path)?;
    migration::apply(&mut salvage)?;
    copy_recoverable_tables(&salvage, broken_path)?;
    apply_salvage_markers(&salvage)?;
    verify_required_identity(&salvage, broken_path)?;
    probe_small_image(&salvage)?;
    quick_check_small_image(&salvage)?;
    drop(salvage);
    promote_salvage(salvage_path, live_path)?;
    open_live_and_probe(live_path)
}

fn copy_recoverable_tables(dest: &Connection, broken_path: &Path) -> Result<(), StateError> {
    let uri = sqlite_readonly_uri(broken_path)?;
    dest.execute("ATTACH DATABASE ?1 AS broken", params![uri])?;
    let result = (|| {
        for table in REQUIRED_COPY_TABLES {
            copy_table(dest, table, true)?;
        }
        for table in BEST_EFFORT_COPY_TABLES {
            let _ = copy_table(dest, table, false);
        }
        Ok(())
    })();
    let _ = dest.execute("DETACH DATABASE broken", []);
    result
}

fn copy_table(conn: &Connection, table: &str, required: bool) -> Result<(), StateError> {
    let exists: i64 = conn.query_row(
        "SELECT COUNT(*) FROM broken.sqlite_master WHERE type = 'table' AND name = ?1",
        params![table],
        |row| row.get(0),
    )?;
    if exists == 0 {
        return Ok(());
    }
    let sql = copy_table_sql(table).ok_or(StateError::InvalidState)?;
    match conn.execute(sql, []) {
        Ok(_) => Ok(()),
        Err(error) if required => Err(StateError::Sql(error)),
        Err(_) => Ok(()),
    }
}

fn copy_table_sql(table: &str) -> Option<&'static str> {
    Some(match table {
        "installation" => "INSERT OR REPLACE INTO installation SELECT * FROM broken.installation",
        "session" => "INSERT OR REPLACE INTO session SELECT * FROM broken.session",
        "components" => "INSERT OR REPLACE INTO components SELECT * FROM broken.components",
        "metadata" => "INSERT OR REPLACE INTO metadata SELECT * FROM broken.metadata",
        "provider_browser_sessions" => {
            "INSERT OR REPLACE INTO provider_browser_sessions SELECT * FROM broken.provider_browser_sessions"
        }
        "usage_upload_context" => {
            "INSERT OR REPLACE INTO usage_upload_context SELECT * FROM broken.usage_upload_context"
        }
        "usage_outbox" => "INSERT OR REPLACE INTO usage_outbox SELECT * FROM broken.usage_outbox",
        "model_catalog_cache" => {
            "INSERT OR REPLACE INTO model_catalog_cache SELECT * FROM broken.model_catalog_cache"
        }
        "diagnostic_attempts" => {
            "INSERT OR REPLACE INTO diagnostic_attempts SELECT * FROM broken.diagnostic_attempts"
        }
        "usage_period_cache" => {
            "INSERT OR REPLACE INTO usage_period_cache SELECT * FROM broken.usage_period_cache"
        }
        _ => return None,
    })
}

fn apply_salvage_markers(conn: &Connection) -> Result<(), StateError> {
    let now = now_rfc3339();
    conn.execute(
        "INSERT INTO metadata(key, value) VALUES ('state_salvaged_at', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![now],
    )?;
    conn.execute(
        "INSERT INTO metadata(key, value) VALUES ('usage_reindex_pending', '1')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [],
    )?;
    conn.execute(
        "INSERT INTO metadata(key, value) VALUES ('snapshot_untrusted', '1')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [],
    )?;
    conn.execute(
        "DELETE FROM metadata WHERE key IN ('diagnostics_persist_probe', 'overview_json')",
        [],
    )?;
    conn.execute("UPDATE components SET refreshing = 0", [])?;
    Ok(())
}

fn verify_required_identity(salvage: &Connection, broken_path: &Path) -> Result<(), StateError> {
    let broken = open_broken_readonly(broken_path)?;
    let broken_installation: Option<String> = broken
        .query_row(
            "SELECT installation_id FROM installation WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .unwrap_or(None);
    let salvage_installation: Option<String> = salvage
        .query_row(
            "SELECT installation_id FROM installation WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(broken_id) = broken_installation
        && salvage_installation.as_deref() != Some(broken_id.as_str())
    {
        return Err(StateError::InvalidState);
    }
    let broken_has_session: bool = broken
        .query_row("SELECT 1 FROM session WHERE id = 1", [], |_| Ok(true))
        .optional()
        .ok()
        .flatten()
        .unwrap_or(false);
    if broken_has_session {
        let salvage_has_session: bool = salvage
            .query_row("SELECT 1 FROM session WHERE id = 1", [], |_| Ok(true))
            .optional()?
            .unwrap_or(false);
        if !salvage_has_session {
            return Err(StateError::InvalidState);
        }
    }
    Ok(())
}

fn open_broken_readonly(path: &Path) -> Result<Connection, StateError> {
    let uri = sqlite_readonly_uri(path)?;
    let connection = Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    connection.execute_batch("PRAGMA query_only = ON;")?;
    Ok(connection)
}

fn sqlite_readonly_uri(path: &Path) -> Result<String, StateError> {
    let path = path.to_str().ok_or(StateError::InvalidState)?;
    let mut encoded = String::with_capacity(path.len());
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'.' | b'-' | b'_' | b':' => {
                encoded.push(byte as char);
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    Ok(format!("file:{encoded}?mode=ro"))
}

fn quick_check_small_image(conn: &Connection) -> Result<(), StateError> {
    let status: String = conn.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if status == "ok" {
        Ok(())
    } else {
        Err(StateError::InvalidState)
    }
}

fn create_owner_only_file(path: &Path) -> Result<(), StateError> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(StateError::InvalidState);
    }
    file.set_permissions(Permissions::from_mode(0o600))?;
    Ok(())
}

fn park_live_image(live_path: &Path, broken_path: &Path) -> Result<(), StateError> {
    remove_sqlite_image(broken_path);
    rename_sqlite_image(live_path, broken_path)?;
    set_owner_file_mode(broken_path);
    set_owner_file_mode(&sqlite_sidecar(broken_path, "-wal"));
    set_owner_file_mode(&sqlite_sidecar(broken_path, "-shm"));
    Ok(())
}

fn restore_parked_image(broken_path: &Path, live_path: &Path) -> Result<(), StateError> {
    if !broken_path.exists() {
        return Err(StateError::InvalidState);
    }
    remove_sqlite_image(live_path);
    rename_sqlite_image(broken_path, live_path)
}

fn promote_salvage(salvage_path: &Path, live_path: &Path) -> Result<(), StateError> {
    remove_sqlite_image(live_path);
    rename_sqlite_image(salvage_path, live_path)?;
    set_owner_file_mode(live_path);
    set_owner_file_mode(&sqlite_sidecar(live_path, "-wal"));
    set_owner_file_mode(&sqlite_sidecar(live_path, "-shm"));
    Ok(())
}

fn rename_sqlite_image(from: &Path, to: &Path) -> Result<(), StateError> {
    fs::rename(from, to)?;
    let _ = fs::rename(sqlite_sidecar(from, "-wal"), sqlite_sidecar(to, "-wal"));
    let _ = fs::rename(sqlite_sidecar(from, "-shm"), sqlite_sidecar(to, "-shm"));
    Ok(())
}

fn remove_sqlite_image(path: &Path) {
    let _ = fs::remove_file(path);
    let _ = fs::remove_file(sqlite_sidecar(path, "-wal"));
    let _ = fs::remove_file(sqlite_sidecar(path, "-shm"));
}

fn sqlite_sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut raw = path.as_os_str().to_os_string();
    raw.push(suffix);
    PathBuf::from(raw)
}

fn set_owner_file_mode(path: &Path) {
    if path.exists() {
        let _ = fs::set_permissions(path, Permissions::from_mode(0o600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::StateStore;
    use rusqlite::ffi::Error as FfiError;
    use serde_json::json;
    use std::os::unix::fs::PermissionsExt;
    use uuid::Uuid;

    #[test]
    fn durable_corruption_excludes_io_and_full() {
        let corrupt = rusqlite::Error::SqliteFailure(
            FfiError {
                code: ErrorCode::DatabaseCorrupt,
                extended_code: 11,
            },
            Some("database disk image is malformed".into()),
        );
        assert!(sqlite_durable_corruption(&corrupt));
        assert!(!sqlite_io_or_full(&corrupt));

        let not_db = rusqlite::Error::SqliteFailure(
            FfiError {
                code: ErrorCode::NotADatabase,
                extended_code: 26,
            },
            Some("file is not a database".into()),
        );
        assert!(sqlite_durable_corruption(&not_db));

        let malformed = rusqlite::Error::SqliteFailure(
            FfiError {
                code: ErrorCode::ConstraintViolation,
                extended_code: 19,
            },
            Some("database disk image is malformed".into()),
        );
        assert!(sqlite_durable_corruption(&malformed));

        let full = rusqlite::Error::SqliteFailure(
            FfiError {
                code: ErrorCode::DiskFull,
                extended_code: 13,
            },
            Some("database or disk is full".into()),
        );
        assert!(!sqlite_durable_corruption(&full));
        assert!(sqlite_io_or_full(&full));

        let io = rusqlite::Error::SqliteFailure(
            FfiError {
                code: ErrorCode::SystemIoFailure,
                extended_code: 10,
            },
            Some("disk I/O error".into()),
        );
        assert!(!sqlite_durable_corruption(&io));
        assert!(sqlite_io_or_full(&io));
    }

    #[test]
    fn probe_and_copy_lists_never_include_usage_trees() {
        for table in PROBE_TABLES
            .iter()
            .chain(REQUIRED_COPY_TABLES)
            .chain(BEST_EFFORT_COPY_TABLES)
        {
            assert!(!table.starts_with("usage_file_"));
            assert_ne!(*table, "usage_dirty_ranges");
            assert_ne!(*table, "usage_partial_sources");
            assert_ne!(*table, "usage_scan_diagnostics");
            assert_ne!(*table, "sync_diagnostics");
            assert_ne!(*table, "diagnostic_snapshot");
            assert_ne!(*table, "legacy_artifacts");
        }
    }

    #[test]
    fn usage_only_damage_does_not_salvage_on_open() {
        let root = std::env::temp_dir().join(format!("quota-salvage-usage-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        store.insert_usage_file_record_for_test().expect("usage");
        assert_eq!(store.usage_event_count().expect("count"), 1);
        drop(store);

        let live = root.join(LIVE_NAME);
        let conn = Connection::open(&live).expect("raw");
        conn.execute_batch(
            "DROP TABLE usage_file_records;
             DROP TABLE usage_file_index;",
        )
        .expect("drop usage");
        drop(conn);

        let store = StateStore::open(&root).expect("reopen");
        assert!(store.state_salvaged_at().expect("marker").is_none());
        assert_eq!(store.installation_id().expect("id"), installation);
        assert!(!root.join(BROKEN_NAME).exists());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn salvage_copies_session_and_skips_usage_records() {
        let root = std::env::temp_dir().join(format!("quota-salvage-copy-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        store
            .write_session_json(&json!({"status":"active","token":"redacted"}))
            .expect("session");
        store.insert_usage_file_record_for_test().expect("usage");
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison probe");
        drop(store);

        let store = StateStore::open(&root).expect("salvaged open");
        assert!(store.state_salvaged_at().expect("marker").is_some());
        assert!(store.usage_reindex_pending().expect("reindex"));
        assert!(store.snapshot_untrusted().expect("untrusted"));
        assert_eq!(store.installation_id().expect("id"), installation);
        assert_eq!(
            store
                .session_json()
                .expect("session")
                .and_then(|value| value
                    .get("status")
                    .and_then(|value| value.as_str().map(str::to_owned))),
            Some("active".into())
        );
        assert_eq!(store.usage_event_count().expect("count"), 0);
        let broken = root.join(BROKEN_NAME);
        assert!(broken.exists());
        let mode = fs::metadata(&broken)
            .expect("broken meta")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }
}
