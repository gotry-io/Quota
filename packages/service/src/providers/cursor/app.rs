use crate::catalog::ProviderId;

use super::super::common::{
    CollectionContext, decode_jwt_payload, normalize_browser_cookie_header, parse_date,
};
use rusqlite::{Connection, OpenFlags, types::ValueRef};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub(super) const SOURCE: &str = "cursor_app_auth";
const ACCESS_TOKEN_KEY: &str = "cursorAuth/accessToken";
const AUTH_SKEW_SECONDS: i64 = 60;
const TOKEN_LIMIT: usize = 8_192;

pub(super) fn usable_session(context: &CollectionContext) -> bool {
    cookie_header(context).is_some()
}

pub(super) fn cookie_header(context: &CollectionContext) -> Option<String> {
    if context.cancelled() {
        return None;
    }
    let path = desktop_state_path(context);
    if !path.is_file() {
        return None;
    }
    let token = read_access_token(&path)?;
    session_from_access_token(&token, context.observed_unix())
}

fn desktop_state_path(context: &CollectionContext) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        context
            .home_directory
            .join("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
    #[cfg(not(target_os = "macos"))]
    {
        let xdg = context
            .env("XDG_CONFIG_HOME")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| context.home_directory.join(".config"));
        xdg.join("Cursor/User/globalStorage/state.vscdb")
    }
}

fn read_access_token(path: &Path) -> Option<String> {
    let connection = open_state_database(path)?;
    let mut statement = connection
        .prepare("SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1")
        .ok()?;
    let mut rows = statement.query([ACCESS_TOKEN_KEY]).ok()?;
    let row = rows.next().ok()??;
    decode_item_value(row.get_ref(0).ok()?)
}

fn open_state_database(path: &Path) -> Option<Connection> {
    match open_state_database_with(path, false) {
        Ok(connection) => Some(connection),
        Err(error) if cannot_open(&error) && wal_sidecars_missing(path) => {
            open_state_database_with(path, true).ok()
        }
        Err(_) => None,
    }
}

fn open_state_database_with(path: &Path, immutable: bool) -> rusqlite::Result<Connection> {
    let connection = if immutable {
        let uri = sqlite_uri(path).ok_or_else(|| {
            rusqlite::Error::InvalidParameterName("cursor state path is not utf-8".to_owned())
        })?;
        Connection::open_with_flags(
            uri,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )?
    } else {
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?
    };
    connection.busy_timeout(Duration::from_millis(250))?;
    let _ = connection.execute_batch("PRAGMA query_only = ON;");
    Ok(connection)
}

fn sqlite_uri(path: &Path) -> Option<String> {
    let raw = path.to_str()?;
    let mut encoded = String::with_capacity(raw.len());
    for byte in raw.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'.' | b'-' | b'_' | b':' => {
                encoded.push(byte as char);
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    Some(format!("file:{encoded}?immutable=1"))
}

fn cannot_open(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(code, _)
            if code.code == rusqlite::ErrorCode::CannotOpen
    )
}

fn wal_sidecars_missing(path: &Path) -> bool {
    !sidecar(path, "-wal").exists() && !sidecar(path, "-shm").exists()
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

fn decode_item_value(value: ValueRef<'_>) -> Option<String> {
    let text = match value {
        ValueRef::Text(bytes) => std::str::from_utf8(bytes).ok()?.to_owned(),
        ValueRef::Blob(bytes) => decode_blob(bytes)?,
        _ => return None,
    };
    let text = text.trim();
    (!text.is_empty() && text.len() <= TOKEN_LIMIT).then(|| text.to_owned())
}

fn decode_blob(bytes: &[u8]) -> Option<String> {
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Some(text.to_owned());
    }
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    let units = bytes
        .chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
        .collect::<Vec<_>>();
    String::from_utf16(&units).ok()
}

fn session_from_access_token(token: &str, now: i64) -> Option<String> {
    let payload = decode_jwt_payload(token)?;
    let user_id = user_id_from_subject(payload.get("sub")?.as_str()?)?;
    let expires_at = parse_date(payload.get("exp"))?;
    if expires_at - now <= AUTH_SKEW_SECONDS {
        return None;
    }
    // The dashboard cookie the app session yields goes through the same catalog
    // allowlist, octet, and bound checks as a browser-supplied header.
    normalize_browser_cookie_header(
        ProviderId::Cursor,
        &format!("WorkosCursorSessionToken={user_id}%3A%3A{token}"),
    )
    .ok()
}

fn user_id_from_subject(subject: &str) -> Option<String> {
    let user_id = subject
        .split('|')
        .map(str::trim)
        .rfind(|part| !part.is_empty())?;
    user_id
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        .then(|| user_id.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::ProviderId;
    use crate::providers::ProviderSession;
    use crate::providers::common::ErrorCategory;
    use crate::providers::cursor::discover;
    use base64::Engine;
    use rusqlite::Connection;
    use std::collections::HashMap;
    use std::fs;

    fn isolated_home() -> PathBuf {
        std::env::temp_dir().join(format!("quota-cursor-app-{}", uuid::Uuid::new_v4()))
    }

    fn isolated_context(home: PathBuf) -> CollectionContext {
        CollectionContext {
            home_directory: home,
            environment: HashMap::new(),
            config_path: None,
            browser_sessions: HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-21T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        }
    }

    fn state_path(home: &Path) -> PathBuf {
        desktop_state_path(&isolated_context(home.to_path_buf()))
    }

    fn write_access_token(home: &Path, token: &str) {
        write_access_token_bytes(home, token.as_bytes());
    }

    fn write_access_token_bytes(home: &Path, token: &[u8]) {
        let path = state_path(home);
        fs::create_dir_all(path.parent().expect("parent")).expect("parent");
        let connection = Connection::open(&path).expect("open fixture");
        connection
            .execute_batch("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
            .expect("schema");
        connection
            .execute(
                "INSERT INTO ItemTable(key, value) VALUES (?1, ?2)",
                rusqlite::params![ACCESS_TOKEN_KEY, token],
            )
            .expect("insert");
        connection.close().expect("close");
    }

    fn test_jwt(sub: &str, exp: i64) -> String {
        let header = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"alg":"none"}"#);
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(format!(r#"{{"sub":"{sub}","exp":{exp}}}"#).as_bytes());
        format!("{header}.{payload}.sig")
    }

    #[test]
    fn remapped_home_does_not_read_the_live_cursor_database() {
        let home = isolated_home();
        let context = isolated_context(home.clone());
        assert!(discover(&context).is_empty());
        assert!(cookie_header(&context).is_none());
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn discovers_usable_cursor_app_session_before_browser_session() {
        let home = isolated_home();
        write_access_token(&home, &test_jwt("auth0|user_abc", 2_000_000_000));
        let mut context = isolated_context(home.clone());
        context
            .browser_sessions
            .insert(ProviderId::Cursor, "wos-session=browser".to_owned());
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].credential_source, SOURCE);
        let header = cookie_header(&context).expect("cookie");
        assert!(header.starts_with("WorkosCursorSessionToken=user_abc%3A%3A"));
        assert!(!header.contains("browser"));
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn expired_or_invalid_app_token_falls_back_to_browser_session() {
        let home = isolated_home();
        write_access_token(&home, &test_jwt("auth0|user_abc", 1_000_000_000));
        let mut context = isolated_context(home.clone());
        assert!(discover(&context).is_empty());
        context
            .browser_sessions
            .insert(ProviderId::Cursor, "wos-session=browser".to_owned());
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].credential_source, "browser_session");
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn rejects_invalid_subject_and_missing_expiry() {
        let home = isolated_home();
        write_access_token(&home, &test_jwt("auth0|user abc", 2_000_000_000));
        assert!(discover(&isolated_context(home.clone())).is_empty());
        let _ = fs::remove_dir_all(&home);

        let home = isolated_home();
        let header = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"alg":"none"}"#);
        let payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"sub":"auth0|user_abc"}"#);
        write_access_token(&home, &format!("{header}.{payload}.sig"));
        assert!(discover(&isolated_context(home.clone())).is_empty());
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn reads_utf8_blob_tokens() {
        let home = isolated_home();
        write_access_token_bytes(&home, test_jwt("user.abc-1", 2_000_000_000).as_bytes());
        let header = cookie_header(&isolated_context(home.clone())).expect("cookie");
        assert!(header.starts_with("WorkosCursorSessionToken=user.abc-1%3A%3A"));
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn official_collect_without_app_session_is_auth_required() {
        let context = isolated_context(isolated_home());
        let session = ProviderSession {
            provider: ProviderId::Cursor,
            credential_source: SOURCE.to_owned(),
        };
        let error = crate::providers::cursor::collect(&session, &context).expect_err("auth");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        // The rung that failed is the app's, and the recovery copy a reader is shown turns on
        // that: an expired app token is not a browser session to re-add.
        assert_eq!(error.source_id, SOURCE);
        assert!(!error.to_string().contains("cursorAuth"));
    }
}
