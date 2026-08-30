//! One-time move of a released single-file image into `identity.sqlite`. Only what this device
//! cannot regenerate comes across; the rest was a cache the next refresh rebuilds. The image is
//! read read-only and removed either way, because a retry on every launch is worse than a reset.
//!
//! A released image's staged uploads do not come across. They were requests in a contract this
//! build no longer speaks, and an hour is replaced by version now: the first scan after the
//! import recomputes every retained hour and sends it again.
//!
//! Two roots are looked at: the one this service keeps state in now, and the released root beside
//! it ([`crate::config::legacy_state_root`]). A device that upgrades across the rename would
//! otherwise become a new installation and a second Device on the same Account.

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

/// Imports a released image if either root holds one, then clears what it read from.
///
/// The current root wins when both hold an image; the released root is cleared either way, so a
/// second launch has nothing left to consider.
pub(super) fn take(root: &Path, identity: &mut Connection) -> LegacyImport {
    let released = crate::config::legacy_state_root(root);
    // The released root's provider configuration crosses even when it kept no image: an API key
    // a person typed is not something the next refresh can rebuild.
    if let Some(source) = released.as_deref() {
        adopt_provider_config(source, root);
    }
    let mut outcome = LegacyImport::Absent;
    for source in [Some(root), released.as_deref()].into_iter().flatten() {
        let live = source.join(LEGACY_PREFIX);
        if !live.is_file() {
            continue;
        }
        if outcome == LegacyImport::Absent {
            outcome = match copy_identity(&live, identity) {
                Ok(()) => LegacyImport::Imported,
                Err(_) => LegacyImport::Unreadable,
            };
        }
        remove_released_images(source);
    }
    // Nothing this build put there is left. The directory itself goes only if nothing else is:
    // an empty `remove_dir` succeeds, and anything unexpected keeps it and is left alone.
    if let Some(source) = released.as_deref() {
        let _ = fs::remove_dir(source);
    }
    outcome
}

/// Moves the released provider configuration into the current root.
///
/// It is read and rewritten through the same owner-only path any other write takes — `0700`
/// directory, `0600` file, no symlink, atomic replace — so an adopted file is indistinguishable
/// from one this build wrote. A device that already has its own is the authority and keeps it.
fn adopt_provider_config(source: &Path, root: &Path) {
    let from = source.join(super::PROVIDER_CONFIG_NAME);
    if !fs::symlink_metadata(&from).is_ok_and(|meta| meta.is_file())
        || fs::symlink_metadata(root.join(super::PROVIDER_CONFIG_NAME)).is_ok()
    {
        return;
    }
    let Ok(released) = super::read_provider_file(source) else {
        return;
    };
    if super::write_provider_file(root, &released).is_ok() {
        let _ = fs::remove_file(&from);
    }
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
    let context: Option<(String, String, i64, String)> = legacy
        .query_row(
            "SELECT account_id, device_id, generation, lower_bound
             FROM usage_upload_context WHERE id = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
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
    if let Some((payload, epoch)) =
        session.filter(|(payload, _)| session_payload_is_usable(payload))
    {
        tx.execute(
            "INSERT OR REPLACE INTO session(id, payload_json, epoch) VALUES (1, ?1, ?2)",
            params![payload, epoch],
        )?;
    }
    if let Some(context) = context {
        tx.execute(
            "INSERT OR REPLACE INTO usage_upload_context(
                id, account_id, device_id, generation, lower_bound
             ) VALUES (1, ?1, ?2, ?3, ?4)",
            params![context.0, context.1, context.2, context.3],
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

/// A released session this build can actually use. Anything else is dropped rather than copied
/// into a row `login` would then refuse forever.
fn session_payload_is_usable(payload: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(payload)
        .is_ok_and(|value| super::session_is_usable(&value))
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
    use std::fs::Permissions;
    use std::os::unix::fs::PermissionsExt;
    use uuid::Uuid;

    fn seed_released_image(path: &Path, session: bool) -> Connection {
        let conn = Connection::open(path).expect("legacy image");
        conn.execute_batch(
            "CREATE TABLE installation(id INTEGER PRIMARY KEY, installation_id TEXT NOT NULL, payload_json TEXT);
             CREATE TABLE session(id INTEGER PRIMARY KEY, payload_json TEXT NOT NULL, epoch INTEGER NOT NULL);
             CREATE TABLE usage_upload_context(id INTEGER PRIMARY KEY, account_id TEXT NOT NULL, device_id TEXT NOT NULL, generation INTEGER NOT NULL, aggregation_timezone TEXT NOT NULL, lower_bound TEXT NOT NULL);
             CREATE TABLE provider_browser_sessions(provider TEXT PRIMARY KEY, cookie_header TEXT NOT NULL, account_fingerprint TEXT NOT NULL, account_label TEXT, updated_at TEXT NOT NULL);
             CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO installation VALUES (1, 'released-installation', '{\"schema_version\":1}');
             INSERT INTO usage_upload_context VALUES (1, 'account', 'device', 3, 'UTC', '2026-08-01T00:00:00Z');
             INSERT INTO provider_browser_sessions VALUES ('cursor', 'wos-session=secret', 'abc', 'ad***@example.com', '2026-08-01T00:00:00Z');
             INSERT INTO metadata VALUES ('usage_upload_enabled', '0');",
        )
        .expect("legacy rows");
        if session {
            conn.execute(
                "INSERT INTO session VALUES (1, '{\"status\":\"active\",\"account_id\":\"account_1\",\"device_id\":\"device_1\",\"device_generation\":1,\"session\":{\"access_token\":\"qb_access_token_synthetic\",\"refresh_token\":\"qbr_refresh_token_synthetic\"}}', 7)",
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
        // A released image's staged uploads spoke a contract this build has retired. What
        // this device still owes its Account is recomputed by the first scan instead.
        assert_eq!(
            identity
                .query_row("SELECT COUNT(*) FROM usage_outbox", [], |row| row
                    .get::<_, i64>(0))
                .expect("outbox"),
            0
        );
        assert_eq!(
            identity
                .query_row(
                    "SELECT generation FROM usage_upload_context WHERE id = 1",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .expect("upload context"),
            3
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
    fn an_unusable_released_session_is_dropped_instead_of_copied() {
        let root = temp_root("legacy-bad-session");
        let live = root.join(LEGACY_PREFIX);
        let conn = seed_released_image(&live, false);
        conn.execute(
            "INSERT INTO session VALUES (1, '{\"status\":\"expired\"}', 7)",
            [],
        )
        .expect("invalid session");
        drop(conn);
        let mut identity = identity_image();

        assert_eq!(take(&root, &mut identity), LegacyImport::Imported);
        let count: i64 = identity
            .query_row("SELECT COUNT(*) FROM session", [], |row| row.get(0))
            .expect("session count");
        assert_eq!(count, 0);
        fs::remove_dir_all(root).expect("cleanup");
    }

    /// A released root beside the current one is what an upgrade across the directory rename
    /// actually looks like on disk, so it is what this test builds.
    #[test]
    fn the_released_root_beside_this_one_hands_over_identity_and_configuration() {
        let base = temp_root("adopt");
        let root = base.join("quota");
        let released = base.join("quotacli");
        fs::create_dir_all(&root).expect("current root");
        fs::create_dir_all(&released).expect("released root");
        drop(seed_released_image(&released.join(LEGACY_PREFIX), true));
        let configuration = released.join(super::super::PROVIDER_CONFIG_NAME);
        fs::write(
            &configuration,
            br#"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-or-released"}}}"#,
        )
        .expect("released configuration");
        fs::set_permissions(&configuration, Permissions::from_mode(0o600)).expect("0600");
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
        // The API key crosses, owner-only, and stops existing where it was.
        let adopted = root.join(super::super::PROVIDER_CONFIG_NAME);
        let metadata = fs::metadata(&adopted).expect("adopted configuration");
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert!(
            String::from_utf8_lossy(&fs::read(&adopted).expect("adopted bytes"))
                .contains("sk-or-released")
        );
        assert!(!configuration.exists());
        // Nothing of the released root is left to consider on the next launch.
        assert!(!released.join(LEGACY_PREFIX).exists());
        assert!(!released.exists());
        assert_eq!(take(&root, &mut identity), LegacyImport::Absent);

        fs::remove_dir_all(base).expect("cleanup");
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
