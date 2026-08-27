//! Claude Code's last rung: the claude.ai session a reader stored from their browser.
//!
//! It is reached only when this Mac holds no Claude credential at all, or when the one it holds
//! answered "sign in again". A refused Keychain is not that answer, so a withheld secret never
//! spends a cookie.

use crate::catalog::ProviderId;
use serde_json::Value;
use std::time::Duration;

use super::super::common::{
    CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient, ProviderError, QuotaAccount,
    QuotaSnapshot, VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity,
    cookie_named_value, mask_email, obj_get, obj_get_any, string,
};
use super::{answers_for_a_known_window, map_usage};

pub const SOURCE: &str = "claude_web_usage_api";
const ORIGIN: &str = "https://claude.ai";

/// Proves the cookie belongs to a signed-in claude.ai account before anything is stored.
///
/// The organization list alone is not that proof — it answers for a session that can no longer
/// read usage — so the same usage document a reading would use has to map as well.
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
    let started = std::time::Instant::now();
    let account = web_account(cookie_header, context, origin, VALIDATION_TIMEOUT)?;
    let remaining = VALIDATION_TIMEOUT.saturating_sub(started.elapsed());
    if remaining.is_zero() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    // The organization list alone is not proof: a session that can list organizations and can
    // no longer read usage is one this build would store and never be able to spend. An
    // account that answers for a window this build knows, even to say it has none, has been
    // read — the same rule the OAuth rung applies, because refusing it told a reader whose
    // account simply has no windows that their session was broken.
    let usage = fetch_usage(
        cookie_header,
        context,
        origin,
        &account.organization_id,
        remaining,
    )?;
    if map_usage(&usage).is_empty() && !answers_for_a_known_window(&usage) {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let (account_fingerprint, _) = account_identity(
        "claude",
        "organization_id",
        Some(account.organization_id.as_str()),
    );
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: mask_email(account.email.as_deref()),
    })
}

pub fn collect(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let cookie_header = context
        .browser_session(ProviderId::Claude)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    collect_at(cookie_header, context, ORIGIN)
}

fn collect_at(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    let account = web_account(cookie_header, context, origin, HTTP_TIMEOUT)?;
    let usage = fetch_usage(
        cookie_header,
        context,
        origin,
        &account.organization_id,
        HTTP_TIMEOUT,
    )?;
    let windows = map_usage(&usage);
    if windows.is_empty() && !answers_for_a_known_window(&usage) {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let (fingerprint, scope) = account_identity(
        "claude",
        "organization_id",
        Some(account.organization_id.as_str()),
    );
    Ok(QuotaSnapshot {
        provider: ProviderId::Claude,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: mask_email(account.email.as_deref()),
            plan: account.plan,
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

/// The organization a reading belongs to, and the identity claude.ai shows beside it.
struct WebAccount {
    organization_id: String,
    email: Option<String>,
    plan: Option<String>,
}

/// The one lookup both the validation and the reading make: which organization this session
/// speaks for, and who it says is signed in.
///
/// `/api/account` is best-effort — it enriches the label and the plan, and a session that
/// cannot reach it can still be read.
fn web_account(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
    timeout: Duration,
) -> Result<WebAccount, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let cookie = request_cookie_header(cookie_header)?;
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let headers = web_headers(cookie, &user_agent);
    let (_, organizations) =
        client.get_json_session(&format!("{origin}/api/organizations"), &headers, SOURCE)?;
    let account = client
        .get_json_session(&format!("{origin}/api/account"), &headers, SOURCE)
        .ok()
        .map(|(_, value)| value);
    let preferred = last_active_organization(cookie_header)
        .or_else(|| account.as_ref().and_then(web_account_organization));
    let organization_id = select_organization_id(&organizations, preferred.as_deref())
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    Ok(WebAccount {
        organization_id,
        email: account.as_ref().and_then(web_account_email),
        plan: account.as_ref().and_then(web_account_plan),
    })
}

fn fetch_usage(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
    organization_id: &str,
    timeout: Duration,
) -> Result<Value, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let cookie = request_cookie_header(cookie_header)?;
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let headers = web_headers(cookie, &user_agent);
    let (_, usage) = client.get_json_session(
        &format!("{origin}/api/organizations/{organization_id}/usage"),
        &headers,
        SOURCE,
    )?;
    Ok(usage)
}

fn web_headers<'a>(cookie: &'a str, user_agent: &'a str) -> [(&'a str, &'a str); 5] {
    [
        ("Accept", "application/json"),
        ("Cookie", cookie),
        ("Origin", ORIGIN),
        ("Referer", "https://claude.ai/"),
        ("User-Agent", user_agent),
    ]
}

fn request_cookie_header(header: &str) -> Result<&str, ProviderError> {
    session_key_from_header(header)
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    Ok(header)
}

/// `sessionKey` is the whole sign-in, and Anthropic's carries a prefix of its own. A header
/// that has only the org hint beside it names no session at all.
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
    use std::collections::HashMap;
    use std::path::PathBuf;

    fn context() -> CollectionContext {
        CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-claude-web-missing-home"),
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

    /// A queue of successful responses, over the shared stub.
    fn serve(bodies: Vec<String>) -> (String, std::thread::JoinHandle<Vec<String>>) {
        crate::providers::common::serve_responses(
            bodies
                .into_iter()
                .map(|body| (200, body.into_bytes()))
                .collect(),
        )
    }

    #[test]
    fn the_catalog_names_the_claude_session_cookies() {
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

    /// The org list alone proves nothing: a session that can list organizations and cannot read
    /// usage is a session this build would store and never be able to spend.
    #[test]
    fn validate_keeps_only_a_session_that_can_read_usage() {
        let organizations = r#"[{"uuid":"org-1","capabilities":["chat"]}]"#.to_owned();
        let account = r#"{"email_address":"ada@example.com","subscription_type":"max"}"#.to_owned();
        let (address, server) = serve(vec![
            organizations.clone(),
            account.clone(),
            r#"{"five_hour":{"utilization":12}}"#.to_owned(),
        ]);
        let validated = validate_at(
            "sessionKey=sk-ant-ok",
            &context(),
            &format!("http://{address}"),
        )
        .expect("validated");
        // The same organization the OAuth rung names, so the ladder does not rename the account.
        let (oauth, scope) = account_identity("claude", "organization_id", Some("org-1"));
        assert_eq!(validated.account_fingerprint, oauth);
        assert_eq!(scope, "global");
        assert_eq!(
            validated.account_label.as_deref(),
            Some("ad***@example.com")
        );
        let heads = server.join().expect("server");
        assert!(heads[0].contains("cookie: sessionkey=sk-ant-ok"));
        assert!(heads[2].contains("/api/organizations/org-1/usage"));

        // An account that answers for a window this build knows, even to say it has none, has
        // been read: the same rule the OAuth rung applies, so the ladder does not tell a
        // reader with no windows that their session is broken.
        let (address, server) = serve(vec![
            organizations.clone(),
            account.clone(),
            r#"{"five_hour":null}"#.to_owned(),
        ]);
        validate_at(
            "sessionKey=sk-ant-ok",
            &context(),
            &format!("http://{address}"),
        )
        .expect("an account with no windows is still an account");
        assert_eq!(server.join().expect("server").len(), 3);

        // A session that still lists organizations and answers for no window this build knows
        // is refused.
        let (address, server) = serve(vec![organizations, account, "{}".to_owned()]);
        let error = validate_at(
            "sessionKey=sk-ant-ok",
            &context(),
            &format!("http://{address}"),
        )
        .expect_err("no usage");
        assert_eq!(error.category, ErrorCategory::Error);
        assert_eq!(error.source_id, SOURCE);
        assert_eq!(server.join().expect("server").len(), 3);
    }

    /// A header without an Anthropic `sessionKey` is rejected before a request is made.
    #[test]
    fn validate_rejects_a_header_that_names_no_session() {
        let error = validate_at("lastActiveOrg=org-2", &context(), "http://127.0.0.1:1")
            .expect_err("no session key");
        assert_eq!(error.category, ErrorCategory::Error);
        assert_eq!(error.source_id, SOURCE);
    }

    /// A reading uses the organization the cookie's own hint names, and reports the plan and
    /// masked identity claude.ai gave beside it.
    #[test]
    fn a_reading_follows_the_last_active_organization() {
        let (address, server) = serve(vec![
            r#"[{"uuid":"org-1","capabilities":["chat"]},{"uuid":"org-2","capabilities":["chat"]}]"#
                .to_owned(),
            r#"{"email_address":"ada@example.com","subscription_type":"max"}"#.to_owned(),
            r#"{"five_hour":{"utilization":12}}"#.to_owned(),
        ]);
        let snapshot = collect_at(
            "lastActiveOrg=org-2; sessionKey=sk-ant-ok",
            &context(),
            &format!("http://{address}"),
        )
        .expect("snapshot");
        assert_eq!(snapshot.account.plan.as_deref(), Some("max"));
        assert_eq!(snapshot.account.fingerprint_scope, "global");
        assert_eq!(snapshot.windows.len(), 1);
        assert!(server.join().expect("server")[2].contains("/api/organizations/org-2/usage"));
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
