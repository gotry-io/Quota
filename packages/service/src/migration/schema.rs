//! Durable, append-only SQLite schema migrations.

use rusqlite::{Connection, Transaction, params};
use uuid::Uuid;

use crate::state::StateError;

const CURRENT_SCHEMA: i64 = 3;

pub fn apply(conn: &mut Connection) -> Result<(), StateError> {
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
    for version in (current + 1)..=CURRENT_SCHEMA {
        let tx = conn.transaction()?;
        match version {
            1 => migration_v1(&tx)?,
            2 => migration_v2(&tx)?,
            3 => migration_v3(&tx)?,
            _ => return Err(StateError::InvalidState),
        }
        tx.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?1, ?2)",
            params![version, crate::state::now_rfc3339()],
        )?;
        tx.commit()?;
    }
    conn.execute(
        "INSERT INTO installation(id, installation_id) VALUES (1, ?1)
         ON CONFLICT(id) DO NOTHING",
        params![Uuid::new_v4().to_string()],
    )?;
    Ok(())
}

fn migration_v1(tx: &Transaction<'_>) -> Result<(), StateError> {
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

fn migration_v2(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS usage_partial_sources (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            start_at TEXT NOT NULL,
            end_at TEXT NOT NULL,
            PRIMARY KEY(agent, source_file_id, start_at, end_at)
        );
        CREATE INDEX IF NOT EXISTS usage_partial_sources_hour
            ON usage_partial_sources(agent, start_at, end_at);
        CREATE TABLE IF NOT EXISTS usage_scan_diagnostics (
            agent TEXT PRIMARY KEY NOT NULL,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_diagnostics (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );",
    )?;
    let mut statement = tx.prepare("PRAGMA table_info(usage_file_records)")?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    if !columns.iter().any(|column| column == "record_key") {
        tx.execute(
            "ALTER TABLE usage_file_records ADD COLUMN record_key TEXT NOT NULL DEFAULT ''",
            [],
        )?;
    }
    Ok(())
}

fn migration_v3(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "DROP TABLE IF EXISTS legacy_artifacts;
         DELETE FROM metadata WHERE key = 'legacy_import_complete';",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn columns(conn: &Connection, table: &str) -> Vec<String> {
        let mut statement = conn
            .prepare(&format!("PRAGMA table_info({table})"))
            .expect("table info");
        statement
            .query_map([], |row| row.get::<_, String>(1))
            .expect("query columns")
            .collect::<Result<Vec<_>, _>>()
            .expect("columns")
    }

    #[test]
    fn fresh_and_v1_schema_reach_the_same_current_shape() {
        let mut fresh = Connection::open_in_memory().expect("fresh");
        apply(&mut fresh).expect("fresh migration");

        let mut v1 = Connection::open_in_memory().expect("v1");
        v1.execute_batch(
            "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
             INSERT INTO schema_migrations(version, applied_at) VALUES (1, 'test');",
        )
        .expect("v1 marker");
        {
            let tx = v1.transaction().expect("v1 transaction");
            migration_v1(&tx).expect("v1 schema");
            tx.commit().expect("v1 commit");
        }
        apply(&mut v1).expect("upgrade migration");

        assert_eq!(
            columns(&fresh, "usage_file_records"),
            columns(&v1, "usage_file_records")
        );
        assert_eq!(
            columns(&fresh, "sync_diagnostics"),
            columns(&v1, "sync_diagnostics")
        );
        let fresh_versions: Vec<i64> = fresh
            .prepare("SELECT version FROM schema_migrations ORDER BY version")
            .expect("fresh versions")
            .query_map([], |row| row.get(0))
            .expect("fresh rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("fresh values");
        let v1_versions: Vec<i64> = v1
            .prepare("SELECT version FROM schema_migrations ORDER BY version")
            .expect("v1 versions")
            .query_map([], |row| row.get(0))
            .expect("v1 rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("v1 values");
        assert_eq!(fresh_versions, vec![1, 2, 3]);
        assert_eq!(fresh_versions, v1_versions);
        assert!(
            fresh
                .query_row(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'legacy_artifacts'",
                    [],
                    |_| Ok(()),
                )
                .is_err()
        );
        assert_eq!(
            fresh
                .query_row("SELECT COUNT(*) FROM installation", [], |row| row
                    .get::<_, i64>(0))
                .expect("installation"),
            1
        );
    }
}
