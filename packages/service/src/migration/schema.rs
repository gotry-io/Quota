//! Durable, append-only SQLite schema migrations.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::Value;
use uuid::Uuid;

use crate::state::StateError;

const CURRENT_SCHEMA: i64 = 12;

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
            9 => migration_v9(&tx)?,
            10 => migration_v10(&tx)?,
            11 => migration_v11(&tx)?,
            12 => migration_v12(&tx)?,
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

/// Rebuild Usage index tables in place. Does not re-run migrations or touch identity tables.
pub(crate) fn recreate_usage_index_tables(tx: &Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "DROP TABLE IF EXISTS usage_file_records;
         DROP TABLE IF EXISTS usage_file_index;
         DROP TABLE IF EXISTS usage_dirty_ranges;
         DROP TABLE IF EXISTS usage_partial_sources;
         CREATE TABLE usage_file_index (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            identity TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_ns TEXT NOT NULL,
            parser_revision TEXT NOT NULL,
            PRIMARY KEY(agent, source_file_id)
         );
         CREATE TABLE usage_file_records (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            record_index INTEGER NOT NULL,
            occurred_at TEXT NOT NULL,
            event_json TEXT NOT NULL,
            record_key TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(agent, source_file_id, record_index)
         );
         CREATE INDEX usage_file_records_time ON usage_file_records(agent, occurred_at);
         CREATE TABLE usage_dirty_ranges (
            agent TEXT NOT NULL,
            start_at TEXT NOT NULL,
            end_at TEXT NOT NULL,
            PRIMARY KEY(agent, start_at, end_at)
         );
         CREATE TABLE usage_partial_sources (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            start_at TEXT NOT NULL,
            end_at TEXT NOT NULL,
            PRIMARY KEY(agent, source_file_id, start_at, end_at)
         );
         CREATE INDEX usage_partial_sources_hour
            ON usage_partial_sources(agent, start_at, end_at);
         DELETE FROM usage_scan_diagnostics;
         DELETE FROM sync_diagnostics;",
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

/// Managed data advanced to v4, so work this device staged under v3 no longer describes a
/// payload Relay accepts. Promoting it changes only the version: v4 kept the shape v3
/// already had for these submissions, so the submission id, Device generation, sequence,
/// coverage, and hourly facts all stand. The derived Account presentation cannot be
/// promoted the same way — it is a response, not this device's work — so it is discarded
/// and rebuilt from the first v4 read, which also keeps the first IPC state decodable.
fn migration_v9(tx: &Transaction<'_>) -> Result<(), StateError> {
    let mut statement = tx.prepare(
        "SELECT submission_id, payload_json FROM usage_outbox
         WHERE json_extract(payload_json, '$.protocol_version') = 3
         ORDER BY submission_id",
    )?;
    let outbox = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);

    for (submission_id, raw) in outbox {
        let mut payload: Value = serde_json::from_str(&raw)?;
        payload["protocol_version"] = Value::from(4);
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
            .and_then(Value::as_i64);
        if cached_version.is_some_and(|version| version < 4) {
            value["account_summary"] = Value::Null;
            tx.execute(
                "UPDATE components SET value_json = ?1 WHERE name = 'account'",
                [serde_json::to_string(&value)?],
            )?;
        }
    }
    // The persisted collection report and Overview both hold readings this build no longer
    // accepts, and the app decodes the whole IPC state or none of it. Strip the retired
    // fields in place rather than discarding a device's last known quota.
    let quota = tx
        .query_row(
            "SELECT value_json FROM components WHERE name = 'quota'",
            [],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    if let Some(raw) = quota {
        let mut value: Value = serde_json::from_str(&raw)?;
        strip_retired_snapshot_fields(&mut value);
        tx.execute(
            "UPDATE components SET value_json = ?1 WHERE name = 'quota'",
            [serde_json::to_string(&value)?],
        )?;
    }
    let overview = tx
        .query_row(
            "SELECT value FROM metadata WHERE key = 'overview_json'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(raw) = overview {
        let mut value: Value = serde_json::from_str(&raw)?;
        strip_retired_snapshot_fields(&mut value);
        tx.execute(
            "UPDATE metadata SET value = ?1 WHERE key = 'overview_json'",
            [serde_json::to_string(&value)?],
        )?;
    }
    tx.execute(
        "DELETE FROM usage_period_cache WHERE source = 'account'",
        [],
    )?;
    Ok(())
}

/// Managed data v5: a read states how completely its range was scanned instead of listing the
/// windows the answer was derived from, and the local Usage detail no longer restates display
/// breakdowns the per-agent summary already carries.
///
/// Staged uploads are promoted in place so queued work survives; the presentations built from
/// the retired shapes are discarded, because both are caches this build rebuilds on its next
/// refresh and the app decodes the whole IPC state or none of it.
fn migration_v10(tx: &Transaction<'_>) -> Result<(), StateError> {
    let mut statement = tx.prepare(
        "SELECT submission_id, payload_json FROM usage_outbox
         WHERE json_extract(payload_json, '$.protocol_version') = 4
         ORDER BY submission_id",
    )?;
    let outbox = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);

    for (submission_id, raw) in outbox {
        let mut payload: Value = serde_json::from_str(&raw)?;
        payload["protocol_version"] = Value::from(5);
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
            .and_then(Value::as_i64);
        if cached_version.is_some_and(|version| version < 5) {
            value["account_summary"] = Value::Null;
            tx.execute(
                "UPDATE components SET value_json = ?1 WHERE name = 'account'",
                [serde_json::to_string(&value)?],
            )?;
        }
    }
    // A submission this build refuses cannot be uploaded and cannot be skipped either: the
    // drain stops at the first entry it cannot send, and Relay answers a gap in the sequence
    // with `sequence_conflict`, which is terminal. v5 adds one rule a staged v4 payload can
    // fail — coverage reaching back before any agent existed — so a device holding one drops
    // its whole staged set and re-stages against the sequence Relay reports it is expecting.
    let stranded: Vec<(String, i64, String)> = tx
        .prepare(
            "SELECT account_id, generation, device_id FROM usage_outbox
             WHERE json_extract(payload_json, '$.coverage.start_at') < ?1",
        )?
        .query_map([crate::usage::EARLIEST_USAGE_INSTANT], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for (account_id, generation, device_id) in stranded {
        tx.execute(
            "DELETE FROM usage_outbox
             WHERE account_id = ?1 AND device_id = ?2 AND generation = ?3",
            params![account_id, device_id, generation],
        )?;
    }

    // Every cached period carries the retired `fallback_models` key, local ones included.
    tx.execute("DELETE FROM usage_period_cache", [])?;
    Ok(())
}

/// Two conditions this build can now name needed room to be recorded: a credential store that
/// refuses what it holds, and a contract Relay has retired.  Both were being filed under codes
/// that sent the reader somewhere that could not help.
///
/// The attempt table names its codes in a CHECK, which SQLite cannot alter, so the table is
/// rebuilt.  History is copied across, because it is the record a reader consults to see how
/// long something has been failing — but only as far as it can be: a row an image should never
/// have held would otherwise fail the whole copy, and a device that cannot open its state is a
/// worse outcome than a device missing a line of history it could not read anyway.
fn migration_v11(tx: &Transaction<'_>) -> Result<(), StateError> {
    // The old indexes stay where they are: they belong to the renamed table and go with it.
    // Dropping a table whose parent reference points at itself performs an implicit delete that
    // fires `ON DELETE SET NULL` for every row, and without the parent index that is a scan per
    // row — 31 seconds on this device's 27,755 attempts against 0.11 with the index in place.
    // Their names come free for the new indexes once the old table is gone.
    tx.execute_batch(
        "ALTER TABLE diagnostic_attempts RENAME TO diagnostic_attempts_v10;
         CREATE TABLE diagnostic_attempts (
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
                'provider_error', 'access_denied', 'client_upgrade_required',
                'partial_source', 'malformed_data',
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
         INSERT OR IGNORE INTO diagnostic_attempts
            SELECT id, parent_refresh_id, kind, trigger, source, subject, mode, started_at,
                   completed_at, duration_ms, outcome, code, recovery, metrics_json,
                   start_revision, end_revision
            FROM diagnostic_attempts_v10;
",
    )?;
    // A row the copy could not take is one no reader could take either — the attempt log is
    // read whole, and a single unparseable code fails all of it.  Dropping it is a repair, but
    // the reader is told the history is short, the same way retention says so.
    let dropped = tx.query_row(
        "SELECT (SELECT COUNT(*) FROM diagnostic_attempts_v10)
              - (SELECT COUNT(*) FROM diagnostic_attempts)",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    if dropped > 0 {
        tx.execute(
            "INSERT INTO metadata(key, value) VALUES ('attempt_history_truncated', '1')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )?;
    }
    tx.execute_batch(
        "DROP TABLE diagnostic_attempts_v10;
         CREATE INDEX diagnostic_attempts_recent_idx
            ON diagnostic_attempts(started_at DESC, id DESC);
         CREATE INDEX diagnostic_attempts_parent_idx
            ON diagnostic_attempts(parent_refresh_id, id);",
    )?;

    Ok(())
}

/// Discards a persisted collection report written under an older contract.
///
/// v4 replaced the discovered-source count with the sources themselves, so a v3 report is
/// not a v4 report with a field missing and cannot be promoted into one.  The report is
/// this device's own cache of its own sources, and the next collection rebuilds it; the app
/// decodes the whole IPC state or none of it, so carrying a shape it cannot read forward
/// would cost more than the few minutes of staleness dropping it costs.
fn migration_v12(tx: &Transaction<'_>) -> Result<(), StateError> {
    let current = tx
        .query_row(
            "SELECT value_json FROM components WHERE name = 'quota'",
            [],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten()
        .map(|raw| serde_json::from_str::<Value>(&raw))
        .transpose()?
        .and_then(|value| {
            value
                .get("protocol_version")
                .and_then(Value::as_i64)
                .map(|version| version == crate::protocol::LOCAL_COLLECTION_PROTOCOL)
        });
    if current == Some(true) {
        return Ok(());
    }
    tx.execute(
        "UPDATE components SET value_json = NULL WHERE name = 'quota'",
        [],
    )?;
    Ok(())
}

/// Removes the stamp and the collector name from every reading in a persisted value.
///
/// A reading is recognised by its own shape rather than by a path, because it appears at
/// different depths in the collection report and in the Overview. `source` also names a
/// collection *result*, which is still a field, so only objects that are readings are touched.
fn strip_retired_snapshot_fields(value: &mut Value) {
    match value {
        Value::Object(object) => {
            let is_reading = ["provider", "account", "windows", "observed_at"]
                .iter()
                .all(|key| object.contains_key(*key));
            if is_reading {
                object.remove("valid_until");
                object.remove("source");
            }
            for nested in object.values_mut() {
                strip_retired_snapshot_fields(nested);
            }
        }
        Value::Array(items) => items.iter_mut().for_each(strip_retired_snapshot_fields),
        _ => {}
    }
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
        assert_eq!(fresh_versions, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
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
    fn migrations_promote_staged_outbox_work_and_discard_stale_account_presentations() {
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
        // Staged work survives every managed-data cutover the ladder has applied, and lands
        // on the version this build uploads.
        assert_eq!(
            payloads
                .iter()
                .map(|payload| payload["protocol_version"].as_i64())
                .collect::<Vec<_>>(),
            vec![
                Some(crate::protocol::MANAGED_DATA_PROTOCOL),
                Some(crate::protocol::MANAGED_DATA_PROTOCOL)
            ]
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
            conn.query_row("SELECT COUNT(*) FROM usage_period_cache", [], |row| row
                .get::<_, i64>(0),)
                .expect("periods"),
            0
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

    /// A device that upgrades still has its last collection and Overview on disk, in the
    /// shape the previous build wrote. The app decodes the whole state or none of it.
    #[test]
    fn migration_strips_retired_reading_fields_from_persisted_state() {
        let mut conn = Connection::open_in_memory().expect("database");
        apply(&mut conn).expect("current schema");
        let reading = serde_json::json!({
            "provider": "codex",
            "account": {"fingerprint": "account", "fingerprint_scope": "global"},
            "windows": [],
            "source": "chatgpt_usage_api",
            "status": "available",
            "observed_at": "2026-08-22T14:51:36Z",
            "valid_until": "2026-08-23T14:51:36Z"
        });
        conn.execute(
            "INSERT INTO components(name, status, value_json) VALUES ('quota', 'ready', ?1)",
            [serde_json::json!({
                // Stamped current, so the later step that drops superseded reports keeps it
                // and this test stays about the fields v9 strips.
                "protocol_version": crate::protocol::LOCAL_COLLECTION_PROTOCOL,
                "captured_at": "2026-08-22T14:51:36Z",
                // A collection result names its own source, which is still a field.
                "results": [{
                    "provider": "codex",
                    "outcome": "success",
                    "source": "chatgpt_usage_api",
                    "sources": [{
                        "source_id": "chatgpt_usage_api",
                        "outcome": "success",
                        "category": "success"
                    }],
                    "snapshots": [reading.clone()]
                }]
            })
            .to_string()],
        )
        .expect("quota fixture");
        conn.execute(
            "INSERT INTO metadata(key, value) VALUES ('overview_json', ?1)",
            [serde_json::json!([{
                "identity": {
                    "provider": "codex",
                    "fingerprint": "account",
                    "scope": "global",
                    "source_id": null
                },
                "snapshot": reading,
                "sources": [],
                "selected_source_id": "local",
                "selected_source_display_name": "Local",
                "is_stale": false
            }])
            .to_string()],
        )
        .expect("overview fixture");
        conn.execute("DELETE FROM schema_migrations WHERE version >= 9", [])
            .expect("rewind migration marker");

        apply(&mut conn).expect("re-apply");

        let quota: Value = serde_json::from_str(
            &conn
                .query_row(
                    "SELECT value_json FROM components WHERE name = 'quota'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .expect("quota value"),
        )
        .expect("quota json");
        let snapshot = &quota["results"][0]["snapshots"][0];
        assert!(snapshot.get("source").is_none());
        assert!(snapshot.get("valid_until").is_none());
        assert_eq!(snapshot["observed_at"], "2026-08-22T14:51:36Z");
        // The result's own source is not a reading's, and stays.
        assert_eq!(quota["results"][0]["source"], "chatgpt_usage_api");

        let overview: Value = serde_json::from_str(
            &conn
                .query_row(
                    "SELECT value FROM metadata WHERE key = 'overview_json'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .expect("overview value"),
        )
        .expect("overview json");
        assert!(overview[0]["snapshot"].get("source").is_none());
        assert!(overview[0]["snapshot"].get("valid_until").is_none());
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
        // Both presentations are caches of a shape this build no longer speaks, so the ladder
        // discards them and the next refresh rebuilds them from facts this device still holds.
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM usage_period_cache", [], |row| row
                .get::<_, i64>(0))
                .expect("period count"),
            0
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM usage_period_cache WHERE source = 'account'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .expect("account period count"),
            0
        );
    }

    #[test]
    fn recreate_usage_index_matches_current_schema_and_clears_scan_diagnostics() {
        let mut conn = Connection::open_in_memory().expect("database");
        apply(&mut conn).expect("current schema");
        conn.execute(
            "INSERT INTO usage_file_records(
               agent, source_file_id, record_index, occurred_at, event_json, record_key
             ) VALUES ('codex', 'source-1', 0, '2026-08-10T12:15:00Z', '{}', 'line:0:0')",
            [],
        )
        .expect("usage record");
        conn.execute(
            "INSERT INTO usage_scan_diagnostics(agent, payload_json, updated_at)
             VALUES ('codex', '{}', '2026-08-10T12:15:00Z')",
            [],
        )
        .expect("scan diagnostics");
        conn.execute(
            "INSERT INTO sync_diagnostics(id, payload_json, updated_at)
             VALUES (1, '{}', '2026-08-10T12:15:00Z')",
            [],
        )
        .expect("sync diagnostics");
        conn.execute(
            "INSERT INTO session(id, payload_json, epoch) VALUES (1, '{\"status\":\"active\"}', 1)",
            [],
        )
        .expect("session");
        let installation: String = conn
            .query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .expect("installation");

        {
            let tx = conn.transaction().expect("tx");
            recreate_usage_index_tables(&tx).expect("recreate");
            tx.rollback().expect("rollback");
        }
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM usage_file_records", [], |row| row
                .get::<_, i64>(0))
                .expect("rolled back records"),
            1
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM usage_scan_diagnostics", [], |row| row
                .get::<_, i64>(0))
                .expect("rolled back diagnostics"),
            1
        );

        {
            let tx = conn.transaction().expect("tx");
            recreate_usage_index_tables(&tx).expect("recreate");
            tx.commit().expect("commit");
        }

        assert_eq!(
            columns(&conn, "usage_file_records"),
            columns_after_fresh_apply("usage_file_records")
        );
        assert_eq!(
            columns(&conn, "usage_file_index"),
            columns_after_fresh_apply("usage_file_index")
        );
        assert_eq!(
            columns(&conn, "usage_partial_sources"),
            columns_after_fresh_apply("usage_partial_sources")
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM usage_file_records", [], |row| row
                .get::<_, i64>(0))
                .expect("records"),
            0
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM usage_scan_diagnostics", [], |row| row
                .get::<_, i64>(0))
                .expect("scan diagnostics"),
            0
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM sync_diagnostics", [], |row| row
                .get::<_, i64>(0))
                .expect("sync diagnostics"),
            0
        );
        assert_eq!(
            conn.query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get::<_, String>(0)
            )
            .expect("installation after"),
            installation
        );
        assert_eq!(
            conn.query_row("SELECT epoch FROM session WHERE id = 1", [], |row| row
                .get::<_, i64>(0))
                .expect("session after"),
            1
        );
        let versions: Vec<i64> = conn
            .prepare("SELECT version FROM schema_migrations ORDER BY version")
            .expect("versions")
            .query_map([], |row| row.get(0))
            .expect("rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("values");
        assert_eq!(versions, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    }

    fn columns_after_fresh_apply(table: &str) -> Vec<String> {
        let mut fresh = Connection::open_in_memory().expect("fresh");
        apply(&mut fresh).expect("fresh apply");
        columns(&fresh, table)
    }

    /// The drain stops at the first entry it cannot send and a gap in the sequence is terminal,
    /// so a device holding a submission this build refuses gives up its whole staged set rather
    /// than stalling behind one payload forever.
    #[test]
    fn a_device_holding_an_unsendable_submission_gives_up_its_staged_set() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn).expect("fresh");
        conn.execute("DELETE FROM schema_migrations WHERE version >= 10", [])
            .expect("rewind");

        let mut stranded = usage_submission(4, "stranded", "codex");
        stranded["coverage"]["start_at"] = serde_json::json!("1970-01-01T00:00:00Z");
        stranded["coverage"]["end_at"] = serde_json::json!("1970-02-01T00:00:00Z");
        let mut behind = usage_submission(4, "behind", "codex");
        behind["sequence"] = serde_json::json!(1);
        let mut other_device = usage_submission(4, "other", "codex");
        other_device["device_id"] = serde_json::json!("device_other");
        conn.execute(
            "INSERT INTO usage_outbox(
                submission_id, account_id, device_id, generation, sequence, payload_json
             ) VALUES ('stranded', 'account', 'device', 1, 0, ?1),
                      ('behind', 'account', 'device', 1, 1, ?2),
                      ('other', 'account', 'device_other', 1, 0, ?3)",
            params![
                stranded.to_string(),
                behind.to_string(),
                other_device.to_string()
            ],
        )
        .expect("stage");

        apply(&mut conn).expect("v10");

        let remaining: Vec<String> = conn
            .prepare("SELECT submission_id FROM usage_outbox ORDER BY submission_id")
            .expect("query")
            .query_map([], |row| row.get(0))
            .expect("rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("values");
        // The stranded entry and everything staged behind it on that device are gone; another
        // device's queue is untouched and is promoted to the version this build uploads.
        assert_eq!(remaining, vec!["other".to_string()]);
        let promoted: Value = serde_json::from_str(
            &conn
                .query_row(
                    "SELECT payload_json FROM usage_outbox WHERE submission_id = 'other'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .expect("payload"),
        )
        .expect("json");
        assert_eq!(
            promoted["protocol_version"].as_i64(),
            Some(crate::protocol::MANAGED_DATA_PROTOCOL)
        );
        assert!(crate::relay::validate_usage_submission(&promoted).is_ok());
    }

    /// Naming a condition is only useful if it can be written down.  The attempt table lists
    /// its codes in a CHECK that SQLite cannot alter, so the ladder rebuilds it — and the
    /// history a reader consults to see how long something has been failing comes across.
    #[test]
    fn the_attempt_table_accepts_the_conditions_this_build_can_name() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn).expect("fresh");
        conn.execute(
            "INSERT INTO diagnostic_attempts(
                kind, trigger, source, mode, started_at, outcome, code, recovery, start_revision
             ) VALUES ('quota_collection', 'scheduled', 'this_device', 'required',
                       '2026-08-25T00:00:00Z', 'failed', 'provider_error', 'retry', 1)",
            [],
        )
        .expect("history");

        for (code, recovery) in [
            ("access_denied", "check_access"),
            ("client_upgrade_required", "upgrade"),
        ] {
            conn.execute(
                "INSERT INTO diagnostic_attempts(
                    kind, trigger, source, mode, started_at, outcome, code, recovery,
                    start_revision
                 ) VALUES ('quota_collection', 'scheduled', 'this_device', 'required',
                           '2026-08-25T00:01:00Z', 'failed', ?1, ?2, 1)",
                params![code, recovery],
            )
            .unwrap_or_else(|error| panic!("{code} rejected: {error}"));
        }

        let kept: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM diagnostic_attempts WHERE code = 'provider_error'",
                [],
                |row| row.get(0),
            )
            .expect("history kept");
        assert_eq!(kept, 1);
        // Rewinding and re-running the rebuild keeps every row it found.
        conn.execute("DELETE FROM schema_migrations WHERE version >= 11", [])
            .expect("rewind");
        apply(&mut conn).expect("v11");
        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM diagnostic_attempts", [], |row| {
                row.get(0)
            })
            .expect("after rebuild");
        assert_eq!(total, 3);
    }

    /// Rebuilding the table must not be able to strand a device.  An image holding a row it
    /// should never have held gives up that row, not the ladder: a service that cannot open
    /// its state is worse than a missing line of history nothing could read anyway.
    #[test]
    fn a_row_the_table_should_never_have_held_does_not_strand_the_ladder() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn).expect("fresh");
        conn.execute("DELETE FROM schema_migrations WHERE version >= 11", [])
            .expect("rewind");
        conn.execute_batch("PRAGMA ignore_check_constraints = ON")
            .expect("simulate an image that already holds one");
        conn.execute(
            "INSERT INTO diagnostic_attempts(
                kind, trigger, source, mode, started_at, outcome, code, recovery, start_revision
             ) VALUES ('quota_collection', 'scheduled', 'this_device', 'required',
                       '2026-08-25T00:00:00Z', 'failed', 'not_a_code', 'retry', 1)",
            [],
        )
        .expect("unreadable row");
        conn.execute(
            "INSERT INTO diagnostic_attempts(
                kind, trigger, source, mode, started_at, outcome, code, recovery, start_revision
             ) VALUES ('quota_collection', 'scheduled', 'this_device', 'required',
                       '2026-08-25T00:00:01Z', 'failed', 'provider_error', 'retry', 1)",
            [],
        )
        .expect("readable row");
        conn.execute_batch("PRAGMA ignore_check_constraints = OFF")
            .expect("restore");

        apply(&mut conn).expect("the ladder still completes");

        let codes: Vec<String> = conn
            .prepare("SELECT code FROM diagnostic_attempts ORDER BY started_at")
            .expect("query")
            .query_map([], |row| row.get(0))
            .expect("rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("values");
        assert_eq!(codes, vec!["provider_error".to_string()]);
        // Dropping it is a repair, but the reader is told their history is short.
        let truncated: String = conn
            .query_row(
                "SELECT value FROM metadata WHERE key = 'attempt_history_truncated'",
                [],
                |row| row.get(0),
            )
            .expect("marker");
        assert_eq!(truncated, "1");
    }

    /// A report written under an older contract is dropped, not carried forward.
    ///
    /// The app decodes the whole IPC state by one version, so a report stamped with a
    /// version it is not costs the reader every surface at once — instead of one cache the
    /// next collection rebuilds in minutes.
    #[test]
    fn a_report_from_an_older_contract_is_dropped() {
        for (name, value, kept) in [
            (
                "the current contract",
                serde_json::json!({
                    "protocol_version": crate::protocol::LOCAL_COLLECTION_PROTOCOL,
                    "captured_at": "2026-08-25T00:00:00Z",
                    "results": []
                }),
                true,
            ),
            (
                "a report that counted its sources instead of naming them",
                serde_json::json!({
                    "protocol_version": 3,
                    "captured_at": "2026-08-25T00:00:00Z",
                    "results": [{
                        "provider": "claude",
                        "outcome": "auth_required",
                        "snapshots": [],
                        "sources": 1
                    }]
                }),
                false,
            ),
            (
                "something else entirely",
                serde_json::json!({"unexpected": true}),
                false,
            ),
        ] {
            let mut conn = Connection::open_in_memory().expect("memory");
            apply(&mut conn).expect("fresh");
            conn.execute("DELETE FROM schema_migrations WHERE version >= 12", [])
                .expect("rewind");
            conn.execute(
                "INSERT INTO components(name, status, value_json) VALUES ('quota', 'ready', ?1)
                 ON CONFLICT(name) DO UPDATE SET value_json = excluded.value_json",
                params![value.to_string()],
            )
            .expect("persisted report");

            apply(&mut conn).expect("v12");

            let stored: Option<String> = conn
                .query_row(
                    "SELECT value_json FROM components WHERE name = 'quota'",
                    [],
                    |row| row.get(0),
                )
                .expect("component");
            match stored {
                Some(stored) => {
                    assert!(kept, "{name}: {stored}");
                    assert_eq!(
                        serde_json::from_str::<Value>(&stored).expect("json"),
                        value,
                        "{name}"
                    );
                }
                None => assert!(!kept, "{name}"),
            }
        }
    }

    /// Opening the store is on the app's request path, and a request that never answers is a
    /// device with no data and no way forward. This ladder step took 75 seconds on an image
    /// holding 27,755 attempts — past every timeout, on every launch, with nothing committed —
    /// and one index dropped a few statements too early is what did it.
    #[test]
    fn the_ladder_stays_inside_a_launch() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn).expect("fresh");
        conn.execute("DELETE FROM schema_migrations WHERE version >= 11", [])
            .expect("rewind");
        {
            let tx = conn.transaction().expect("transaction");
            for index in 0..30_000 {
                tx.execute(
                    "INSERT INTO diagnostic_attempts(
                        kind, trigger, source, mode, started_at, outcome, code, recovery,
                        start_revision
                     ) VALUES ('quota_collection', 'scheduled', 'this_device', 'required',
                               '2026-08-25T00:00:00Z', 'failed', 'provider_error', 'retry', ?1)",
                    params![index],
                )
                .expect("history");
            }
            tx.commit().expect("commit");
        }

        let started = std::time::Instant::now();
        apply(&mut conn).expect("v11");
        let elapsed = started.elapsed();

        let kept: i64 = conn
            .query_row("SELECT COUNT(*) FROM diagnostic_attempts", [], |row| {
                row.get(0)
            })
            .expect("kept");
        assert_eq!(kept, 30_000);
        assert!(
            elapsed < std::time::Duration::from_secs(10),
            "the ladder took {elapsed:?} for {kept} attempts"
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
