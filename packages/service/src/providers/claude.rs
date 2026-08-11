use crate::catalog::ProviderId;
use serde_json::Value;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError, ProviderSession,
    QuotaAccount, QuotaSnapshot, QuotaWindow, account_identity, clamp_percent, is_executable_file,
    mask_email, number, obj_get, obj_get_any, parse_date, read_bounded_file, run_bounded_command,
    string,
};

pub const SOURCE: &str = "anthropic_oauth_usage_api";
pub const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const PROFILE_URL: &str = "https://api.anthropic.com/api/oauth/profile";
pub const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const AUTH_REFRESH_SKEW: i64 = 60;

#[derive(Clone, Debug)]
struct Credentials {
    access_token: String,
    expires_at: Option<i64>,
    scopes: Vec<String>,
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    load_credentials(context)
        .map(|credentials| {
            vec![ProviderSession {
                provider: ProviderId::Claude,
                credential_source: credentials.source,
            }]
        })
        .unwrap_or_default()
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let mut credentials = load_credentials(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    if !credentials
        .scopes
        .iter()
        .any(|scope| scope == "user:profile")
    {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    let refresh_attempted = credentials
        .expires_at
        .map(|expiry| expiry <= now_seconds(context) + AUTH_REFRESH_SKEW)
        .unwrap_or(false);
    if refresh_attempted {
        credentials = refresh_and_reload(&credentials, context).unwrap_or(credentials);
    }
    match collect_with_credentials(&credentials, context) {
        Ok(snapshot) => Ok(snapshot),
        Err(error) if error.category == ErrorCategory::AuthRequired && !refresh_attempted => {
            let refreshed =
                refresh_and_reload(&credentials, context).unwrap_or(credentials.clone());
            if refreshed.access_token != credentials.access_token
                || refreshed.expires_at != credentials.expires_at
            {
                collect_with_credentials(&refreshed, context)
            } else {
                Err(error)
            }
        }
        Err(error) => Err(error),
    }
}

fn load_credentials(context: &CollectionContext) -> Option<Credentials> {
    let root = context
        .env("CLAUDE_CONFIG_DIR")
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".claude"));
    let file = root.join(".credentials.json");
    let file_credentials = read_credentials_file(&file);
    if file_credentials
        .as_ref()
        .map(|credentials| !is_expiring(credentials, now_seconds(context)))
        .unwrap_or(false)
    {
        return file_credentials;
    }
    if cfg!(target_os = "macos")
        && let Some(credentials) = read_keychain(context)
    {
        return Some(credentials);
    }
    file_credentials
}

fn read_credentials_file(path: &Path) -> Option<Credentials> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let value: Value = serde_json::from_slice(&read_bounded_file(path, LOCAL_FILE_LIMIT)?).ok()?;
    parse_credentials(&value, &path.to_string_lossy())
}

fn read_keychain(context: &CollectionContext) -> Option<Credentials> {
    let mut command = Command::new("/usr/bin/security");
    command.args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]);
    let output = run_bounded_command(
        command,
        Duration::from_secs(10),
        context.cancel.as_ref(),
        1_048_576,
    )?;
    let value: Value = serde_json::from_slice(&output).ok()?;
    parse_credentials(&value, &format!("macOS Keychain: {KEYCHAIN_SERVICE}"))
}

fn parse_credentials(value: &Value, source: &str) -> Option<Credentials> {
    if value.get("claudeAiOauth").is_none() && value.get("mcpOAuth").is_some() {
        return None;
    }
    let oauth = value.get("claudeAiOauth")?.as_object()?;
    let access_token = obj_get_any(
        &Value::Object(oauth.clone()),
        &["accessToken", "access_token"],
    )
    .and_then(|v| string(Some(v)))?;
    let expires_at = obj_get_any(&Value::Object(oauth.clone()), &["expiresAt", "expires_at"])
        .and_then(|v| parse_date(Some(v)));
    let scopes = oauth
        .get("scopes")
        .and_then(Value::as_array)
        .map(|values| values.iter().filter_map(|v| string(Some(v))).collect())
        .unwrap_or_default();
    Some(Credentials {
        access_token,
        expires_at,
        scopes,
        subscription_type: obj_get_any(
            &Value::Object(oauth.clone()),
            &["subscriptionType", "subscription_type"],
        )
        .and_then(|v| string(Some(v))),
        rate_limit_tier: obj_get_any(
            &Value::Object(oauth.clone()),
            &["rateLimitTier", "rate_limit_tier"],
        )
        .and_then(|v| string(Some(v))),
        source: source.to_owned(),
    })
}

fn is_expiring(credentials: &Credentials, now: i64) -> bool {
    credentials
        .expires_at
        .map(|expiry| expiry <= now + AUTH_REFRESH_SKEW)
        .unwrap_or(false)
}

fn refresh_and_reload(
    credentials: &Credentials,
    context: &CollectionContext,
) -> Option<Credentials> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let executable = resolve_executable(context)?;
    let script = Path::new("/usr/bin/script");
    if !fs::metadata(script)
        .map(|metadata| metadata.is_file())
        .unwrap_or(false)
    {
        return None;
    }
    let probe_dir = std::env::temp_dir().join(format!(
        "quota-claude-probe-{}-{}",
        std::process::id(),
        Uuid::new_v4()
    ));
    fs::create_dir_all(probe_dir.join(".claude")).ok()?;
    let settings = probe_dir.join(".claude/settings.local.json");
    fs::write(
        &settings,
        b"{\"disableDeepLinkRegistration\":\"disable\"}\n",
    )
    .ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&probe_dir, fs::Permissions::from_mode(0o700)).ok()?;
        fs::set_permissions(&settings, fs::Permissions::from_mode(0o600)).ok()?;
    }
    let session_id = Uuid::new_v4().to_string();
    let _cleanup = ProbeCleanup::new(context, &probe_dir, &session_id);
    // macOS `script` allocates the PTY that Claude's interactive slash
    // commands require, while still letting us invoke the executable without
    // a shell. The probe is read-only and exits immediately after /status.
    let mut command = Command::new(script);
    command
        .args([
            "-q",
            "/dev/null",
            &executable,
            "--allowed-tools",
            "",
            "--session-id",
            &session_id,
        ])
        .current_dir(&probe_dir)
        .env("HOME", &context.home_directory)
        .env("DISABLE_AUTOUPDATER", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for (key, value) in &context.environment {
        if key != "HOME" && !key.starts_with("ANTHROPIC_") {
            command.env(key, value);
        }
    }
    command.env("HOME", &context.home_directory);
    let mut child = command.spawn().ok()?;
    let Some(mut stdin) = child.stdin.take() else {
        stop_child(&mut child);
        let _ = fs::remove_dir_all(&probe_dir);
        return None;
    };
    let Some(stdout) = child.stdout.take() else {
        stop_child(&mut child);
        let _ = fs::remove_dir_all(&probe_dir);
        return None;
    };
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut output = Vec::new();
        let result = stdout
            .take(1_048_577)
            .read_to_end(&mut output)
            .map(|_| output);
        let _ = sender.send(result.ok());
    });
    if stdin.write_all(b"/status\n/exit\n").is_err() {
        stop_child(&mut child);
        let _ = fs::remove_dir_all(&probe_dir);
        return None;
    }
    drop(stdin);
    let started = std::time::Instant::now();
    let mut output = None;
    let status = loop {
        if context.cancelled() {
            stop_child(&mut child);
            let _ = fs::remove_dir_all(&probe_dir);
            return None;
        }
        if output.is_none() {
            match receiver.try_recv() {
                Ok(Some(bytes)) => {
                    if bytes.len() > 1_048_576 {
                        stop_child(&mut child);
                        let _ = fs::remove_dir_all(&probe_dir);
                        return None;
                    }
                    output = Some(bytes);
                }
                Ok(None) | Err(mpsc::TryRecvError::Disconnected) => {
                    stop_child(&mut child);
                    let _ = fs::remove_dir_all(&probe_dir);
                    return None;
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < Duration::from_secs(60) => {
                thread::sleep(Duration::from_millis(25));
            }
            Ok(None) | Err(_) => {
                stop_child(&mut child);
                let _ = fs::remove_dir_all(&probe_dir);
                return None;
            }
        }
    };
    if !status.success() {
        let _ = receiver.recv_timeout(Duration::from_secs(1));
        let _ = fs::remove_dir_all(&probe_dir);
        return None;
    }
    let _ = output.or_else(|| receiver.recv_timeout(Duration::from_secs(1)).ok().flatten())?;
    let _ = fs::remove_dir_all(&probe_dir);
    let reloaded = load_credentials(context)?;
    ((reloaded.access_token != credentials.access_token)
        || (reloaded.expires_at != credentials.expires_at))
        .then_some(reloaded)
}

fn stop_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

struct ProbeCleanup {
    probe_dir: PathBuf,
    transcript: PathBuf,
}

impl ProbeCleanup {
    fn new(context: &CollectionContext, probe_dir: &Path, session_id: &str) -> Self {
        let config_root = context
            .env("CLAUDE_CONFIG_DIR")
            .and_then(|value| value.split(',').next())
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| context.home_directory.join(".claude"));
        let project = probe_dir
            .to_string_lossy()
            .chars()
            .map(|value| {
                if value.is_ascii_alphanumeric() {
                    value
                } else {
                    '-'
                }
            })
            .take(200)
            .collect::<String>();
        Self {
            probe_dir: probe_dir.to_owned(),
            transcript: config_root
                .join("projects")
                .join(project)
                .join(format!("{session_id}.jsonl")),
        }
    }
}

impl Drop for ProbeCleanup {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.transcript);
        let _ = fs::remove_dir_all(&self.probe_dir);
    }
}

fn resolve_executable(context: &CollectionContext) -> Option<String> {
    if let Some(path) = context
        .env("CLAUDE_CLI_PATH")
        .filter(|v| !v.trim().is_empty())
    {
        return Some(path.to_owned());
    }
    let paths = [
        context.home_directory.join(".local/bin/claude"),
        context.home_directory.join(".claude/local/claude"),
        context.home_directory.join(".claude/bin/claude"),
        PathBuf::from("/opt/homebrew/bin/claude"),
        PathBuf::from("/usr/local/bin/claude"),
        PathBuf::from("/Applications/cmux.app/Contents/Resources/bin/claude"),
    ];
    paths
        .into_iter()
        .find(|path| is_executable_file(path))
        .map(|path| path.to_string_lossy().into_owned())
        .or_else(|| Some("claude".to_owned()))
}

fn collect_with_credentials(
    credentials: &Credentials,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if !credentials
        .scopes
        .iter()
        .any(|scope| scope == "user:profile")
    {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    let client = HttpClient::new()?;
    let bearer = format!("Bearer {}", credentials.access_token);
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("anthropic-beta", "oauth-2025-04-20"),
        ("User-Agent", "claude-code/2.1.0"),
    ];
    let usage = match client.get_json(USAGE_URL, &headers, SOURCE) {
        Ok((_, value)) => value,
        Err(error) => return Err(error),
    };
    let windows = map_usage(&usage);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let (email, organization_id) = {
        let profile_headers = [
            ("Authorization", bearer.as_str()),
            ("Accept", "application/json"),
        ];
        match client.get_json(PROFILE_URL, &profile_headers, SOURCE) {
            Ok((_, value)) => map_profile(&value),
            Err(_) => (None, None),
        }
    };
    let plan = credentials
        .subscription_type
        .clone()
        .or_else(|| credentials.rate_limit_tier.clone());
    let (fingerprint, scope) =
        account_identity("claude", "organization_id", organization_id.as_deref());
    Ok(QuotaSnapshot {
        provider: ProviderId::Claude,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: mask_email(email.as_deref()),
            plan,
        },
        windows,
        source: SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn map_usage(value: &Value) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    for (value, id, title, duration) in [
        (
            obj_get(value, "five_hour"),
            "five_hour",
            "5 hour",
            18_000_u64,
        ),
        (
            obj_get(value, "seven_day"),
            "seven_day",
            "Weekly",
            604_800_u64,
        ),
        (
            obj_get(value, "seven_day_sonnet"),
            "seven_day_sonnet",
            "Sonnet weekly",
            604_800,
        ),
        (
            obj_get(value, "seven_day_opus"),
            "seven_day_opus",
            "Opus weekly",
            604_800,
        ),
        (
            obj_get(value, "seven_day_oauth_apps"),
            "seven_day_oauth_apps",
            "OAuth apps weekly",
            604_800,
        ),
    ] {
        if let Some(window) = usage_window(value, id, title, duration) {
            windows.push(window);
        }
    }
    if let Some(limits) = obj_get(value, "limits").and_then(Value::as_array) {
        let mut seen = std::collections::HashSet::new();
        for entry in limits {
            if string(obj_get(entry, "kind")).as_deref() != Some("weekly_scoped")
                || string(obj_get(entry, "group")).as_deref() != Some("weekly")
            {
                continue;
            }
            let Some(percent) = number(obj_get(entry, "percent")) else {
                continue;
            };
            let model = obj_get(entry, "scope").and_then(|v| obj_get(v, "model"));
            let Some(model_name) = obj_get_any(
                model.unwrap_or(&Value::Null),
                &["display_name", "displayName"],
            )
            .and_then(|v| string(Some(v))) else {
                continue;
            };
            let model_id =
                obj_get(model.unwrap_or(&Value::Null), "id").and_then(|v| string(Some(v)));
            if is_all_models(model_id.as_deref(), &model_name) {
                continue;
            }
            let identity = model_id.as_deref().unwrap_or(&model_name);
            let id = format!("claude-weekly-scoped-{}", slug(identity));
            if !seen.insert(id.clone()) {
                continue;
            }
            windows.push(QuotaWindow {
                id,
                title: format!("{model_name} only"),
                used_percent: clamp_percent(percent),
                resets_at: obj_get_any(entry, &["resets_at", "resetsAt"])
                    .and_then(|v| parse_date(Some(v)))
                    .map(super::common::unix_seconds_to_iso),
                duration_seconds: Some(604_800),
                remaining_value: None,
                limit_value: None,
                value_unit: None,
            });
        }
    }
    let routines = [
        "seven_day_routines",
        "seven_day_claude_routines",
        "claude_routines",
        "routines",
        "routine",
        "seven_day_cowork",
        "cowork",
    ]
    .iter()
    .find_map(|key| obj_get(value, key));
    if let Some(window) = usage_window(routines, "claude-routines", "Daily Routines", 604_800) {
        windows.push(window);
    }
    let extra = obj_get(value, "extra_usage").or_else(|| obj_get(value, "extraUsage"));
    if let Some(utilization) = extra.and_then(|v| number(obj_get(v, "utilization"))) {
        windows.push(QuotaWindow {
            id: "extra_usage".to_owned(),
            title: "Extra usage".to_owned(),
            used_percent: clamp_percent(utilization),
            resets_at: None,
            duration_seconds: None,
            remaining_value: None,
            limit_value: None,
            value_unit: None,
        });
    }
    windows
}

fn usage_window(
    value: Option<&Value>,
    id: &str,
    title: &str,
    duration: u64,
) -> Option<QuotaWindow> {
    let value = value?;
    let utilization = number(obj_get(value, "utilization"))?;
    Some(QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(utilization),
        resets_at: obj_get_any(value, &["resets_at", "resetsAt"])
            .and_then(|v| parse_date(Some(v)))
            .map(super::common::unix_seconds_to_iso),
        duration_seconds: Some(duration),
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    })
}

fn map_profile(value: &Value) -> (Option<String>, Option<String>) {
    let account = obj_get(value, "account");
    let organization = obj_get(value, "organization");
    (
        obj_get_any(
            account.unwrap_or(&Value::Null),
            &["emailAddress", "email_address", "email"],
        )
        .and_then(|v| string(Some(v)))
        .or_else(|| {
            obj_get_any(value, &["emailAddress", "email_address", "email"])
                .and_then(|v| string(Some(v)))
        }),
        obj_get(organization.unwrap_or(&Value::Null), "uuid")
            .and_then(|v| string(Some(v)))
            .or_else(|| {
                obj_get_any(value, &["organizationUuid", "organization_uuid"])
                    .and_then(|v| string(Some(v)))
            }),
    )
}

fn is_all_models(model_id: Option<&str>, model_name: &str) -> bool {
    if slug(model_name) == "all-models" {
        return true;
    }
    model_id
        .map(|id| {
            let id = slug(id);
            id == "all-models" || id.ends_with("-all-models")
        })
        .unwrap_or(false)
}

fn slug(value: &str) -> String {
    let mut output = String::new();
    for character in value.to_ascii_lowercase().chars() {
        if character.is_ascii_alphanumeric() {
            output.push(character);
        } else if !output.ends_with('-') {
            output.push('-');
        }
    }
    output.trim_matches('-').to_owned()
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
    fn maps_optional_usage_windows_and_extra_usage() {
        let windows = map_usage(&serde_json::json!({
            "five_hour": null,
            "seven_day": {"utilization": 41.5, "resets_at": "2026-08-09T12:00:00Z"},
            "extra_usage": {"utilization": 12.5}
        }));
        assert!(windows.iter().any(|window| window.id == "seven_day"));
        assert!(windows.iter().any(|window| window.id == "extra_usage"));
    }

    #[test]
    fn parses_oauth_credentials_and_rejects_mcp_only_payloads() {
        let credentials = parse_credentials(
            &serde_json::json!({
                "claudeAiOauth": {
                    "accessToken": "claude-access",
                    "refreshToken": "claude-refresh",
                    "expiresAt": "2026-08-11T00:00:00Z",
                    "scopes": ["user:profile"],
                    "subscriptionType": "pro",
                    "rateLimitTier": "max"
                }
            }),
            "fixture",
        )
        .unwrap();
        assert_eq!(credentials.access_token, "claude-access");
        assert_eq!(credentials.expires_at, Some(1786406400));
        assert_eq!(credentials.scopes, ["user:profile"]);
        assert_eq!(credentials.subscription_type.as_deref(), Some("pro"));
        assert!(
            parse_credentials(
                &serde_json::json!({
                    "mcpOAuth": {"token": "mcp-only"}
                }),
                "fixture"
            )
            .is_none()
        );
        assert!(
            parse_credentials(
                &serde_json::json!({
                    "claudeAiOauth": {"scopes": ["user:profile"]}
                }),
                "fixture"
            )
            .is_none()
        );
    }

    #[test]
    fn keeps_scoped_model_limits_and_drops_all_models_scope() {
        let windows = map_usage(&serde_json::json!({
            "limits": [
                {"kind": "weekly_scoped", "group": "weekly", "percent": 17,
                 "scope": {"model": {"id": "claude-sonnet-4", "display_name": "Claude Sonnet"}},
                 "resets_at": "2026-08-12T00:00:00Z"},
                {"kind": "weekly_scoped", "group": "weekly", "percent": 90,
                 "scope": {"model": {"id": "all-models", "display_name": "All models"}}}
            ]
        }));
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "claude-weekly-scoped-claude-sonnet-4");
        assert_eq!(windows[0].used_percent, 17.0);
    }
}
