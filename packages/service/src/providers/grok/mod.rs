use crate::catalog::ProviderId;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError, ProviderSession,
    QuotaAccount, QuotaSnapshot, QuotaWindow, account_identity, clamp_percent, duration_seconds,
    mask_display_name, mask_email, number, obj_get, obj_get_any, parse_date, read_bounded_file,
    slug, string,
};

mod billing_rpc;

pub const SOURCE: &str = "grok_billing_api";
pub const BILLING_RPC_SOURCE: &str = billing_rpc::SOURCE;
pub const BILLING_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
pub const SETTINGS_URL: &str = "https://cli-chat-proxy.grok.com/v1/settings";
const SETTINGS_TIMEOUT: Duration = Duration::from_secs(2);
const PLAN_SLUG_LIMIT: usize = 64;
const OIDC_PREFIX: &str = "https://auth.x.ai::";
const AUTH_REFRESH_SKEW: i64 = 60;
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
    load_credentials(context)
        .map(|credentials| ProviderSession {
            provider: ProviderId::Grok,
            credential_source: credentials.source,
        })
        .into_iter()
        .collect()
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    collect_local(context)
}

fn collect_local(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let credentials = load_credentials(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    // The Grok CLI owns token renewal, and this build no longer starts it to trigger one.
    // A grant that is out of time is a sign-in only that CLI can renew.
    if credentials
        .expires_at
        .map(|expiry| expiry <= context.observed_unix() + AUTH_REFRESH_SKEW)
        .unwrap_or(false)
    {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    collect_with_credentials(&credentials, context)
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

fn collect_with_credentials(
    credentials: &Credentials,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    let bearer = format!("Bearer {}", credentials.access_token);
    let user_agent = context.user_agent();
    let headers = proxy_headers(credentials, &bearer, &user_agent);
    let proxy = fetch_proxy_billing(&headers);
    let proxy_reachable = proxy.is_ok();
    let window = match proxy {
        Ok(window) => window,
        // Rejected or malformed proxy answers are final. When the proxy is merely
        // unreachable, grok.com's own billing RPC accepts the same OAuth token.
        Err(error) if error.category != ErrorCategory::Unavailable => return Err(error),
        Err(proxy_error) => billing_rpc::bearer_billing_window(&credentials.access_token, context)
            .map_err(|_| proxy_error)?,
    };
    // The tier lives behind the same host as billing, so an unreachable proxy
    // would only spend the refresh's remaining budget re-learning that.
    let plan = proxy_reachable
        .then(|| fetch_settings_plan(&headers, context))
        .flatten()
        .or_else(|| grok_plan(credentials));
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
            plan,
        },
        windows: vec![window],
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn proxy_headers<'a>(
    credentials: &'a Credentials,
    bearer: &'a str,
    user_agent: &'a str,
) -> Vec<(&'a str, &'a str)> {
    let mut headers = vec![
        ("Authorization", bearer),
        ("Accept", "application/json"),
        ("X-XAI-Token-Auth", "xai-grok-cli"),
        ("User-Agent", user_agent),
    ];
    if let Some(user_id) = credentials.user_id.as_deref() {
        headers.push(("x-userid", user_id));
    }
    headers
}

fn fetch_proxy_billing(headers: &[(&str, &str)]) -> Result<QuotaWindow, ProviderError> {
    let client = HttpClient::new()?;
    let (_, value) = client.get_json(BILLING_URL, headers, SOURCE)?;
    map_billing(&value)
}

/// Billing does not name the tier; the CLI settings envelope does
/// (`subscription_tier_display`, e.g. "SuperGrok Heavy"). Best-effort and bounded:
/// a missing or slow answer leaves the credential-derived plan hint in place.
fn fetch_settings_plan(headers: &[(&str, &str)], context: &CollectionContext) -> Option<String> {
    if context.cancelled() {
        return None;
    }
    let client = HttpClient::with_timeout(SETTINGS_TIMEOUT).ok()?;
    let (_, value) = client.get_json(SETTINGS_URL, headers, SOURCE).ok()?;
    plan_slug(string(obj_get(&value, "subscription_tier_display")).as_deref())
}

/// Normalizes a display tier into the catalog's plan slug shape
/// ("SuperGrok Heavy" → "supergrok_heavy").
fn plan_slug(display: Option<&str>) -> Option<String> {
    let slug = slug(display?, '_');
    (!slug.is_empty() && slug.len() <= PLAN_SLUG_LIMIT).then_some(slug)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// The Grok CLI owns this token, so a Mac without one has nothing for this collector to
    /// try. There is no second rung to fall to.
    fn no_local_grant_discovers_nothing() {
        let context = CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-grok-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: None,
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
        };
        assert!(discover(&context).is_empty());
        assert!(ProviderId::Grok.metadata().browser_session.is_none());
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
    fn settings_tier_display_becomes_a_plan_slug() {
        assert_eq!(
            plan_slug(Some("SuperGrok Heavy")).as_deref(),
            Some("supergrok_heavy")
        );
        assert_eq!(plan_slug(Some("SuperGrok")).as_deref(), Some("supergrok"));
        assert_eq!(
            plan_slug(Some("  Pro - Lite  ")).as_deref(),
            Some("pro_lite")
        );
        assert!(plan_slug(Some("   ")).is_none());
        assert!(plan_slug(Some("---")).is_none());
        assert!(plan_slug(None).is_none());
        assert!(plan_slug(Some(&"x".repeat(65))).is_none());
    }
}
