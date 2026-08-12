use super::scan::{UsageParser, discover_usage_files_at, roots_for, scan_jsonl_files};
use super::{
    BillableTools, BillingChannel, ChannelSource, NormalizedUsageEvent, NormalizedUsageRecord,
    ParsedLine, UsageAgent, UsageError, bounded_model_text, context_bucket, object,
};
use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{Map, Value};

pub fn scan_grok_usage(
    options: &super::UsageScanOptions,
) -> Result<super::UsageScanResult, UsageError> {
    let discovery =
        discover_usage_files_at(UsageAgent::Grok, &roots_for(UsageAgent::Grok, options))?;
    scan_jsonl_files(UsageAgent::Grok, options, discovery, || GrokParser)
}

struct GrokParser;

impl UsageParser for GrokParser {
    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        if value.get("method").and_then(Value::as_str) != Some("_x.ai/session/update") {
            return ParsedLine::empty();
        }
        let Some(params) = object(value.get("params")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some(update) = object(params.get("update")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        if update.get("sessionUpdate").and_then(Value::as_str) != Some("turn_completed") {
            return ParsedLine::empty();
        }
        let Some(usage_value) = update.get("usage") else {
            return ParsedLine::empty();
        };
        if usage_value.is_null() {
            return ParsedLine::empty();
        }
        let Some(usage) = object(Some(usage_value)) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        self.usage(value, usage, source_file_id)
    }
}

impl GrokParser {
    fn usage(
        &self,
        value: &Map<String, Value>,
        usage: &Map<String, Value>,
        source_file_id: &str,
    ) -> ParsedLine {
        let Some(messages) = super::safe_count(usage.get("numTurns")).filter(|value| *value > 0)
        else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some(model_calls) = super::safe_count(usage.get("modelCalls")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some(models) = object(usage.get("modelUsage")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        if models.len() != 1 {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        }
        let Some((reported_model, model_value)) = models.iter().next() else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        if reported_model == "unknown" {
            return ParsedLine::empty();
        }
        let Some(model) = bounded_model_text(Some(reported_model)) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
        };
        let Some(model_usage) = object(Some(model_value)) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        if super::safe_count(model_usage.get("modelCalls")) != Some(model_calls)
            || model_calls < messages
        {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        }
        let Some(occurred_at) = seconds_instant(value.get("timestamp")) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidTimestamp);
        };
        let Some((input, cache_read, cache_write, output, reasoning)) = parse_usage(model_usage)
        else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let source_cost = match exact_cost_microusd(model_usage.get("costUsdTicks")) {
            Ok(value) => value,
            Err(()) => return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage),
        };
        if input == 0
            && cache_read == 0
            && cache_write == 0
            && output == 0
            && reasoning == 0
            && source_cost.is_none()
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
                    requests: messages,
                    context_bucket: context_bucket(input),
                    service_tier: "unknown".into(),
                    speed: "unknown".into(),
                    inference_geo: "unknown".into(),
                    billable_tools: BillableTools::default(),
                    source_cost_covered_requests: if source_cost.is_some() { messages } else { 0 },
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
    let input = super::safe_count(usage.get("inputTokens"))?;
    let output = super::safe_count(usage.get("outputTokens"))?;
    let total = super::safe_count(usage.get("totalTokens"))?;
    let cache_read = super::safe_count(usage.get("cachedReadTokens"))?;
    let cache_write = super::safe_count(usage.get("cacheCreationTokens"))?;
    let reasoning = super::safe_count(usage.get("reasoningTokens"))?;
    (total == super::safe_sum(&[input, output])?
        && super::safe_sum(&[cache_read, cache_write])? <= input
        && reasoning <= output)
        .then_some((input, cache_read, cache_write, output, reasoning))
}

fn seconds_instant(value: Option<&Value>) -> Option<String> {
    let seconds = super::safe_count(value)?;
    DateTime::<Utc>::from_timestamp(i64::try_from(seconds).ok()?, 0)
        .map(|value| value.to_rfc3339_opts(SecondsFormat::Millis, true))
}

fn exact_cost_microusd(value: Option<&Value>) -> Result<Option<String>, ()> {
    let Some(ticks) = value.and_then(Value::as_u64) else {
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
