//! Official provider status pages.
//!
//! Catalog rows with `status_page.kind = statuspage_v2` are polled for `status.indicator` and
//! `status.description` only. The request carries no credential, stores no user data, and a
//! failed poll leaves the last reading in place.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::Value;

use crate::catalog::{PROVIDER_CATALOG, StatusPageKind};
use crate::protocol::ProviderStatusView;
use crate::providers::common::{HttpClient, ProviderError};

pub const STATUS_TIMEOUT: Duration = Duration::from_secs(10);
pub const STATUS_BODY_LIMIT: usize = 64 * 1024;

const INDICATORS: &[&str] = &["none", "minor", "major", "critical"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderStatusReading {
    pub provider: String,
    pub indicator: String,
    pub description: String,
    pub checked_at: String,
}

impl ProviderStatusReading {
    pub fn to_view(&self) -> ProviderStatusView {
        ProviderStatusView {
            provider: self.provider.clone(),
            indicator: self.indicator.clone(),
            description: self.description.clone(),
            checked_at: self.checked_at.clone(),
        }
    }
}

pub fn catalog_endpoints() -> Vec<(&'static str, &'static str)> {
    PROVIDER_CATALOG
        .iter()
        .filter_map(|entry| {
            let page = entry.status_page?;
            match page.kind {
                StatusPageKind::StatuspageV2 => Some((entry.id.as_str(), page.url?)),
                StatusPageKind::None => None,
            }
        })
        .collect()
}

pub fn is_indicator(value: &str) -> bool {
    INDICATORS.contains(&value)
}

pub fn parse_statuspage_v2(
    body: &Value,
    provider: &str,
    checked_at: &str,
) -> Option<ProviderStatusReading> {
    let status = body.get("status")?;
    let indicator = status.get("indicator")?.as_str()?;
    if !is_indicator(indicator) {
        return None;
    }
    let description = status.get("description")?.as_str()?;
    Some(ProviderStatusReading {
        provider: provider.to_owned(),
        indicator: indicator.to_owned(),
        description: description.to_owned(),
        checked_at: checked_at.to_owned(),
    })
}

pub fn poll(
    client: &HttpClient,
    user_agent: &str,
    pages: &[(&str, &str)],
    checked_at: &str,
) -> BTreeMap<String, ProviderStatusReading> {
    let headers = [("User-Agent", user_agent)];
    let mut out = BTreeMap::new();
    for (provider, url) in pages {
        match fetch_one(client, &headers, url) {
            Ok(body) => {
                if let Some(reading) = parse_statuspage_v2(&body, provider, checked_at) {
                    out.insert((*provider).to_owned(), reading);
                }
            }
            Err(_) => {}
        }
    }
    out
}

pub fn merge(
    last: BTreeMap<String, ProviderStatusReading>,
    fresh: BTreeMap<String, ProviderStatusReading>,
) -> BTreeMap<String, ProviderStatusReading> {
    let mut out = last;
    out.extend(fresh);
    out
}

pub fn component_value(readings: &BTreeMap<String, ProviderStatusReading>) -> Value {
    let status = readings
        .iter()
        .map(|(provider, reading)| {
            (
                provider.clone(),
                serde_json::json!({
                    "indicator": reading.indicator,
                    "description": reading.description,
                    "checked_at": reading.checked_at,
                }),
            )
        })
        .collect::<serde_json::Map<String, Value>>();
    serde_json::json!({ "status": status })
}

pub fn readings_from_component(value: Option<&Value>) -> BTreeMap<String, ProviderStatusReading> {
    let Some(status) = value
        .and_then(|value| value.get("status"))
        .and_then(Value::as_object)
    else {
        return BTreeMap::new();
    };
    let mut out = BTreeMap::new();
    for entry in PROVIDER_CATALOG {
        let Some(item) = status.get(entry.id.as_str()) else {
            continue;
        };
        let Some(indicator) = item.get("indicator").and_then(Value::as_str) else {
            continue;
        };
        if !is_indicator(indicator) {
            continue;
        }
        let Some(description) = item.get("description").and_then(Value::as_str) else {
            continue;
        };
        let Some(checked_at) = item.get("checked_at").and_then(Value::as_str) else {
            continue;
        };
        out.insert(
            entry.id.as_str().to_owned(),
            ProviderStatusReading {
                provider: entry.id.as_str().to_owned(),
                indicator: indicator.to_owned(),
                description: description.to_owned(),
                checked_at: checked_at.to_owned(),
            },
        );
    }
    out
}

pub fn views_in_catalog_order(
    readings: &BTreeMap<String, ProviderStatusReading>,
) -> Vec<ProviderStatusView> {
    PROVIDER_CATALOG
        .iter()
        .filter_map(|entry| {
            readings
                .get(entry.id.as_str())
                .map(ProviderStatusReading::to_view)
        })
        .collect()
}

fn fetch_one(
    client: &HttpClient,
    headers: &[(&str, &str)],
    url: &str,
) -> Result<Value, ProviderError> {
    let (_status, body) =
        client.get_json_limited(url, headers, "status_page", STATUS_BODY_LIMIT)?;
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::common::serve_responses;
    use serde_json::json;

    #[test]
    fn catalog_lists_only_statuspage_v2_urls() {
        let pages = catalog_endpoints();
        assert_eq!(
            pages,
            vec![
                ("codex", "https://status.openai.com/api/v2/status.json"),
                ("claude", "https://status.claude.com/api/v2/status.json"),
                ("kimi", "https://status.moonshot.cn/api/v2/status.json"),
                ("cursor", "https://status.cursor.com/api/v2/status.json"),
            ]
        );
    }

    #[test]
    fn parse_takes_indicator_and_description_only() {
        let body = json!({
            "page": { "id": "abc", "name": "OpenAI" },
            "status": {
                "indicator": "minor",
                "description": "Partial System Outage"
            }
        });
        let reading = parse_statuspage_v2(&body, "codex", "2026-09-06T00:00:00Z").expect("reading");
        assert_eq!(reading.provider, "codex");
        assert_eq!(reading.indicator, "minor");
        assert_eq!(reading.description, "Partial System Outage");
        assert_eq!(reading.checked_at, "2026-09-06T00:00:00Z");
    }

    #[test]
    fn parse_rejects_unknown_indicators() {
        let body = json!({
            "status": { "indicator": "maintenance", "description": "Scheduled" }
        });
        assert_eq!(
            parse_statuspage_v2(&body, "codex", "2026-09-06T00:00:00Z"),
            None
        );
    }

    #[test]
    fn poll_records_success_and_skips_failures() {
        let ok = serde_json::to_vec(&json!({
            "status": { "indicator": "none", "description": "All Systems Operational" }
        }))
        .expect("json");
        let (address, handle) =
            serve_responses(vec![(200, ok), (500, b"{\"error\":true}".to_vec())]);
        let client = HttpClient::with_timeout(STATUS_TIMEOUT).expect("client");
        let url_a = format!("http://{address}/a");
        let url_b = format!("http://{address}/b");
        let pages = [("codex", url_a.as_str()), ("claude", url_b.as_str())];
        let readings = poll(&client, "Quota/test", &pages, "2026-09-06T00:00:00Z");
        let heads = handle.join().expect("server");
        assert_eq!(readings.len(), 1);
        assert_eq!(readings["codex"].indicator, "none");
        assert!(
            heads
                .iter()
                .all(|head| head.contains("user-agent: quota/test"))
        );
        assert!(!readings.contains_key("claude"));
    }

    #[test]
    fn poll_rejects_bodies_over_64_kib() {
        let (address, handle) = serve_responses(vec![(200, vec![b'x'; STATUS_BODY_LIMIT + 1])]);
        let client = HttpClient::with_timeout(STATUS_TIMEOUT).expect("client");
        let url = format!("http://{address}/");
        let readings = poll(
            &client,
            "Quota/test",
            &[("codex", url.as_str())],
            "2026-09-06T00:00:00Z",
        );
        let _ = handle.join();
        assert!(readings.is_empty());
    }

    #[test]
    fn a_failed_provider_keeps_its_last_reading() {
        let last = BTreeMap::from([(
            "codex".to_owned(),
            ProviderStatusReading {
                provider: "codex".to_owned(),
                indicator: "minor".to_owned(),
                description: "Partial System Outage".to_owned(),
                checked_at: "2026-09-06T00:00:00Z".to_owned(),
            },
        )]);
        let merged = merge(last, BTreeMap::new());
        assert_eq!(merged["codex"].indicator, "minor");
    }

    #[test]
    fn component_round_trip_preserves_catalog_order() {
        let mut readings = BTreeMap::new();
        readings.insert(
            "cursor".to_owned(),
            ProviderStatusReading {
                provider: "cursor".to_owned(),
                indicator: "none".to_owned(),
                description: "All Systems Operational".to_owned(),
                checked_at: "2026-09-06T00:00:00Z".to_owned(),
            },
        );
        readings.insert(
            "codex".to_owned(),
            ProviderStatusReading {
                provider: "codex".to_owned(),
                indicator: "major".to_owned(),
                description: "Major Service Outage".to_owned(),
                checked_at: "2026-09-06T00:01:00Z".to_owned(),
            },
        );
        let value = component_value(&readings);
        let restored = readings_from_component(Some(&value));
        let views = views_in_catalog_order(&restored);
        assert_eq!(views.len(), 2);
        assert_eq!(views[0].provider, "codex");
        assert_eq!(views[1].provider, "cursor");
    }
}
