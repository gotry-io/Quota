use crate::catalog::ProviderId;
use serde_json::Value;

use super::common::{
    ApiKeyCredentials, CollectionContext, ErrorCategory, HttpClient, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, api_key_identity, number,
    resolve_api_key, string,
};

pub const SOURCE: &str = "deepseek_balance_api";

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    resolve(context)
        .ok()
        .map(|credentials| {
            vec![ProviderSession {
                provider: ProviderId::DeepSeek,
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
    let url = format!("{}/user/balance", credentials.base_url);
    let auth = format!("Bearer {}", credentials.api_key);
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", auth.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, value) = client.get_json(&url, &headers, SOURCE)?;
    let balances =
        map_balances(&value).ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    let windows = map_windows(&balances);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let (fingerprint, scope) = api_key_identity("deepseek", &credentials.api_key);
    Ok(QuotaSnapshot {
        provider: ProviderId::DeepSeek,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some(credentials.label),
            plan: Some("Credits".to_owned()),
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn resolve(context: &CollectionContext) -> Result<ApiKeyCredentials, ProviderError> {
    resolve_api_key(context, ProviderId::DeepSeek, SOURCE)
}

#[derive(Clone, Debug)]
struct Balance {
    currency: String,
    total: f64,
}

fn map_balances(value: &Value) -> Option<Vec<Balance>> {
    let root = value.as_object()?;
    let entries = root
        .get("balance_infos")
        .or_else(|| root.get("balanceInfos"))?
        .as_array()?;
    let mut balances = Vec::new();
    for entry in entries {
        let Some(object) = entry.as_object() else {
            continue;
        };
        let currency = string(object.get("currency"))
            .unwrap_or_else(|| "USD".to_owned())
            .to_ascii_uppercase();
        let Some(total) = super::common::obj_get_any(entry, &["total_balance", "totalBalance"])
            .and_then(|value| number(Some(value)))
        else {
            continue;
        };
        if total.is_finite() && total >= 0.0 {
            balances.push(Balance { currency, total });
        }
    }
    (!balances.is_empty()).then_some(balances)
}

fn map_windows(balances: &[Balance]) -> Vec<QuotaWindow> {
    let positive: Vec<&Balance> = balances
        .iter()
        .filter(|balance| balance.total > 0.0)
        .collect();
    let selected: Vec<&Balance> = if positive.is_empty() {
        vec![
            balances
                .iter()
                .find(|balance| balance.currency == "USD")
                .unwrap_or(&balances[0]),
        ]
    } else {
        positive
    };
    let mut selected = selected;
    selected.sort_by(|a, b| match (a.currency == "USD", b.currency == "USD") {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.currency.cmp(&b.currency),
    });
    selected
        .into_iter()
        .map(|balance| {
            let usd = balance.currency == "USD";
            QuotaWindow {
                id: if usd {
                    "balance".to_owned()
                } else {
                    format!("balance_{}", balance.currency.to_ascii_lowercase())
                },
                title: if usd {
                    "Balance (USD)".to_owned()
                } else {
                    format!("Balance ({})", balance.currency)
                },
                used_percent: 0.0,
                resets_at: None,
                duration_seconds: None,
                primary_cadence: None,
                remaining_value: Some(balance.total),
                limit_value: None,
                value_unit: usd.then_some("usd"),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_positive_non_usd_balance_when_usd_is_zero() {
        let balances = map_balances(&serde_json::json!({"balance_infos": [
            {"currency": "CNY", "total_balance": "3.96"},
            {"currency": "USD", "total_balance": "0"}
        ]}))
        .unwrap();
        let windows = map_windows(&balances);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "balance_cny");
        assert_eq!(windows[0].remaining_value, Some(3.96));
    }

    #[test]
    fn accepts_camel_case_and_keeps_one_zero_balance_row() {
        let balances = map_balances(&serde_json::json!({
            "balanceInfos": [
                {"currency": "USD", "totalBalance": "0"},
                {"currency": "CNY", "totalBalance": 0}
            ]
        }))
        .unwrap();
        let windows = map_windows(&balances);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "balance");
        assert_eq!(windows[0].remaining_value, Some(0.0));
        assert!(map_balances(&serde_json::json!({"balance_infos": []})).is_none());
    }
}
