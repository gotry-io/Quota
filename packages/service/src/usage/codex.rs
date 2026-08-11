use super::scan::{UsageParser, discover_usage_files_at, roots_for, scan_jsonl_files};
use super::{
    BillableTools, BillingChannel, ChannelSource, NormalizedUsageEvent, NormalizedUsageRecord,
    ParsedLine, UsageAgent, UsageError, bounded_model, canonical_instant, context_bucket, object,
    safe_count, safe_sum, string_field,
};
use serde_json::{Map, Value};

pub fn scan_codex_usage(
    options: &super::UsageScanOptions,
) -> Result<super::UsageScanResult, UsageError> {
    let discovery =
        discover_usage_files_at(UsageAgent::Codex, &roots_for(UsageAgent::Codex, options))?;
    scan_jsonl_files(UsageAgent::Codex, options, discovery, || {
        CodexParser::default()
    })
}

#[derive(Clone, Copy, Debug, Default)]
struct TokenUsage {
    input: u64,
    cache_read: u64,
    cache_write: u64,
    output: u64,
    reasoning: u64,
    total: u64,
}

struct CodexParser {
    current_model: Option<String>,
    context_invalidated: bool,
    service_tier: String,
    speed: String,
    billing_channel: BillingChannel,
    channel_source: ChannelSource,
    previous_totals: Option<TokenUsage>,
    pending_records: Vec<NormalizedUsageRecord>,
}

impl Default for CodexParser {
    fn default() -> Self {
        Self {
            current_model: None,
            context_invalidated: false,
            service_tier: String::new(),
            speed: String::new(),
            billing_channel: BillingChannel::OpenaiDirect,
            channel_source: ChannelSource::AgentDefault,
            previous_totals: None,
            pending_records: Vec::new(),
        }
    }
}

fn explicit_billing_channel(value: &str) -> BillingChannel {
    match value.trim().to_ascii_lowercase().as_str() {
        "openai" => BillingChannel::OpenaiDirect,
        _ => BillingChannel::Unknown,
    }
}

impl CodexParser {
    fn model_from(
        &self,
        payload: &Map<String, Value>,
        info: &Map<String, Value>,
    ) -> Result<Option<String>, ()> {
        let candidate = ["model", "model_name"]
            .into_iter()
            .find_map(|key| payload.get(key).filter(|value| !value.is_null()))
            .or_else(|| {
                ["model", "model_name"]
                    .into_iter()
                    .find_map(|key| info.get(key).filter(|value| !value.is_null()))
            });
        match candidate {
            None => Ok(None),
            Some(value) => bounded_model(Some(value)).ok_or(()).map(Some),
        }
    }

    fn take_pending(&mut self) -> Vec<NormalizedUsageRecord> {
        if self.current_model.is_none() || self.pending_records.is_empty() {
            return Vec::new();
        }
        let model = self.current_model.clone().expect("checked above");
        self.pending_records
            .drain(..)
            .map(|mut record| {
                record.event.model = model.clone();
                record
            })
            .collect()
    }

    fn settings(&mut self, payload: &Map<String, Value>) -> Option<super::CoverageReasonCode> {
        self.update_provider(payload);
        let settings = object(payload.get("thread_settings"));
        let value = settings.and_then(|value| value.get("service_tier"))?;
        match value.as_str() {
            Some("fast") | Some("priority") => {
                self.service_tier = "priority".into();
                self.speed = "fast".into();
                None
            }
            Some("default") | Some("standard") => {
                self.service_tier = "standard".into();
                self.speed = "standard".into();
                None
            }
            Some("flex") => {
                self.service_tier = "flex".into();
                self.speed = "unknown".into();
                None
            }
            _ => {
                self.service_tier = "unknown".into();
                self.speed = "unknown".into();
                Some(super::CoverageReasonCode::InvalidUsage)
            }
        }
    }

    fn update_provider(&mut self, value: &Map<String, Value>) {
        let Some(provider) = value.get("model_provider").and_then(Value::as_str) else {
            return;
        };
        self.billing_channel = explicit_billing_channel(provider);
        self.channel_source = if self.billing_channel == BillingChannel::Unknown {
            ChannelSource::Unknown
        } else {
            ChannelSource::Explicit
        };
    }
}

impl UsageParser for CodexParser {
    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        match string_field(value, "type") {
            Some("turn_context") => {
                let payload = object(value.get("payload"));
                if let Some(payload) = payload {
                    self.update_provider(payload);
                }
                let Some(model) = bounded_model(payload.and_then(|value| value.get("model")))
                else {
                    self.invalidate_context();
                    return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
                };
                self.current_model = Some(model);
                self.context_invalidated = false;
                ParsedLine {
                    records: self.take_pending(),
                    reason: None,
                    ignored_empty_records: 0,
                }
            }
            Some("event_msg") => self.event_message(value, source_file_id),
            _ => {
                if value.get("usage").is_some()
                    || object(value.get("payload"))
                        .and_then(|payload| payload.get("info"))
                        .is_some()
                {
                    ParsedLine::reason(super::CoverageReasonCode::UnknownRecord)
                } else {
                    ParsedLine::empty()
                }
            }
        }
    }

    fn finish(&mut self) -> ParsedLine {
        self.pending_records.clear();
        ParsedLine::empty()
    }
}

impl CodexParser {
    fn invalidate_context(&mut self) {
        self.current_model = None;
        self.context_invalidated = true;
        self.previous_totals = None;
        self.pending_records.clear();
    }

    fn event_message(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        let Some(payload) = object(value.get("payload")) else {
            return ParsedLine::reason(super::CoverageReasonCode::UnknownRecord);
        };
        let Some(payload_type) = string_field(payload, "type") else {
            return ParsedLine::reason(super::CoverageReasonCode::UnknownRecord);
        };
        if payload_type == "thread_settings_applied" {
            return ParsedLine {
                records: Vec::new(),
                reason: self.settings(payload),
                ignored_empty_records: 0,
            };
        }
        if payload_type != "token_count" {
            return ParsedLine::empty();
        }
        let Some(occurred_at) = value
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(canonical_instant)
        else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidTimestamp);
        };
        let Some(info_value) = payload.get("info") else {
            return ParsedLine::empty();
        };
        if info_value.is_null() {
            return ParsedLine::empty();
        }
        let Some(info) = object(Some(info_value)) else {
            return ParsedLine::reason(super::CoverageReasonCode::InvalidUsage);
        };
        self.update_provider(payload);
        self.update_provider(info);
        let parsed_model = match self.model_from(payload, info) {
            Ok(value) => value,
            Err(()) => {
                self.invalidate_context();
                return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
            }
        };
        if let Some(model) = parsed_model {
            self.current_model = Some(model);
            self.context_invalidated = false;
        }
        if self.current_model.is_none() && self.context_invalidated {
            // An invalid explicit context invalidates the previous attribution. Do not queue a
            // token record here: a later valid context must never relabel it as that model.
            return ParsedLine::reason(super::CoverageReasonCode::InvalidModel);
        }
        let mut records = self.take_pending();
        let total = match optional_token_usage(info.get("total_token_usage")) {
            Ok(value) => value,
            Err(()) => {
                return ParsedLine {
                    records,
                    reason: Some(super::CoverageReasonCode::InvalidUsage),
                    ignored_empty_records: 0,
                };
            }
        };
        let last = match optional_token_usage(info.get("last_token_usage")) {
            Ok(value) => value,
            Err(()) => {
                return ParsedLine {
                    records,
                    reason: Some(super::CoverageReasonCode::InvalidUsage),
                    ignored_empty_records: 0,
                };
            }
        };
        let usage = if let Some(total_usage) = total {
            if self
                .previous_totals
                .is_some_and(|previous| equal_usage(total_usage, previous))
            {
                self.previous_totals = Some(total_usage);
                return ParsedLine {
                    records,
                    reason: None,
                    ignored_empty_records: 0,
                };
            }
            let usage = last.or_else(|| {
                self.previous_totals
                    .and_then(|previous| subtract_usage(total_usage, Some(previous)))
                    .or(Some(total_usage))
            });
            self.previous_totals = Some(total_usage);
            let Some(usage) = usage else {
                return ParsedLine {
                    records,
                    reason: Some(super::CoverageReasonCode::InvalidUsage),
                    ignored_empty_records: 0,
                };
            };
            usage
        } else {
            let Some(usage) = last else {
                return ParsedLine {
                    records,
                    reason: None,
                    ignored_empty_records: 0,
                };
            };
            usage
        };
        if is_empty_usage(usage) {
            return ParsedLine {
                records,
                reason: None,
                ignored_empty_records: 1,
            };
        }
        let event = NormalizedUsageEvent {
            occurred_at,
            agent: UsageAgent::Codex,
            model: self
                .current_model
                .clone()
                .unwrap_or_else(|| "unknown".into()),
            billing_channel: self.billing_channel,
            channel_source: self.channel_source,
            input_tokens: usage.input,
            cache_read_tokens: usage.cache_read,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: usage.cache_write,
            output_tokens: usage.output,
            reasoning_tokens: usage.reasoning,
            requests: 1,
            context_bucket: context_bucket(usage.input),
            service_tier: if self.service_tier.is_empty() {
                "unknown".into()
            } else {
                self.service_tier.clone()
            },
            speed: if self.speed.is_empty() {
                "unknown".into()
            } else {
                self.speed.clone()
            },
            inference_geo: "unknown".into(),
            billable_tools: BillableTools::default(),
            source_cost_microusd: None,
            source_cost_covered_requests: 0,
        };
        let record = NormalizedUsageRecord {
            event,
            source_file_id: source_file_id.to_owned(),
            record_key: String::new(),
        };
        if self.current_model.is_none() {
            self.pending_records.push(record);
        } else {
            records.push(record);
        }
        ParsedLine {
            records,
            reason: None,
            ignored_empty_records: 0,
        }
    }
}

fn optional_token_usage(value: Option<&Value>) -> Result<Option<TokenUsage>, ()> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => parse_token_usage(value).map(Some).ok_or(()),
    }
}

fn parse_token_usage(value: &Value) -> Option<TokenUsage> {
    let usage = object(Some(value))?;
    let input = safe_count(usage.get("input_tokens"))?;
    let output = safe_count(usage.get("output_tokens"))?;
    let cache_read = if usage.contains_key("cached_input_tokens") {
        safe_count(usage.get("cached_input_tokens"))?
    } else {
        0
    };
    let cache_write = if usage.contains_key("cache_write_input_tokens") {
        safe_count(usage.get("cache_write_input_tokens"))?
    } else {
        0
    };
    let reasoning = if usage.contains_key("reasoning_output_tokens") {
        safe_count(usage.get("reasoning_output_tokens"))?
    } else {
        0
    };
    let cache_total = safe_sum(&[cache_read, cache_write])?;
    let total = safe_sum(&[input, output])?;
    (cache_total <= input && reasoning <= output).then_some(TokenUsage {
        input,
        cache_read,
        cache_write,
        output,
        reasoning,
        total,
    })
}

fn subtract_usage(current: TokenUsage, previous: Option<TokenUsage>) -> Option<TokenUsage> {
    let previous = previous?;
    if current.input < previous.input
        || current.cache_read < previous.cache_read
        || current.cache_write < previous.cache_write
        || current.output < previous.output
        || current.reasoning < previous.reasoning
        || current.total < previous.total
    {
        return None;
    }
    let usage = TokenUsage {
        input: current.input - previous.input,
        cache_read: current.cache_read - previous.cache_read,
        cache_write: current.cache_write - previous.cache_write,
        output: current.output - previous.output,
        reasoning: current.reasoning - previous.reasoning,
        total: current.total - previous.total,
    };
    let cache_total = safe_sum(&[usage.cache_read, usage.cache_write])?;
    (cache_total <= usage.input
        && usage.reasoning <= usage.output
        && usage.total == usage.input + usage.output)
        .then_some(usage)
}

fn equal_usage(left: TokenUsage, right: TokenUsage) -> bool {
    left.input == right.input
        && left.cache_read == right.cache_read
        && left.cache_write == right.cache_write
        && left.output == right.output
        && left.reasoning == right.reasoning
        && left.total == right.total
}

fn is_empty_usage(value: TokenUsage) -> bool {
    value.input == 0
        && value.cache_read == 0
        && value.cache_write == 0
        && value.output == 0
        && value.reasoning == 0
}
