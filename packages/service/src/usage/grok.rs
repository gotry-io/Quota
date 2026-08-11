use super::scan::{UsageParser, discover_usage_files_at, roots_for, scan_jsonl_files};
use super::{
    BillableTools, BillingChannel, ChannelSource, NormalizedUsageEvent, NormalizedUsageRecord,
    ParsedLine, UsageAgent, UsageError, bounded_dimension, bounded_model, canonical_instant,
    context_bucket, object, optional_count,
};
use serde_json::{Map, Value};

pub fn scan_grok_usage(
    options: &super::UsageScanOptions,
) -> Result<super::UsageScanResult, UsageError> {
    let discovery =
        discover_usage_files_at(UsageAgent::Grok, &roots_for(UsageAgent::Grok, options))?;
    scan_jsonl_files(UsageAgent::Grok, options, discovery, || {
        GrokParser::default()
    })
}

#[derive(Default)]
struct GrokParser {
    model: Option<String>,
    turn_started_at: Option<String>,
}

impl UsageParser for GrokParser {
    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        match value.get("type").and_then(Value::as_str) {
            Some("turn_started") => {
                self.turn_started_at = value
                    .get("ts")
                    .and_then(Value::as_str)
                    .and_then(canonical_instant);
                self.model = if value.get("model_id").and_then(Value::as_str) == Some("unknown") {
                    None
                } else {
                    bounded_model(value.get("model_id"))
                };
                ParsedLine::empty()
            }
            Some("usage") => self.usage(value, source_file_id),
            _ => ParsedLine::empty(),
        }
    }
}

impl GrokParser {
    fn usage(&self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        let Some(usage) = object(value.get("usage")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let explicit_model = value.get("model_id").or_else(|| value.get("model"));
        if explicit_model.and_then(Value::as_str) == Some("unknown") {
            return ParsedLine::empty();
        }
        let model = match explicit_model {
            Some(value) => bounded_model(Some(value)),
            None => self.model.clone(),
        };
        let Some(model) = model else {
            return ParsedLine::empty();
        };
        let occurred_at = value
            .get("ts")
            .and_then(Value::as_str)
            .and_then(canonical_instant)
            .or_else(|| self.turn_started_at.clone());
        let Some(occurred_at) = occurred_at else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidTimestamp);
        };
        let Some((input, cache_read, cache_write, output, reasoning)) = parse_usage(usage) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let source_cost = match exact_cost_microusd(usage.get("cost_in_usd_ticks")) {
            Ok(value) => value,
            Err(()) => return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage),
        };
        let Some(tools) = parse_tools(usage.get("server_tool_use")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        if input == 0
            && cache_read == 0
            && cache_write == 0
            && output == 0
            && reasoning == 0
            && tools.web_search == 0
            && tools.web_fetch == 0
            && source_cost.as_deref().is_none_or(|value| value == "0")
        {
            return ParsedLine::ignored_empty();
        }
        ParsedLine {
            records: vec![NormalizedUsageRecord {
                event: NormalizedUsageEvent {
                    occurred_at,
                    agent: UsageAgent::Grok,
                    model,
                    billing_channel: BillingChannel::XaiDirect,
                    channel_source: ChannelSource::AgentDefault,
                    input_tokens: input,
                    cache_read_tokens: cache_read,
                    cache_write_5m_tokens: 0,
                    cache_write_1h_tokens: 0,
                    cache_write_inferred_tokens: cache_write,
                    output_tokens: output,
                    reasoning_tokens: reasoning,
                    requests: 1,
                    context_bucket: context_bucket(input),
                    service_tier: optional_dimension(usage.get("service_tier")),
                    speed: "unknown".into(),
                    inference_geo: "unknown".into(),
                    billable_tools: tools,
                    source_cost_covered_requests: if source_cost.is_some() { 1 } else { 0 },
                    source_cost_microusd: source_cost,
                },
                source_file_id: source_file_id.to_owned(),
                record_key: String::new(),
            }],
            reason: None,
            ignored_empty_records: 0,
        }
    }
}

fn parse_usage(usage: &Map<String, Value>) -> Option<(u64, u64, u64, u64, u64)> {
    let input = super::safe_count(usage.get("input_tokens"))?;
    let output = super::safe_count(usage.get("output_tokens"))?;
    let cache_read = optional_count(usage.get("cache_read_input_tokens"))?;
    let cache_write = optional_count(usage.get("cache_creation_input_tokens"))?;
    let reasoning = optional_count(usage.get("reasoning_tokens"))?;
    (reasoning <= output).then_some((
        super::safe_sum(&[input, cache_read, cache_write])?,
        cache_read,
        cache_write,
        output,
        reasoning,
    ))
}

fn parse_tools(value: Option<&Value>) -> Option<BillableTools> {
    let Some(value) = value else {
        return Some(BillableTools::default());
    };
    if value.is_null() {
        return Some(BillableTools::default());
    }
    let tools = object(Some(value))?;
    Some(BillableTools {
        web_search: optional_count(tools.get("web_search_requests"))?,
        web_fetch: optional_count(tools.get("web_fetch_requests"))?,
    })
}

fn exact_cost_microusd(value: Option<&Value>) -> Result<Option<String>, ()> {
    let Some(value) = value else { return Ok(None) };
    if value.is_null() {
        return Ok(None);
    }
    let Some(ticks) = (match value {
        Value::String(value) => value.parse::<u128>().ok(),
        Value::Number(value) => value.as_u64().map(u128::from),
        _ => None,
    }) else {
        return Err(());
    };
    if ticks == 0 {
        return Ok(None);
    }
    let rounded = ticks.checked_add(5_000).ok_or(())? / 10_000;
    let value = rounded.to_string();
    if value.len() > 32 {
        return Err(());
    }
    Ok(Some(value))
}

fn optional_dimension(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "unknown".into(),
        Some(Value::String(value)) if value.is_empty() => "unknown".into(),
        Some(value) => bounded_dimension(Some(value)).unwrap_or_else(|| "unknown".into()),
    }
}
