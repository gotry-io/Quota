use crate::catalog::ProviderId;
use serde_json::Value;
use std::thread;

use super::common::{
    ApiKeyCredentials, CollectionContext, ErrorCategory, HttpClient, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, api_key_identity, clamp_percent,
    number, obj_get, obj_get_any, parse_date, resolve_api_key, string, url_encode,
};

pub const SOURCE: &str = "litellm_budget_api";

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    resolve(context)
        .ok()
        .map(|credentials| {
            vec![ProviderSession {
                provider: ProviderId::LiteLlm,
                credential_source: credentials.source,
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
    let root = credentials
        .base_url
        .trim_end_matches('/')
        .trim_end_matches("/v1")
        .trim_end_matches('/')
        .to_owned();
    let client = HttpClient::new()?;
    let auth = format!("Bearer {}", credentials.api_key);
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", auth.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let key_json = client
        .get_json(&format!("{root}/key/info"), &headers, SOURCE)?
        .1;
    let key_info =
        map_key_info(&key_json).ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    if key_info.user_id.is_none() && key_info.team_id.is_none() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let user_id = key_info.user_id.clone();
    let team_id = key_info.team_id.clone();
    let (personal, team) = thread::scope(|scope| {
        let personal = user_id.as_ref().map(|id| {
            scope.spawn(|| {
                get_budget(
                    &client,
                    &root,
                    &headers,
                    &format!("{root}/user/info?user_id={}", url_encode(id)),
                    None,
                    false,
                )
            })
        });
        let team = team_id.as_ref().map(|id| {
            scope.spawn(|| {
                get_budget(
                    &client,
                    &root,
                    &headers,
                    &format!("{root}/team/info?team_id={}", url_encode(id)),
                    Some(id),
                    user_id.is_none(),
                )
            })
        });
        let personal = personal
            .map(|handle| handle.join().unwrap_or(Ok(None)))
            .transpose()?
            .flatten();
        let team = team
            .map(|handle| handle.join().unwrap_or(Ok(None)))
            .transpose()?
            .flatten();
        Ok::<_, ProviderError>((personal, team))
    })?;
    let windows = map_windows(personal.as_ref(), team.as_ref());
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
    }
    let (fingerprint, scope) = api_key_identity("litellm", &credentials.api_key);
    Ok(QuotaSnapshot {
        provider: ProviderId::LiteLlm,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some(credentials.label),
            plan: Some(key_info.key_name.unwrap_or_else(|| "LiteLLM".to_owned())),
        },
        windows,
        status: "available",
        observed_at: context.observed_at(),
    })
}

fn resolve(context: &CollectionContext) -> Result<ApiKeyCredentials, ProviderError> {
    resolve_api_key(context, ProviderId::LiteLlm)
}

#[derive(Clone, Debug, Default)]
struct KeyInfo {
    user_id: Option<String>,
    team_id: Option<String>,
    key_name: Option<String>,
}

#[derive(Clone, Debug)]
struct Budget {
    spend: f64,
    limit: Option<f64>,
    reset: Option<String>,
    label: String,
}

fn map_key_info(value: &Value) -> Option<KeyInfo> {
    let info = obj_get(value, "info")
        .or_else(|| obj_get(value, "data"))
        .unwrap_or(value);
    if let Some(nested) = obj_get(info, "key").or_else(|| obj_get(info, "key_info"))
        && obj_get_any(
            info,
            &[
                "user_id",
                "userId",
                "team_id",
                "teamId",
                "spend",
                "spend_usd",
            ],
        )
        .is_none()
    {
        return map_key_info(nested);
    }
    Some(KeyInfo {
        user_id: obj_get_any(info, &["user_id", "userId"]).and_then(|v| string(Some(v))),
        team_id: obj_get_any(info, &["team_id", "teamId"]).and_then(|v| string(Some(v))),
        key_name: obj_get_any(info, &["key_name", "keyName", "key_alias"])
            .and_then(|v| string(Some(v))),
    })
}

fn get_budget(
    client: &HttpClient,
    _root: &str,
    headers: &[(&str, &str)],
    url: &str,
    team_id: Option<&str>,
    required: bool,
) -> Result<Option<Budget>, ProviderError> {
    match client.get_json(url, headers, SOURCE) {
        Ok((_, value)) => Ok(map_budget(
            &value,
            if url.contains("/team/") {
                "Team"
            } else {
                "Personal"
            },
            team_id,
            url.contains("/team/"),
        )),
        Err(error)
            if !required
                && matches!(
                    error.category,
                    ErrorCategory::Unavailable | ErrorCategory::Unsupported
                ) =>
        {
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

fn map_budget(
    value: &Value,
    fallback_label: &str,
    team_id: Option<&str>,
    team: bool,
) -> Option<Budget> {
    let object = if team {
        obj_get(value, "team_info")
            .or_else(|| obj_get(value, "team"))
            .or_else(|| obj_get(value, "data"))
            .or_else(|| find_team(value, team_id?))
            .unwrap_or(value)
    } else {
        obj_get(value, "user_info")
            .or_else(|| obj_get(value, "user"))
            .or_else(|| obj_get(value, "data"))
            .unwrap_or(value)
    };
    let spend = obj_get_any(
        object,
        if team {
            &["spend", "team_spend", "spend_usd"]
        } else {
            &["spend", "user_spend", "spend_usd"]
        },
    )
    .and_then(|v| number(Some(v)))
    .unwrap_or(0.0);
    let limit = obj_get_any(
        object,
        if team {
            &["max_budget", "team_max_budget", "budget"]
        } else {
            &["max_budget", "user_max_budget", "budget"]
        },
    )
    .and_then(|v| number(Some(v)))
    .filter(|value| *value > 0.0);
    let reset = obj_get_any(object, &["budget_reset_at", "budget_duration_reset_at"])
        .and_then(|v| parse_date(Some(v)).map(super::common::unix_seconds_to_iso));
    let label = if team {
        obj_get_any(object, &["team_alias", "alias", "name"])
            .and_then(|v| string(Some(v)))
            .map(|name| format!("Team {name}"))
            .unwrap_or_else(|| "Team".to_owned())
    } else {
        fallback_label.to_owned()
    };
    Some(Budget {
        spend,
        limit,
        reset,
        label,
    })
}

fn find_team<'a>(value: &'a Value, team_id: &str) -> Option<&'a Value> {
    let teams = obj_get(value, "teams").or_else(|| obj_get(value, "team_list"))?;
    teams.as_array()?.iter().find(|entry| {
        obj_get_any(entry, &["team_id", "id"])
            .and_then(|value| string(Some(value)))
            .as_deref()
            == Some(team_id)
    })
}

fn map_windows(personal: Option<&Budget>, team: Option<&Budget>) -> Vec<QuotaWindow> {
    [
        personal.map(|budget| ("personal", budget)),
        team.map(|budget| ("team", budget)),
    ]
    .into_iter()
    .flatten()
    .filter_map(|(id, budget)| {
        let limit = budget.limit?;
        let remaining = (limit - budget.spend).max(0.0);
        Some(QuotaWindow {
            id: id.to_owned(),
            title: format!("{} budget", budget.label),
            used_percent: clamp_percent(budget.spend / limit * 100.0),
            resets_at: budget.reset.clone(),
            duration_seconds: None,
            remaining_value: Some(remaining),
            limit_value: Some(limit),
            value_unit: Some("usd"),
        })
    })
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn does_not_turn_unbounded_spend_into_quota() {
        let budget = map_budget(
            &serde_json::json!({"user_info": {"spend": 12.5}}),
            "Personal",
            None,
            false,
        )
        .unwrap();
        assert!(map_windows(Some(&budget), None).is_empty());
    }

    #[test]
    fn maps_nested_key_info_and_team_list_variants() {
        let key = map_key_info(&serde_json::json!({
            "info": {"key": {"user_id": "user-1", "team_id": "team-1", "key_alias": "prod"}}
        }))
        .unwrap();
        assert_eq!(key.user_id.as_deref(), Some("user-1"));
        assert_eq!(key.team_id.as_deref(), Some("team-1"));
        assert_eq!(key.key_name.as_deref(), Some("prod"));

        let team = map_budget(
            &serde_json::json!({"teams": [{"id": "team-1", "alias": "eng", "spend": 5, "max_budget": 200}]}),
            "Team",
            Some("team-1"),
            true,
        ).unwrap();
        assert_eq!(team.label, "Team eng");
        let windows = map_windows(None, Some(&team));
        assert_eq!(windows[0].used_percent, 2.5);
    }
}
