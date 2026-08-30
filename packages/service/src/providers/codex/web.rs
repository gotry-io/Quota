//! Codex's last rung: the ChatGPT web session a reader stored from their browser.
//!
//! It is reached only when this Mac holds no Codex credential at all, or when every credential
//! it holds answered "sign in again". The session is proven to belong to a signed-in account
//! before it is stored, and the account it names is the same one the OAuth rung reports, so a
//! reading does not change identity when the ladder falls through to here.

use crate::catalog::ProviderId;
use serde_json::Value;
use std::time::Duration;

use super::super::common::{
    CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient, ProviderError, QuotaSnapshot,
    VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity, cookie_named_value, mask_email,
    obj_get, obj_get_any, string,
};
use super::{Credentials, Identity, collect_api, map_usage, snapshot};

pub const SOURCE: &str = "chatgpt_web_usage_api";
const ORIGIN: &str = "https://chatgpt.com";
const SESSION_PATH: &str = "/api/auth/session";
const ME_PATH: &str = "/backend-api/me";

/// Proves the cookie belongs to a signed-in ChatGPT account before anything is stored.
///
/// `/api/auth/session` answers with the account the cookie signs in as; a jar that carries a
/// session cookie for nobody answers with none of it, and that is a rejection rather than a
/// session worth keeping.
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
    if !has_chatgpt_session_cookie(cookie_header) {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let session = fetch_web_session(cookie_header, context, origin, VALIDATION_TIMEOUT)?;
    if session.account_id.is_none() && session.email.is_none() && session.access_token.is_none() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let (account_fingerprint, _) =
        account_identity("codex", "account_id", session.account_id.as_deref());
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: mask_email(session.email.as_deref()),
    })
}

pub fn collect(
    context: &CollectionContext,
    cookie_header: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    let session = fetch_web_session(cookie_header, context, ORIGIN, HTTP_TIMEOUT)?;
    // The session document often carries a bearer the WHAM endpoint accepts. Spending that is
    // the same request the OAuth rung makes, so it reports the same windows.
    if let Some(access_token) = session.access_token.as_deref() {
        let credentials = Credentials::from_web_session(access_token, session.account_id.clone());
        let identity = Identity {
            email: session.email.clone(),
            plan: session.plan.clone(),
            account_id: session.account_id.clone(),
        };
        match collect_api(&credentials, &identity, context, SOURCE) {
            Ok(Some(snapshot)) => return Ok(snapshot),
            Ok(None) => return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE)),
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
    let (_, value) = client.get_json_session(super::USAGE_URL, &headers, SOURCE)?;
    let mapped = map_usage(&value);
    if mapped.malformed_success {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    if mapped.windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    Ok(snapshot(
        &mapped.windows,
        mapped.plan.or_else(|| session.plan.clone()).as_deref(),
        mapped.email.or_else(|| session.email.clone()).as_deref(),
        mapped
            .account_id
            .or_else(|| session.account_id.clone())
            .as_deref(),
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
    origin: &str,
    timeout: Duration,
) -> Result<WebSession, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    if !has_chatgpt_session_cookie(cookie_header) {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let headers = [
        ("Cookie", cookie_header),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    match client.get_json_session(&format!("{origin}{SESSION_PATH}"), &headers, SOURCE) {
        Ok((_, value)) => {
            let session = parse_web_session(&value);
            if session.identified() {
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
    let (_, value) = client.get_json_session(&format!("{origin}{ME_PATH}"), &headers, SOURCE)?;
    let session = parse_web_session(&value);
    if session.identified() {
        return Ok(session);
    }
    Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE))
}

impl WebSession {
    /// Whether the document names an account at all. A signed-out jar gets an empty one.
    fn identified(&self) -> bool {
        self.email.is_some() || self.account_id.is_some() || self.access_token.is_some()
    }
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

/// Whether the stored header carries a whole ChatGPT sign-in rather than only the context
/// cookies that travel beside one.
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
    use std::collections::HashMap;
    use std::path::PathBuf;

    fn context() -> CollectionContext {
        CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-codex-web-missing-home"),
            environment: HashMap::new(),
            config_path: None,
            browser_sessions: HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        }
    }

    /// One request, one canned answer, and the request head handed back for inspection.
    /// A queue of responses, over the shared stub.
    fn serve(bodies: Vec<(u16, String)>) -> (String, std::thread::JoinHandle<Vec<String>>) {
        crate::providers::common::serve_responses(
            bodies
                .into_iter()
                .map(|(status, body)| (status, body.into_bytes()))
                .collect(),
        )
    }

    #[test]
    fn the_catalog_names_the_chatgpt_session_cookies() {
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
        // A context cookie on its own is not a sign-in.
        assert!(!has_chatgpt_session_cookie("_account=acct"));
        assert!(!has_chatgpt_session_cookie("cf_clearance=bot"));
    }

    /// A cookie is stored only once ChatGPT has said whose it is.
    #[test]
    fn validate_keeps_only_a_session_that_names_an_account() {
        let (address, server) = serve(vec![(
            200,
            r#"{"user":{"email":"ada@example.com"},"account":{"id":"acct_1","planType":"plus"}}"#
                .to_owned(),
        )]);
        let validated = validate_at(
            "__Secure-next-auth.session-token=abc",
            &context(),
            &format!("http://{address}"),
        )
        .expect("validated");
        assert_eq!(
            validated.account_label.as_deref(),
            Some("ad***@example.com")
        );
        // The same account the OAuth rung reports, so falling through does not rename it.
        let (oauth, scope) = account_identity("codex", "account_id", Some("acct_1"));
        assert_eq!(validated.account_fingerprint, oauth);
        assert_eq!(scope, "global");
        assert!(!validated.account_fingerprint.contains("acct_1"));
        let heads = server.join().expect("server");
        assert!(heads[0].contains("cookie: __secure-next-auth.session-token=abc"));

        // A signed-out jar answers with a document that names nobody: both documents are
        // asked, and the cookie is still refused.
        let (address, server) = serve(vec![(200, "{}".to_owned()), (200, "{}".to_owned())]);
        let error = validate_at(
            "__Secure-next-auth.session-token=abc",
            &context(),
            &format!("http://{address}"),
        )
        .expect_err("signed out");
        assert_eq!(error.source_id, SOURCE);
        assert_eq!(server.join().expect("server").len(), 2);
    }

    /// A header carrying no session cookie is rejected without a request at all.
    #[test]
    fn validate_rejects_a_header_with_no_session_cookie() {
        let error = validate_at("_account=acct", &context(), "http://127.0.0.1:1")
            .expect_err("no session cookie");
        assert_eq!(error.category, ErrorCategory::Error);
        assert_eq!(error.source_id, SOURCE);
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
        assert!(!parse_web_session(&serde_json::json!({})).identified());
    }
}
