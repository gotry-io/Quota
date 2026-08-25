//! `identity.sqlite` schema.
//!
//! Everything here is something this device cannot regenerate: who it is, who it is signed in
//! as, what it still owes an Account, and the preferences a person set. It is small, it is
//! written rarely, and it is never rebuilt from anything else.

use rusqlite::{Connection, params};
use uuid::Uuid;

use crate::state::StateError;

const CURRENT_SCHEMA: i64 = 1;

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

#[cfg(test)]
mod tests {
    use super::*;

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
