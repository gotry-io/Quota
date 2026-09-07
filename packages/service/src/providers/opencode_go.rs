use crate::catalog::ProviderId;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::path::PathBuf;

use super::common::{
    Cadence, CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError,
    ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow, api_key_identity, clamp_percent,
    number, obj_get, obj_get_any, parse_date, read_bounded_file, resolve_api_key, string,
    unix_seconds_to_iso,
};

pub const SOURCE: &str = "opencode_go_usage_api";
pub const LOCAL_SOURCE: &str = "opencode_go_local";
const USAGE_PATH: &str = "/usage";
const SESSION_LIMIT_USD: f64 = 12.0;
const WEEKLY_LIMIT_USD: f64 = 30.0;
const MONTHLY_LIMIT_USD: f64 = 60.0;
const FIVE_HOURS_MS: i64 = 5 * 60 * 60 * 1000;
const WEEK_MS: i64 = 7 * 24 * 60 * 60 * 1000;

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    if local_auth_key(context).is_some() {
        return vec![session(
            local_auth_path(context).to_string_lossy().into_owned(),
        )];
    }
    resolve_api_key(context, ProviderId::OpencodeGo, SOURCE)
        .ok()
        .map(|credentials| vec![session(credentials.source)])
        .unwrap_or_default()
}

pub fn is_local_credential_source(source: &str) -> bool {
    source.ends_with("auth.json") || source.contains("/opencode/")
}

pub fn collect(
    _session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_at(context, None)
}

fn collect_at(
    context: &CollectionContext,
    usage_url: Option<&str>,
) -> Result<QuotaSnapshot, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    match collect_local(context) {
        Ok(snapshot) => return Ok(snapshot),
        Err(error) if error.category == ErrorCategory::AuthRequired => {}
        Err(error) => return Err(error),
    }
    collect_api(context, usage_url)
}

fn session(credential_source: String) -> ProviderSession {
    ProviderSession {
        provider: ProviderId::OpencodeGo,
        credential_source,
        cookie_header: None,
    }
}

fn opencode_dir(context: &CollectionContext) -> PathBuf {
    context
        .env("XDG_DATA_HOME")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".local").join("share"))
        .join("opencode")
}

fn local_auth_path(context: &CollectionContext) -> PathBuf {
    opencode_dir(context).join("auth.json")
}

fn local_database_path(context: &CollectionContext) -> PathBuf {
    opencode_dir(context).join("opencode.db")
}

fn local_auth_key(context: &CollectionContext) -> Option<String> {
    let bytes = read_bounded_file(&local_auth_path(context), LOCAL_FILE_LIMIT)?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    let entry = obj_get(&value, "opencode-go")?;
    string(obj_get(entry, "key")).filter(|key| !key.is_empty())
}

fn collect_local(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let key = local_auth_key(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, LOCAL_SOURCE))?;
    let database = local_database_path(context);
    let rows = read_local_costs(&database)?;
    if rows.is_empty() {
        return Err(ProviderError::new(
            ErrorCategory::AuthRequired,
            LOCAL_SOURCE,
        ));
    }
    let now_ms = context.observed_unix().saturating_mul(1_000);
    let session_start = now_ms.saturating_sub(FIVE_HOURS_MS);
    let week_start = start_of_utc_week_ms(now_ms);
    let month_start = start_of_utc_month_ms(now_ms);
    let mut session_cost = 0.0;
    let mut weekly_cost = 0.0;
    let mut monthly_cost = 0.0;
    let mut oldest_session = None;
    for row in &rows {
        if row.created_ms >= session_start && row.created_ms < now_ms {
            session_cost += row.cost;
            if oldest_session.is_none_or(|oldest| row.created_ms < oldest) {
                oldest_session = Some(row.created_ms);
            }
        }
        if row.created_ms >= week_start && row.created_ms < now_ms {
            weekly_cost += row.cost;
        }
        if row.created_ms >= month_start && row.created_ms < now_ms {
            monthly_cost += row.cost;
        }
    }
    let session_reset = oldest_session
        .unwrap_or(now_ms)
        .saturating_add(FIVE_HOURS_MS);
    let week_end = week_start.saturating_add(WEEK_MS);
    let month_end = next_utc_month_ms(month_start);
    let windows = vec![
        usd_window(
            Cadence::FiveHour,
            session_cost,
            SESSION_LIMIT_USD,
            Some(session_reset),
        ),
        usd_window(
            Cadence::Weekly,
            weekly_cost,
            WEEKLY_LIMIT_USD,
            Some(week_end),
        ),
        usd_window(
            Cadence::Monthly,
            monthly_cost,
            MONTHLY_LIMIT_USD,
            Some(month_end),
        ),
    ];
    Ok(snapshot(&key, windows, context.observed_at()))
}

struct CostRow {
    created_ms: i64,
    cost: f64,
}

fn read_local_costs(path: &PathBuf) -> Result<Vec<CostRow>, ProviderError> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|_| ProviderError::new(ErrorCategory::AuthRequired, LOCAL_SOURCE))?;
    let mut statement = connection
        .prepare(
            r#"
SELECT
  CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER),
  CAST(json_extract(data, '$.cost') AS REAL)
FROM message
WHERE json_valid(data)
  AND json_extract(data, '$.providerID') = 'opencode-go'
  AND json_extract(data, '$.role') = 'assistant'
  AND json_type(data, '$.cost') IN ('integer', 'real')
"#,
        )
        .map_err(|_| ProviderError::new(ErrorCategory::Error, LOCAL_SOURCE))?;
    let rows = statement
        .query_map([], |row| {
            Ok(CostRow {
                created_ms: row.get(0)?,
                cost: row.get(1)?,
            })
        })
        .map_err(|_| ProviderError::new(ErrorCategory::Error, LOCAL_SOURCE))?;
    let mut costs = Vec::new();
    for row in rows {
        let row = row.map_err(|_| ProviderError::new(ErrorCategory::Error, LOCAL_SOURCE))?;
        if row.created_ms > 0 && row.cost.is_finite() && row.cost >= 0.0 {
            costs.push(row);
        }
    }
    Ok(costs)
}

fn collect_api(
    context: &CollectionContext,
    usage_url: Option<&str>,
) -> Result<QuotaSnapshot, ProviderError> {
    let credentials = resolve_api_key(context, ProviderId::OpencodeGo, SOURCE)?;
    let client = HttpClient::new()?;
    let url = usage_url
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{}{USAGE_PATH}", credentials.base_url.trim_end_matches('/')));
    let auth = format!("Bearer {}", credentials.api_key);
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", auth.as_str()),
        ("Accept", "application/json"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, value) = client.get_json(&url, &headers, SOURCE)?;
    let windows = map_api_windows(&value, context.observed_unix())
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, SOURCE))?;
    Ok(snapshot(
        &credentials.api_key,
        windows,
        context.observed_at(),
    ))
}

fn map_api_windows(value: &Value, now: i64) -> Option<Vec<QuotaWindow>> {
    let usage = obj_get(value, "usage").unwrap_or(value);
    let rolling = obj_get(usage, "rolling")
        .or_else(|| obj_get(usage, "rollingUsage"))
        .or_else(|| obj_get(value, "rolling"))?;
    let weekly = obj_get(usage, "weekly").or_else(|| obj_get(usage, "weeklyUsage"));
    let monthly = obj_get(usage, "monthly").or_else(|| obj_get(usage, "monthlyUsage"));
    let mut windows = Vec::new();
    windows.push(percent_window(
        Cadence::FiveHour,
        rolling,
        now,
        Some(5 * 3_600),
    )?);
    if let Some(weekly) = weekly
        && let Some(window) = percent_window(Cadence::Weekly, weekly, now, Some(7 * 86_400))
    {
        windows.push(window);
    }
    if let Some(monthly) = monthly
        && let Some(window) = percent_window(Cadence::Monthly, monthly, now, None)
    {
        windows.push(window);
    }
    Some(windows)
}

fn percent_window(
    cadence: Cadence,
    value: &Value,
    now: i64,
    duration_seconds: Option<u64>,
) -> Option<QuotaWindow> {
    let used_percent = percent_used(value)?;
    let remaining = number(obj_get_any(
        value,
        &["remaining", "remainingUsd", "remaining_usd", "balance"],
    ));
    let limit = number(obj_get_any(
        value,
        &["limit", "limitUsd", "limit_usd", "allowance"],
    ));
    Some(QuotaWindow {
        id: cadence.wire().to_owned(),
        title: cadence.title().to_owned(),
        used_percent: clamp_percent(used_percent),
        resets_at: reset_at(value, now),
        duration_seconds,
        primary_cadence: Some(cadence),
        remaining_value: remaining.filter(|value| *value >= 0.0),
        limit_value: limit.filter(|value| *value > 0.0),
        value_unit: remaining.or(limit).map(|_| "usd"),
    })
}

fn percent_used(value: &Value) -> Option<f64> {
    number(obj_get_any(
        value,
        &[
            "usagePercent",
            "usedPercent",
            "percentUsed",
            "percent",
            "usage_percent",
            "used_percent",
        ],
    ))
    .or_else(|| {
        number(obj_get_any(
            value,
            &["remainingPercent", "remaining_percent", "percentRemaining"],
        ))
        .map(|remaining| 100.0 - remaining)
    })
}

fn reset_at(value: &Value, now: i64) -> Option<String> {
    if let Some(seconds) = obj_get_any(
        value,
        &[
            "resetAt",
            "resetsAt",
            "reset_at",
            "resets_at",
            "renewAt",
            "renew_at",
        ],
    )
    .and_then(|value| parse_date(Some(value)))
    {
        return Some(unix_seconds_to_iso(seconds));
    }
    let reset_in = number(obj_get_any(
        value,
        &[
            "resetInSec",
            "resetInSeconds",
            "reset_sec",
            "reset_in_sec",
            "resetsInSec",
        ],
    ))?;
    if !reset_in.is_finite() || reset_in < 0.0 {
        return None;
    }
    Some(unix_seconds_to_iso(now.saturating_add(reset_in as i64)))
}

fn usd_window(cadence: Cadence, used: f64, limit: f64, reset_ms: Option<i64>) -> QuotaWindow {
    let remaining = (limit - used).max(0.0);
    QuotaWindow {
        id: cadence.wire().to_owned(),
        title: cadence.title().to_owned(),
        used_percent: clamp_percent(if limit > 0.0 {
            used / limit * 100.0
        } else {
            0.0
        }),
        resets_at: reset_ms.map(|ms| unix_seconds_to_iso(ms.div_euclid(1_000))),
        duration_seconds: match cadence {
            Cadence::FiveHour => Some(5 * 3_600),
            Cadence::Weekly => Some(7 * 86_400),
            Cadence::Monthly => None,
        },
        primary_cadence: Some(cadence),
        remaining_value: Some(remaining),
        limit_value: Some(limit),
        value_unit: Some("usd"),
    }
}

fn snapshot(key: &str, windows: Vec<QuotaWindow>, observed_at: String) -> QuotaSnapshot {
    let (fingerprint, scope) = api_key_identity("opencode_go", key);
    QuotaSnapshot {
        provider: ProviderId::OpencodeGo,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: None,
            plan: Some("go".to_owned()),
        },
        windows,
        status: "available",
        observed_at,
    }
}

fn start_of_utc_week_ms(now_ms: i64) -> i64 {
    // Monday 00:00 UTC, ISO week.
    let now_s = now_ms.div_euclid(1_000);
    let days = now_s.div_euclid(86_400);
    let weekday = (days + 3).rem_euclid(7); // 1970-01-01 was Thursday; Monday = 0
    (days - weekday) * 86_400 * 1_000
}

fn start_of_utc_month_ms(now_ms: i64) -> i64 {
    let now_s = now_ms.div_euclid(1_000);
    let days = now_s.div_euclid(86_400);
    let (year, month, _) = civil_from_days(days);
    days_from_civil(year, month, 1) * 86_400 * 1_000
}

fn next_utc_month_ms(month_start_ms: i64) -> i64 {
    let days = month_start_ms.div_euclid(1_000).div_euclid(86_400);
    let (year, month, _) = civil_from_days(days);
    let (year, month) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
    days_from_civil(year, month, 1) * 86_400 * 1_000
}

fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097) as u32;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m, d)
}

fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year } as i64;
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400) as u32;
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe as i64 - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: std::path::PathBuf::from("/tmp/quota-opencode-go-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: Some(std::path::PathBuf::from(
                "/tmp/quota-opencode-go-missing-config/providers.json",
            )),
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T12:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        }
    }

    #[test]
    fn maps_official_usage_api_windows() {
        let windows = map_api_windows(
            &serde_json::json!({
                "usage": {
                    "rolling": { "usagePercent": 25.0, "resetInSec": 3600 },
                    "weekly": { "usagePercent": 40.0, "resetInSec": 86400 },
                    "monthly": { "usagePercent": 10.0, "resetInSec": 864000 }
                }
            }),
            1_786_363_200,
        )
        .expect("windows");
        assert_eq!(
            windows
                .iter()
                .map(|window| window.id.as_str())
                .collect::<Vec<_>>(),
            ["five_hour", "weekly", "monthly"]
        );
        assert_eq!(windows[0].used_percent, 25.0);
        assert_eq!(windows[0].primary_cadence, Some(Cadence::FiveHour));
        assert_eq!(windows[1].used_percent, 40.0);
        assert_eq!(windows[2].used_percent, 10.0);
    }

    #[test]
    fn collect_api_sends_bearer_key() {
        let (address, server) = crate::providers::common::serve_responses(vec![(
            200,
            br#"{"usage":{"rolling":{"usagePercent":12.5,"resetInSec":100}}}"#.to_vec(),
        )]);
        let mut context = isolated_context();
        context
            .environment
            .insert("OPENCODE_API_KEY".into(), "sk-go-test".into());
        let snapshot =
            collect_at(&context, Some(&format!("http://{address}/usage"))).expect("snapshot");
        assert_eq!(snapshot.account.plan.as_deref(), Some("go"));
        assert_eq!(snapshot.windows[0].id, "five_hour");
        assert_eq!(snapshot.windows[0].used_percent, 12.5);
        let head = server.join().expect("server").remove(0);
        assert!(head.contains("authorization: bearer sk-go-test"));
    }

    #[test]
    fn local_costs_map_to_published_dollar_limits() {
        let root = std::env::temp_dir().join(format!(
            "quota-opencode-go-local-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("time")
                .as_nanos()
        ));
        let data = root.join(".local").join("share").join("opencode");
        std::fs::create_dir_all(&data).expect("dir");
        std::fs::write(
            data.join("auth.json"),
            r#"{"opencode-go":{"key":"sk-local"}}"#,
        )
        .expect("auth");
        let connection = Connection::open(data.join("opencode.db")).expect("db");
        connection
            .execute_batch(
                "CREATE TABLE message(
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL,
                    data TEXT NOT NULL
                )",
            )
            .expect("schema");
        let created = 1_786_363_200_000i64 - 60_000;
        let payload = format!(
            r#"{{"role":"assistant","providerID":"opencode-go","modelID":"kimi-k3","time":{{"created":{created}}},"cost":3.0}}"#
        );
        connection
            .execute(
                "INSERT INTO message(id, session_id, time_created, time_updated, data) VALUES (?1, 's', ?2, ?2, ?3)",
                params!["m1", created, payload],
            )
            .expect("insert");
        drop(connection);
        let mut context = isolated_context();
        context.home_directory = root.clone();
        let snapshot = collect_at(&context, Some("http://127.0.0.1:1/usage")).expect("local");
        assert_eq!(snapshot.windows[0].id, "five_hour");
        assert_eq!(snapshot.windows[0].remaining_value, Some(9.0));
        assert_eq!(snapshot.windows[0].limit_value, Some(12.0));
        assert_eq!(snapshot.windows[0].value_unit, Some("usd"));
        assert_eq!(snapshot.windows[1].limit_value, Some(30.0));
        assert_eq!(snapshot.windows[2].limit_value, Some(60.0));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn missing_key_and_local_auth_is_auth_required() {
        let error = collect(
            &ProviderSession {
                provider: ProviderId::OpencodeGo,
                credential_source: "missing".into(),
                cookie_header: None,
            },
            &isolated_context(),
        )
        .expect_err("missing");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
    }
}
