use super::scan::{UsageParser, discover_usage_files_at, roots_for, scan_jsonl_files};
use super::{
    BillableTools, BillingChannel, ChannelSource, NormalizedUsageEvent, NormalizedUsageRecord,
    ParsedLine, UsageAgent, UsageError, bounded_model, bounded_model_text, canonical_instant,
    context_bucket, object, optional_count, safe_count,
};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

pub fn scan_copilot_usage(
    options: &super::UsageScanOptions,
) -> Result<super::UsageScanResult, UsageError> {
    let discovery = discover_usage_files_at(
        UsageAgent::Copilot,
        &roots_for(UsageAgent::Copilot, options),
    )?;
    scan_jsonl_files(
        UsageAgent::Copilot,
        options,
        discovery,
        CopilotParser::default,
    )
}

#[derive(Default)]
struct CopilotParser {
    saw_per_call: bool,
    previous: BTreeMap<String, TokenUsage>,
}

#[derive(Clone, Copy, Debug, Default)]
struct TokenUsage {
    input: u64,
    cache_read: u64,
    cache_write: u64,
    output: u64,
    reasoning: u64,
    requests: u64,
}

impl UsageParser for CopilotParser {
    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        match value.get("type").and_then(Value::as_str) {
            Some("assistant.usage") => {
                self.saw_per_call = true;
                assistant_usage(value, source_file_id)
            }
            Some("session.shutdown") if !self.saw_per_call => self.shutdown(value, source_file_id),
            _ => ParsedLine::empty(),
        }
    }
}

fn assistant_usage(value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
    let data = object(value.get("data")).unwrap_or(value);
    event_from_usage(
        value,
        data,
        data.get("model").or_else(|| value.get("model")),
        1,
        source_file_id,
    )
}

impl CopilotParser {
    fn shutdown(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        let Some(data) = object(value.get("data")).or(Some(value)) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        let Some(metrics) = object(data.get("modelMetrics")) else {
            return ParsedLine::empty();
        };
        let mut records = Vec::new();
        let mut reason = None;
        for (model, metric) in metrics {
            let Some(metric) = object(Some(metric)) else {
                reason = Some(super::CoverageReasonCode::InvalidUsage);
                continue;
            };
            let Some(usage) = object(metric.get("usage")).or(Some(metric)) else {
                reason = Some(super::CoverageReasonCode::InvalidUsage);
                continue;
            };
            let requests = object(metric.get("requests"))
                .and_then(|value| safe_count(value.get("count")))
                .or_else(|| optional_count(metric.get("count")))
                .unwrap_or(1);
            let Some(current) = token_usage(usage, requests) else {
                reason = Some(super::CoverageReasonCode::InvalidUsage);
                continue;
            };
            let previous = self
                .previous
                .insert(model.clone(), current)
                .unwrap_or_default();
            let delta = subtract(current, previous);
            if delta.input == 0
                && delta.cache_read == 0
                && delta.cache_write == 0
                && delta.output == 0
                && delta.reasoning == 0
                && delta.requests == 0
            {
                continue;
            }
            match event_from_counts(value, model, delta, source_file_id) {
                ParsedLine {
                    records: mut next,
                    reason: next_reason,
                    ..
                } => {
                    records.append(&mut next);
                    if reason.is_none() {
                        reason = next_reason;
                    }
                }
            }
        }
        ParsedLine {
            records,
            reason,
            ignored_empty_records: 0,
        }
    }
}

fn event_from_usage(
    envelope: &Map<String, Value>,
    usage: &Map<String, Value>,
    model: Option<&Value>,
    requests: u64,
    source_file_id: &str,
) -> ParsedLine {
    let Some(model) = bounded_model(model) else {
        return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
    };
    let Some(counts) = token_usage(usage, requests) else {
        return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
    };
    event_from_counts(envelope, &model, counts, source_file_id)
}

fn event_from_counts(
    envelope: &Map<String, Value>,
    model: &str,
    counts: TokenUsage,
    source_file_id: &str,
) -> ParsedLine {
    let Some(model) = bounded_model_text(Some(model)) else {
        return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
    };
    let Some(occurred_at) = envelope
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(canonical_instant)
    else {
        return ParsedLine::reason(super::CoverageReasonCode::InvalidTimestamp);
    };
    let cache_total = match counts.cache_read.checked_add(counts.cache_write) {
        Some(total) => total,
        None => return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage),
    };
    let input = if counts.input >= cache_total {
        counts.input
    } else {
        match counts.input.checked_add(cache_total) {
            Some(total) => total,
            None => return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage),
        }
    };
    let output = if counts.reasoning > counts.output {
        match counts.output.checked_add(counts.reasoning) {
            Some(total) => total,
            None => return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage),
        }
    } else {
        counts.output
    };
    if output < counts.reasoning {
        return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
    }
    let requests = counts.requests.max(1);
    if counts.input == 0 && output == 0 && counts.cache_read == 0 && counts.cache_write == 0 {
        return ParsedLine::ignored_empty();
    }
    ParsedLine {
        records: vec![NormalizedUsageRecord {
            event: NormalizedUsageEvent {
                occurred_at,
                agent: UsageAgent::Copilot,
                model,
                billing_channel: BillingChannel::Unknown,
                channel_source: ChannelSource::Unknown,
                input_tokens: input,
                cache_read_tokens: counts.cache_read,
                cache_write_5m_tokens: 0,
                cache_write_1h_tokens: 0,
                cache_write_inferred_tokens: counts.cache_write,
                output_tokens: output,
                reasoning_tokens: counts.reasoning,
                requests,
                context_bucket: context_bucket(input),
                service_tier: "unknown".into(),
                speed: "unknown".into(),
                inference_geo: "unknown".into(),
                billable_tools: BillableTools::default(),
                source_cost_microusd: None,
                source_cost_covered_requests: 0,
            },
            source_file_id: source_file_id.to_owned(),
            record_key: String::new(),
        }],
        reason: None,
        ignored_empty_records: 0,
    }
}

fn token_usage(usage: &Map<String, Value>, requests: u64) -> Option<TokenUsage> {
    Some(TokenUsage {
        input: optional_count(
            usage
                .get("inputTokens")
                .or_else(|| usage.get("input_tokens"))
                .or_else(|| usage.get("promptTokens")),
        )?,
        cache_read: optional_count(
            usage
                .get("cacheReadTokens")
                .or_else(|| usage.get("cache_read_tokens")),
        )?,
        cache_write: optional_count(
            usage
                .get("cacheWriteTokens")
                .or_else(|| usage.get("cache_write_tokens"))
                .or_else(|| usage.get("cacheCreationInputTokens")),
        )?,
        output: optional_count(
            usage
                .get("outputTokens")
                .or_else(|| usage.get("output_tokens")),
        )?,
        reasoning: optional_count(
            usage
                .get("reasoningTokens")
                .or_else(|| usage.get("reasoning_tokens")),
        )?,
        requests,
    })
}

fn subtract(current: TokenUsage, previous: TokenUsage) -> TokenUsage {
    TokenUsage {
        input: current.input.saturating_sub(previous.input),
        cache_read: current.cache_read.saturating_sub(previous.cache_read),
        cache_write: current.cache_write.saturating_sub(previous.cache_write),
        output: current.output.saturating_sub(previous.output),
        reasoning: current.reasoning.saturating_sub(previous.reasoning),
        requests: current.requests.saturating_sub(previous.requests),
    }
}
