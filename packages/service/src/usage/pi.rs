use super::scan::{UsageParser, discover_usage_files_at, roots_for, scan_jsonl_files};
use super::{
    BillableTools, BillingChannel, ChannelSource, NormalizedUsageEvent, NormalizedUsageRecord,
    ParsedLine, UsageAgent, UsageError, bounded_model, canonical_instant, context_bucket, object,
};
use serde_json::{Map, Value};

pub fn scan_pi_usage(
    options: &super::UsageScanOptions,
) -> Result<super::UsageScanResult, UsageError> {
    let discovery = discover_usage_files_at(UsageAgent::Pi, &roots_for(UsageAgent::Pi, options))?;
    scan_jsonl_files(UsageAgent::Pi, options, discovery, || PiParser)
}

struct PiParser;

impl UsageParser for PiParser {
    const CONTEXT_FREE: bool = true;

    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        if value.get("type").and_then(Value::as_str) != Some("message") {
            return ParsedLine::empty();
        }
        let Some(message) = object(value.get("message")) else {
            return ParsedLine::empty();
        };
        if message.get("role").and_then(Value::as_str) != Some("assistant") {
            return ParsedLine::empty();
        }
        if message.get("model").and_then(Value::as_str) == Some("unknown") {
            return ParsedLine::empty();
        }
        let Some(model) = bounded_model(message.get("model")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
        };
        let occurred_at = message
            .get("timestamp")
            .and_then(milliseconds_instant)
            .or_else(|| {
                value
                    .get("timestamp")
                    .and_then(Value::as_str)
                    .and_then(canonical_instant)
            });
        let Some(occurred_at) = occurred_at else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidTimestamp);
        };
        let Some(usage) = object(message.get("usage")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some((input, cache_read, cache_write, output, reasoning)) = parse_usage(usage) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let source_cost = match source_cost_microusd(
            object(usage.get("cost")).and_then(|value| value.get("total")),
        ) {
            Ok(value) => value,
            Err(()) => return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage),
        };
        if input == 0
            && cache_read == 0
            && cache_write == 0
            && output == 0
            && reasoning == 0
            && source_cost.as_deref().is_none_or(|value| value == "0")
        {
            return ParsedLine::ignored_empty();
        }
        let channel = billing_channel(message.get("provider").and_then(Value::as_str));
        ParsedLine {
            records: vec![NormalizedUsageRecord {
                event: NormalizedUsageEvent {
                    occurred_at,
                    agent: UsageAgent::Pi,
                    model,
                    billing_channel: channel,
                    channel_source: if channel == BillingChannel::Unknown {
                        ChannelSource::Unknown
                    } else {
                        ChannelSource::Explicit
                    },
                    input_tokens: input,
                    cache_read_tokens: cache_read,
                    cache_write_5m_tokens: 0,
                    cache_write_1h_tokens: 0,
                    cache_write_inferred_tokens: cache_write,
                    output_tokens: output,
                    reasoning_tokens: reasoning,
                    requests: 1,
                    context_bucket: context_bucket(input),
                    service_tier: "unknown".into(),
                    speed: "unknown".into(),
                    inference_geo: "unknown".into(),
                    billable_tools: BillableTools::default(),
                    source_cost_microusd: source_cost.clone(),
                    source_cost_covered_requests: if source_cost.is_some() { 1 } else { 0 },
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
    let input = super::safe_count(usage.get("input"))?;
    let output = super::safe_count(usage.get("output"))?;
    let cache_read = super::safe_count(usage.get("cacheRead"))?;
    let cache_write = super::safe_count(usage.get("cacheWrite"))?;
    let reasoning = if usage.contains_key("reasoning") {
        super::safe_count(usage.get("reasoning"))?
    } else {
        0
    };
    if reasoning > output {
        return None;
    }
    Some((
        super::safe_sum(&[input, cache_read, cache_write])?,
        cache_read,
        cache_write,
        output,
        reasoning,
    ))
}

fn milliseconds_instant(value: &Value) -> Option<String> {
    let value = super::safe_count(Some(value))?;
    chrono::DateTime::<chrono::Utc>::from_timestamp_millis(value as i64)
        .map(|value| value.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}

fn source_cost_microusd(value: Option<&Value>) -> Result<Option<String>, ()> {
    let Some(value) = value else { return Ok(None) };
    if value.is_null() {
        return Ok(None);
    }
    let number = value.as_f64().ok_or(())?;
    if !number.is_finite() || number < 0.0 {
        return Err(());
    }
    let rounded = (number * 1_000_000.0).round();
    if rounded > super::MAX_SAFE_COUNT as f64 {
        return Err(());
    }
    Ok((rounded != 0.0).then_some((rounded as u64).to_string()))
}

fn billing_channel(provider: Option<&str>) -> BillingChannel {
    match provider {
        Some("openai") => BillingChannel::OpenaiDirect,
        Some("anthropic") => BillingChannel::AnthropicDirect,
        Some("azure-openai") => BillingChannel::AzureOpenai,
        Some("amazon-bedrock") | Some("bedrock") => BillingChannel::AwsBedrock,
        Some("google-vertex") => BillingChannel::GoogleVertex,
        Some("openrouter") => BillingChannel::Openrouter,
        Some("xai") => BillingChannel::XaiDirect,
        Some("moonshotai") | Some("kimi-for-coding") => BillingChannel::MoonshotDirect,
        Some("deepseek") => BillingChannel::DeepseekDirect,
        _ => BillingChannel::Unknown,
    }
}
