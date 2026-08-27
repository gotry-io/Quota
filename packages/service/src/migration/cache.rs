//! `cache.sqlite` schema.
//!
//! Everything here is derived from something else — local log files, Relay responses, this
//! device's own last refresh — so the whole file is disposable. It is never salvaged and never
//! copied: a damaged image is deleted and the next refresh fills it in again.

use rusqlite::{Connection, params};

use crate::state::StateError;

const CURRENT_SCHEMA: i64 = 1;

/// Applies the schema, starting the change counter at `revision_floor`.
///
/// The counter has to keep going up across a rebuild: QuotaBar ignores a change event whose
/// revision is not newer than the last state it read, so a cache that restarted at zero would
/// leave the panel showing nothing until the count caught up.
pub fn apply(conn: &mut Connection, revision_floor: u64) -> Result<(), StateError> {
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
            1 => migration_v1(&tx, revision_floor)?,
            _ => return Err(StateError::InvalidState),
        }
        tx.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?1, ?2)",
            params![version, crate::state::now_rfc3339()],
        )?;
        tx.commit()?;
    }
    Ok(())
}

fn migration_v1(tx: &rusqlite::Transaction<'_>, revision_floor: u64) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
         );
         CREATE TABLE components (
            name TEXT PRIMARY KEY NOT NULL,
            status TEXT NOT NULL,
            value_json TEXT,
            updated_at TEXT,
            last_error_code TEXT,
            last_error_action TEXT,
            refreshing INTEGER NOT NULL DEFAULT 0 CHECK (refreshing IN (0, 1))
         );
         CREATE TABLE usage_file_index (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            identity TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_ns TEXT NOT NULL,
            parser_revision TEXT NOT NULL,
            parsed_offset INTEGER NOT NULL DEFAULT 0,
            prefix_hash TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(agent, source_file_id)
         );
         CREATE TABLE usage_file_records (
            agent TEXT NOT NULL,
            source_file_id TEXT NOT NULL,
            record_key TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            event_json TEXT NOT NULL,
            PRIMARY KEY(agent, source_file_id, record_key)
         );
         CREATE INDEX usage_file_records_time ON usage_file_records(agent, occurred_at);
         CREATE TABLE usage_hourly_facts (
            agent TEXT NOT NULL,
            bucket_start_utc TEXT NOT NULL,
            billing_channel TEXT NOT NULL,
            channel_source TEXT NOT NULL,
            model TEXT NOT NULL,
            context_bucket TEXT NOT NULL,
            service_tier TEXT NOT NULL,
            speed TEXT NOT NULL,
            inference_geo TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_write_5m_tokens INTEGER NOT NULL,
            cache_write_1h_tokens INTEGER NOT NULL,
            cache_write_inferred_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_tokens INTEGER NOT NULL,
            requests INTEGER NOT NULL,
            web_search_requests INTEGER NOT NULL,
            web_fetch_requests INTEGER NOT NULL,
            source_cost_microusd INTEGER,
            source_cost_covered_requests INTEGER NOT NULL,
            partial INTEGER NOT NULL CHECK (partial IN (0, 1)),
            scan_version INTEGER NOT NULL,
            PRIMARY KEY(agent, bucket_start_utc, billing_channel, channel_source, model,
                        context_bucket, service_tier, speed, inference_geo)
         );
         CREATE INDEX usage_hourly_facts_day ON usage_hourly_facts(bucket_start_utc);
         -- The period fold groups by the UTC date and then by every dimension a row is keyed
         -- on. Ordered that way, the grouping streams off this index instead of sorting the
         -- whole table into a temporary b-tree first: measured over one year of hours,
         -- 82 ms to 31 ms. The summed columns are deliberately not in it — carrying them made
         -- the same fold 27 ms and doubled what every recomputed hour has to write.
         CREATE INDEX usage_hourly_facts_period ON usage_hourly_facts(
            substr(bucket_start_utc, 1, 10), agent, billing_channel, channel_source, model,
            context_bucket, service_tier, speed, inference_geo);
         CREATE TABLE usage_dirty_hours (
            agent TEXT NOT NULL,
            bucket_start_utc TEXT NOT NULL,
            scan_version INTEGER NOT NULL,
            partial INTEGER NOT NULL CHECK (partial IN (0, 1)),
            PRIMARY KEY(agent, bucket_start_utc)
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
         CREATE TABLE usage_scan_diagnostics (
            agent TEXT PRIMARY KEY NOT NULL,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
         );
         CREATE TABLE model_catalog_cache (
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
         CREATE TABLE account_read_cache (
            account_id TEXT NOT NULL,
            query TEXT NOT NULL,
            etag TEXT NOT NULL,
            body_json TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(account_id, query)
         );
         CREATE TABLE diagnostic_snapshot (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload_json TEXT NOT NULL,
            completed_at TEXT NOT NULL
         );
         CREATE TABLE diagnostic_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_refresh_id INTEGER REFERENCES diagnostic_attempts(id) ON DELETE SET NULL,
            kind TEXT NOT NULL CHECK (kind IN (
                'refresh', 'quota_collection', 'usage_scan', 'usage_upload',
                'account_sync', 'pricing_refresh'
            )),
            trigger TEXT NOT NULL CHECK (trigger IN (
                'manual', 'scheduled', 'startup', 'recheck', 'settings_change', 'account_change'
            )),
            subject TEXT CHECK (subject IS NULL OR (
                length(subject) BETWEEN 7 AND 96
                AND (subject LIKE 'provider:%' OR subject LIKE 'agent:%')
                AND subject NOT GLOB '*[^a-z0-9_:]*'
            )),
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
                'truncated_active_source',
                'device_deleted'
            ))
         );
         CREATE INDEX diagnostic_attempts_recent_idx
            ON diagnostic_attempts(started_at DESC, id DESC);
         CREATE INDEX diagnostic_attempts_parent_idx
            ON diagnostic_attempts(parent_refresh_id, id);
         CREATE INDEX diagnostic_attempts_kind_idx
            ON diagnostic_attempts(kind, subject, id DESC);",
    )?;
    tx.execute(
        "INSERT INTO metadata(key, value) VALUES ('revision', ?1)",
        params![revision_floor.to_string()],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rebuilt_cache_counts_on_from_where_the_last_one_stopped() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn, 41).expect("schema");
        assert_eq!(
            conn.query_row(
                "SELECT value FROM metadata WHERE key = 'revision'",
                [],
                |row| row.get::<_, String>(0)
            )
            .expect("revision"),
            "41"
        );
    }

    #[test]
    fn an_image_written_by_a_newer_client_fails_closed() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn, 0).expect("schema");
        conn.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (99, '2026-08-25T00:00:00Z')",
            [],
        )
        .expect("newer marker");
        assert!(matches!(
            apply(&mut conn, 0),
            Err(StateError::ClientUpgradeRequired)
        ));
    }
}
