use crate::catalog::ProviderId;
use serde_json::Value;

use super::super::common::{
    CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient, ProviderError, QuotaSnapshot,
    VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity, cookie_named_value, mask_email,
    obj_get, obj_get_any, string,
};
use super::{Credentials, Identity, collect_api, map_usage, snapshot};
use std::time::Duration;

pub const WEB_SOURCE: &str = "chatgpt_web_usage_api";
const SESSION_URL: &str = "https://chatgpt.com/api/auth/session";
const ME_URL: &str = "https://chatgpt.com/backend-api/me";

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    if !has_chatgpt_session_cookie(cookie_header) {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let session = fetch_web_session(cookie_header, context, VALIDATION_TIMEOUT)?;
    if session.account_id.is_none() && session.email.is_none() && session.access_token.is_none() {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let (account_fingerprint, _) =
        account_identity("codex", "account_id", session.account_id.as_deref());
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: mask_email(session.email.as_deref()),
    })
}

pub fn collect(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let cookie_header = context
        .browser_session(ProviderId::Codex)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE))?;
    let session = fetch_web_session(cookie_header, context, HTTP_TIMEOUT)?;
    if let Some(access_token) = session.access_token.as_deref() {
        let credentials = Credentials {
            access_token: access_token.to_owned(),
            id_token: None,
            account_id: session.account_id.clone(),
        };
        let identity = Identity {
            email: session.email.clone(),
            plan: session.plan.clone(),
            account_id: session.account_id.clone(),
        };
        match collect_api(&credentials, &identity, context, WEB_SOURCE) {
            Ok(Some(snapshot)) => return Ok(snapshot),
            Ok(None) => {
                return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
            }
            Err(error) if error.category != ErrorCategory::AuthRequired => return Err(error),
            Err(_) => {}
        }
    }
    collect_web_usage(cookie_header, &session, context)
}

fn collect_web_usage(
    cookie_header: &str,
    session: &WebSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    let client = HttpClient::new()?;
    let user_agent = context.user_agent();
    let mut headers = vec![
        ("Cookie", cookie_header),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    if let Some(account_id) = session.account_id.as_deref() {
        headers.push(("ChatGPT-Account-Id", account_id));
    }
    let (_, value) = client.get_json_session(super::USAGE_URL, &headers, WEB_SOURCE)?;
    let mapped = map_usage(&value);
    if mapped.malformed_success {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    if mapped.windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    let plan = mapped.plan.or_else(|| session.plan.clone());
    let email = mapped.email.or_else(|| session.email.clone());
    let account_id = mapped.account_id.or_else(|| session.account_id.clone());
    Ok(snapshot(
        &mapped.windows,
        plan.as_deref(),
        email.as_deref(),
        account_id.as_deref(),
        &context.observed_at(),
    ))
}

#[derive(Clone, Debug, Default)]
struct WebSession {
    email: Option<String>,
    plan: Option<String>,
    account_id: Option<String>,
    access_token: Option<String>,
}

fn fetch_web_session(
    cookie_header: &str,
    context: &CollectionContext,
    timeout: Duration,
) -> Result<WebSession, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    if !has_chatgpt_session_cookie(cookie_header) {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let headers = [
        ("Cookie", cookie_header),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    match client.get_json_session(SESSION_URL, &headers, WEB_SOURCE) {
        Ok((_, value)) => {
            let session = parse_web_session(&value);
            if session.email.is_some()
                || session.account_id.is_some()
                || session.access_token.is_some()
            {
                return Ok(session);
            }
        }
        Err(error)
            if matches!(
                error.category,
                ErrorCategory::Unavailable | ErrorCategory::AuthRequired
            ) =>
        {
            return Err(error);
        }
        Err(_) => {}
    }
    let (_, value) = client.get_json_session(ME_URL, &headers, WEB_SOURCE)?;
    let session = parse_web_session(&value);
    if session.email.is_some() || session.account_id.is_some() || session.access_token.is_some() {
        return Ok(session);
    }
    Err(ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE))
}

fn parse_web_session(value: &Value) -> WebSession {
    let user = obj_get(value, "user").unwrap_or(value);
    let account = obj_get(value, "account").or_else(|| obj_get(user, "account"));
    WebSession {
        email: obj_get_any(user, &["email", "email_address", "emailAddress"])
            .and_then(|v| string(Some(v)))
            .or_else(|| {
                obj_get_any(value, &["email", "email_address", "emailAddress"])
                    .and_then(|v| string(Some(v)))
            }),
        plan: account
            .and_then(|account| {
                obj_get_any(account, &["planType", "plan_type", "plan"])
                    .and_then(|v| string(Some(v)))
            })
            .or_else(|| {
                obj_get_any(value, &["planType", "plan_type", "plan"]).and_then(|v| string(Some(v)))
            }),
        account_id: account
            .and_then(|account| {
                obj_get_any(account, &["id", "account_id", "accountId"])
                    .and_then(|v| string(Some(v)))
            })
            .or_else(|| {
                obj_get_any(value, &["account_id", "accountId", "chatgpt_account_id"])
                    .and_then(|v| string(Some(v)))
            }),
        access_token: obj_get_any(value, &["accessToken", "access_token"])
            .and_then(|v| string(Some(v))),
    }
}

fn has_chatgpt_session_cookie(header: &str) -> bool {
    let Some(spec) = ProviderId::Codex.metadata().browser_session else {
        return false;
    };
    spec.cookie_names.iter().any(|name| {
        is_chatgpt_session_cookie_name(name) && cookie_named_value(header, name).is_some()
    })
}

fn is_chatgpt_session_cookie_name(name: &str) -> bool {
    name.contains("session-token") || name.contains("authjs") || name.contains("next-auth")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browser_session_catalog_and_session_cookie_rules() {
        let spec = ProviderId::Codex
            .metadata()
            .browser_session
            .expect("codex browser session");
        assert!(
            spec.cookie_names
                .contains(&"__Secure-next-auth.session-token")
        );
        assert!(has_chatgpt_session_cookie(
            "__Secure-next-auth.session-token=abc; _account=acct"
        ));
        assert!(!has_chatgpt_session_cookie("_account=acct"));
        assert!(!has_chatgpt_session_cookie("cf_clearance=bot"));
    }

    #[test]
    fn parses_chatgpt_session_identity() {
        let session = parse_web_session(&serde_json::json!({
            "user": {"email": "Ada@Example.com"},
            "accessToken": "session-access",
            "account": {"id": "acct_1", "planType": "plus"}
        }));
        assert_eq!(session.email.as_deref(), Some("Ada@Example.com"));
        assert_eq!(session.account_id.as_deref(), Some("acct_1"));
        assert_eq!(session.access_token.as_deref(), Some("session-access"));
        assert_eq!(session.plan.as_deref(), Some("plus"));
        let (fingerprint, scope) = account_identity("codex", "account_id", None);
        assert_eq!(scope, "source");
        assert_eq!(
            snapshot(
                &[],
                None,
                Some("Ada@Example.com"),
                None,
                "2026-08-10T00:00:00Z"
            )
            .account
            .fingerprint,
            fingerprint
        );
    }
}
