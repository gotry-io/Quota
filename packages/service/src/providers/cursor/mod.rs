use crate::catalog::ProviderId;
use serde_json::Value;
use std::time::Duration;

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, ProviderError, ProviderSession, QuotaAccount,
    QuotaSnapshot, QuotaWindow, VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity,
    clamp_percent, collect_official_or_browser, discover_official_or_browser, mask_email, number,
    obj_get, parse_date, unix_seconds_to_iso, url_encode,
};

mod app;

/// The dashboard reached with a stored browser session, and the same dashboard reached with
/// the session a signed-in Cursor.app holds. Which rung failed is what a reader is told to go
/// and fix, so a failure names the credential it was spending, not just the endpoint.
pub const WEB_SOURCE: &str = "cursor_dashboard_api";
pub const APP_SOURCE: &str = app::SOURCE;
const ORIGIN: &str = "https://cursor.com";
/// Optional dashboard calls must not stretch a refresh that already has its
/// required usage summary.
const OPTIONAL_TIMEOUT: Duration = Duration::from_secs(5);

/// The validated session plus the stable subject that the legacy request-usage
/// endpoint keys on.
#[derive(Debug)]
struct Identity {
    session: ValidatedBrowserSession,
    subject: Option<String>,
}

/// Cursor has no CLI to sign in with and no API key, so a signed-in Cursor.app is the only
/// credential this Mac can find on its own, and a stored browser session is the rung after it.
pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    discover_official_or_browser(
        ProviderId::Cursor,
        app::usable_session(context).then(|| ProviderSession {
            provider: ProviderId::Cursor,
            credential_source: app::SOURCE.to_owned(),
        }),
        context,
    )
}

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    validate_at(cookie_header, context, ORIGIN, WEB_SOURCE).map(|identity| identity.session)
}

fn validate_at(
    cookie_header: &str,
    context: &CollectionContext,
    origin: &str,
    source: &'static str,
) -> Result<Identity, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, source));
    }
    let client = HttpClient::with_timeout(VALIDATION_TIMEOUT)?;
    let user_agent = context.user_agent();
    let headers = [
        ("Accept", "application/json"),
        ("Cookie", cookie_header),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, identity) =
        client.get_json_session(&format!("{origin}/api/auth/me"), &headers, source)?;
    identity_from_response(&identity, cookie_header, source)
}

fn identity_from_response(
    value: &Value,
    cookie_header: &str,
    source: &'static str,
) -> Result<Identity, ProviderError> {
    let sub = bounded_identity(value.get("sub"), 256);
    let email = bounded_identity(value.get("email"), 254).filter(|value| valid_email(value));
    let normalized_email = email.as_ref().map(|value| value.to_ascii_lowercase());
    let (namespace, owner) = sub
        .as_deref()
        .map(|value| ("sub", value))
        .or_else(|| normalized_email.as_deref().map(|value| ("email", value)))
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, source))?;
    let (account_fingerprint, _) = account_identity("cursor", namespace, Some(owner));
    let display_email = email.as_deref().and_then(|value| {
        let (local, domain) = value.split_once('@')?;
        Some(format!("{local}@{}", domain.to_ascii_lowercase()))
    });
    let account_label = mask_email(display_email.as_deref())
        .filter(|label| label.len() <= 128 && !label.chars().any(char::is_control));
    Ok(Identity {
        session: ValidatedBrowserSession {
            cookie_header: cookie_header.to_owned(),
            account_fingerprint,
            account_label,
        },
        subject: sub,
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

/// Reads the live Cursor.app session, and falls back to the stored browser session only when
/// the app has no usable sign-in to offer. Any other failure is this refresh's answer: a
/// rejected reading is not a reason to spend a second request on the same account.
pub fn collect(
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_official_or_browser(
        session,
        context,
        ProviderId::Cursor,
        APP_SOURCE,
        || {
            let cookie_header = app::cookie_header(context)
                .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, APP_SOURCE))?;
            collect_with_cookie(&cookie_header, context, APP_SOURCE)
        },
        || {
            let cookie_header = context
                .browser_session(ProviderId::Cursor)
                .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE))?;
            collect_with_cookie(cookie_header, context, WEB_SOURCE)
        },
    )
}

fn collect_with_cookie(
    cookie_header: &str,
    context: &CollectionContext,
    source: &'static str,
) -> Result<QuotaSnapshot, ProviderError> {
    let identity = validate_at(cookie_header, context, ORIGIN, source)?;
    let client = HttpClient::new()?;
    let user_agent = context.user_agent();
    let headers = [
        ("Accept", "application/json"),
        ("Cookie", cookie_header),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, summary) =
        client.get_json_session(&format!("{ORIGIN}/api/usage-summary"), &headers, source)?;
    let extras = optional_usage(
        &summary,
        cookie_header,
        identity.subject.as_deref(),
        context,
        source,
    );
    let windows = quota_windows(&summary, &extras, source)?;
    Ok(QuotaSnapshot {
        provider: ProviderId::Cursor,
        account: QuotaAccount {
            fingerprint: identity.session.account_fingerprint,
            fingerprint_scope: "global",
            label: identity.session.account_label,
            plan: bounded_identity(summary.get("membershipType"), 64),
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

/// A best-effort dashboard payload alongside `/api/usage-summary`. Absent when
/// the account cannot use it or the call fails; neither fails the refresh.
#[derive(Default)]
enum OptionalUsage {
    /// `GET /api/usage?user=<sub>`: request counters for legacy request-based plans.
    Requests(Value),
    /// `POST /api/dashboard/get-sand-usage-status`: the weekly Grok Bot allowance.
    GrokBot(Value),
    #[default]
    None,
}

/// Fetches whichever optional payload this account can actually show. The two are
/// mutually exclusive in [`quota_windows`] — a legacy request quota replaces the
/// token-based windows that Grok Bot accompanies — so only one call is made, and
/// the summary already says which plan shape this is.
fn optional_usage(
    summary: &Value,
    cookie_header: &str,
    subject: Option<&str>,
    context: &CollectionContext,
    source: &'static str,
) -> OptionalUsage {
    if context.cancelled() {
        return OptionalUsage::None;
    }
    let Ok(client) = HttpClient::with_timeout(OPTIONAL_TIMEOUT) else {
        return OptionalUsage::None;
    };
    let user_agent = context.user_agent();
    let headers = [
        ("Accept", "application/json"),
        ("Cookie", cookie_header),
        ("Origin", ORIGIN),
        ("User-Agent", user_agent.as_str()),
    ];
    if has_token_based_plan(summary) {
        return client
            .post_json_session(
                &format!("{ORIGIN}/api/dashboard/get-sand-usage-status"),
                &headers,
                &Value::Object(Default::default()),
                source,
            )
            .ok()
            .map(|(_, value)| OptionalUsage::GrokBot(value))
            .unwrap_or_default();
    }
    subject
        .and_then(|subject| {
            let url = format!("{ORIGIN}/api/usage?user={}", url_encode(subject));
            client
                .get_json_session(&url, &headers, source)
                .ok()
                .map(|(_, value)| OptionalUsage::Requests(value))
        })
        .unwrap_or_default()
}

/// Usage-based pricing reports the Cursor / Other Models percentages; an account
/// that does not cannot be on one, and may still carry a legacy request quota.
fn has_token_based_plan(summary: &Value) -> bool {
    obj_get(summary, "individualUsage")
        .and_then(|value| obj_get(value, "plan"))
        .filter(|plan| plan.get("enabled").and_then(Value::as_bool) != Some(false))
        .is_some_and(|plan| {
            number(plan.get("autoPercentUsed")).is_some()
                || number(plan.get("apiPercentUsed")).is_some()
        })
}

fn quota_windows(
    summary: &Value,
    extras: &OptionalUsage,
    source: &'static str,
) -> Result<Vec<QuotaWindow>, ProviderError> {
    let reset = parse_date(summary.get("billingCycleEnd")).map(unix_seconds_to_iso);
    let individual = obj_get(summary, "individualUsage");
    let team = obj_get(summary, "teamUsage");
    let mut windows = Vec::new();
    // A legacy request quota replaces the token-based Cursor/Other Models split and
    // the weekly Grok Bot bar, which only make sense next to usage-based pricing.
    let legacy = match extras {
        OptionalUsage::Requests(value) => request_window(value, reset.clone()),
        _ => None,
    };
    if let Some(window) = legacy {
        windows.push(window);
    } else {
        if let Some(plan) = individual.and_then(|value| obj_get(value, "plan")) {
            windows.extend(included_windows(plan, reset.clone()));
        }
        if let OptionalUsage::GrokBot(value) = extras
            && let Some(window) = grok_bot_window(value)
        {
            windows.push(window);
        }
    }
    if windows.is_empty()
        && let Some(overall) = individual.and_then(|value| obj_get(value, "overall"))
        && let Some(window) = money_window("individual", "Individual", overall, reset.clone())
    {
        windows.push(window);
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
        return Err(ProviderError::new(ErrorCategory::Error, source));
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

/// `/api/usage` `gpt-4`: `maxRequestUsage` present and positive marks a legacy
/// request-based plan; `numRequestsTotal` is preferred over `numRequests`.
fn request_window(value: &Value, resets_at: Option<String>) -> Option<QuotaWindow> {
    let model = obj_get(value, "gpt-4")?;
    let limit = number(model.get("maxRequestUsage")).filter(|limit| *limit > 0.0)?;
    let used = number(model.get("numRequestsTotal"))
        .or_else(|| number(model.get("numRequests")))
        .filter(|used| *used >= 0.0)?;
    Some(QuotaWindow {
        id: "requests".to_owned(),
        title: "Requests".to_owned(),
        used_percent: clamp_percent(used / limit * 100.0),
        resets_at,
        duration_seconds: None,
        remaining_value: Some((limit - used).max(0.0)),
        limit_value: Some(limit),
        value_unit: Some("count"),
    })
}

/// `get-sand-usage-status`: the weekly Grok Bot allowance, only for accounts with
/// a non-zero included limit.
fn grok_bot_window(value: &Value) -> Option<QuotaWindow> {
    if value
        .get("hasNonZeroIncludedLimit")
        .and_then(Value::as_bool)
        != Some(true)
    {
        return None;
    }
    let used = number(value.get("usagePercent"))?;
    let start = parse_date(value.get("currentPeriodStart"));
    let end = parse_date(value.get("nextResetTimestampUtc"));
    Some(QuotaWindow {
        id: "grok_bot".to_owned(),
        title: "Grok Bot".to_owned(),
        used_percent: clamp_percent(used),
        resets_at: end.map(unix_seconds_to_iso),
        duration_seconds: super::common::duration_seconds(start, end),
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    })
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
    use super::super::common::BROWSER_SESSION_SOURCE;
    use super::*;

    #[test]
    fn cursor_is_an_account_sync_catalog_provider() {
        assert!(ProviderId::ALL.contains(&ProviderId::Cursor));
        assert!(ProviderId::Cursor.metadata().account_sync);
        assert!(ProviderId::Cursor.syncs_to_account());
        assert_eq!(
            ProviderId::Cursor
                .metadata()
                .browser_session
                .map(|session| session.exclusive),
            Some(true)
        );
    }

    #[test]
    fn a_stored_session_is_discovered_only_without_a_usable_app_session() {
        let mut context = CollectionContext {
            home_directory: std::path::PathBuf::from("/tmp/quota-cursor-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: None,
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        };
        assert!(discover(&context).is_empty());
        context
            .browser_sessions
            .insert(ProviderId::Cursor, "wos-session=stored".to_owned());
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].credential_source, BROWSER_SESSION_SOURCE);
    }

    /// A cancelled refresh must not start a request for either rung, and whichever rung it was
    /// answers under its own name: an app session a reader has to renew in Cursor.app is not a
    /// browser session they re-add here.
    #[test]
    fn a_cancelled_refresh_reads_neither_rung_and_each_answers_for_itself() {
        let mut context = CollectionContext {
            cancel: Some(std::sync::Arc::new(std::sync::atomic::AtomicBool::new(
                true,
            ))),
            ..CollectionContext::default()
        };
        context
            .browser_sessions
            .insert(ProviderId::Cursor, "wos-session=stored".to_owned());
        let session = |credential_source: &str| ProviderSession {
            provider: ProviderId::Cursor,
            credential_source: credential_source.to_owned(),
        };

        let app = collect(&session(app::SOURCE), &context).expect_err("cancelled");
        assert_eq!(app.source_id, APP_SOURCE);

        let web = collect(&session(BROWSER_SESSION_SOURCE), &context).expect_err("cancelled");
        assert_eq!(web.category, ErrorCategory::Unavailable);
        assert_eq!(web.source_id, WEB_SOURCE);
    }

    #[test]
    fn identity_is_stable_and_redacted() {
        let value = serde_json::json!({"sub":"user-secret", "email":"Ada@Example.com"});
        let identity =
            identity_from_response(&value, "wos-session=secret", WEB_SOURCE).expect("identity");
        assert_eq!(identity.subject.as_deref(), Some("user-secret"));
        let session = identity.session;
        assert_eq!(session.account_label.as_deref(), Some("Ad***@example.com"));
        assert!(!session.account_fingerprint.contains("user-secret"));
        let wire = serde_json::to_string(&session.account_fingerprint).expect("wire");
        assert!(!wire.contains("Ada"));
    }

    #[test]
    fn usage_summary_maps_official_model_groups_and_on_demand_money() {
        let windows = quota_windows(
            &serde_json::json!({
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
            }),
            &OptionalUsage::default(),
            WEB_SOURCE,
        )
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
            quota_windows(
                &serde_json::json!({"individualUsage":{"plan":{"used":1}}}),
                &OptionalUsage::default(),
                WEB_SOURCE
            )
            .is_err()
        );
    }

    fn token_summary() -> Value {
        serde_json::json!({
            "billingCycleEnd": "2026-09-01T00:00:00Z",
            "individualUsage": {
                "plan": {"enabled": true, "autoPercentUsed": 12.5, "apiPercentUsed": 3.0},
                "onDemand": {"enabled": true, "used": 100, "limit": 1000}
            }
        })
    }

    #[test]
    fn grok_bot_weekly_allowance_follows_the_included_windows() {
        let extras = OptionalUsage::GrokBot(serde_json::json!({
            "currentPeriodStart": "2026-08-18T00:00:00.000Z",
            "nextResetTimestampUtc": "2026-08-25T00:00:00.000Z",
            "usagePercent": 42.5,
            "hasAvailableUsage": true,
            "hasNonZeroIncludedLimit": true
        }));
        let windows = quota_windows(&token_summary(), &extras, WEB_SOURCE).expect("windows");
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["cursor_models", "other_models", "grok_bot", "on_demand"]
        );
        let bot = &windows[2];
        assert_eq!(bot.title, "Grok Bot");
        assert_eq!(bot.used_percent, 42.5);
        assert_eq!(bot.resets_at.as_deref(), Some("2026-08-25T00:00:00Z"));
        assert_eq!(bot.duration_seconds, Some(604_800));

        let no_allowance = OptionalUsage::GrokBot(
            serde_json::json!({"usagePercent": 10, "hasNonZeroIncludedLimit": false}),
        );
        assert!(
            quota_windows(&token_summary(), &no_allowance, WEB_SOURCE)
                .expect("windows")
                .iter()
                .all(|window| window.id != "grok_bot")
        );
    }

    #[test]
    fn legacy_request_plan_replaces_token_windows_and_grok_bot() {
        let extras = OptionalUsage::Requests(serde_json::json!({
            "gpt-4": {"numRequests": 120, "numRequestsTotal": 130, "maxRequestUsage": 500},
            "startOfMonth": "2026-08-01T00:00:00Z"
        }));
        let windows = quota_windows(&token_summary(), &extras, WEB_SOURCE).expect("windows");
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["requests", "on_demand"]
        );
        let requests = &windows[0];
        assert_eq!(requests.title, "Requests");
        assert_eq!(requests.used_percent, 26.0);
        assert_eq!(requests.remaining_value, Some(370.0));
        assert_eq!(requests.limit_value, Some(500.0));
        assert_eq!(requests.value_unit, Some("count"));
        assert_eq!(requests.resets_at.as_deref(), Some("2026-09-01T00:00:00Z"));

        // Usage-based accounts answer the endpoint without a request cap.
        let unlimited = OptionalUsage::Requests(
            serde_json::json!({"gpt-4": {"numRequests": 3, "maxRequestUsage": null}}),
        );
        assert_eq!(
            quota_windows(&token_summary(), &unlimited, WEB_SOURCE).expect("windows")[0].id,
            "cursor_models"
        );
    }

    #[test]
    fn plan_shape_picks_the_single_optional_call() {
        // Usage-based pricing reports the model percentages, so only Grok Bot can apply.
        assert!(has_token_based_plan(&token_summary()));
        // A legacy request plan reports neither, and a disabled plan is not usage-based.
        assert!(!has_token_based_plan(&serde_json::json!({
            "individualUsage": {"onDemand": {"enabled": true, "used": 1, "limit": 2}}
        })));
        assert!(!has_token_based_plan(&serde_json::json!({
            "individualUsage": {"plan": {"enabled": false, "autoPercentUsed": 5.0}}
        })));
        assert!(!has_token_based_plan(&serde_json::json!({})));
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
            assert!(identity_from_response(&value, "wos-session=secret", WEB_SOURCE).is_err());
        }
    }

    #[test]
    fn validation_maps_provider_auth_status_without_leaking_body() {
        for status in [401, 403] {
            let (address, server) = crate::providers::common::serve_responses(vec![(
                status,
                b"provider-secret-response".to_vec(),
            )]);
            let error = validate_at(
                "wos-session=cookie-secret",
                &CollectionContext::default(),
                &format!("http://{address}"),
                WEB_SOURCE,
            )
            .expect_err("auth failure");
            assert_eq!(error.category, ErrorCategory::AuthRequired);
            assert!(!error.to_string().contains("provider-secret-response"));
            assert!(!error.to_string().contains("cookie-secret"));
            server.join().expect("server");
        }
    }
}
