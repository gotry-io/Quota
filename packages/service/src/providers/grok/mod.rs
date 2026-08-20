use crate::catalog::ProviderId;
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError, ProviderSession,
    QuotaAccount, QuotaSnapshot, QuotaWindow, ValidatedBrowserSession, account_identity,
    clamp_percent, collect_official_or_browser, discover_official_or_browser, duration_seconds,
    is_executable_file, mask_display_name, mask_email, number, obj_get, obj_get_any, parse_date,
    read_bounded_file, string,
};

mod web;

pub const SOURCE: &str = "grok_billing_api";
pub const BILLING_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const OIDC_PREFIX: &str = "https://auth.x.ai::";
const LEGACY_SCOPE: &str = "https://accounts.x.ai/sign-in";

#[derive(Clone, Debug)]
struct Credentials {
    scope: String,
    access_token: String,
    user_id: Option<String>,
    email: Option<String>,
    first_name: Option<String>,
    last_name: Option<String>,
    team_id: Option<String>,
    auth_mode: Option<String>,
    expires_at: Option<i64>,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    discover_official_or_browser(
        ProviderId::Grok,
        load_credentials(context).map(|credentials| ProviderSession {
            provider: ProviderId::Grok,
            credential_source: credentials.source,
        }),
        context,
    )
}

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    web::validate_browser_session(cookie_header, context)
}

pub fn collect(
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_official_or_browser(
        session,
        context,
        ProviderId::Grok,
        SOURCE,
        || collect_local(context),
        || web::collect(context),
    )
}

fn collect_local(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let mut credentials = load_credentials(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let mut refresh_succeeded = false;
    if credentials
        .expires_at
        .map(|expiry| expiry <= now_seconds(context) + 60)
        .unwrap_or(false)
        && let Some(refreshed) = refresh_and_reload(&credentials, context)
    {
        credentials = refreshed;
        refresh_succeeded = true;
    }
    match collect_with_credentials(&credentials, context) {
        Ok(snapshot) => Ok(snapshot),
        Err(error) if error.category == ErrorCategory::AuthRequired && !refresh_succeeded => {
            if let Some(refreshed) = refresh_and_reload(&credentials, context) {
                collect_with_credentials(&refreshed, context)
            } else {
                Err(error)
            }
        }
        Err(error) => Err(error),
    }
}

fn load_credentials(context: &CollectionContext) -> Option<Credentials> {
    let mut paths = Vec::new();
    if let Some(home) = context
        .env("GROK_HOME")
        .filter(|value| !value.trim().is_empty())
    {
        paths.push(PathBuf::from(home).join("auth.json"));
    }
    paths.push(context.home_directory.join(".grok/auth.json"));
    for path in paths {
        if let Some(credentials) = read_credentials(&path) {
            return Some(credentials);
        }
    }
    None
}

fn read_credentials(path: &Path) -> Option<Credentials> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let value: Value = serde_json::from_slice(&read_bounded_file(path, LOCAL_FILE_LIMIT)?).ok()?;
    parse_credentials(&value, &path.to_string_lossy())
}

fn parse_credentials(value: &Value, source: &str) -> Option<Credentials> {
    let object = value.as_object()?;
    let mut oidc = Vec::new();
    let mut legacy = Vec::new();
    for (scope, value) in object {
        let Some(entry) = value.as_object() else {
            continue;
        };
        if string(entry.get("key")).is_none() {
            continue;
        }
        if scope.starts_with(OIDC_PREFIX) {
            oidc.push((scope.as_str(), entry));
        } else if scope == LEGACY_SCOPE || scope.contains("/sign-in") {
            legacy.push((scope.as_str(), entry));
        }
    }
    let selected = newest(oidc).or_else(|| newest(legacy))?;
    let entry = selected.1;
    Some(Credentials {
        scope: selected.0.to_owned(),
        access_token: string(entry.get("key"))?,
        user_id: obj_get_any(&Value::Object(entry.clone()), &["user_id", "userId"])
            .and_then(|value| string(Some(value))),
        email: string(entry.get("email")),
        first_name: obj_get_any(&Value::Object(entry.clone()), &["first_name", "firstName"])
            .and_then(|value| string(Some(value))),
        last_name: obj_get_any(&Value::Object(entry.clone()), &["last_name", "lastName"])
            .and_then(|value| string(Some(value))),
        team_id: obj_get_any(&Value::Object(entry.clone()), &["team_id", "teamId"])
            .and_then(|value| string(Some(value))),
        auth_mode: obj_get_any(&Value::Object(entry.clone()), &["auth_mode", "authMode"])
            .and_then(|value| string(Some(value))),
        expires_at: obj_get_any(&Value::Object(entry.clone()), &["expires_at", "expiresAt"])
            .and_then(|value| parse_date(Some(value))),
        source: source.to_owned(),
    })
}

fn newest<'a>(
    entries: Vec<(&'a str, &'a serde_json::Map<String, Value>)>,
) -> Option<(&'a str, &'a serde_json::Map<String, Value>)> {
    entries.into_iter().reduce(|best, candidate| {
        let best_expiry = obj_get_any(&Value::Object(best.1.clone()), &["expires_at", "expiresAt"])
            .and_then(|value| parse_date(Some(value)));
        let candidate_expiry = obj_get_any(
            &Value::Object(candidate.1.clone()),
            &["expires_at", "expiresAt"],
        )
        .and_then(|value| parse_date(Some(value)));
        if candidate_expiry.is_some() && (best_expiry.is_none() || candidate_expiry > best_expiry) {
            candidate
        } else {
            best
        }
    })
}

fn refresh_and_reload(previous: &Credentials, context: &CollectionContext) -> Option<Credentials> {
    let executable = resolve_executable(context)?;
    let (path, backup) = snapshot_auth(context)?;
    let mut child = Command::new(executable)
        .args(["agent", "stdio"])
        .envs(&context.environment)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let Some(mut stdin) = child.stdin.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let auth_method = loop {
            let Some(value) = read_rpc_line(&mut reader) else {
                break None;
            };
            let method = value
                .get("result")
                .and_then(|value| value.get("authMethods"))
                .and_then(Value::as_array)
                .and_then(|methods| {
                    methods.iter().find_map(|method| {
                        (string(obj_get(method, "id")).as_deref() == Some("cached_token"))
                            .then(|| "cached_token".to_owned())
                    })
                });
            if method.is_some()
                || value
                    .get("result")
                    .and_then(|v| v.get("authMethods"))
                    .is_some()
            {
                break method;
            }
        };
        let _ = sender.send(auth_method);
    });
    let initialize = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "1",
            "clientCapabilities": {
                "fs": { "readTextFile": false, "writeTextFile": false },
                "terminal": false
            }
        }
    });
    let Some(initialize) = serde_json::to_string(&initialize).ok() else {
        let _ = child.kill();
        let _ = child.wait();
        restore_if_missing(&path, &backup);
        return None;
    };
    if stdin.write_all(initialize.as_bytes()).is_err() || stdin.write_all(b"\n").is_err() {
        let _ = child.kill();
        let _ = child.wait();
        restore_if_missing(&path, &backup);
        return None;
    }
    let started = std::time::Instant::now();
    let method_id = loop {
        if context.cancelled() || started.elapsed() >= Duration::from_secs(20) {
            let _ = child.kill();
            let _ = child.wait();
            restore_if_missing(&path, &backup);
            return None;
        }
        match receiver.recv_timeout(Duration::from_millis(100)) {
            Ok(method_id) => break method_id,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = child.kill();
                let _ = child.wait();
                restore_if_missing(&path, &backup);
                return None;
            }
        }
    };
    if let Some(method_id) = method_id {
        let authenticate = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "authenticate",
            "params": { "methodId": method_id, "_meta": { "headless": true } }
        });
        let Some(text) = serde_json::to_string(&authenticate).ok() else {
            let _ = child.kill();
            let _ = child.wait();
            restore_if_missing(&path, &backup);
            return None;
        };
        if stdin.write_all(text.as_bytes()).is_err() || stdin.write_all(b"\n").is_err() {
            let _ = child.kill();
            let _ = child.wait();
            restore_if_missing(&path, &backup);
            return None;
        }
    }
    drop(stdin);
    if !wait_child(&mut child, Duration::from_secs(20), context) {
        restore_if_missing(&path, &backup);
        return None;
    }
    if let Some(current) = read_credentials(&path) {
        if current.access_token != previous.access_token
            || current.expires_at != previous.expires_at
        {
            return Some(current);
        }
        return None;
    }
    restore_if_missing(&path, &backup);
    None
}

fn wait_child(
    child: &mut std::process::Child,
    timeout: Duration,
    context: &CollectionContext,
) -> bool {
    let started = std::time::Instant::now();
    loop {
        if context.cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            return false;
        }
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if started.elapsed() < timeout => thread::sleep(Duration::from_millis(25)),
            Ok(None) | Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

fn read_rpc_line(reader: &mut BufReader<impl std::io::Read>) -> Option<Value> {
    let mut line = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        line.clear();
        loop {
            let size = reader.read(&mut byte).ok()?;
            if size == 0 {
                if line.is_empty() {
                    return None;
                }
                break;
            }
            line.push(byte[0]);
            if line.len() > 1_048_576 {
                return None;
            }
            if byte[0] == b'\n' {
                break;
            }
        }
        if let Ok(value) = serde_json::from_slice(&line) {
            return Some(value);
        }
    }
}

fn snapshot_auth(context: &CollectionContext) -> Option<(PathBuf, Vec<u8>)> {
    let mut paths = Vec::new();
    if let Some(home) = context
        .env("GROK_HOME")
        .filter(|value| !value.trim().is_empty())
    {
        paths.push(PathBuf::from(home).join("auth.json"));
    }
    paths.push(context.home_directory.join(".grok/auth.json"));
    paths.into_iter().find_map(|path| {
        let bytes = read_bounded_file(&path, LOCAL_FILE_LIMIT)?;
        let value: Value = serde_json::from_slice(&bytes).ok()?;
        parse_credentials(&value, &path.to_string_lossy())?;
        Some((path, bytes))
    })
}

fn restore_if_missing(path: &Path, bytes: &[u8]) {
    if path.exists() {
        return;
    }
    #[cfg(unix)]
    let options = {
        use std::os::unix::fs::OpenOptionsExt;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true).mode(0o600);
        options
    };
    #[cfg(not(unix))]
    let mut options = {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        options
    };
    if let Ok(mut file) = options.open(path) {
        let _ = file.write_all(bytes);
        let _ = file.sync_all();
    }
}

fn resolve_executable(context: &CollectionContext) -> Option<String> {
    if let Some(path) = context
        .env("GROK_CLI_PATH")
        .filter(|value| !value.trim().is_empty())
    {
        return Some(path.to_owned());
    }
    let paths = [
        context.home_directory.join(".grok/bin/grok"),
        context.home_directory.join(".local/bin/grok"),
        PathBuf::from("/usr/local/bin/grok"),
        PathBuf::from("/opt/homebrew/bin/grok"),
    ];
    paths
        .into_iter()
        .find(|path| is_executable_file(path))
        .map(|path| path.to_string_lossy().into_owned())
        .or_else(|| Some("grok".to_owned()))
}

fn collect_with_credentials(
    credentials: &Credentials,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    let client = HttpClient::new()?;
    let bearer = format!("Bearer {}", credentials.access_token);
    let user_agent = context.user_agent();
    let mut headers = vec![
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("X-XAI-Token-Auth", "xai-grok-cli"),
        ("User-Agent", user_agent.as_str()),
    ];
    if let Some(user_id) = credentials.user_id.as_deref() {
        headers.push(("x-userid", user_id));
    }
    let (_, value) = client.get_json(BILLING_URL, &headers, SOURCE)?;
    let window = map_billing(&value)?;
    let namespace = if credentials.team_id.is_some() {
        "team_id"
    } else {
        "user_id"
    };
    let owner = credentials
        .team_id
        .as_deref()
        .or(credentials.user_id.as_deref());
    let (fingerprint, scope) = account_identity("grok", namespace, owner);
    let display_name = [
        credentials.first_name.as_deref(),
        credentials.last_name.as_deref(),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" ");
    Ok(QuotaSnapshot {
        provider: ProviderId::Grok,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: mask_email(credentials.email.as_deref())
                .or_else(|| mask_display_name(Some(&display_name))),
            plan: grok_plan(credentials),
        },
        windows: vec![window],
        source: SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn map_billing(value: &Value) -> Result<QuotaWindow, ProviderError> {
    let config =
        obj_get(value, "config").ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    let current = obj_get(config, "currentPeriod");
    let used = number(obj_get(config, "creditUsagePercent"))
        .or_else(|| {
            let limit = money(obj_get(config, "monthlyLimit"))?;
            let total = money(obj_get(config, "used"))?;
            (limit > 0.0).then_some(total / limit * 100.0)
        })
        .or_else(|| {
            current
                .or_else(|| obj_get(config, "billingPeriodEnd"))
                .map(|_| 0.0)
        })
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    let cycle = current.unwrap_or(config);
    let start = parse_date(obj_get_any(cycle, &["start", "billingPeriodStart"]));
    let end = parse_date(obj_get_any(cycle, &["end", "billingPeriodEnd"]));
    let title = match string(obj_get_any(
        current.unwrap_or(&Value::Null),
        &["type", "periodType", "period_type"],
    ))
    .map(|value| value.to_ascii_lowercase())
    {
        Some(value) if value.contains("weekly") => "Weekly",
        Some(value) if value.contains("monthly") => "Monthly",
        _ => "Billing cycle",
    };
    Ok(QuotaWindow {
        id: "billing_cycle".to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(used),
        resets_at: end.map(super::common::unix_seconds_to_iso),
        duration_seconds: duration_seconds(start, end),
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    })
}

fn money(value: Option<&Value>) -> Option<f64> {
    number(value).or_else(|| number(value.and_then(|value| obj_get(value, "val"))))
}

fn grok_plan(credentials: &Credentials) -> Option<String> {
    if credentials.scope.starts_with(OIDC_PREFIX) {
        return Some("supergrok".to_owned());
    }
    let mode = credentials
        .auth_mode
        .as_deref()?
        .trim()
        .to_ascii_lowercase();
    if mode.is_empty() {
        return None;
    }
    if matches!(
        mode.as_str(),
        "oidc" | "supergrok" | "super_grok" | "super-grok" | "super"
    ) {
        Some("supergrok".to_owned())
    } else if matches!(mode.as_str(), "session" | "legacy" | "cached_token") {
        None
    } else {
        Some(mode)
    }
}

fn now_seconds(context: &CollectionContext) -> i64 {
    context
        .now
        .as_deref()
        .and_then(|value| super::common::parse_date(Some(&Value::String(value.to_owned()))))
        .unwrap_or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_secs() as i64)
                .unwrap_or(0)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovers_browser_session_when_oauth_is_absent() {
        let mut context = CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-grok-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: None,
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
        };
        assert!(discover(&context).is_empty());
        context
            .browser_sessions
            .insert(ProviderId::Grok, "sso=session-value".to_owned());
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].credential_source, "browser_session");
    }

    #[test]
    fn maps_weekly_billing_cycle() {
        let value = serde_json::json!({"config": {"creditUsagePercent": 8, "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-07-30T07:33:06Z", "end": "2026-08-06T07:33:06Z"}}});
        let window = map_billing(&value).unwrap();
        assert_eq!(window.title, "Weekly");
        assert_eq!(window.used_percent, 8.0);
        assert_eq!(window.duration_seconds, Some(604800));
        assert_eq!(window.resets_at.as_deref(), Some("2026-08-06T07:33:06Z"));
    }

    #[test]
    fn maps_new_weekly_period_without_usage_percent() {
        let value = serde_json::json!({
            "config": {
                "currentPeriod": {
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "start": "2026-08-13T07:33:06.406166+00:00",
                    "end": "2026-08-20T07:33:06.406166+00:00"
                },
                "billingPeriodStart": "2026-08-13T07:33:06.406166+00:00",
                "billingPeriodEnd": "2026-08-20T07:33:06.406166+00:00"
            }
        });
        let window = map_billing(&value).unwrap();
        assert_eq!(window.title, "Weekly");
        assert_eq!(window.used_percent, 0.0);
        assert_eq!(window.resets_at.as_deref(), Some("2026-08-20T07:33:06Z"));
    }

    #[test]
    fn prefers_latest_oidc_credentials_and_falls_back_to_legacy() {
        let credentials = parse_credentials(
            &serde_json::json!({
                "https://auth.x.ai::old": {"key": "old", "expires_at": "2026-08-11T00:00:00Z"},
                "https://auth.x.ai::new": {"key": "new", "expires_at": "2026-08-12T00:00:00Z", "user_id": "user-new"},
                "https://accounts.x.ai/sign-in": {"key": "legacy", "user_id": "user-legacy"}
            }),
            "fixture",
        )
        .unwrap();
        assert_eq!(credentials.access_token, "new");
        assert_eq!(credentials.user_id.as_deref(), Some("user-new"));
        assert_eq!(grok_plan(&credentials).as_deref(), Some("supergrok"));

        let legacy = parse_credentials(
            &serde_json::json!({
                "https://auth.x.ai::empty": {"key": "  "},
                "https://accounts.x.ai/sign-in": {"key": "legacy", "auth_mode": "session"}
            }),
            "fixture",
        )
        .unwrap();
        assert_eq!(legacy.access_token, "legacy");
        assert!(grok_plan(&legacy).is_none());
    }

    #[test]
    fn maps_deprecated_money_objects_and_rejects_missing_usage() {
        let window = map_billing(&serde_json::json!({
            "config": {
                "monthlyLimit": {"val": 2000},
                "used": {"val": 500},
                "currentPeriod": {"periodType": "monthly", "billingPeriodStart": "2026-08-01T00:00:00Z", "billingPeriodEnd": "2026-09-01T00:00:00Z"}
            }
        })).unwrap();
        assert_eq!(window.used_percent, 25.0);
        assert_eq!(window.title, "Monthly");
        assert!(map_billing(&serde_json::json!({"config": {}})).is_err());
    }

    #[test]
    fn skips_non_json_cli_noise_before_rpc_response() {
        let mut reader = BufReader::new(std::io::Cursor::new(
            b"startup banner\n{\"jsonrpc\":\"2.0\",\"id\":1}\n".to_vec(),
        ));
        let value = read_rpc_line(&mut reader).unwrap();
        assert_eq!(value.get("id").and_then(Value::as_u64), Some(1));
    }
}
