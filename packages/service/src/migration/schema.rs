//! Durable, append-only SQLite schema migrations.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::Value;
use uuid::Uuid;

use crate::state::StateError;

const CURRENT_SCHEMA: i64 = 8;

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
            4 => migration_v4(&tx)?,
            5 => migration_v5(&tx)?,
            6 => migration_v6(&tx)?,
            7 => migration_v7(&tx)?,
            8 => migration_v8(&tx)?,
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

fn migration_v4(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE model_catalog_cache (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload_json TEXT NOT NULL,
            etag TEXT
        );
        CREATE TABLE usage_period_cache (
            source TEXT NOT NULL,
            period TEXT NOT NULL,
            value_json TEXT NOT NULL,
            PRIMARY KEY(source, period)
        );
        INSERT INTO metadata(key, value) VALUES ('usage_upload_enabled', '1');
        DELETE FROM components WHERE name = 'usage';",
    )?;
    Ok(())
}

fn migration_v5(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE provider_browser_sessions (
            provider TEXT PRIMARY KEY NOT NULL,
            cookie_header TEXT NOT NULL,
            account_fingerprint TEXT NOT NULL,
            account_label TEXT,
            updated_at TEXT NOT NULL
        );",
    )?;
    Ok(())
}

fn migration_v6(tx: &Transaction<'_>) -> Result<(), StateError> {
    let mut statement =
        tx.prepare("SELECT submission_id, payload_json FROM usage_outbox ORDER BY submission_id")?;
    let outbox = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);

    for (submission_id, raw) in outbox {
        let mut payload: Value = serde_json::from_str(&raw)?;
        if payload.get("protocol_version").and_then(Value::as_u64) != Some(2) {
            continue;
        }
        payload["protocol_version"] = Value::from(3);
        tx.execute(
            "UPDATE usage_outbox SET payload_json = ?1 WHERE submission_id = ?2",
            params![serde_json::to_string(&payload)?, submission_id],
        )?;
    }

    let account = tx
        .query_row(
            "SELECT value_json FROM components WHERE name = 'account'",
            [],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    if let Some(raw) = account {
        let mut value: Value = serde_json::from_str(&raw)?;
        let cached_version = value
            .get("account_summary")
            .and_then(|summary| summary.get("protocol_version"))
            .and_then(Value::as_u64);
        if cached_version == Some(2) {
            value["account_summary"] = Value::Null;
            tx.execute(
                "UPDATE components SET value_json = ?1 WHERE name = 'account'",
                [serde_json::to_string(&value)?],
            )?;
        }
    }
    tx.execute(
        "DELETE FROM usage_period_cache WHERE source = 'account'",
        [],
    )?;
    Ok(())
}

fn migration_v7(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE diagnostic_snapshot (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload_json TEXT NOT NULL,
            completed_at TEXT NOT NULL
        );",
    )?;
    Ok(())
}

fn migration_v8(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE diagnostic_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_refresh_id INTEGER REFERENCES diagnostic_attempts(id) ON DELETE SET NULL,
            kind TEXT NOT NULL CHECK (kind IN (
                'refresh', 'quota_collection', 'usage_scan', 'usage_upload',
                'account_sync', 'pricing_refresh', 'device_health_upload'
            )),
            trigger TEXT NOT NULL CHECK (trigger IN (
                'manual', 'scheduled', 'startup', 'recheck', 'settings_change', 'account_change'
            )),
            source TEXT NOT NULL CHECK (source IN ('this_device', 'account', 'system')),
            subject TEXT CHECK (subject IS NULL OR (
                length(subject) BETWEEN 7 AND 96
                AND (subject LIKE 'provider:%' OR subject LIKE 'agent:%')
                AND subject NOT GLOB '*[^a-z0-9_:]*'
            )),
            mode TEXT NOT NULL CHECK (mode IN ('inactive', 'opportunistic', 'required')),
            started_at TEXT NOT NULL,
            completed_at TEXT,
            duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms BETWEEN 0 AND 86400000),
            outcome TEXT CHECK (outcome IS NULL OR outcome IN (
                'success', 'partial', 'no_work', 'failed', 'interrupted', 'cancelled'
            )),
            code TEXT CHECK (code IS NULL OR code IN (
                'process_interrupted', 'cancelled', 'no_work', 'authentication_required',
                'network_error', 'unavailable', 'invalid_response', 'invalid_state',
                'provider_error', 'partial_source', 'malformed_data',
                'truncated_active_source', 'invalid_usage_batch', 'unrepresentable_hour',
                'device_deleted', 'upload_disabled', 'signed_out'
            )),
            recovery TEXT NOT NULL CHECK (recovery IN (
                'none', 'automatic', 'login', 'configure_provider', 'retry',
                'update_source', 'check_access', 'upgrade', 'reinstall', 'feedback'
            )),
            metrics_json TEXT NOT NULL DEFAULT '{}',
            start_revision INTEGER NOT NULL CHECK (start_revision >= 0),
            end_revision INTEGER CHECK (end_revision IS NULL OR end_revision >= 0)
        );
        CREATE INDEX diagnostic_attempts_recent_idx
            ON diagnostic_attempts(started_at DESC, id DESC);
        CREATE INDEX diagnostic_attempts_parent_idx
            ON diagnostic_attempts(parent_refresh_id, id);
        INSERT INTO metadata(key, value) VALUES ('attempt_history_truncated', '0')
            ON CONFLICT(key) DO NOTHING;",
    )?;

    // QuotaBar 0.0.15 may have cached the shipped default managed-data v3 summary, whose Device
    // shape predates the explicit `device_health=1` response. The new client strictly decodes the
    // opted-in shape, so discard only this derived presentation before it can cross IPC. Session,
    // upload identity, local Usage, and Account Usage period caches remain intact and the next
    // refresh rebuilds the summary from Relay.
    let account = tx
        .query_row(
            "SELECT value_json FROM components WHERE name = 'account'",
            [],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    if let Some(raw) = account {
        let mut value: Value = serde_json::from_str(&raw)?;
        if value
            .get("account_summary")
            .is_some_and(|summary| !summary.is_null())
        {
            value["account_summary"] = Value::Null;
            tx.execute(
                "UPDATE components SET value_json = ?1 WHERE name = 'account'",
                [serde_json::to_string(&value)?],
            )?;
        }
    }
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
        assert_eq!(
            columns(&fresh, "diagnostic_snapshot"),
            columns(&v1, "diagnostic_snapshot")
        );
        assert_eq!(
            columns(&fresh, "diagnostic_attempts"),
            columns(&v1, "diagnostic_attempts")
        );
        assert_eq!(
            columns(&fresh, "model_catalog_cache"),
            columns(&v1, "model_catalog_cache")
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
        assert_eq!(fresh_versions, vec![1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(fresh_versions, v1_versions);
        assert_eq!(
            columns(&fresh, "usage_period_cache"),
            ["source", "period", "value_json"]
        );
        assert_eq!(
            columns(&fresh, "provider_browser_sessions"),
            [
                "provider",
                "cookie_header",
                "account_fingerprint",
                "account_label",
                "updated_at"
            ]
        );
        assert_eq!(
            fresh
                .query_row(
                    "SELECT value FROM metadata WHERE key = 'usage_upload_enabled'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .expect("Usage upload preference"),
            "1"
        );
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

    #[test]
    fn v4_discards_only_the_derived_usage_component() {
        let mut conn = Connection::open_in_memory().expect("database");
        apply(&mut conn).expect("current schema");
        conn.execute(
            "INSERT INTO components(name, status, value_json) VALUES ('usage', 'ready', '{}')",
            [],
        )
        .expect("usage component");
        conn.execute(
            "INSERT INTO components(name, status, value_json) VALUES ('quota', 'ready', '{}')",
            [],
        )
        .expect("quota component");
        conn.execute("DELETE FROM schema_migrations WHERE version >= 4", [])
            .expect("rewind migration marker");
        conn.execute("DROP TABLE model_catalog_cache", [])
            .expect("rewind catalog cache");
        conn.execute("DROP TABLE usage_period_cache", [])
            .expect("rewind period cache");
        conn.execute("DROP TABLE provider_browser_sessions", [])
            .expect("rewind browser sessions");
        conn.execute("DROP TABLE diagnostic_snapshot", [])
            .expect("rewind diagnostics");
        conn.execute("DROP TABLE diagnostic_attempts", [])
            .expect("rewind attempt journal");
        conn.execute(
            "DELETE FROM metadata WHERE key = 'attempt_history_truncated'",
            [],
        )
        .expect("rewind attempt metadata");
        conn.execute(
            "DELETE FROM metadata WHERE key = 'usage_upload_enabled'",
            [],
        )
        .expect("rewind upload preference");

        apply(&mut conn).expect("v4 migration");

        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM components WHERE name = 'usage'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("usage count"),
            0
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM components WHERE name = 'quota'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("quota count"),
            1
        );
    }

    #[test]
    fn v6_promotes_v2_outbox_and_discards_v2_account_presentations() {
        let mut conn = Connection::open_in_memory().expect("database");
        apply(&mut conn).expect("current schema");
        conn.execute(
            "INSERT INTO usage_outbox(
                submission_id, account_id, device_id, generation, sequence, payload_json
             ) VALUES ('v2', 'account', 'device', 1, 0, ?1),
                      ('v3', 'account', 'device', 1, 1, ?2)",
            params![
                usage_submission(2, "v2", "codex").to_string(),
                usage_submission(3, "v3", "cursor").to_string()
            ],
        )
        .expect("outbox fixtures");
        conn.execute(
            "INSERT INTO components(name, status, value_json)
             VALUES ('account', 'ready', ?1)",
            [serde_json::json!({
                "auth_status": "signed_in",
                "account_id": "account",
                "device_id": "device",
                "device_generation": 1,
                "account_summary": {"protocol_version": 2, "quota": []}
            })
            .to_string()],
        )
        .expect("account fixture");
        conn.execute(
            "INSERT INTO usage_period_cache(source, period, value_json)
             VALUES ('local', 'today', '{}'), ('account', 'today', '{}')",
            [],
        )
        .expect("period fixtures");
        conn.execute("DELETE FROM schema_migrations WHERE version >= 6", [])
            .expect("rewind migration marker");
        conn.execute("DROP TABLE diagnostic_snapshot", [])
            .expect("rewind diagnostics");
        conn.execute("DROP TABLE diagnostic_attempts", [])
            .expect("rewind attempt journal");
        conn.execute(
            "DELETE FROM metadata WHERE key = 'attempt_history_truncated'",
            [],
        )
        .expect("rewind attempt metadata");

        apply(&mut conn).expect("v6 migration");

        let payloads = conn
            .prepare("SELECT payload_json FROM usage_outbox ORDER BY submission_id")
            .expect("outbox query")
            .query_map([], |row| row.get::<_, String>(0))
            .expect("outbox rows")
            .map(|row| {
                serde_json::from_str::<Value>(&row.expect("outbox payload")).expect("outbox json")
            })
            .collect::<Vec<_>>();
        assert_eq!(
            payloads
                .iter()
                .map(|payload| payload["protocol_version"].as_u64())
                .collect::<Vec<_>>(),
            vec![Some(3), Some(3)]
        );
        assert!(
            payloads
                .iter()
                .all(|payload| crate::relay::validate_usage_submission(payload).is_ok())
        );

        let account: Value = serde_json::from_str(
            &conn
                .query_row(
                    "SELECT value_json FROM components WHERE name = 'account'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .expect("account value"),
        )
        .expect("account json");
        assert_eq!(account["account_id"], "account");
        assert!(account["account_summary"].is_null());
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM usage_period_cache WHERE source = 'local'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("local periods"),
            1
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM usage_period_cache WHERE source = 'account'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("account periods"),
            0
        );
    }

    #[test]
    fn v8_discards_only_the_pre_health_account_summary() {
        let mut conn = Connection::open_in_memory().expect("database");
        apply(&mut conn).expect("current schema");
        conn.execute(
            "INSERT INTO components(name, status, value_json)
             VALUES ('account', 'ready', ?1)",
            [serde_json::json!({
                "auth_status": "signed_in",
                "account_id": "account",
                "device_id": "device",
                "device_generation": 1,
                "account_summary": {
                    "protocol_version": 3,
                    "devices": [{"device_id": "device", "platform": "macos"}]
                }
            })
            .to_string()],
        )
        .expect("account fixture");
        conn.execute(
            "INSERT INTO session(id, payload_json, epoch) VALUES (1, '{\"status\":\"active\"}', 7)",
            [],
        )
        .expect("session fixture");
        conn.execute(
            "INSERT INTO usage_period_cache(source, period, value_json)
             VALUES ('local', 'today', '{}'), ('account', 'today', '{}')",
            [],
        )
        .expect("period fixtures");
        conn.execute("DELETE FROM schema_migrations WHERE version >= 8", [])
            .expect("rewind migration marker");
        conn.execute("DROP TABLE diagnostic_attempts", [])
            .expect("rewind attempt journal");
        conn.execute(
            "DELETE FROM metadata WHERE key = 'attempt_history_truncated'",
            [],
        )
        .expect("rewind attempt metadata");

        apply(&mut conn).expect("v8 migration");

        let account: Value = serde_json::from_str(
            &conn
                .query_row(
                    "SELECT value_json FROM components WHERE name = 'account'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .expect("account value"),
        )
        .expect("account json");
        assert_eq!(account["account_id"], "account");
        assert_eq!(account["device_id"], "device");
        assert!(account["account_summary"].is_null());
        assert_eq!(
            conn.query_row("SELECT epoch FROM session WHERE id = 1", [], |row| row
                .get::<_, i64>(0))
                .expect("session epoch"),
            7
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM usage_period_cache", [], |row| row
                .get::<_, i64>(0))
                .expect("period count"),
            2
        );
    }

    fn usage_submission(protocol_version: u64, submission_id: &str, agent: &str) -> Value {
        serde_json::json!({
            "protocol_version": protocol_version,
            "submission_id": submission_id,
            "device_id": "device",
            "generation": 1,
            "sequence": 0,
            "parser_revision": "rust-v1",
            "aggregation_timezone": "UTC",
            "coverage": {
                "agent": agent,
                "start_at": "2026-08-10T00:00:00Z",
                "end_at": "2026-08-10T01:00:00Z",
                "status": "complete"
            },
            "rows": []
        })
    }
}
