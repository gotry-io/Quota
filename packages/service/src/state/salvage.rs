//! Durable-image salvage: copy identity and last-good rows, never Usage trees.

use std::cell::RefCell;
use std::fs::{self, OpenOptions, Permissions};
use std::io::Read;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, params};

use super::{StateError, now_rfc3339};
use crate::migration;

const LIVE_NAME: &str = "state.sqlite";
const BROKEN_NAME: &str = "state.sqlite.broken";
const SALVAGE_NAME: &str = "state.sqlite.salvage";
const GOOD_NAME: &str = "state.sqlite.good";
const GOOD_TMP_NAME: &str = "state.sqlite.good.tmp";
const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";
const COPY_HEADROOM_BYTES: u64 = 64 * 1024 * 1024;

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

const METADATA_COPY_EXCLUDED: &str = "'state_salvaged_at', 'snapshot_untrusted', \
     'usage_reindex_pending', 'diagnostics_persist_probe', 'overview_json'";

thread_local! {
    static SQL_LOG: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LiveKind {
    Missing,
    Empty,
    NotSqlite,
    Sqlite,
}

#[derive(Debug, Clone, Default)]
struct ImageIdentity {
    installation_id: Option<String>,
    has_session: bool,
    salvaged_at: Option<String>,
}

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

pub(super) fn open_or_salvage(root: &Path) -> Result<(Connection, bool), StateError> {
    let live_path = root.join(LIVE_NAME);
    let broken_path = root.join(BROKEN_NAME);
    remove_sqlite_image(&root.join(SALVAGE_NAME));
    match classify_live_path(&live_path)? {
        LiveKind::Missing | LiveKind::Empty | LiveKind::NotSqlite if broken_path.exists() => {
            resume_interrupted_salvage(root, &live_path, &broken_path)
        }
        LiveKind::Missing | LiveKind::Empty => first_install(&live_path),
        LiveKind::NotSqlite => fail_closed_or_restore_good(root, &live_path),
        LiveKind::Sqlite => open_existing_or_salvage(root, &live_path, &broken_path),
    }
}

pub(super) fn salvage_existing(root: &Path) -> Result<Connection, StateError> {
    let live_path = root.join(LIVE_NAME);
    salvage_once(root, &live_path)
}

pub(super) fn reopen_live(root: &Path) -> Result<Connection, StateError> {
    open_live_and_probe(&root.join(LIVE_NAME))
}

pub(super) fn checkpoint_wal(conn: &Connection) -> Result<(), StateError> {
    conn.execute_batch("PRAGMA wal_checkpoint(RESTART);")?;
    Ok(())
}

pub(super) fn write_last_good_if_space(root: &Path) -> Result<bool, StateError> {
    let live_path = root.join(LIVE_NAME);
    if !has_copy_space(root, &live_path) {
        return Ok(false);
    }
    let tmp_path = root.join(GOOD_TMP_NAME);
    let good_path = root.join(GOOD_NAME);
    remove_sqlite_image(&tmp_path);
    let result = (|| {
        create_owner_only_file(&tmp_path)?;
        let mut good = open_snapshot_connection(&tmp_path)?;
        migration::apply(&mut good)?;
        let uri = sqlite_readonly_uri(&live_path)?;
        good.execute("ATTACH DATABASE ?1 AS src", params![uri])?;
        let copied = copy_recoverable_tables(&good, "src");
        let _ = good.execute("DETACH DATABASE src", []);
        copied?;
        drop(good);
        fs::rename(&tmp_path, &good_path)?;
        set_owner_file_mode(&good_path);
        let _ = fs::remove_file(sqlite_sidecar(&good_path, "-wal"));
        let _ = fs::remove_file(sqlite_sidecar(&good_path, "-shm"));
        Ok(true)
    })();
    if result.is_err() {
        remove_sqlite_image(&tmp_path);
    }
    result
}

fn first_install(live_path: &Path) -> Result<(Connection, bool), StateError> {
    create_owner_only_file(live_path)?;
    Ok((open_live_and_probe(live_path)?, false))
}

fn fail_closed_or_restore_good(
    root: &Path,
    live_path: &Path,
) -> Result<(Connection, bool), StateError> {
    match restore_last_good_snapshot(root, live_path) {
        Ok(connection) => Ok((connection, true)),
        Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
        Err(_) => Err(StateError::InvalidState),
    }
}

fn open_existing_or_salvage(
    root: &Path,
    live_path: &Path,
    broken_path: &Path,
) -> Result<(Connection, bool), StateError> {
    let mut connection = match open_writable_connection(live_path) {
        Ok(connection) => connection,
        Err(error) if sqlite_io_or_full_error(&error) => return Err(StateError::Unavailable),
        Err(error) if sqlite_durable_corruption_error(&error) => {
            return salvage_unreadable_live(root, live_path, broken_path);
        }
        Err(StateError::ClientUpgradeRequired) => return Err(StateError::ClientUpgradeRequired),
        Err(error) => return Err(map_open_failure(error)),
    };
    let live_identity = read_identity(&connection);
    let broken_identity = if broken_path.exists() {
        Some(read_broken_identity(broken_path)?)
    } else {
        None
    };
    if let Some(broken) = &broken_identity {
        if is_create_migrate_race(&live_identity, broken) {
            drop(connection);
            return resume_interrupted_salvage(root, live_path, broken_path);
        }
        if is_incomplete_replacement(&live_identity, broken) {
            drop(connection);
            return fail_closed_incomplete_replacement(root, live_path);
        }
    }
    match migration::apply(&mut connection) {
        Ok(()) => {}
        Err(error) if sqlite_io_or_full_error(&error) => return Err(StateError::Unavailable),
        Err(error) if sqlite_durable_corruption_error(&error) => {
            drop(connection);
            return salvage_if_identity_ok(root, live_path, broken_path, &live_identity);
        }
        Err(StateError::ClientUpgradeRequired) => return Err(StateError::ClientUpgradeRequired),
        Err(error) => return Err(map_open_failure(error)),
    }
    match probe_small_image(&connection) {
        Ok(()) => Ok((connection, false)),
        Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
        Err(error) if sqlite_durable_corruption_error(&error) => {
            drop(connection);
            salvage_if_identity_ok(root, live_path, broken_path, &live_identity)
        }
        Err(error) => Err(map_open_failure(error)),
    }
}

fn salvage_unreadable_live(
    root: &Path,
    live_path: &Path,
    broken_path: &Path,
) -> Result<(Connection, bool), StateError> {
    if broken_path.exists() {
        resume_interrupted_salvage(root, live_path, broken_path)
    } else {
        Ok((salvage_once(root, live_path)?, true))
    }
}

fn salvage_if_identity_ok(
    root: &Path,
    live_path: &Path,
    broken_path: &Path,
    live_identity: &ImageIdentity,
) -> Result<(Connection, bool), StateError> {
    if live_identity.salvaged_at.is_some()
        && broken_path.exists()
        && let Ok(broken) = read_broken_identity(broken_path)
        && is_incomplete_replacement(live_identity, &broken)
    {
        return fail_closed_incomplete_replacement(root, live_path);
    }
    Ok((salvage_once(root, live_path)?, true))
}

fn is_create_migrate_race(live: &ImageIdentity, broken: &ImageIdentity) -> bool {
    live.salvaged_at.is_none()
        && broken.installation_id.is_some()
        && (live.installation_id.is_none() || live.installation_id != broken.installation_id)
}

fn is_incomplete_replacement(live: &ImageIdentity, broken: &ImageIdentity) -> bool {
    live.salvaged_at.is_some()
        && ((broken.installation_id.is_some()
            && (live.installation_id.is_none() || live.installation_id != broken.installation_id))
            || (broken.has_session && !live.has_session))
}

fn fail_closed_incomplete_replacement(
    root: &Path,
    live_path: &Path,
) -> Result<(Connection, bool), StateError> {
    fail_closed_or_restore_good(root, live_path)
}

fn resume_interrupted_salvage(
    root: &Path,
    live_path: &Path,
    broken_path: &Path,
) -> Result<(Connection, bool), StateError> {
    if !has_copy_space(root, broken_path) {
        return Err(StateError::Unavailable);
    }
    if live_path.exists() {
        remove_sqlite_image(live_path);
    }
    let salvage_path = root.join(SALVAGE_NAME);
    remove_sqlite_image(&salvage_path);
    match build_and_promote(live_path, &salvage_path, broken_path) {
        Ok(connection) => Ok((connection, true)),
        Err(error) => {
            remove_sqlite_image(&salvage_path);
            if sqlite_io_or_full_error(&error) {
                Err(StateError::Unavailable)
            } else {
                match restore_last_good_snapshot(root, live_path) {
                    Ok(connection) => Ok((connection, true)),
                    Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
                    Err(_) => Err(StateError::InvalidState),
                }
            }
        }
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

fn open_snapshot_connection(path: &Path) -> Result<Connection, StateError> {
    let connection =
        Connection::open_with_flags(path, OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
    connection.execute_batch(
        "PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = 5000;
         PRAGMA journal_mode = OFF;",
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
    if !has_copy_space(root, live_path) {
        return Err(StateError::Unavailable);
    }
    remove_sqlite_image(&salvage_path);
    park_live_image(live_path, &broken_path)?;
    match build_and_promote(live_path, &salvage_path, &broken_path) {
        Ok(connection) => Ok(connection),
        Err(error) => {
            remove_sqlite_image(&salvage_path);
            let _ = restore_parked_image(&broken_path, live_path);
            if sqlite_io_or_full_error(&error) {
                Err(StateError::Unavailable)
            } else {
                match restore_last_good_snapshot(root, live_path) {
                    Ok(connection) => Ok(connection),
                    Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
                    Err(_) => Err(StateError::InvalidState),
                }
            }
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
    let uri = sqlite_readonly_uri(broken_path)?;
    salvage.execute("ATTACH DATABASE ?1 AS broken", params![uri])?;
    let copied = copy_recoverable_tables(&salvage, "broken");
    let _ = salvage.execute("DETACH DATABASE broken", []);
    copied?;
    apply_salvage_markers(&salvage)?;
    verify_required_identity(&salvage, broken_path)?;
    probe_small_image(&salvage)?;
    quick_check_small_image(&salvage)?;
    drop(salvage);
    promote_salvage(salvage_path, live_path)?;
    if fail_promoted_probe() {
        let _ = restore_parked_image(broken_path, live_path);
        return Err(StateError::InvalidState);
    }
    match open_live_and_probe(live_path) {
        Ok(connection) => Ok(connection),
        Err(error) => {
            let _ = restore_parked_image(broken_path, live_path);
            Err(error)
        }
    }
}

fn copy_recoverable_tables(dest: &Connection, src_alias: &str) -> Result<(), StateError> {
    if !matches!(src_alias, "broken" | "src") {
        return Err(StateError::InvalidState);
    }
    for table in REQUIRED_COPY_TABLES {
        copy_table(dest, table, true, src_alias)?;
    }
    for table in BEST_EFFORT_COPY_TABLES {
        let _ = copy_table(dest, table, false, src_alias);
    }
    Ok(())
}

fn copy_table(
    conn: &Connection,
    table: &str,
    required: bool,
    src_alias: &str,
) -> Result<(), StateError> {
    let exists_sql = format!(
        "SELECT COUNT(*) FROM {src_alias}.sqlite_master WHERE type = 'table' AND name = ?1"
    );
    log_sql(&exists_sql);
    let exists: i64 = conn.query_row(&exists_sql, params![table], |row| row.get(0))?;
    if exists == 0 {
        return Ok(());
    }
    let sql = copy_table_sql(table, src_alias).ok_or(StateError::InvalidState)?;
    log_sql(&sql);
    match conn.execute(&sql, []) {
        Ok(_) => Ok(()),
        Err(error) if required => Err(StateError::Sql(error)),
        Err(_) => Ok(()),
    }
}

fn copy_table_sql(table: &str, src_alias: &str) -> Option<String> {
    Some(match table {
        "installation" => {
            format!("INSERT OR REPLACE INTO installation SELECT * FROM {src_alias}.installation")
        }
        "session" => format!("INSERT OR REPLACE INTO session SELECT * FROM {src_alias}.session"),
        "components" => {
            format!("INSERT OR REPLACE INTO components SELECT * FROM {src_alias}.components")
        }
        "metadata" => format!(
            "INSERT OR REPLACE INTO metadata SELECT * FROM {src_alias}.metadata \
             WHERE key NOT IN ({METADATA_COPY_EXCLUDED})"
        ),
        "provider_browser_sessions" => format!(
            "INSERT OR REPLACE INTO provider_browser_sessions SELECT * FROM {src_alias}.provider_browser_sessions"
        ),
        "usage_upload_context" => format!(
            "INSERT OR REPLACE INTO usage_upload_context SELECT * FROM {src_alias}.usage_upload_context"
        ),
        "usage_outbox" => {
            format!("INSERT OR REPLACE INTO usage_outbox SELECT * FROM {src_alias}.usage_outbox")
        }
        "model_catalog_cache" => format!(
            "INSERT OR REPLACE INTO model_catalog_cache SELECT * FROM {src_alias}.model_catalog_cache"
        ),
        "diagnostic_attempts" => format!(
            "INSERT OR REPLACE INTO diagnostic_attempts SELECT * FROM {src_alias}.diagnostic_attempts"
        ),
        "usage_period_cache" => format!(
            "INSERT OR REPLACE INTO usage_period_cache SELECT * FROM {src_alias}.usage_period_cache"
        ),
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
    let broken_installation = optional_text(
        &broken,
        "SELECT installation_id FROM installation WHERE id = 1",
    )?;
    let salvage_installation = optional_text(
        salvage,
        "SELECT installation_id FROM installation WHERE id = 1",
    )?;
    if let Some(broken_id) = broken_installation.as_deref()
        && salvage_installation.as_deref() != Some(broken_id)
    {
        return Err(StateError::InvalidState);
    }
    if row_exists(&broken, "SELECT 1 FROM session WHERE id = 1")?
        && !row_exists(salvage, "SELECT 1 FROM session WHERE id = 1")?
    {
        return Err(StateError::InvalidState);
    }
    if row_exists(&broken, "SELECT 1 FROM usage_upload_context WHERE id = 1")?
        && !row_exists(salvage, "SELECT 1 FROM usage_upload_context WHERE id = 1")?
    {
        return Err(StateError::InvalidState);
    }
    if table_exists(&broken, "usage_outbox")? {
        let broken_count = count_rows(&broken, "SELECT COUNT(*) FROM usage_outbox")?;
        let salvage_count = count_rows(salvage, "SELECT COUNT(*) FROM usage_outbox")?;
        if salvage_count != broken_count {
            return Err(StateError::InvalidState);
        }
    }
    Ok(())
}

fn optional_text(conn: &Connection, sql: &str) -> Result<Option<String>, StateError> {
    log_sql(sql);
    match conn.query_row(sql, [], |row| row.get(0)).optional() {
        Ok(value) => Ok(value),
        Err(error) if sqlite_io_or_full(&error) => Err(StateError::Unavailable),
        Err(error) if is_missing_relation(&error) => Ok(None),
        Err(error) => Err(StateError::Sql(error)),
    }
}

fn row_exists(conn: &Connection, sql: &str) -> Result<bool, StateError> {
    log_sql(sql);
    match conn.query_row(sql, [], |_| Ok(true)).optional() {
        Ok(value) => Ok(value.unwrap_or(false)),
        Err(error) if sqlite_io_or_full(&error) => Err(StateError::Unavailable),
        Err(error) if is_missing_relation(&error) => Ok(false),
        Err(error) => Err(StateError::Sql(error)),
    }
}

fn count_rows(conn: &Connection, sql: &str) -> Result<i64, StateError> {
    log_sql(sql);
    match conn.query_row(sql, [], |row| row.get(0)) {
        Ok(value) => Ok(value),
        Err(error) if sqlite_io_or_full(&error) => Err(StateError::Unavailable),
        Err(error) => Err(StateError::Sql(error)),
    }
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool, StateError> {
    log_sql("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1");
    match conn.query_row(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
        params![table],
        |_| Ok(true),
    ) {
        Ok(_) => Ok(true),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(false),
        Err(error) if sqlite_io_or_full(&error) => Err(StateError::Unavailable),
        Err(error) => Err(StateError::Sql(error)),
    }
}

fn is_missing_relation(error: &rusqlite::Error) -> bool {
    let message = error.to_string().to_ascii_lowercase();
    message.contains("no such table") || message.contains("no such column")
}

fn open_broken_readonly(path: &Path) -> Result<Connection, StateError> {
    let uri = sqlite_readonly_uri(path)?;
    let connection = Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .map_err(|error| {
        if sqlite_io_or_full(&error) {
            StateError::Unavailable
        } else {
            StateError::Sql(error)
        }
    })?;
    let pragmas = "PRAGMA query_only = ON; PRAGMA busy_timeout = 5000;";
    log_sql(pragmas);
    connection.execute_batch(pragmas).map_err(|error| {
        if sqlite_io_or_full(&error) {
            StateError::Unavailable
        } else {
            StateError::Sql(error)
        }
    })?;
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

fn read_broken_identity(path: &Path) -> Result<ImageIdentity, StateError> {
    let connection = open_broken_readonly(path)?;
    Ok(read_identity(&connection))
}

fn read_identity(conn: &Connection) -> ImageIdentity {
    ImageIdentity {
        installation_id: optional_text(
            conn,
            "SELECT installation_id FROM installation WHERE id = 1",
        )
        .ok()
        .flatten(),
        has_session: row_exists(conn, "SELECT 1 FROM session WHERE id = 1").unwrap_or(false),
        salvaged_at: optional_text(
            conn,
            "SELECT value FROM metadata WHERE key = 'state_salvaged_at'",
        )
        .ok()
        .flatten(),
    }
}

fn classify_live_path(path: &Path) -> Result<LiveKind, StateError> {
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(LiveKind::Missing),
        Err(error) if error.raw_os_error() == Some(libc::ELOOP) => {
            return Err(StateError::InvalidState);
        }
        Err(error) => return Err(error.into()),
    };
    if !file.metadata()?.is_file() {
        return Err(StateError::InvalidState);
    }
    if file.metadata()?.len() == 0 {
        return Ok(LiveKind::Empty);
    }
    let mut header = [0u8; 16];
    let read = file.read(&mut header)?;
    if read < 16 || &header != SQLITE_HEADER {
        Ok(LiveKind::NotSqlite)
    } else {
        Ok(LiveKind::Sqlite)
    }
}

fn restore_last_good_snapshot(root: &Path, live_path: &Path) -> Result<Connection, StateError> {
    let good_path = root.join(GOOD_NAME);
    if classify_live_path(&good_path)? != LiveKind::Sqlite {
        return Err(StateError::InvalidState);
    }
    let identity = read_broken_identity(&good_path)?;
    if identity.installation_id.is_none() {
        return Err(StateError::InvalidState);
    }
    let tmp_path = root.join("state.sqlite.good-restore");
    remove_sqlite_image(&tmp_path);
    fs::copy(&good_path, &tmp_path)?;
    set_owner_file_mode(&tmp_path);
    remove_sqlite_image(live_path);
    fs::rename(&tmp_path, live_path)?;
    set_owner_file_mode(live_path);
    let connection = open_live_and_probe(live_path)?;
    apply_salvage_markers(&connection)?;
    Ok(connection)
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

fn has_copy_space(root: &Path, source: &Path) -> bool {
    let Ok(live_size) = image_bytes(source) else {
        return false;
    };
    let Some(free) = available_bytes(root) else {
        return false;
    };
    free >= live_size
        .saturating_mul(2)
        .saturating_add(COPY_HEADROOM_BYTES)
}

fn image_bytes(path: &Path) -> Result<u64, StateError> {
    let mut total = 0u64;
    for candidate in [
        path.to_path_buf(),
        sqlite_sidecar(path, "-wal"),
        sqlite_sidecar(path, "-shm"),
    ] {
        match fs::metadata(&candidate) {
            Ok(metadata) if metadata.is_file() => total = total.saturating_add(metadata.len()),
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(total)
}

fn available_bytes(path: &Path) -> Option<u64> {
    if let Some(override_bytes) = available_bytes_override() {
        return Some(override_bytes);
    }
    let dir = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent().unwrap_or(path).to_path_buf()
    };
    let c_path = std::ffi::CString::new(dir.to_str()?).ok()?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    let result = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if result != 0 {
        return None;
    }
    let stat = unsafe { stat.assume_init() };
    let fragment_size = u64::try_from(stat.f_frsize).unwrap_or(4096);
    Some((stat.f_bavail as u64).saturating_mul(fragment_size))
}

fn log_sql(sql: &str) {
    SQL_LOG.with(|log| {
        if let Some(entries) = log.borrow_mut().as_mut() {
            entries.push(sql.to_owned());
        }
    });
}

fn fail_promoted_probe() -> bool {
    test_hooks::fail_promoted_probe()
}

fn available_bytes_override() -> Option<u64> {
    test_hooks::available_bytes_override()
}

mod test_hooks {
    #[cfg(test)]
    use std::cell::Cell;

    #[cfg(test)]
    thread_local! {
        static FAIL_PROMOTED_PROBE: Cell<bool> = const { Cell::new(false) };
        static AVAILABLE_OVERRIDE: Cell<Option<u64>> = const { Cell::new(None) };
    }

    pub(super) fn fail_promoted_probe() -> bool {
        #[cfg(test)]
        {
            return FAIL_PROMOTED_PROBE.with(|cell| cell.replace(false));
        }
        #[cfg(not(test))]
        false
    }

    pub(super) fn available_bytes_override() -> Option<u64> {
        #[cfg(test)]
        {
            AVAILABLE_OVERRIDE.with(Cell::get)
        }
        #[cfg(not(test))]
        {
            None
        }
    }

    #[cfg(test)]
    pub(super) fn set_fail_next_promoted_probe() {
        FAIL_PROMOTED_PROBE.with(|cell| cell.set(true));
    }

    #[cfg(test)]
    pub(super) fn set_available_bytes(bytes: u64) {
        AVAILABLE_OVERRIDE.with(|cell| cell.set(Some(bytes)));
    }

    #[cfg(test)]
    pub(super) fn clear_available_bytes() {
        AVAILABLE_OVERRIDE.with(|cell| cell.set(None));
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

    fn start_sql_log() {
        SQL_LOG.with(|log| *log.borrow_mut() = Some(Vec::new()));
    }

    fn take_sql_log() -> Vec<String> {
        SQL_LOG.with(|log| log.borrow_mut().take().unwrap_or_default())
    }

    fn assert_no_usage_tree_sql(statements: &[String]) {
        for statement in statements {
            let lower = statement.to_ascii_lowercase();
            assert!(
                !lower.contains("usage_file_"),
                "unexpected Usage tree SQL: {statement}"
            );
            assert!(
                !lower.contains("usage_dirty_ranges"),
                "unexpected dirty-range SQL: {statement}"
            );
            assert!(
                !lower.contains("usage_partial_sources"),
                "unexpected partial-source SQL: {statement}"
            );
            assert!(
                !lower.contains("usage_scan_diagnostics"),
                "unexpected scan-diagnostic SQL: {statement}"
            );
        }
    }

    fn temp_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!("quota-salvage-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        fs::canonicalize(&root).expect("canonicalize")
    }

    fn write_session(store: &StateStore) {
        store
            .write_session_json(&json!({"status":"active","token":"redacted"}))
            .expect("session");
    }

    fn session_status(store: &StateStore) -> Option<String> {
        store.session_json().expect("session").and_then(|value| {
            value
                .get("status")
                .and_then(|value| value.as_str().map(str::to_owned))
        })
    }

    fn session_status_in(path: &Path) -> Option<String> {
        let connection = open_broken_readonly(path).ok()?;
        let payload: String = connection
            .query_row("SELECT payload_json FROM session WHERE id = 1", [], |row| {
                row.get(0)
            })
            .ok()?;
        serde_json::from_str::<serde_json::Value>(&payload)
            .ok()?
            .get("status")?
            .as_str()
            .map(str::to_owned)
    }

    fn installation_in(path: &Path) -> Option<String> {
        let connection = open_broken_readonly(path).ok()?;
        connection
            .query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .ok()
    }

    fn copy_sqlite_image(from: &Path, to: &Path) {
        fs::copy(from, to).expect("copy image");
        set_owner_file_mode(to);
        let _ = fs::copy(sqlite_sidecar(from, "-wal"), sqlite_sidecar(to, "-wal"));
        let _ = fs::copy(sqlite_sidecar(from, "-shm"), sqlite_sidecar(to, "-shm"));
    }

    fn write_incomplete_live(live: &Path, salvaged_at: &str) {
        remove_sqlite_image(live);
        create_owner_only_file(live).expect("create live");
        let mut connection = open_writable_connection(live).expect("open live");
        migration::apply(&mut connection).expect("apply");
        connection
            .execute("DELETE FROM installation", [])
            .expect("drop installation");
        connection
            .execute("DELETE FROM session", [])
            .expect("drop session");
        connection
            .execute(
                "INSERT INTO metadata(key, value) VALUES ('state_salvaged_at', ?1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![salvaged_at],
            )
            .expect("marker");
    }

    fn file_mode(path: &Path) -> u32 {
        fs::metadata(path).expect("meta").permissions().mode() & 0o777
    }

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
        let root = temp_root();
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
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        write_session(&store);
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
        assert_eq!(session_status(&store), Some("active".into()));
        assert_eq!(store.usage_event_count().expect("count"), 0);
        let broken = root.join(BROKEN_NAME);
        assert!(broken.exists());
        assert_eq!(file_mode(&broken), 0o600);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn park_then_kill_before_promote_resumes_session() {
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        write_session(&store);
        drop(store);

        let live = root.join(LIVE_NAME);
        let broken = root.join(BROKEN_NAME);
        park_live_image(&live, &broken).expect("park");
        assert_eq!(session_status_in(&broken).as_deref(), Some("active"));

        start_sql_log();
        let store = StateStore::open(&root).expect("resume");
        let statements = take_sql_log();
        assert_no_usage_tree_sql(&statements);
        assert!(
            statements.iter().any(|sql| {
                let lower = sql.to_ascii_lowercase();
                lower.contains("installation") || lower.contains("session")
            }),
            "resume must SELECT identity tables: {statements:?}"
        );
        assert_eq!(store.installation_id().expect("id"), installation);
        assert_eq!(session_status(&store), Some("active".into()));
        assert!(store.state_salvaged_at().expect("marker").is_some());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn promote_then_probe_fail_restores_and_incomplete_replacement_does_not_park() {
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        write_session(&store);
        drop(store);

        let live = root.join(LIVE_NAME);
        let broken = root.join(BROKEN_NAME);
        park_live_image(&live, &broken).expect("park");
        test_hooks::set_fail_next_promoted_probe();
        assert!(StateStore::open(&root).is_err());
        assert_eq!(session_status_in(&live).as_deref(), Some("active"));

        copy_sqlite_image(&live, &broken);
        write_incomplete_live(&live, "2026-08-17T01:00:00Z");
        assert!(StateStore::open(&root).is_err());
        assert_eq!(session_status_in(&broken).as_deref(), Some("active"));
        assert!(installation_in(&broken).is_some());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn later_corruption_of_good_salvaged_image_salvages_again() {
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        write_session(&store);
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        drop(store);

        let store = StateStore::open(&root).expect("first salvage");
        assert!(store.state_salvaged_at().expect("marker").is_some());
        assert_eq!(store.installation_id().expect("id"), installation);
        assert_eq!(session_status(&store), Some("active".into()));
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison again");
        drop(store);

        let store = StateStore::open(&root).expect("second salvage");
        assert!(store.state_salvaged_at().expect("marker").is_some());
        assert_eq!(store.installation_id().expect("id"), installation);
        assert_eq!(session_status(&store), Some("active".into()));
        assert!(root.join(BROKEN_NAME).exists());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn required_copy_failure_does_not_promote() {
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        let installation = store.installation_id().expect("installation");
        write_session(&store);
        drop(store);

        let live = root.join(LIVE_NAME);
        let conn = Connection::open(&live).expect("raw");
        conn.execute_batch("ALTER TABLE session ADD COLUMN extra TEXT NOT NULL DEFAULT 'x';")
            .expect("widen session");
        drop(conn);
        let store = StateStore::open(&root).expect("reopen widened");
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        drop(store);

        assert!(matches!(
            StateStore::open(&root),
            Err(StateError::InvalidState)
        ));
        assert!(!root.join(SALVAGE_NAME).exists());
        let restored = Connection::open(&live).expect("restored live");
        let extra: i64 = restored
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('session') WHERE name = 'extra'",
                [],
                |row| row.get(0),
            )
            .expect("extra column");
        assert_eq!(extra, 1);
        let restored_id: String = restored
            .query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .expect("installation");
        assert_eq!(restored_id, installation);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn opening_broken_does_not_set_wal() {
        let root = temp_root();
        let broken = root.join(BROKEN_NAME);
        create_owner_only_file(&broken).expect("create broken");
        let mut connection = open_snapshot_connection(&broken).expect("snapshot");
        migration::apply(&mut connection).expect("apply");
        connection
            .execute(
                "INSERT INTO session(id, payload_json, epoch) VALUES (1, '{\"status\":\"active\"}', 1)",
                [],
            )
            .expect("session");
        drop(connection);
        assert!(!sqlite_sidecar(&broken, "-wal").exists());

        start_sql_log();
        let connection = open_broken_readonly(&broken).expect("readonly");
        let statements = take_sql_log();
        assert!(
            !statements
                .iter()
                .any(|sql| sql.to_ascii_lowercase().contains("journal_mode")
                    && sql.to_ascii_lowercase().contains("wal")),
            "{statements:?}"
        );
        assert!(!sqlite_sidecar(&broken, "-wal").exists());
        let query_only: i64 = connection
            .query_row("PRAGMA query_only", [], |row| row.get(0))
            .expect("query_only");
        assert_eq!(query_only, 1);
        drop(connection);
        assert!(!sqlite_sidecar(&broken, "-wal").exists());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn post_refresh_writes_good_when_space_allows_and_skips_when_short() {
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        write_session(&store);
        store.insert_usage_file_record_for_test().expect("usage");
        let installation = store.installation_id().expect("installation");
        store
            .run_repair(crate::state::RepairSite::PostRefresh)
            .expect("post refresh");
        let good = root.join(GOOD_NAME);
        assert!(good.exists());
        assert_eq!(file_mode(&good), 0o600);
        assert!(!sqlite_sidecar(&good, "-wal").exists());
        let good_conn = open_broken_readonly(&good).expect("good");
        let good_id: String = good_conn
            .query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .expect("good installation");
        assert_eq!(good_id, installation);
        let usage_count: i64 = good_conn
            .query_row("SELECT COUNT(*) FROM usage_file_records", [], |row| {
                row.get(0)
            })
            .expect("usage");
        assert_eq!(usage_count, 0);
        drop(good_conn);

        fs::remove_file(&good).expect("remove good");
        test_hooks::set_available_bytes(0);
        store
            .run_repair(crate::state::RepairSite::PostRefresh)
            .expect("skip good");
        test_hooks::clear_available_bytes();
        assert!(!good.exists());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn fail_closed_restores_from_good_when_identity_cannot_be_kept() {
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        write_session(&store);
        store
            .run_repair(crate::state::RepairSite::PostRefresh)
            .expect("write good");
        assert!(root.join(GOOD_NAME).exists());
        drop(store);

        let live = root.join(LIVE_NAME);
        let conn = Connection::open(&live).expect("raw");
        conn.execute_batch("ALTER TABLE session ADD COLUMN extra TEXT NOT NULL DEFAULT 'x';")
            .expect("widen session");
        drop(conn);
        let store = StateStore::open(&root).expect("reopen widened");
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        drop(store);

        let store = StateStore::open(&root).expect("restored from good");
        assert_eq!(session_status(&store), Some("active".into()));
        assert!(store.usage_reindex_pending().expect("reindex"));
        let extra: i64 = {
            let conn = store.db.lock().expect("lock");
            conn.query_row(
                "SELECT COUNT(*) FROM pragma_table_info('session') WHERE name = 'extra'",
                [],
                |row| row.get(0),
            )
            .expect("extra")
        };
        assert_eq!(extra, 0);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn low_disk_does_not_copy_a_second_image() {
        let root = temp_root();
        let store = StateStore::open(&root).expect("state");
        write_session(&store);
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        drop(store);

        test_hooks::set_available_bytes(0);
        let opened = StateStore::open(&root);
        test_hooks::clear_available_bytes();
        assert!(matches!(opened, Err(StateError::Unavailable)));
        assert!(!root.join(BROKEN_NAME).exists());
        fs::remove_dir_all(root).expect("cleanup");
    }
}
