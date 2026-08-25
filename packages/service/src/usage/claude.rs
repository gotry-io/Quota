use super::scan::{UsageParser, discover_usage_files_at, roots_for, scan_jsonl_files};
use super::{
    BillableTools, BillingChannel, ChannelSource, NormalizedUsageEvent, NormalizedUsageRecord,
    ParsedLine, UsageAgent, UsageError, bounded_dimension, bounded_model, canonical_instant,
    context_bucket, object, optional_count,
};
use serde_json::{Map, Value};

pub fn scan_claude_usage(
    options: &super::UsageScanOptions,
) -> Result<super::UsageScanResult, UsageError> {
    let discovery = discover_usage_files_at(
        UsageAgent::ClaudeCode,
        &roots_for(UsageAgent::ClaudeCode, options),
    )?;
    scan_jsonl_files(UsageAgent::ClaudeCode, options, discovery, || ClaudeParser)
}

#[derive(Default)]
struct ClaudeParser;

impl UsageParser for ClaudeParser {
    const CONTEXT_FREE: bool = true;

    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        let Some(message) = object(value.get("message")) else {
            return if value.get("type").is_none() {
                ParsedLine::reason(super::CoverageReasonCode::UnknownRecord)
            } else {
                ParsedLine::empty()
            };
        };
        let Some(usage_value) = message.get("usage") else {
            return if value.get("type").is_none() {
                ParsedLine::reason(super::CoverageReasonCode::UnknownRecord)
            } else {
                ParsedLine::empty()
            };
        };
        if value.contains_key("type")
            && value.get("type").and_then(Value::as_str) != Some("assistant")
        {
            return ParsedLine::reason(super::CoverageReasonCode::UnknownRecord);
        }
        if message.get("role").and_then(Value::as_str) == Some("user") {
            return ParsedLine::reason(super::CoverageReasonCode::UnknownRecord);
        }
        let Some(usage) = object(Some(usage_value)) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some(occurred_at) = value
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(canonical_instant)
        else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidTimestamp);
        };
        let model = if message.get("model").and_then(Value::as_str) == Some("<synthetic>") {
            Some("synthetic".to_string())
        } else {
            bounded_model(message.get("model"))
        };
        let Some(model) = model else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
        };
        let Some(tokens) = parse_tokens(usage) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some((service_tier, speed, inference_geo)) = parse_dimensions(usage) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some(tools) = parse_tools(usage.get("server_tool_use")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let source_cost = match parse_source_cost(value.get("costUSD")) {
            Ok(value) => value,
            Err(()) => return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage),
        };
        if tokens.input == 0
            && tokens.cache_read == 0
            && tokens.cache_write_5m == 0
            && tokens.cache_write_1h == 0
            && tokens.cache_write_inferred == 0
            && tokens.output == 0
            && tokens.reasoning == 0
            && tools.web_search == 0
            && tools.web_fetch == 0
            && source_cost.as_deref().is_none_or(|value| value == "0")
        {
            return ParsedLine::ignored_empty();
        }
        let (billing_channel, channel_source) = if model.starts_with("claude-") {
            (BillingChannel::AnthropicDirect, ChannelSource::AgentDefault)
        } else {
            (BillingChannel::Unknown, ChannelSource::Unknown)
        };
        ParsedLine {
            records: vec![NormalizedUsageRecord {
                event: NormalizedUsageEvent {
                    occurred_at,
                    agent: UsageAgent::ClaudeCode,
                    model,
                    billing_channel,
                    channel_source,
                    input_tokens: tokens.input,
                    cache_read_tokens: tokens.cache_read,
                    cache_write_5m_tokens: tokens.cache_write_5m,
                    cache_write_1h_tokens: tokens.cache_write_1h,
                    cache_write_inferred_tokens: tokens.cache_write_inferred,
                    output_tokens: tokens.output,
                    reasoning_tokens: tokens.reasoning,
                    requests: 1,
                    context_bucket: context_bucket(tokens.input),
                    service_tier,
                    speed,
                    inference_geo,
                    billable_tools: tools,
                    source_cost_microusd: source_cost,
                    source_cost_covered_requests: if value
                        .get("costUSD")
                        .is_some_and(|value| !value.is_null())
                    {
                        1
                    } else {
                        0
                    },
                },
                source_file_id: source_file_id.to_owned(),
                record_key: String::new(),
            }],
            reason: None,
            ignored_empty_records: 0,
        }
    }
}

struct ClaudeTokens {
    input: u64,
    cache_read: u64,
    cache_write_5m: u64,
    cache_write_1h: u64,
    cache_write_inferred: u64,
    output: u64,
    reasoning: u64,
}

fn parse_tokens(usage: &Map<String, Value>) -> Option<ClaudeTokens> {
    let uncached_input = super::safe_count(usage.get("input_tokens"))?;
    let output = super::safe_count(usage.get("output_tokens"))?;
    let cache_read = optional_count(usage.get("cache_read_input_tokens"))?;
    let cache_write_total = optional_count(usage.get("cache_creation_input_tokens"))?;
    let mut cache_write_5m = 0;
    let mut cache_write_1h = 0;
    if let Some(value) = usage.get("cache_creation")
        && !value.is_null()
    {
        let breakdown = object(Some(value))?;
        cache_write_5m = optional_count(breakdown.get("ephemeral_5m_input_tokens"))?;
        cache_write_1h = optional_count(breakdown.get("ephemeral_1h_input_tokens"))?;
    }
    let classified = super::safe_sum(&[cache_write_5m, cache_write_1h])?;
    if classified > cache_write_total {
        return None;
    }
    let cache_write_inferred = cache_write_total - classified;
    let input = super::safe_sum(&[uncached_input, cache_read, cache_write_total])?;
    let reasoning = if let Some(value) = usage.get("output_tokens_details") {
        if value.is_null() {
            0
        } else {
            let details = object(Some(value))?;
            let value = super::safe_count(details.get("thinking_tokens"))?;
            if value > output {
                return None;
            }
            value
        }
    } else {
        0
    };
    super::safe_sum(&[input, output])?;
    Some(ClaudeTokens {
        input,
        cache_read,
        cache_write_5m,
        cache_write_1h,
        cache_write_inferred,
        output,
        reasoning,
    })
}

fn parse_dimensions(usage: &Map<String, Value>) -> Option<(String, String, String)> {
    Some((
        optional_dimension(usage.get("service_tier"))?,
        optional_dimension(usage.get("speed"))?,
        optional_dimension(usage.get("inference_geo"))?,
    ))
}

fn optional_dimension(value: Option<&Value>) -> Option<String> {
    match value {
        None | Some(Value::Null) => Some("unknown".into()),
        Some(Value::String(value)) if value.is_empty() => Some("unknown".into()),
        Some(value) => bounded_dimension(Some(value)),
    }
}

fn parse_tools(value: Option<&Value>) -> Option<BillableTools> {
    let Some(value) = value else {
        return Some(BillableTools::default());
    };
    if value.is_null() {
        return Some(BillableTools::default());
    }
    let value = object(Some(value))?;
    Some(BillableTools {
        web_search: optional_count(value.get("web_search_requests"))?,
        web_fetch: optional_count(value.get("web_fetch_requests"))?,
    })
}

fn parse_source_cost(value: Option<&Value>) -> Result<Option<String>, ()> {
    let Some(value) = value else { return Ok(None) };
    if value.is_null() {
        return Ok(None);
    }
    let number = value.as_f64().ok_or(())?;
    if !number.is_finite() || number < 0.0 {
        return Err(());
    }
    // JS Math.round(value * 1_000_000), implemented without a floating result
    // being retained in the emitted protocol string.
    let rounded = (number * 1_000_000.0).round();
    if rounded > super::MAX_SAFE_COUNT as f64 {
        return Err(());
    }
    Ok(Some((rounded as u64).to_string()))
}
