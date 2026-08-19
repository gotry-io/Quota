use crate::catalog::ProviderId;
use serde_json::Value;

use super::common::{
    ApiKeyCredentials, CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, VALIDATION_TIMEOUT,
    ValidatedBrowserSession, account_identity, api_key_identity, clamp_percent,
    collect_official_or_browser, cookie_named_value, discover_official_or_browser, number, obj_get,
    obj_get_any, parse_date, resolve_api_key, string,
};

pub const SOURCE: &str = "kimi_code_usages_api";
pub const WEB_SOURCE: &str = "kimi_web_billing_api";
const WEB_USAGES_URL: &str =
    "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages";

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    discover_official_or_browser(
        ProviderId::Kimi,
        resolve(context).ok().map(|credentials| ProviderSession {
            provider: ProviderId::Kimi,
            credential_source: credentials.source,
        }),
        context,
    )
}

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    let token = kimi_auth_token(cookie_header)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let data = fetch_web_usages(&token, context, WEB_USAGES_URL, VALIDATION_TIMEOUT)?;
    if map_web_usages(&data).is_none() {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let (account_fingerprint, _) = account_identity("kimi", "api_key", None);
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: Some("Kimi".to_owned()),
    })
}

pub fn collect(
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_official_or_browser(
        session,
        context,
        ProviderId::Kimi,
        SOURCE,
        || collect_api(context),
        || collect_web(context),
    )
}

fn collect_api(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let credentials = resolve(context)?;
    let client = HttpClient::new()?;
    let url = format!("{}/coding/v1/usages", credentials.base_url);
    let auth = format!("Bearer {}", credentials.api_key);
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", auth.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, value) = client.get_json(&url, &headers, SOURCE)?;
    let data =
        map_usages(&value).ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    let windows = map_windows(&data);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let (fingerprint, scope) = api_key_identity("kimi", &credentials.api_key);
    Ok(QuotaSnapshot {
        provider: ProviderId::Kimi,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some(credentials.label),
            plan: None,
        },
        windows,
        source: SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn resolve(context: &CollectionContext) -> Result<ApiKeyCredentials, ProviderError> {
    resolve_api_key(context, ProviderId::Kimi)
}

fn collect_web(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let cookie_header = context
        .browser_session(ProviderId::Kimi)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE))?;
    let token = kimi_auth_token(cookie_header)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let value = fetch_web_usages(&token, context, WEB_USAGES_URL, HTTP_TIMEOUT)?;
    let data = map_web_usages(&value)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let windows = map_windows(&data);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let (fingerprint, scope) = account_identity("kimi", "api_key", None);
    Ok(QuotaSnapshot {
        provider: ProviderId::Kimi,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some("Kimi".to_owned()),
            plan: None,
        },
        windows,
        source: WEB_SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn fetch_web_usages(
    token: &str,
    context: &CollectionContext,
    url: &str,
    timeout: std::time::Duration,
) -> Result<Value, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    let client = HttpClient::with_timeout(timeout)?;
    let auth = format!("Bearer {token}");
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", auth.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, value) = client.post_json_session(url, &headers, &serde_json::json!({}), WEB_SOURCE)?;
    Ok(value)
}

fn kimi_auth_token(header: &str) -> Option<String> {
    let value = cookie_named_value(header, "kimi-auth")?.trim();
    (!value.is_empty() && value.len() <= 8_192 && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
}

fn map_web_usages(value: &Value) -> Option<Usage> {
    let usages = value.get("usages").and_then(Value::as_array)?;
    let entry = usages.iter().find(|entry| {
        matches!(
            string(obj_get(entry, "scope")).as_deref(),
            Some("FEATURE_CODING" | "coding")
        )
    })?;
    let usage = obj_get(entry, "detail")
        .or_else(|| obj_get(entry, "usage"))
        .cloned()
        .unwrap_or(Value::Null);
    map_usages(&serde_json::json!({
        "usage": usage,
        "limits": entry.get("limits").cloned().unwrap_or(Value::Null),
    }))
}

#[derive(Clone, Debug)]
struct Detail {
    limit: f64,
    used: f64,
    remaining: f64,
    resets_at: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct Usage {
    weekly: Option<Detail>,
    five_hour: Option<Detail>,
}

fn map_usages(value: &Value) -> Option<Usage> {
    let root = value.as_object()?;
    let weekly = map_detail(
        root.get("usage")
            .filter(|value| value.is_object())
            .or(Some(value)),
    );
    let five_hour = root
        .get("limits")
        .and_then(Value::as_array)
        .and_then(|limits| {
            limits.iter().find_map(|entry| {
                let window = obj_get(entry, "window")?;
                let duration = number(obj_get(window, "duration"))?;
                let unit =
                    string(obj_get(window, "timeUnit").or_else(|| obj_get(window, "time_unit")));
                if (duration - 300.0).abs() > f64::EPSILON
                    || unit
                        .as_deref()
                        .map(|v| !matches!(v, "TIME_UNIT_MINUTE" | "minute" | "MINUTE"))
                        .unwrap_or(false)
                {
                    return None;
                }
                map_detail(obj_get(entry, "detail").or(Some(entry)))
            })
        });
    (weekly.is_some() || five_hour.is_some()).then_some(Usage { weekly, five_hour })
}

fn map_detail(value: Option<&Value>) -> Option<Detail> {
    let value = value?;
    let limit = number(obj_get(value, "limit"));
    let used = number(obj_get(value, "used"));
    let remaining = number(obj_get(value, "remaining"));
    if limit.is_none() && used.is_none() && remaining.is_none() {
        return None;
    }
    let limit = limit.unwrap_or_else(|| used.unwrap_or(0.0) + remaining.unwrap_or(0.0));
    let used = used.unwrap_or_else(|| {
        if limit > 0.0 {
            (limit - remaining.unwrap_or(0.0)).max(0.0)
        } else {
            0.0
        }
    });
    let remaining = remaining.unwrap_or_else(|| {
        if limit > 0.0 {
            (limit - used).max(0.0)
        } else {
            0.0
        }
    });
    let resets_at = obj_get_any(value, &["resetTime", "reset_time", "resets_at"])
        .and_then(|value| parse_date(Some(value)).map(super::common::unix_seconds_to_iso));
    Some(Detail {
        limit,
        used,
        remaining,
        resets_at,
    })
}

fn map_windows(data: &Usage) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    if let Some(detail) = &data.weekly {
        windows.push(window("weekly", "Weekly", detail));
    }
    if let Some(detail) = &data.five_hour {
        windows.push(window("five_hour", "5 hour", detail));
    }
    windows
}

fn window(id: &str, title: &str, detail: &Detail) -> QuotaWindow {
    let denom = if detail.limit > 0.0 {
        detail.limit
    } else {
        detail.used + detail.remaining
    };
    QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent: if denom > 0.0 {
            clamp_percent(detail.used / denom * 100.0)
        } else if detail.remaining > 0.0 {
            0.0
        } else {
            100.0
        },
        resets_at: detail.resets_at.clone(),
        duration_seconds: None,
        remaining_value: Some(detail.remaining.max(0.0)),
        limit_value: (denom > 0.0).then_some(denom),
        value_unit: Some("count"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: std::path::PathBuf::from("/tmp/quota-kimi-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: Some(std::path::PathBuf::from(
                "/tmp/quota-kimi-missing-config/providers.json",
            )),
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
        }
    }

    #[test]
    fn discovers_browser_session_when_api_key_is_absent() {
        let mut context = isolated_context();
        assert!(discover(&context).is_empty());
        context.browser_sessions.insert(
            ProviderId::Kimi,
            "kimi-auth=eyJhbGciOiJIUzI1NiJ9.e30.ok".to_owned(),
        );
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].credential_source, "browser_session");
    }

    #[test]
    fn kimi_auth_token_rules_and_fingerprint_redaction() {
        assert_eq!(
            kimi_auth_token("kimi-auth=eyJhbGciOiJIUzI1NiJ9.e30.ok").as_deref(),
            Some("eyJhbGciOiJIUzI1NiJ9.e30.ok")
        );
        assert!(kimi_auth_token("kimi-auth=").is_none());
        assert!(kimi_auth_token("sessionKey=sk-ant-ok").is_none());
        let (fingerprint, scope) = account_identity("kimi", "api_key", None);
        assert_eq!(scope, "source");
        assert!(!fingerprint.contains("super-secret"));
    }

    #[test]
    fn maps_web_coding_usages() {
        let spec = ProviderId::Kimi
            .metadata()
            .browser_session
            .expect("kimi browser session");
        assert_eq!(spec.cookie_names, &["kimi-auth"]);
        let data = map_web_usages(&serde_json::json!({
            "usages": [{
                "scope": "FEATURE_CODING",
                "detail": {"limit": "100", "used": "25", "remaining": "75"},
                "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": "50", "used": "10", "remaining": "40"}}]
            }]
        }))
        .unwrap();
        let windows = map_windows(&data);
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["weekly", "five_hour"]
        );
    }

    #[test]
    fn maps_weekly_and_five_hour_windows() {
        let data = map_usages(&serde_json::json!({
            "usage": {"limit": "100", "used": "25", "remaining": "75"},
            "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": "50", "used": "10", "remaining": "40"}}]
        })).unwrap();
        let windows = map_windows(&data);
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["weekly", "five_hour"]
        );
        assert_eq!(windows[1].value_unit, Some("count"));
    }

    #[test]
    fn derives_missing_values_and_rejects_non_five_hour_limits() {
        let data = map_usages(&serde_json::json!({
            "usage": {"used": "25", "remaining": "75"},
            "limits": [
                {"window": {"duration": 60, "timeUnit": "minute"}, "detail": {"limit": 10, "used": 1}},
                {"window": {"duration": 300, "timeUnit": "minute"}, "detail": {"remaining": 40}}
            ]
        })).unwrap();
        let windows = map_windows(&data);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].limit_value, Some(100.0));
        assert_eq!(windows[1].limit_value, Some(40.0));
        assert_eq!(windows[1].used_percent, 0.0);
    }
}
