use crate::catalog::ProviderId;
use serde_json::Value;
use std::thread;

use super::common::{
    ApiKeyCredentials, CollectionContext, ErrorCategory, HttpClient, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, clamp_percent, number, obj_get,
    resolve_api_key,
};

pub const SOURCE: &str = "openrouter_api";

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    resolve(context)
        .ok()
        .map(|credentials| {
            vec![ProviderSession {
                provider: ProviderId::OpenRouter,
                credential_source: credentials.source,
                cookie_header: None,
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
    let credentials = resolve(context)?;
    let client = HttpClient::new()?;
    let api_key = credentials.api_key.clone();
    let user_agent = context.user_agent();
    let client_name = context.client_name.clone();
    let credits_url = format!("{}/credits", credentials.base_url);
    let key_url = format!("{}/key", credentials.base_url);
    // These are independent meters. Keep both requests concurrent so a slow key endpoint does not
    // delay a usable credits result.
    let (credits_result, key_result) = thread::scope(|scope| {
        let credits = scope.spawn(|| {
            get_meter(
                &client,
                &credits_url,
                &api_key,
                &user_agent,
                &client_name,
                Meter::Credits,
            )
        });
        let key = scope.spawn(|| {
            get_meter(
                &client,
                &key_url,
                &api_key,
                &user_agent,
                &client_name,
                Meter::Key,
            )
        });
        (
            credits
                .join()
                .unwrap_or_else(|_| Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE))),
            key.join()
                .unwrap_or_else(|_| Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE))),
        )
    });
    let mut credits = None;
    let mut key = None;
    let mut unavailable = true;
    let mut malformed = false;
    for result in [credits_result, key_result] {
        match result {
            Ok((kind, value)) => {
                unavailable = false;
                match kind {
                    Meter::Credits => credits = map_credits(&value),
                    Meter::Key => key = map_key(&value),
                }
                if (kind == Meter::Credits && credits.is_none())
                    || (kind == Meter::Key && key.is_none())
                {
                    malformed = true;
                }
            }
            Err(error) if error.category == ErrorCategory::AuthRequired => return Err(error),
            Err(error) => {
                unavailable &= error.category == ErrorCategory::Unavailable;
                if error.category != ErrorCategory::Unavailable {
                    malformed = true;
                }
            }
        }
    }
    let windows = map_windows(credits.as_ref(), key.as_ref());
    if windows.is_empty() {
        return Err(ProviderError::new(
            if unavailable && !malformed {
                ErrorCategory::Unavailable
            } else {
                ErrorCategory::Error
            },
            SOURCE,
        ));
    }
    Ok(snapshot(&credentials, windows, &context.observed_at()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Meter {
    Credits,
    Key,
}

fn get_meter(
    client: &HttpClient,
    url: &str,
    api_key: &str,
    user_agent: &str,
    client_name: &str,
    meter: Meter,
) -> Result<(Meter, Value), ProviderError> {
    let headers = [
        ("Authorization", format!("Bearer {api_key}")),
        ("Accept", "application/json".to_owned()),
        ("User-Agent", user_agent.to_owned()),
        ("X-Title", client_name.to_owned()),
    ];
    let refs = headers
        .iter()
        .map(|(name, value)| (*name, value.as_str()))
        .collect::<Vec<_>>();
    client
        .get_json(url, &refs, SOURCE)
        .map(|(_, value)| (meter, value))
}

fn resolve(context: &CollectionContext) -> Result<ApiKeyCredentials, ProviderError> {
    resolve_api_key(context, ProviderId::OpenRouter, SOURCE)
}

#[derive(Clone, Copy, Debug)]
struct Credits {
    total: f64,
    usage: f64,
}

#[derive(Clone, Debug, Default)]
struct Key {
    limit: Option<f64>,
    remaining: Option<f64>,
    reset: Option<String>,
    usage: Option<f64>,
    daily: Option<f64>,
    weekly: Option<f64>,
    monthly: Option<f64>,
}

fn map_credits(value: &Value) -> Option<Credits> {
    let data = obj_get(value, "data")?;
    let total = number(obj_get(data, "total_credits"))?;
    let usage = number(obj_get(data, "total_usage"))?;
    (total.is_finite() && usage.is_finite() && total >= 0.0).then_some(Credits { total, usage })
}

fn map_key(value: &Value) -> Option<Key> {
    let data = obj_get(value, "data")?;
    Some(Key {
        limit: number(obj_get(data, "limit")),
        remaining: number(obj_get(data, "limit_remaining")),
        reset: super::common::string(obj_get(data, "limit_reset")).map(|v| v.to_ascii_lowercase()),
        usage: number(obj_get(data, "usage")),
        daily: number(obj_get(data, "usage_daily")),
        weekly: number(obj_get(data, "usage_weekly")),
        monthly: number(obj_get(data, "usage_monthly")),
    })
}

fn map_windows(credits: Option<&Credits>, key: Option<&Key>) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    if let Some(key) = key
        && let Some(limit) = key.limit.filter(|value| *value > 0.0)
        && let Some(used) = key_used(key, limit).filter(|value| value.is_finite() && *value >= 0.0)
    {
        let remaining = (limit - used).max(0.0);
        let (id, title) = match key.reset.as_deref() {
            Some("daily") => ("key_daily", "API key daily"),
            Some("weekly") => ("key_weekly", "API key weekly"),
            Some("monthly") => ("key_monthly", "API key monthly"),
            _ => ("key_budget", "API key budget"),
        };
        windows.push(QuotaWindow {
            id: id.to_owned(),
            title: title.to_owned(),
            used_percent: clamp_percent(used / limit * 100.0),
            resets_at: None,
            duration_seconds: None,
            remaining_value: Some(remaining),
            limit_value: Some(limit),
            value_unit: Some("usd"),
        });
    }
    if let Some(credits) = credits.filter(|value| value.total > 0.0) {
        windows.push(QuotaWindow {
            id: "credits".to_owned(),
            title: "Balance (USD)".to_owned(),
            used_percent: 0.0,
            resets_at: None,
            duration_seconds: None,
            remaining_value: Some((credits.total - credits.usage).max(0.0)),
            limit_value: None,
            value_unit: Some("usd"),
        });
    }
    windows
}

fn key_used(key: &Key, limit: f64) -> Option<f64> {
    if let Some(remaining) = key.remaining.filter(|value| value.is_finite()) {
        return Some(limit - remaining.clamp(0.0, limit));
    }
    match key.reset.as_deref() {
        Some("daily") => key.daily,
        Some("weekly") => key.weekly,
        Some("monthly") => key.monthly,
        _ => key.usage,
    }
}

fn snapshot(
    credentials: &ApiKeyCredentials,
    windows: Vec<QuotaWindow>,
    observed_at: &str,
) -> QuotaSnapshot {
    let (fingerprint, scope) = super::common::api_key_identity("openrouter", &credentials.api_key);
    QuotaSnapshot {
        provider: ProviderId::OpenRouter,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some(credentials.label.clone()),
            plan: Some("Credits".to_owned()),
        },
        windows,
        status: "available",
        observed_at: observed_at.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../../provider/fixtures/quota-responses.json");

    #[test]
    fn maps_key_budget_before_credits() {
        let credits =
            map_credits(&serde_json::json!({"data": {"total_credits": 100, "total_usage": 40}}));
        let key = map_key(
            &serde_json::json!({"data": {"limit": 50, "limit_remaining": 30, "limit_reset": "daily"}}),
        );
        let windows = map_windows(credits.as_ref(), key.as_ref());
        assert_eq!(windows[0].id, "key_daily");
        assert_eq!(windows[0].used_percent, 40.0);
        assert_eq!(windows[1].id, "credits");
    }

    #[test]
    fn uses_period_specific_usage_and_keeps_zero_credit_accounts_visible() {
        let credits =
            map_credits(&serde_json::json!({"data": {"total_credits": 0, "total_usage": 0}}));
        let key = map_key(&serde_json::json!({
            "data": {"limit": 25, "usage": 99, "usage_daily": 5, "limit_reset": "daily"}
        }));
        let windows = map_windows(credits.as_ref(), key.as_ref());
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "key_daily");
        assert_eq!(windows[0].used_percent, 20.0);
        assert!(map_credits(&serde_json::json!({"data": {"total_credits": "bad"}})).is_none());
    }

    #[test]
    fn maps_provider_response_fixture() {
        let root: Value = serde_json::from_str(FIXTURE).expect("provider quota fixture");
        let openrouter = root.get("openrouter").expect("OpenRouter fixture");
        let credits = map_credits(openrouter.get("credits").expect("credits response"));
        let key = map_key(openrouter.get("key").expect("key response"));
        let windows = map_windows(credits.as_ref(), key.as_ref());
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].id, "key_daily");
        assert_eq!(windows[0].used_percent, 40.0);
        assert_eq!(windows[1].id, "credits");
        assert_eq!(windows[1].title, "Balance (USD)");
        assert_eq!(windows[1].remaining_value, Some(60.0));
    }
}
