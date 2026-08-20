use crate::catalog::ProviderId;
use serde_json::Value;
use std::time::Duration;

use super::super::common::{
    CollectionContext, ErrorCategory, HttpClient, ProviderError, QuotaAccount, QuotaSnapshot,
    VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity, cookie_named_value, mask_email,
    obj_get, obj_get_any, string,
};
use super::map_usage;

pub const WEB_SOURCE: &str = "claude_web_usage_api";
const WEB_ORIGIN: &str = "https://claude.ai";

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    let organization = fetch_organization_id(
        cookie_header,
        context,
        WEB_ORIGIN,
        VALIDATION_TIMEOUT,
        last_active_organization(cookie_header).as_deref(),
        true,
    )?;
    let (account_fingerprint, _) =
        account_identity("claude", "organization_id", Some(&organization));
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: None,
    })
}

pub fn collect(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let cookie_header = context
        .browser_session(ProviderId::Claude)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE))?;
    collect_at(cookie_header, context, WEB_ORIGIN)
}

fn collect_at(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    let identity = web_account(cookie_header, context, origin)?;
    let organization = identity
        .organization_id
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let client = HttpClient::new()?;
    let user_agent = context.user_agent();
    let cookie = request_cookie_header(cookie_header)?;
    let headers = web_headers(cookie, &user_agent);
    let (_, usage) = client.get_json_session(
        &format!("{origin}/api/organizations/{organization}/usage"),
        &headers,
        WEB_SOURCE,
    )?;
    let windows = map_usage(&usage);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    let (fingerprint, scope) =
        account_identity("claude", "organization_id", Some(organization.as_str()));
    Ok(QuotaSnapshot {
        provider: ProviderId::Claude,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: mask_email(identity.email.as_deref()),
            plan: identity.plan,
        },
        windows,
        source: WEB_SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

struct WebAccount {
    organization_id: Option<String>,
    email: Option<String>,
    plan: Option<String>,
}

fn web_account(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
) -> Result<WebAccount, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    let cookie = request_cookie_header(cookie_header)?;
    let client = HttpClient::new()?;
    let user_agent = context.user_agent();
    let headers = web_headers(cookie, &user_agent);
    let (_, organizations) =
        client.get_json_session(&format!("{origin}/api/organizations"), &headers, WEB_SOURCE)?;
    let account = client
        .get_json_session(&format!("{origin}/api/account"), &headers, WEB_SOURCE)
        .ok()
        .map(|(_, value)| value);
    let preferred = last_active_organization(cookie_header)
        .or_else(|| account.as_ref().and_then(web_account_organization));
    let organization_id = select_organization_id(&organizations, preferred.as_deref())
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    Ok(WebAccount {
        organization_id: Some(organization_id),
        email: account.as_ref().and_then(web_account_email),
        plan: account.as_ref().and_then(web_account_plan),
    })
}

fn fetch_organization_id(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
    timeout: Duration,
    preferred: Option<&str>,
    verify_usage: bool,
) -> Result<String, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    let started = std::time::Instant::now();
    let cookie = request_cookie_header(cookie_header)?;
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let headers = web_headers(cookie, &user_agent);
    let (_, organizations) =
        client.get_json_session(&format!("{origin}/api/organizations"), &headers, WEB_SOURCE)?;
    let preferred = preferred
        .map(str::to_owned)
        .or_else(|| last_active_organization(cookie_header));
    let organization = select_organization_id(&organizations, preferred.as_deref())
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    if verify_usage {
        let remaining = timeout.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
        }
        let client = HttpClient::with_timeout(remaining)?;
        let (_, usage) = client.get_json_session(
            &format!("{origin}/api/organizations/{organization}/usage"),
            &headers,
            WEB_SOURCE,
        )?;
        if map_usage(&usage).is_empty() {
            return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
        }
    }
    Ok(organization)
}

fn web_headers<'a>(cookie: &'a str, user_agent: &'a str) -> [(&'a str, &'a str); 5] {
    [
        ("Accept", "application/json"),
        ("Cookie", cookie),
        ("Origin", WEB_ORIGIN),
        ("Referer", "https://claude.ai/"),
        ("User-Agent", user_agent),
    ]
}

fn request_cookie_header(header: &str) -> Result<&str, ProviderError> {
    session_key_from_header(header)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    Ok(header)
}

fn session_key_from_header(header: &str) -> Option<String> {
    let value = cookie_named_value(header, "sessionKey")?.trim();
    (value.starts_with("sk-ant-") && value.len() <= 512 && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
}

fn select_organization_id(value: &Value, preferred: Option<&str>) -> Option<String> {
    let entries = value
        .as_array()
        .or_else(|| obj_get(value, "organizations").and_then(Value::as_array))?;
    if let Some(preferred) = preferred {
        for entry in entries {
            let Some(id) = organization_id(entry) else {
                continue;
            };
            if id == preferred && !organization_is_api_disabled(entry) {
                return Some(id);
            }
        }
    }
    let mut first = None;
    for entry in entries {
        if !organization_allows_chat(entry) {
            continue;
        }
        let Some(id) = organization_id(entry) else {
            continue;
        };
        if first.is_none() {
            first = Some(id);
        }
    }
    first
}

fn organization_id(value: &Value) -> Option<String> {
    obj_get_any(value, &["uuid", "id"])
        .and_then(|v| string(Some(v)))
        .filter(|id| !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control))
}

fn last_active_organization(header: &str) -> Option<String> {
    let value = cookie_named_value(header, "lastActiveOrg")?.trim();
    (!value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
}

fn web_account_organization(value: &Value) -> Option<String> {
    obj_get(value, "organization")
        .and_then(organization_id)
        .or_else(|| {
            obj_get_any(
                value,
                &["organizationUuid", "organization_uuid", "organization_id"],
            )
            .and_then(|v| string(Some(v)))
        })
        .filter(|id| !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control))
}

fn organization_is_api_disabled(value: &Value) -> bool {
    value.get("api_disabled") == Some(&Value::Bool(true))
        || value.get("apiDisabled") == Some(&Value::Bool(true))
}

fn organization_allows_chat(value: &Value) -> bool {
    if organization_is_api_disabled(value) {
        return false;
    }
    obj_get_any(value, &["capabilities", "capability"])
        .and_then(|v| v.as_array())
        .is_some_and(|capabilities| {
            capabilities
                .iter()
                .any(|capability| matches!(capability.as_str(), Some("chat" | "claude_pro")))
        })
}

fn web_account_email(value: &Value) -> Option<String> {
    obj_get_any(value, &["email", "email_address", "emailAddress"])
        .and_then(|v| string(Some(v)))
        .or_else(|| {
            obj_get(value, "account").and_then(|account| {
                obj_get_any(account, &["email", "email_address", "emailAddress"])
                    .and_then(|v| string(Some(v)))
            })
        })
}

fn web_account_plan(value: &Value) -> Option<String> {
    obj_get_any(
        value,
        &[
            "subscription_type",
            "subscriptionType",
            "plan",
            "rate_limit_tier",
            "rateLimitTier",
        ],
    )
    .and_then(|v| string(Some(v)))
    .filter(|plan| plan.len() <= 64 && !plan.chars().any(char::is_control))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browser_session_catalog_and_session_key_rules() {
        let spec = ProviderId::Claude
            .metadata()
            .browser_session
            .expect("claude browser session");
        assert_eq!(spec.cookie_names, &["sessionKey", "lastActiveOrg"]);
        assert!(session_key_from_header("sessionKey=sk-ant-ok").is_some());
        assert!(session_key_from_header("sessionKey=not-anthropic").is_none());
        assert_eq!(
            last_active_organization("sessionKey=sk-ant-ok; lastActiveOrg=org-2").as_deref(),
            Some("org-2")
        );
    }

    #[test]
    fn selects_chat_capable_organization() {
        let value = serde_json::json!([
            {"uuid": "api-only", "api_disabled": true},
            {"uuid": "chat-org", "capabilities": ["chat"]},
            {"uuid": "last-active", "capabilities": ["chat"]}
        ]);
        assert_eq!(
            select_organization_id(&value, None).as_deref(),
            Some("chat-org")
        );
        assert_eq!(
            select_organization_id(&value, Some("last-active")).as_deref(),
            Some("last-active")
        );
        assert_eq!(
            select_organization_id(&value, Some("api-only")).as_deref(),
            Some("chat-org")
        );
        assert_eq!(
            select_organization_id(
                &serde_json::json!([
                    {"uuid": "api-only", "api_disabled": true},
                    {"uuid": "preferred-plain"},
                    {"uuid": "chat-org", "capabilities": ["chat"]}
                ]),
                Some("preferred-plain")
            )
            .as_deref(),
            Some("preferred-plain")
        );
        assert_eq!(
            request_cookie_header("lastActiveOrg=org-2; sessionKey=sk-ant-ok").ok(),
            Some("lastActiveOrg=org-2; sessionKey=sk-ant-ok")
        );
        assert!(
            select_organization_id(
                &serde_json::json!([
                    {"uuid": "unknown-a"},
                    {"uuid": "unknown-b"}
                ]),
                None
            )
            .is_none()
        );
        assert_eq!(
            web_account_organization(&serde_json::json!({
                "organization": {"uuid": "acct-org"}
            }))
            .as_deref(),
            Some("acct-org")
        );
    }
}
