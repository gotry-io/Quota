//! One-time move of a released single-file image into `identity.sqlite`. Only what this device
//! cannot regenerate comes across; the rest was a cache the next refresh rebuilds. The image is
//! read read-only and removed either way, because a retry on every launch is worse than a reset.

use std::fs;
use std::path::Path;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use super::StateError;

const LEGACY_PREFIX: &str = "state.sqlite";

/// `Unreadable` means a released image was there and could not be read: this device starts over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum LegacyImport {
    Absent,
    Imported,
    Unreadable,
}

/// Imports a released image if one is present, then removes it.
pub(super) fn take(root: &Path, identity: &mut Connection) -> LegacyImport {
    let live = root.join(LEGACY_PREFIX);
    if !live.is_file() {
        return LegacyImport::Absent;
    }
    let outcome = match copy_identity(&live, identity) {
        Ok(()) => LegacyImport::Imported,
        Err(_) => LegacyImport::Unreadable,
    };
    remove_released_images(root);
    outcome
}

fn copy_identity(live: &Path, identity: &mut Connection) -> Result<(), StateError> {
    let legacy = Connection::open_with_flags(
        live,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    legacy.execute_batch("PRAGMA query_only = ON; PRAGMA busy_timeout = 5000;")?;
    let installation: (String, Option<String>) = legacy.query_row(
        "SELECT installation_id, payload_json FROM installation WHERE id = 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let session: Option<(String, i64)> = legacy
        .query_row(
            "SELECT payload_json, epoch FROM session WHERE id = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let context: Option<(String, String, i64, String, String)> = legacy
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
    let outbox: Vec<(String, String, String, i64, i64, String)> = rows(
        &legacy,
        "SELECT submission_id, account_id, device_id, generation, sequence, payload_json
         FROM usage_outbox",
        |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        },
    )?;
    let sessions: Vec<(String, String, String, Option<String>, String)> = rows(
        &legacy,
        "SELECT provider, cookie_header, account_fingerprint, account_label, updated_at
         FROM provider_browser_sessions",
        |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        },
    )?;
    let upload_enabled: Option<String> = legacy
        .query_row(
            "SELECT value FROM metadata WHERE key = 'usage_upload_enabled'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    drop(legacy);

    let tx = identity.transaction()?;
    tx.execute(
        "UPDATE installation SET installation_id = ?1, payload_json = ?2 WHERE id = 1",
        params![installation.0, installation.1],
    )?;
    if let Some((payload, epoch)) = session {
        tx.execute(
            "INSERT OR REPLACE INTO session(id, payload_json, epoch) VALUES (1, ?1, ?2)",
            params![payload, epoch],
        )?;
    }
    if let Some(context) = context {
        tx.execute(
            "INSERT OR REPLACE INTO usage_upload_context(
                id, account_id, device_id, generation, aggregation_timezone, lower_bound
             ) VALUES (1, ?1, ?2, ?3, ?4, ?5)",
            params![context.0, context.1, context.2, context.3, context.4],
        )?;
    }
    for entry in outbox {
        tx.execute(
            "INSERT OR REPLACE INTO usage_outbox(
                submission_id, account_id, device_id, generation, sequence, payload_json
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![entry.0, entry.1, entry.2, entry.3, entry.4, entry.5],
        )?;
    }
    for entry in sessions {
        tx.execute(
            "INSERT OR REPLACE INTO provider_browser_sessions(
                provider, cookie_header, account_fingerprint, account_label, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![entry.0, entry.1, entry.2, entry.3, entry.4],
        )?;
    }
    if let Some(value) = upload_enabled.filter(|value| value == "0" || value == "1") {
        tx.execute(
            "INSERT INTO preferences(key, value) VALUES ('usage_upload_enabled', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![value],
        )?;
    }
    tx.commit()?;
    Ok(())
}

type RowMap<T> = fn(&rusqlite::Row<'_>) -> Result<T, rusqlite::Error>;

fn rows<T>(conn: &Connection, sql: &str, map: RowMap<T>) -> Result<Vec<T>, StateError> {
    let mut statement = conn.prepare(sql)?;
    let values = statement.query_map([], map)?.collect::<Result<_, _>>()?;
    Ok(values)
}

/// Removes the image and every sidecar or parked copy beside it, by prefix rather than by a
/// list of names this build no longer knows.
fn remove_released_images(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name.to_str().is_some_and(|n| n.starts_with(LEGACY_PREFIX)) {
            let _ = fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn seed_released_image(path: &Path, session: bool) -> Connection {
        let conn = Connection::open(path).expect("legacy image");
        conn.execute_batch(
            "CREATE TABLE installation(id INTEGER PRIMARY KEY, installation_id TEXT NOT NULL, payload_json TEXT);
             CREATE TABLE session(id INTEGER PRIMARY KEY, payload_json TEXT NOT NULL, epoch INTEGER NOT NULL);
             CREATE TABLE usage_upload_context(id INTEGER PRIMARY KEY, account_id TEXT NOT NULL, device_id TEXT NOT NULL, generation INTEGER NOT NULL, aggregation_timezone TEXT NOT NULL, lower_bound TEXT NOT NULL);
             CREATE TABLE usage_outbox(submission_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, device_id TEXT NOT NULL, generation INTEGER NOT NULL, sequence INTEGER NOT NULL, payload_json TEXT NOT NULL);
             CREATE TABLE provider_browser_sessions(provider TEXT PRIMARY KEY, cookie_header TEXT NOT NULL, account_fingerprint TEXT NOT NULL, account_label TEXT, updated_at TEXT NOT NULL);
             CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO installation VALUES (1, 'released-installation', '{\"schema_version\":1}');
             INSERT INTO usage_upload_context VALUES (1, 'account', 'device', 3, 'UTC', '2026-08-01T00:00:00Z');
             INSERT INTO usage_outbox VALUES ('submission', 'account', 'device', 3, 0, '{}');
             INSERT INTO provider_browser_sessions VALUES ('cursor', 'wos-session=secret', 'abc', 'ad***@example.com', '2026-08-01T00:00:00Z');
             INSERT INTO metadata VALUES ('usage_upload_enabled', '0');",
        )
        .expect("legacy rows");
        if session {
            conn.execute(
                "INSERT INTO session VALUES (1, '{\"status\":\"active\"}', 7)",
                [],
            )
            .expect("legacy session");
        }
        conn
    }

    /// `NOFOLLOW` rejects a symlink anywhere in the path, and the macOS temporary directory
    /// reaches through one, so a test root is resolved the way the service resolves its own.
    fn temp_root(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("quota-{name}-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        fs::canonicalize(&root).expect("canonical root")
    }

    fn identity_image() -> Connection {
        let mut conn = Connection::open_in_memory().expect("identity");
        crate::migration::identity::apply(&mut conn).expect("identity schema");
        conn
    }

    #[test]
    fn a_released_image_hands_over_its_identity_and_is_removed() {
        let root = temp_root("legacy");
        let live = root.join(LEGACY_PREFIX);
        drop(seed_released_image(&live, true));
        for sidecar in [".parked", ".snapshot"] {
            fs::write(root.join(format!("{LEGACY_PREFIX}{sidecar}")), b"leftover")
                .expect("released sidecar");
        }
        let mut identity = identity_image();

        assert_eq!(take(&root, &mut identity), LegacyImport::Imported);

        assert_eq!(
            identity
                .query_row(
                    "SELECT installation_id FROM installation WHERE id = 1",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .expect("installation"),
            "released-installation"
        );
        assert_eq!(
            identity
                .query_row("SELECT epoch FROM session WHERE id = 1", [], |row| row
                    .get::<_, i64>(0))
                .expect("session"),
            7
        );
        assert_eq!(
            identity
                .query_row("SELECT COUNT(*) FROM usage_outbox", [], |row| row
                    .get::<_, i64>(0))
                .expect("outbox"),
            1
        );
        assert_eq!(
            identity
                .query_row(
                    "SELECT COUNT(*) FROM provider_browser_sessions",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .expect("browser sessions"),
            1
        );
        assert_eq!(
            identity
                .query_row(
                    "SELECT value FROM preferences WHERE key = 'usage_upload_enabled'",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .expect("preference"),
            "0"
        );
        assert!(
            fs::read_dir(&root)
                .expect("entries")
                .flatten()
                .all(|entry| !entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(LEGACY_PREFIX))
        );
        assert_eq!(take(&root, &mut identity), LegacyImport::Absent);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn an_unreadable_released_image_starts_this_device_over_and_is_still_removed() {
        let root = temp_root("legacy-bad");
        fs::write(root.join(LEGACY_PREFIX), b"not a database at all").expect("garbage");
        let mut identity = identity_image();
        let fresh: String = identity
            .query_row(
                "SELECT installation_id FROM installation WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .expect("installation");

        assert_eq!(take(&root, &mut identity), LegacyImport::Unreadable);

        assert_eq!(
            identity
                .query_row(
                    "SELECT installation_id FROM installation WHERE id = 1",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .expect("installation"),
            fresh
        );
        assert!(!root.join(LEGACY_PREFIX).exists());
        fs::remove_dir_all(root).expect("cleanup");
    }
}
