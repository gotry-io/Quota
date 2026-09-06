use crate::catalog::ProviderId;
use serde_json::Value;
use std::path::{Path, PathBuf};

use super::common::{
    Cadence, CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, account_identity, clamp_percent,
    number, obj_get, obj_get_any, parse_date, plan_slug, read_bounded_file, string,
    unix_seconds_to_iso,
};

pub const SOURCE: &str = "github_copilot_user_api";
const USER_URL: &str = "https://api.github.com/copilot_internal/user";

#[derive(Clone, Debug)]
struct Token {
    value: String,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    first_token(context)
        .map(|token| {
            vec![ProviderSession {
                provider: ProviderId::Copilot,
                credential_source: token.source,
                cookie_header: None,
            }]
        })
        .unwrap_or_default()
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_at(context, USER_URL)
}

fn collect_at(context: &CollectionContext, url: &str) -> Result<QuotaSnapshot, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let tokens = discover_tokens(context);
    if tokens.is_empty() {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    let client = HttpClient::new()?;
    let mut last_auth = ProviderError::new(ErrorCategory::AuthRequired, SOURCE);
    for token in tokens {
        match fetch_user(&client, context, url, &token.value) {
            Ok(value) => return map_snapshot(context, &value),
            Err(error) if error.category == ErrorCategory::AuthRequired => last_auth = error,
            Err(error) => return Err(error),
        }
    }
    Err(last_auth)
}

fn first_token(context: &CollectionContext) -> Option<Token> {
    discover_tokens(context).into_iter().next()
}

fn discover_tokens(context: &CollectionContext) -> Vec<Token> {
    let mut tokens = Vec::new();
    for key in ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] {
        if let Some(value) = context
            .env(key)
            .map(str::trim)
            .filter(|value| looks_like_github_token(value))
            .map(str::to_owned)
        {
            tokens.push(Token {
                value,
                source: key.to_owned(),
            });
        }
    }
    let config = xdg_config(context).join("github-copilot");
    for name in ["apps.json", "hosts.json"] {
        let path = config.join(name);
        tokens.extend(tokens_from_file(&path));
    }
    tokens
}

fn xdg_config(context: &CollectionContext) -> PathBuf {
    context
        .env("XDG_CONFIG_HOME")
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".config"))
}

fn tokens_from_file(path: &Path) -> Vec<Token> {
    let Some(bytes) = read_bounded_file(path, LOCAL_FILE_LIMIT) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return Vec::new();
    };
    let source = path.to_string_lossy().into_owned();
    let mut preferred = Vec::new();
    let mut rest = Vec::new();
    collect_tokens(&value, &source, &mut preferred, &mut rest, false);
    preferred.append(&mut rest);
    preferred
}

fn collect_tokens(
    value: &Value,
    source: &str,
    preferred: &mut Vec<Token>,
    rest: &mut Vec<Token>,
    under_github: bool,
) {
    match value {
        Value::Object(object) => {
            if let Some(token) = object
                .get("oauth_token")
                .or_else(|| object.get("oauthToken"))
                .or_else(|| object.get("token"))
                .or_else(|| object.get("access_token"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| looks_like_github_token(value))
            {
                let entry = Token {
                    value: token.to_owned(),
                    source: source.to_owned(),
                };
                if under_github {
                    preferred.push(entry);
                } else {
                    rest.push(entry);
                }
            }
            for (key, child) in object {
                let github = under_github || key.contains("github.com");
                collect_tokens(child, source, preferred, rest, github);
            }
        }
        Value::Array(entries) => {
            for entry in entries {
                collect_tokens(entry, source, preferred, rest, under_github);
            }
        }
        _ => {}
    }
}

fn looks_like_github_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 8_192
        && !value.chars().any(char::is_control)
        && (value.starts_with("gho_")
            || value.starts_with("ghu_")
            || value.starts_with("github_pat_"))
}

fn fetch_user(
    client: &HttpClient,
    context: &CollectionContext,
    url: &str,
    token: &str,
) -> Result<Value, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let auth = format!("Bearer {token}");
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", auth.as_str()),
        ("Accept", "application/vnd.github+json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, value) = client.get_json(url, &headers, SOURCE)?;
    Ok(value)
}

fn map_snapshot(
    context: &CollectionContext,
    value: &Value,
) -> Result<QuotaSnapshot, ProviderError> {
    let windows = map_windows(value);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let login = string(obj_get_any(value, &["login", "name"]));
    let (fingerprint, scope) = account_identity("copilot", "login", login.as_deref());
    Ok(QuotaSnapshot {
        provider: ProviderId::Copilot,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: login,
            plan: plan_slug(
                string(obj_get_any(value, &["copilot_plan", "copilotPlan", "sku"])).as_deref(),
            ),
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn parse_reset(value: &Value) -> Option<String> {
    if let Some(seconds) = parse_date(Some(value)) {
        return Some(unix_seconds_to_iso(seconds));
    }
    let text = string(Some(value))?;
    if text.len() == 10
        && text.as_bytes().get(4) == Some(&b'-')
        && text.as_bytes().get(7) == Some(&b'-')
    {
        parse_date(Some(&Value::String(format!("{text}T00:00:00Z")))).map(unix_seconds_to_iso)
    } else {
        None
    }
}

fn map_windows(value: &Value) -> Vec<QuotaWindow> {
    let reset = obj_get_any(value, &["quota_reset_date", "quotaResetDate"]).and_then(parse_reset);
    if let Some(snapshots) = obj_get_any(value, &["quota_snapshots", "quotaSnapshots"]) {
        let mut windows = Vec::new();
        if let Some(window) = snapshot_window(
            obj_get(snapshots, "premium_interactions")
                .or_else(|| obj_get(snapshots, "premiumInteractions")),
            "premium_requests",
            "Premium Requests",
            true,
            reset.as_deref(),
        ) {
            windows.push(window);
        }
        for (key, id, title) in [
            ("chat", "chat", "Chat"),
            ("completions", "completions", "Completions"),
        ] {
            if let Some(window) =
                snapshot_window(obj_get(snapshots, key), id, title, false, reset.as_deref())
            {
                windows.push(window);
            }
        }
        if !windows.is_empty() {
            return windows;
        }
    }
    limited_user_windows(value, reset.as_deref())
}

fn snapshot_window(
    value: Option<&Value>,
    id: &str,
    title: &str,
    primary: bool,
    fallback_reset: Option<&str>,
) -> Option<QuotaWindow> {
    let value = value?;
    let unlimited = value
        .get("unlimited")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let remaining = number(obj_get_any(
        value,
        &["remaining", "quota_remaining", "quotaRemaining"],
    ));
    let entitlement = number(obj_get_any(value, &["entitlement", "entitlement_requests"]));
    let percent_remaining = number(obj_get_any(
        value,
        &["percent_remaining", "percentRemaining"],
    ));
    if unlimited {
        return Some(QuotaWindow {
            id: id.to_owned(),
            title: title.to_owned(),
            used_percent: 0.0,
            resets_at: obj_get_any(value, &["reset_date", "resetDate", "quota_reset_at"])
                .and_then(parse_reset)
                .or_else(|| fallback_reset.map(str::to_owned)),
            duration_seconds: None,
            primary_cadence: primary.then_some(Cadence::Monthly),
            remaining_value: remaining.filter(|value| *value >= 0.0),
            limit_value: None,
            value_unit: Some("count"),
        });
    }
    let remaining = remaining?;
    let limit = entitlement.filter(|value| *value > 0.0).unwrap_or_else(|| {
        percent_remaining
            .filter(|percent| *percent > 0.0)
            .map(|percent| remaining / (percent / 100.0))
            .unwrap_or(remaining)
    });
    let used_percent = percent_remaining
        .map(|percent| clamp_percent(100.0 - percent))
        .unwrap_or_else(|| {
            if limit > 0.0 {
                clamp_percent((limit - remaining).max(0.0) / limit * 100.0)
            } else if remaining > 0.0 {
                0.0
            } else {
                100.0
            }
        });
    Some(QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent,
        resets_at: obj_get_any(value, &["reset_date", "resetDate", "quota_reset_at"])
            .and_then(|value| parse_date(Some(value)).map(unix_seconds_to_iso))
            .or_else(|| fallback_reset.map(str::to_owned)),
        duration_seconds: None,
        primary_cadence: primary.then_some(Cadence::Monthly),
        remaining_value: Some(remaining.max(0.0)),
        limit_value: (limit > 0.0).then_some(limit),
        value_unit: Some("count"),
    })
}

fn limited_user_windows(value: &Value, reset: Option<&str>) -> Vec<QuotaWindow> {
    let Some(quotas) = obj_get_any(value, &["limited_user_quotas", "limitedUserQuotas"]) else {
        return Vec::new();
    };
    [
        (
            "premium_interactions",
            "premium_requests",
            "Premium Requests",
            true,
        ),
        ("chat", "chat", "Chat", false),
        ("completions", "completions", "Completions", false),
    ]
    .into_iter()
    .filter_map(|(key, id, title, primary)| {
        let remaining = number(obj_get(quotas, key))?;
        Some(QuotaWindow {
            id: id.to_owned(),
            title: title.to_owned(),
            used_percent: if remaining > 0.0 { 0.0 } else { 100.0 },
            resets_at: reset.map(str::to_owned),
            duration_seconds: None,
            primary_cadence: primary.then_some(Cadence::Monthly),
            remaining_value: Some(remaining.max(0.0)),
            limit_value: None,
            value_unit: Some("count"),
        })
    })
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: std::path::PathBuf::from("/tmp/quota-copilot-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: Some(std::path::PathBuf::from(
                "/tmp/quota-copilot-missing-config/providers.json",
            )),
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        }
    }

    const USER: &str = r#"{
        "login": "octocat",
        "copilot_plan": "pro",
        "quota_reset_date": "2026-09-01",
        "quota_snapshots": {
            "premium_interactions": {
                "entitlement": 300,
                "remaining": 180,
                "percent_remaining": 60.0,
                "unlimited": false
            },
            "chat": { "entitlement": -1, "remaining": 0, "unlimited": true },
            "completions": { "entitlement": 2000, "remaining": 1500, "percent_remaining": 75.0, "unlimited": false }
        }
    }"#;

    #[test]
    fn maps_monthly_premium_requests_as_the_headline() {
        let windows = map_windows(&serde_json::from_str(USER).unwrap());
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["premium_requests", "chat", "completions"]
        );
        assert_eq!(windows[0].title, "Premium Requests");
        assert_eq!(windows[0].primary_cadence, Some(Cadence::Monthly));
        assert_eq!(windows[0].remaining_value, Some(180.0));
        assert_eq!(windows[0].limit_value, Some(300.0));
        assert_eq!(windows[0].used_percent, 40.0);
        assert_eq!(
            windows[0].resets_at.as_deref(),
            Some("2026-09-01T00:00:00Z")
        );
        assert_eq!(windows[1].limit_value, None);
        assert_eq!(windows[1].used_percent, 0.0);
        assert_eq!(windows[2].remaining_value, Some(1500.0));
    }

    #[test]
    fn reads_apps_json_github_com_token_first() {
        let root = std::env::temp_dir().join(format!(
            "quota-copilot-apps-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("time")
                .as_nanos()
        ));
        let dir = root.join(".config").join("github-copilot");
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(
            dir.join("apps.json"),
            r#"{"other.example":{"oauth_token":"gho_other"},"github.com":{"user":"octocat","oauth_token":"gho_github"}}"#,
        )
        .expect("apps");
        let mut context = isolated_context();
        context.home_directory = root.clone();
        let tokens = discover_tokens(&context);
        assert_eq!(tokens[0].value, "gho_github");
        assert_eq!(tokens[1].value, "gho_other");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn collect_sends_bearer_token_and_maps_plan() {
        let (address, server) =
            crate::providers::common::serve_responses(vec![(200, USER.as_bytes().to_vec())]);
        let mut context = isolated_context();
        context
            .environment
            .insert("COPILOT_GITHUB_TOKEN".into(), "gho_from_env".into());
        let snapshot = collect_at(&context, &format!("http://{address}/copilot_internal/user"))
            .expect("snapshot");
        assert_eq!(snapshot.account.label.as_deref(), Some("octocat"));
        assert_eq!(snapshot.account.plan.as_deref(), Some("pro"));
        assert_eq!(snapshot.windows[0].id, "premium_requests");
        let head = server.join().expect("server").remove(0);
        assert!(head.contains("authorization: bearer gho_from_env"));
        assert!(head.contains("application/vnd.github+json"));
    }

    #[test]
    fn missing_token_is_auth_required() {
        let error = collect(
            &ProviderSession {
                provider: ProviderId::Copilot,
                credential_source: "missing".into(),
                cookie_header: None,
            },
            &isolated_context(),
        )
        .expect_err("missing");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        assert_eq!(error.source_id, SOURCE);
    }
}
