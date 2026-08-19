use crate::catalog::ProviderId;
use serde_json::Value;

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, ProviderError, ProviderSession, QuotaAccount,
    QuotaSnapshot, QuotaWindow, VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity,
    clamp_percent, mask_email, number, obj_get, parse_date, unix_seconds_to_iso,
};

pub const SOURCE: &str = "cursor_dashboard_api";
const ORIGIN: &str = "https://cursor.com";

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    context
        .browser_session(ProviderId::Cursor)
        .map(|_| {
            vec![ProviderSession {
                provider: ProviderId::Cursor,
                credential_source: "browser_session".to_owned(),
            }]
        })
        .unwrap_or_default()
}

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    validate_at(cookie_header, context, ORIGIN)
}

fn validate_at(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
) -> Result<ValidatedBrowserSession, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let client = HttpClient::with_timeout(VALIDATION_TIMEOUT)?;
    let user_agent = context.user_agent();
    let headers = [
        ("Accept", "application/json"),
        ("Cookie", cookie_header),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, identity) =
        client.get_json_session(&format!("{origin}/api/auth/me"), &headers, SOURCE)?;
    identity_from_response(&identity, cookie_header)
}

fn identity_from_response(
    value: &Value,
    cookie_header: &str,
) -> Result<ValidatedBrowserSession, ProviderError> {
    let sub = bounded_identity(value.get("sub"), 256);
    let email = bounded_identity(value.get("email"), 254).filter(|value| valid_email(value));
    let normalized_email = email.as_ref().map(|value| value.to_ascii_lowercase());
    let (namespace, owner) = sub
        .as_deref()
        .map(|value| ("sub", value))
        .or_else(|| normalized_email.as_deref().map(|value| ("email", value)))
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    let (account_fingerprint, _) = account_identity("cursor", namespace, Some(owner));
    let display_email = email.as_deref().and_then(|value| {
        let (local, domain) = value.split_once('@')?;
        Some(format!("{local}@{}", domain.to_ascii_lowercase()))
    });
    let account_label = mask_email(display_email.as_deref())
        .filter(|label| label.len() <= 128 && !label.chars().any(char::is_control));
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label,
    })
}

fn bounded_identity(value: Option<&Value>, limit: usize) -> Option<String> {
    let value = value?.as_str()?.trim();
    (!value.is_empty() && value.len() <= limit && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
}

fn valid_email(value: &str) -> bool {
    if !value.is_ascii() || value.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return false;
    }
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.is_empty()
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && domain.contains('.')
        && !domain.contains('@')
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    let cookie_header = context
        .browser_session(ProviderId::Cursor)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let identity = validate_browser_session(cookie_header, context)?;
    let client = HttpClient::new()?;
    let user_agent = context.user_agent();
    let headers = [
        ("Accept", "application/json"),
        ("Cookie", cookie_header),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, summary) =
        client.get_json_session(&format!("{ORIGIN}/api/usage-summary"), &headers, SOURCE)?;
    let windows = quota_windows(&summary)?;
    Ok(QuotaSnapshot {
        provider: ProviderId::Cursor,
        account: QuotaAccount {
            fingerprint: identity.account_fingerprint,
            fingerprint_scope: "global",
            label: identity.account_label,
            plan: bounded_identity(summary.get("membershipType"), 64),
        },
        windows,
        source: SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn quota_windows(summary: &Value) -> Result<Vec<QuotaWindow>, ProviderError> {
    let reset = parse_date(summary.get("billingCycleEnd")).map(unix_seconds_to_iso);
    let individual = obj_get(summary, "individualUsage");
    let team = obj_get(summary, "teamUsage");
    let mut windows = Vec::new();
    if let Some(plan) = individual.and_then(|value| obj_get(value, "plan")) {
        windows.extend(included_windows(plan, reset.clone()));
    }
    if let Some(overall) = individual.and_then(|value| obj_get(value, "overall")) {
        if windows.is_empty()
            && let Some(window) = money_window("individual", "Individual", overall, reset.clone())
        {
            windows.push(window);
        }
    }
    if let Some(on_demand) = individual.and_then(|value| obj_get(value, "onDemand"))
        && let Some(window) = money_window("on_demand", "On-demand", on_demand, reset.clone())
    {
        windows.push(window);
    }
    if let Some(pooled) = team.and_then(|value| obj_get(value, "pooled"))
        && let Some(window) = money_window("team_pool", "Team pool", pooled, reset.clone())
    {
        windows.push(window);
    }
    if let Some(on_demand) = team.and_then(|value| obj_get(value, "onDemand"))
        && let Some(window) =
            money_window("team_on_demand", "Team on-demand", on_demand, reset.clone())
    {
        windows.push(window);
    }
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    Ok(windows)
}

fn included_windows(value: &Value, resets_at: Option<String>) -> Vec<QuotaWindow> {
    if value.get("enabled").and_then(Value::as_bool) == Some(false) {
        return Vec::new();
    }
    let api_money = included_api_remaining(value);
    [
        ("cursor_models", "Cursor Models", "autoPercentUsed"),
        ("other_models", "Other Models", "apiPercentUsed"),
    ]
    .into_iter()
    .filter_map(|(id, title, field)| {
        let api = id == "other_models";
        Some(QuotaWindow {
            id: id.to_owned(),
            title: title.to_owned(),
            used_percent: clamp_percent(number(value.get(field))?),
            resets_at: resets_at.clone(),
            duration_seconds: None,
            remaining_value: api
                .then_some(api_money)
                .flatten()
                .map(|(remaining, _)| remaining),
            limit_value: api.then_some(api_money).flatten().map(|(_, limit)| limit),
            value_unit: (api && api_money.is_some()).then_some("usd"),
        })
    })
    .collect()
}

fn included_api_remaining(value: &Value) -> Option<(f64, f64)> {
    let used = number(value.get("used"))?;
    let limit = number(value.get("limit"))?;
    if used < 0.0 || limit <= 0.0 {
        return None;
    }
    let remaining = number(value.get("remaining"))
        .filter(|value| *value >= 0.0)
        .unwrap_or_else(|| (limit - used).max(0.0));
    Some((remaining / 100.0, limit / 100.0))
}

fn money_window(
    id: &str,
    title: &str,
    value: &Value,
    resets_at: Option<String>,
) -> Option<QuotaWindow> {
    if value.get("enabled").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let used = number(value.get("used"))?;
    let limit = number(value.get("limit"))?;
    if used < 0.0 || limit <= 0.0 {
        return None;
    }
    let remaining = number(value.get("remaining"))
        .filter(|value| *value >= 0.0)
        .unwrap_or_else(|| (limit - used).max(0.0));
    let percent = number(value.get("totalPercentUsed")).unwrap_or_else(|| used / limit * 100.0);
    Some(QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(percent),
        resets_at,
        duration_seconds: None,
        remaining_value: Some(remaining / 100.0),
        limit_value: Some(limit / 100.0),
        value_unit: Some("usd"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_is_an_account_sync_catalog_provider() {
        assert!(ProviderId::ALL.contains(&ProviderId::Cursor));
        assert!(ProviderId::Cursor.metadata().account_sync);
        assert_eq!(ProviderId::Cursor.metadata().account_sync_protocol, Some(3));
        assert_eq!(
            ProviderId::Cursor
                .metadata()
                .browser_session
                .map(|session| session.exclusive),
            Some(true)
        );
    }

    #[test]
    fn identity_is_stable_and_redacted() {
        let value = serde_json::json!({"sub":"user-secret", "email":"Ada@Example.com"});
        let session = identity_from_response(&value, "wos-session=secret").expect("identity");
        assert_eq!(session.account_label.as_deref(), Some("Ad***@example.com"));
        assert!(!session.account_fingerprint.contains("user-secret"));
        let wire = serde_json::to_string(&session.account_fingerprint).expect("wire");
        assert!(!wire.contains("Ada"));
    }

    #[test]
    fn usage_summary_maps_official_model_groups_and_on_demand_money() {
        let windows = quota_windows(&serde_json::json!({
            "billingCycleEnd": "2026-09-01T00:00:00Z",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 15684,
                    "limit": 40000,
                    "totalPercentUsed": 6.2736,
                    "autoPercentUsed": 0.541,
                    "apiPercentUsed": 29.204
                },
                "onDemand": {"enabled":true,"used":125,"limit":500,"remaining":375}
            }
        }))
        .expect("windows");
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].title, "Cursor Models");
        assert_eq!(windows[0].used_percent, 0.541);
        assert_eq!(windows[0].remaining_value, None);
        assert_eq!(windows[1].title, "Other Models");
        assert_eq!(windows[1].used_percent, 29.204);
        assert_eq!(windows[1].remaining_value, Some(243.16));
        assert_eq!(windows[1].limit_value, Some(400.0));
        assert_eq!(windows[1].value_unit, Some("usd"));
        assert_eq!(windows[2].remaining_value, Some(3.75));
    }

    #[test]
    fn partial_or_unbounded_usage_is_rejected() {
        assert!(
            quota_windows(&serde_json::json!({"individualUsage":{"plan":{"used":1}}})).is_err()
        );
    }

    #[test]
    fn provider_text_is_bounded_before_wire_output() {
        assert_eq!(
            bounded_identity(Some(&serde_json::json!(" Pro ")), 64).as_deref(),
            Some("Pro")
        );
        assert!(bounded_identity(Some(&serde_json::json!("x".repeat(65))), 64).is_none());
        assert!(bounded_identity(Some(&serde_json::json!("bad\nplan")), 64).is_none());
    }

    #[test]
    fn identity_rejects_oversized_control_and_malformed_values() {
        for value in [
            serde_json::json!({"sub":"x".repeat(257)}),
            serde_json::json!({"sub":"bad\nsub"}),
            serde_json::json!({"email":"not-an-email"}),
            serde_json::json!({"email":"a@localhost"}),
        ] {
            assert!(identity_from_response(&value, "wos-session=secret").is_err());
        }
    }

    #[test]
    fn validation_maps_provider_auth_status_without_leaking_body() {
        use std::io::{Read as _, Write as _};
        use std::net::TcpListener;

        for status in ["401 Unauthorized", "403 Forbidden"] {
            let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
            let address = listener.local_addr().expect("address");
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().expect("accept");
                let mut request = [0_u8; 2048];
                let _ = stream.read(&mut request);
                let body = b"provider-secret-response";
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
                .expect("response headers");
                stream.write_all(body).expect("response body");
            });
            let error = validate_at(
                "wos-session=cookie-secret",
                &CollectionContext::default(),
                &format!("http://{address}"),
            )
            .expect_err("auth failure");
            assert_eq!(error.category, ErrorCategory::AuthRequired);
            assert!(!error.to_string().contains("provider-secret-response"));
            assert!(!error.to_string().contains("cookie-secret"));
            server.join().expect("server");
        }
    }
}
