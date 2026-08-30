//! `identity.sqlite` schema.
//!
//! Everything here is something this device cannot regenerate: who it is, who it is signed in
//! as, what it still owes an Account, and the preferences a person set. It is small, it is
//! written rarely, and it is never rebuilt from anything else.

use rusqlite::{Connection, params};
use uuid::Uuid;

use crate::state::StateError;

const CURRENT_SCHEMA: i64 = 4;

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

fn migration_v1(tx: &rusqlite::Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE installation (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            installation_id TEXT NOT NULL,
            payload_json TEXT
         );
         CREATE TABLE session (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload_json TEXT NOT NULL,
            epoch INTEGER NOT NULL DEFAULT 0
         );
         CREATE TABLE usage_upload_context (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            account_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            generation INTEGER NOT NULL,
            lower_bound TEXT NOT NULL
         );
         CREATE TABLE usage_outbox (
            agent TEXT NOT NULL,
            bucket_start_utc TEXT NOT NULL,
            account_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            generation INTEGER NOT NULL,
            scan_version INTEGER NOT NULL,
            partial INTEGER NOT NULL CHECK (partial IN (0, 1)),
            rows_json TEXT NOT NULL,
            PRIMARY KEY(agent, bucket_start_utc)
         );
         CREATE TABLE provider_browser_sessions (
            provider TEXT PRIMARY KEY NOT NULL,
            cookie_header TEXT NOT NULL,
            account_fingerprint TEXT NOT NULL,
            account_label TEXT,
            updated_at TEXT NOT NULL
         );
         CREATE TABLE preferences (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
         );
         INSERT INTO preferences(key, value) VALUES ('usage_upload_enabled', '1');",
    )?;
    Ok(())
}

/// Relay's usage sync revision joins the upload identity, so a revision Relay advances re-seeds
/// every retained hour the same way a new account or device generation does. An image written
/// before it existed has never seen one, which is what zero says.
fn migration_v2(tx: &rusqlite::Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "ALTER TABLE usage_upload_context ADD COLUMN sync_revision INTEGER NOT NULL DEFAULT 0;",
    )?;
    Ok(())
}

/// Quota collection cadence is a preference, default five minutes. Existing identities that
/// never stored one keep that default; a later Settings change overwrites the row.
fn migration_v3(tx: &rusqlite::Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "INSERT OR IGNORE INTO preferences(key, value)
         VALUES ('quota_refresh_interval_seconds', '300');",
    )?;
    Ok(())
}

/// Browser scan is a preference: one provider may keep several validated sessions, and a
/// stored session from before this shape means scanning is already on.
fn migration_v4(tx: &rusqlite::Transaction<'_>) -> Result<(), StateError> {
    tx.execute_batch(
        "CREATE TABLE provider_browser_sessions_v4 (
            provider TEXT NOT NULL,
            account_fingerprint TEXT NOT NULL,
            cookie_header TEXT NOT NULL,
            account_label TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (provider, account_fingerprint)
         );
         INSERT INTO provider_browser_sessions_v4(
            provider, account_fingerprint, cookie_header, account_label, updated_at
         )
         SELECT provider, account_fingerprint, cookie_header, account_label, updated_at
         FROM provider_browser_sessions;
         INSERT OR IGNORE INTO preferences(key, value)
         SELECT 'browser_scan:' || provider, '1' FROM provider_browser_sessions;
         DROP TABLE provider_browser_sessions;
         ALTER TABLE provider_browser_sessions_v4 RENAME TO provider_browser_sessions;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A v1 image keeps its upload identity across the upgrade and starts at revision zero.
    #[test]
    fn a_v1_image_gains_the_sync_revision_without_losing_its_upload_identity() {
        let mut conn = Connection::open_in_memory().expect("memory");
        conn.execute_batch(
            "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);",
        )
        .expect("ladder");
        let tx = conn.transaction().expect("transaction");
        migration_v1(&tx).expect("v1");
        tx.execute_batch(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (1, '2026-08-25T00:00:00Z');
             INSERT INTO usage_upload_context(id, account_id, device_id, generation, lower_bound)
             VALUES (1, 'account', 'device', 3, '1970-01-01T00:00:00Z');",
        )
        .expect("v1 rows");
        tx.commit().expect("commit");

        apply(&mut conn).expect("upgrade");
        let (generation, sync_revision): (i64, i64) = conn
            .query_row(
                "SELECT generation, sync_revision FROM usage_upload_context WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("context");
        assert_eq!((generation, sync_revision), (3, 0));
        assert_eq!(
            conn.query_row(
                "SELECT value FROM preferences WHERE key = 'quota_refresh_interval_seconds'",
                [],
                |row| row.get::<_, String>(0),
            )
            .expect("cadence after upgrade"),
            "300"
        );
    }

    #[test]
    fn a_fresh_identity_names_this_installation_and_keeps_the_upload_default() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn).expect("schema");
        let installation: String = conn
            .query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .expect("installation");
        assert_eq!(installation.len(), 36);
        assert_eq!(
            conn.query_row(
                "SELECT value FROM preferences WHERE key = 'usage_upload_enabled'",
                [],
                |row| row.get::<_, String>(0),
            )
            .expect("preference"),
            "1"
        );
        assert_eq!(
            conn.query_row(
                "SELECT value FROM preferences WHERE key = 'quota_refresh_interval_seconds'",
                [],
                |row| row.get::<_, String>(0),
            )
            .expect("cadence"),
            "300"
        );

        // Re-applying is a no-op: the installation this device already answers as must not
        // change because the service restarted.
        apply(&mut conn).expect("re-apply");
        assert_eq!(
            conn.query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .expect("installation again"),
            installation
        );
    }

    #[test]
    fn an_image_written_by_a_newer_client_fails_closed() {
        let mut conn = Connection::open_in_memory().expect("memory");
        apply(&mut conn).expect("schema");
        conn.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (99, '2026-08-25T00:00:00Z')",
            [],
        )
        .expect("newer marker");
        assert!(matches!(
            apply(&mut conn),
            Err(StateError::ClientUpgradeRequired)
        ));
    }
}
