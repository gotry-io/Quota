use super::scan::{
    UsageParser, discover_usage_files_at, file_index, finish_scan, is_cancelled,
    matching_file_info, parse_range, push_reason, roots_for, scan_jsonl_files, source_coverage,
};
use super::{
    BillableTools, BillingChannel, ChannelSource, CoverageReason, CoverageReasonCode,
    NormalizedUsageEvent, NormalizedUsageRecord, ParsedLine, UsageAgent, UsageError,
    UsageFileDiscoveryResult, UsageFileIndex, UsageScanOptions, UsageScanResult, UsageSourceScan,
    bounded_model, bounded_model_text, canonical_instant, context_bucket, object, optional_count,
    safe_count, safe_sum,
};
use rusqlite::{Connection, OpenFlags, types::ValueRef};
use serde_json::{Map, Value};
use std::collections::HashSet;
use std::path::Path;

const MAXIMUM_CURSOR_ROWS: usize = 2_000_000;

pub fn scan_cursor_usage(options: &UsageScanOptions) -> Result<UsageScanResult, UsageError> {
    let discovery =
        discover_usage_files_at(UsageAgent::Cursor, &roots_for(UsageAgent::Cursor, options))?;
    let discovery_reasons = discovery.reasons;
    let allow_deleted_cleanup = discovery_reasons.iter().all(|reason| {
        !matches!(
            reason.code,
            CoverageReasonCode::PermissionDenied
                | CoverageReasonCode::SourceUnreadable
                | CoverageReasonCode::DiscoveryLimit
        )
    });
    let mut jsonl_files = Vec::new();
    let mut database_files = Vec::new();
    for file in discovery.files {
        if is_sqlite_source(&file.path) {
            database_files.push(file);
        } else {
            jsonl_files.push(file);
        }
    }
    let discovered_ids: HashSet<String> = jsonl_files
        .iter()
        .chain(database_files.iter())
        .map(|file| file.source_file_id.clone())
        .collect();
    let jsonl = scan_jsonl_files(
        UsageAgent::Cursor,
        &options_with_index(options, &jsonl_files),
        UsageFileDiscoveryResult {
            files: jsonl_files,
            reasons: Vec::new(),
        },
        || CursorParser,
    )?;
    let databases = scan_databases(
        options,
        UsageFileDiscoveryResult {
            files: database_files,
            reasons: Vec::new(),
        },
    )?;
    let mut deleted_source_file_ids = if allow_deleted_cleanup {
        options
            .file_index
            .keys()
            .filter(|source_file_id| !discovered_ids.contains(*source_file_id))
            .cloned()
            .collect()
    } else {
        Vec::new()
    };
    deleted_source_file_ids.sort();
    Ok(merge_scans(
        options,
        discovery_reasons,
        jsonl,
        databases,
        deleted_source_file_ids,
    ))
}

struct CursorParser;

impl UsageParser for CursorParser {
    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
        match usage_map(value) {
            Ok(None) => ParsedLine::empty(),
            Ok(Some(usage)) => match observation_from_value(value, usage, source_file_id, "") {
                Ok(observation) if observation_is_empty(&observation) => {
                    ParsedLine::ignored_empty()
                }
                Ok(observation) => fact_line(observation),
                Err(reason) => ParsedLine::reason(reason),
            },
            Err(()) => ParsedLine::reason(CoverageReasonCode::InvalidUsage),
        }
    }
}

#[derive(Clone)]
struct CursorTokens {
    input: u64,
    cache_read: u64,
    cache_write: u64,
    output: u64,
    reasoning: u64,
}

impl CursorTokens {
    fn is_empty(&self) -> bool {
        self.input == 0
            && self.cache_read == 0
            && self.cache_write == 0
            && self.output == 0
            && self.reasoning == 0
    }
}

struct CursorObservation {
    record_key: String,
    occurred_at: String,
    occurred_ms: i64,
    composer_id: String,
    is_assistant: bool,
    model: Option<String>,
    provider: Option<String>,
    tokens: CursorTokens,
    source_cost: Option<String>,
    source_cost_present: bool,
    source_file_id: String,
}

fn scan_databases(
    options: &UsageScanOptions,
    discovery: UsageFileDiscoveryResult,
) -> Result<UsageScanResult, UsageError> {
    let range = parse_range(&options.start_at, &options.end_at)?;
    let discovery_files = discovery.files;
    let mut records = Vec::new();
    let mut reasons = discovery.reasons;
    let mut scanned_sources = 0usize;
    let mut skipped_sources = 0usize;
    let mut ignored_empty_records = 0u64;
    let mut unchanged_source_file_ids = Vec::new();
    let mut sources = Vec::new();
    let mut rows_seen = 0usize;
    let mut stopped = false;
    for file in discovery_files {
        if stopped {
            break;
        }
        if is_cancelled(options) {
            push_reason(&mut reasons, CoverageReasonCode::ScanCancelled);
            break;
        }
        let current = match matching_file_info(&file, &mut reasons) {
            Some(value) => value,
            None => {
                scanned_sources += 1;
                let source_reasons = vec![CoverageReason {
                    code: CoverageReasonCode::SourceChanged,
                    count: 1,
                }];
                sources.push(database_source(options, file, Vec::new(), source_reasons));
                continue;
            }
        };
        let current_index = UsageFileIndex {
            source_file_id: current.source_file_id.clone(),
            identity: current.identity.clone(),
            size: current.size,
            modified_ns: current.modified_ns,
            parser_revision: options.parser_revision.clone(),
            ..UsageFileIndex::default()
        };
        if options
            .file_index
            .get(&current.source_file_id)
            .is_some_and(|old| {
                old.identity == current_index.identity
                    && old.size == current_index.size
                    && old.modified_ns == current_index.modified_ns
                    && old.parser_revision == current_index.parser_revision
            })
        {
            skipped_sources += 1;
            unchanged_source_file_ids.push(current.source_file_id);
            continue;
        }
        scanned_sources += 1;
        let mut source_records = Vec::new();
        let mut source_reasons = Vec::new();
        let connection =
            match Connection::open_with_flags(&current.path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
                Ok(value) => value,
                Err(_) => {
                    push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable);
                    for reason in &source_reasons {
                        super::scan::push_reason_count(&mut reasons, reason.code, reason.count);
                    }
                    sources.push(database_source(
                        options,
                        current,
                        Vec::new(),
                        source_reasons,
                    ));
                    continue;
                }
            };
        let parsed = if current.path.file_name().and_then(|name| name.to_str()) == Some("store.db")
        {
            parse_store_database(
                &connection,
                &current.source_file_id,
                &range,
                options,
                &mut rows_seen,
                &mut stopped,
            )
        } else {
            parse_state_database(
                &connection,
                &current.source_file_id,
                &range,
                options,
                &mut rows_seen,
                &mut stopped,
            )
        };
        drop(connection);
        match parsed {
            Ok((file_records, file_reasons, ignored)) => {
                source_records = file_records;
                source_reasons = file_reasons;
                ignored_empty_records = ignored_empty_records.saturating_add(ignored);
            }
            Err(()) => push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable),
        }
        let source = match matching_file_info(&current, &mut source_reasons) {
            Some(after)
                if after.size != current.size
                    || after.modified_ns != current.modified_ns
                    || after.identity != current.identity =>
            {
                push_reason(&mut source_reasons, CoverageReasonCode::SourceChanged);
                after
            }
            Some(after) => after,
            None => current.clone(),
        };
        for reason in &source_reasons {
            super::scan::push_reason_count(&mut reasons, reason.code, reason.count);
        }
        records.extend(source_records.iter().cloned());
        sources.push(database_source(
            options,
            source,
            source_records,
            source_reasons,
        ));
    }
    Ok(finish_scan(
        UsageAgent::Cursor,
        options,
        super::scan::ScanParts {
            records,
            reasons,
            scanned_source_count: scanned_sources,
            skipped_source_count: skipped_sources,
            ignored_empty_records,
            unchanged_source_file_ids,
            deleted_source_file_ids: Vec::new(),
            sources,
        },
    ))
}

fn parse_state_database(
    connection: &Connection,
    source_file_id: &str,
    range: &super::scan::ScanRange,
    options: &UsageScanOptions,
    rows_seen: &mut usize,
    stopped: &mut bool,
) -> Result<(Vec<NormalizedUsageRecord>, Vec<CoverageReason>, u64), ()> {
    if !table_exists(connection, "cursorDiskKV")? {
        return Ok((Vec::new(), Vec::new(), 0));
    }
    let mut statement = connection
        .prepare("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%' ORDER BY key")
        .map_err(|_| ())?;
    let mut observations = Vec::new();
    let mut reasons = Vec::new();
    let mut ignored = 0u64;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, blob_bytes(row.get_ref(1)?)))
    });
    let rows = match rows {
        Ok(value) => value,
        Err(_) => return Err(()),
    };
    for row in rows {
        if is_cancelled(options) {
            push_reason(&mut reasons, CoverageReasonCode::ScanCancelled);
            *stopped = true;
            break;
        }
        *rows_seen += 1;
        if *rows_seen > MAXIMUM_CURSOR_ROWS {
            push_reason(&mut reasons, CoverageReasonCode::RecordLimit);
            *stopped = true;
            break;
        }
        let (key, raw) = match row {
            Ok(value) => value,
            Err(_) => {
                push_reason(&mut reasons, CoverageReasonCode::SourceUnreadable);
                continue;
            }
        };
        let Some(value) = decode_json_object(&raw) else {
            continue;
        };
        match usage_map(&value) {
            Ok(None) => {}
            Ok(Some(usage)) => match observation_from_value(&value, usage, source_file_id, &key) {
                Ok(mut observation) => {
                    if observation.composer_id.is_empty() {
                        observation.composer_id = composer_id_from_key(&key).unwrap_or_default();
                    }
                    if observation.record_key.is_empty() {
                        observation.record_key = key;
                    }
                    observations.push(observation);
                }
                Err(reason) => push_reason(&mut reasons, reason),
            },
            Err(()) => push_reason(&mut reasons, CoverageReasonCode::InvalidUsage),
        }
    }
    let mut records = Vec::new();
    for observation in pair_composer_observations(observations) {
        if observation_is_empty(&observation) {
            ignored = ignored.saturating_add(1);
            continue;
        }
        match collect_observation(observation, &mut records, range) {
            Ok(value) => ignored = ignored.saturating_add(value),
            Err(reason) => push_reason(&mut reasons, reason),
        }
    }
    Ok((records, reasons, ignored))
}

fn parse_store_database(
    connection: &Connection,
    source_file_id: &str,
    range: &super::scan::ScanRange,
    options: &UsageScanOptions,
    rows_seen: &mut usize,
    stopped: &mut bool,
) -> Result<(Vec<NormalizedUsageRecord>, Vec<CoverageReason>, u64), ()> {
    let Some((key_column, value_column)) = blobs_columns(connection)? else {
        return Ok((Vec::new(), Vec::new(), 0));
    };
    let query =
        format!("SELECT \"{key_column}\", \"{value_column}\" FROM blobs ORDER BY \"{key_column}\"");
    let mut statement = connection.prepare(&query).map_err(|_| ())?;
    let mut records = Vec::new();
    let mut reasons = Vec::new();
    let mut ignored = 0u64;
    let rows = statement.query_map([], |row| {
        Ok((optional_text(row.get_ref(0)?), blob_bytes(row.get_ref(1)?)))
    });
    let rows = match rows {
        Ok(value) => value,
        Err(_) => return Err(()),
    };
    let mut parser = CursorParser;
    for row in rows {
        if is_cancelled(options) {
            push_reason(&mut reasons, CoverageReasonCode::ScanCancelled);
            *stopped = true;
            break;
        }
        *rows_seen += 1;
        if *rows_seen > MAXIMUM_CURSOR_ROWS {
            push_reason(&mut reasons, CoverageReasonCode::RecordLimit);
            *stopped = true;
            break;
        }
        let (key, raw) = match row {
            Ok(value) => value,
            Err(_) => {
                push_reason(&mut reasons, CoverageReasonCode::SourceUnreadable);
                continue;
            }
        };
        let Some(value) = decode_json_object(&raw) else {
            continue;
        };
        let mut parsed = parser.parse(&value, source_file_id);
        if let Some(record) = parsed.records.first_mut()
            && record.record_key.is_empty()
        {
            if let Some(key) = key.filter(|value| !value.is_empty()) {
                record.record_key = key;
            }
        }
        ignored = ignored.saturating_add(super::scan::collect_parsed(
            parsed,
            &mut records,
            &mut reasons,
            range,
            *rows_seen as u64,
        ));
    }
    Ok((records, reasons, ignored))
}

fn observation_from_value(
    value: &Map<String, Value>,
    usage: &Map<String, Value>,
    source_file_id: &str,
    record_key: &str,
) -> Result<CursorObservation, CoverageReasonCode> {
    let tokens = parse_tokens(usage).ok_or(CoverageReasonCode::InvalidUsage)?;
    let source_cost = match source_cost_microusd(cost_value(value, usage)) {
        Ok(value) => value,
        Err(()) => return Err(CoverageReasonCode::InvalidUsage),
    };
    let occurred_at = occurred_at(value).ok_or(CoverageReasonCode::InvalidTimestamp)?;
    let occurred_ms = super::parse_instant(&occurred_at)
        .ok_or(CoverageReasonCode::InvalidTimestamp)?
        .timestamp_millis();
    let model = match model_value(value) {
        None => None,
        Some(value) => Some(bounded_model(Some(value)).ok_or(CoverageReasonCode::InvalidModel)?),
    };
    Ok(CursorObservation {
        record_key: record_key.to_owned(),
        occurred_at,
        occurred_ms,
        composer_id: composer_id_from_value(value),
        is_assistant: is_assistant(value),
        model,
        provider: provider_value(value),
        tokens,
        source_cost_present: source_cost.is_some(),
        source_cost,
        source_file_id: source_file_id.to_owned(),
    })
}

fn observation_is_empty(observation: &CursorObservation) -> bool {
    observation.tokens.is_empty()
        && observation
            .source_cost
            .as_deref()
            .is_none_or(|value| value == "0")
}

fn pair_composer_observations(mut observations: Vec<CursorObservation>) -> Vec<CursorObservation> {
    observations.sort_by(|left, right| {
        left.composer_id
            .cmp(&right.composer_id)
            .then(left.occurred_ms.cmp(&right.occurred_ms))
            .then(left.record_key.cmp(&right.record_key))
    });
    let mut paired = Vec::new();
    let mut pending: Option<CursorObservation> = None;
    let mut current_composer = String::new();
    for observation in observations {
        if observation.composer_id != current_composer {
            pending = None;
            current_composer = observation.composer_id.clone();
        }
        if !observation.is_assistant {
            pending = Some(observation);
            continue;
        }
        let Some(user) = pending.take() else {
            paired.push(observation);
            continue;
        };
        paired.push(merge_user_into_assistant(user, observation));
    }
    paired
}

fn merge_user_into_assistant(
    user: CursorObservation,
    mut assistant: CursorObservation,
) -> CursorObservation {
    if assistant.tokens.input == 0 {
        assistant.tokens.input = user.tokens.input;
        if assistant.tokens.cache_read == 0 {
            assistant.tokens.cache_read = user.tokens.cache_read;
        }
        if assistant.tokens.cache_write == 0 {
            assistant.tokens.cache_write = user.tokens.cache_write;
        }
    }
    if assistant.model.is_none() {
        assistant.model = user.model;
    }
    if assistant.provider.is_none() {
        assistant.provider = user.provider;
    }
    if assistant.source_cost.is_none() {
        assistant.source_cost = user.source_cost;
        assistant.source_cost_present |= user.source_cost_present;
    }
    assistant
}

fn fact_line(observation: CursorObservation) -> ParsedLine {
    match fact_record(observation) {
        Ok(record) => ParsedLine {
            records: vec![record],
            reason: None,
            ignored_empty_records: 0,
        },
        Err(reason) => ParsedLine::reason(reason),
    }
}

fn collect_observation(
    observation: CursorObservation,
    records: &mut Vec<NormalizedUsageRecord>,
    range: &super::scan::ScanRange,
) -> Result<u64, CoverageReasonCode> {
    if observation.occurred_ms < range.start_ms || observation.occurred_ms >= range.end_ms {
        return Ok(0);
    }
    records.push(fact_record(observation)?);
    Ok(0)
}

fn fact_record(
    observation: CursorObservation,
) -> Result<NormalizedUsageRecord, CoverageReasonCode> {
    let model = observation
        .model
        .as_deref()
        .and_then(|value| bounded_model_text(Some(value)))
        .ok_or(CoverageReasonCode::InvalidModel)?;
    let (billing_channel, channel_source) = billing_channel(observation.provider.as_deref());
    Ok(NormalizedUsageRecord {
        event: NormalizedUsageEvent {
            occurred_at: observation.occurred_at,
            agent: UsageAgent::Cursor,
            model,
            billing_channel,
            channel_source,
            input_tokens: observation.tokens.input,
            cache_read_tokens: observation.tokens.cache_read,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: observation.tokens.cache_write,
            output_tokens: observation.tokens.output,
            reasoning_tokens: observation.tokens.reasoning,
            requests: 1,
            context_bucket: context_bucket(observation.tokens.input),
            service_tier: "unknown".into(),
            speed: "unknown".into(),
            inference_geo: "unknown".into(),
            billable_tools: BillableTools::default(),
            source_cost_microusd: observation.source_cost.clone(),
            source_cost_covered_requests: if observation.source_cost_present {
                1
            } else {
                0
            },
        },
        source_file_id: observation.source_file_id,
        record_key: observation.record_key,
    })
}

fn usage_map(value: &Map<String, Value>) -> Result<Option<&Map<String, Value>>, ()> {
    if let Some(token_count) = value.get("tokenCount") {
        if token_count.is_null() {
            // Continue to other usage-shaped fields.
        } else {
            return object(Some(token_count)).ok_or(()).map(Some);
        }
    }
    if let Some(usage) = value.get("usage") {
        if usage.is_null() {
            return Ok(None);
        }
        return object(Some(usage)).ok_or(()).map(Some);
    }
    if let Some(message) = object(value.get("message")) {
        if let Some(token_count) = message.get("tokenCount") {
            if !token_count.is_null() {
                return object(Some(token_count)).ok_or(()).map(Some);
            }
        }
        if let Some(usage) = message.get("usage") {
            if usage.is_null() {
                return Ok(None);
            }
            return object(Some(usage)).ok_or(()).map(Some);
        }
    }
    Ok(None)
}

fn parse_tokens(usage: &Map<String, Value>) -> Option<CursorTokens> {
    if usage.contains_key("input_tokens")
        || usage.contains_key("output_tokens")
        || usage.contains_key("cache_read_input_tokens")
        || usage.contains_key("cache_creation_input_tokens")
    {
        return parse_api_tokens(usage);
    }
    if usage.contains_key("inputTokens")
        || usage.contains_key("outputTokens")
        || usage.contains_key("cacheReadTokens")
        || usage.contains_key("cacheWriteTokens")
    {
        return parse_native_tokens(usage);
    }
    if usage.contains_key("input") || usage.contains_key("output") {
        return parse_simple_tokens(usage);
    }
    Some(CursorTokens {
        input: 0,
        cache_read: 0,
        cache_write: 0,
        output: 0,
        reasoning: 0,
    })
}

fn parse_api_tokens(usage: &Map<String, Value>) -> Option<CursorTokens> {
    let uncached = optional_count(usage.get("input_tokens"))?;
    let output = optional_count(usage.get("output_tokens"))?;
    let cache_read = optional_count(usage.get("cache_read_input_tokens"))?;
    let cache_write = optional_count(usage.get("cache_creation_input_tokens"))?;
    let reasoning = parse_reasoning(usage, output)?;
    Some(CursorTokens {
        input: safe_sum(&[uncached, cache_read, cache_write])?,
        cache_read,
        cache_write,
        output,
        reasoning,
    })
}

fn parse_native_tokens(usage: &Map<String, Value>) -> Option<CursorTokens> {
    let input = optional_count(usage.get("inputTokens"))?;
    let output = optional_count(usage.get("outputTokens"))?;
    let cache_read = optional_count(
        usage
            .get("cacheReadTokens")
            .or_else(|| usage.get("cachedReadTokens")),
    )?;
    let cache_write = optional_count(
        usage
            .get("cacheWriteTokens")
            .or_else(|| usage.get("cacheCreationTokens")),
    )?;
    if safe_sum(&[cache_read, cache_write])? > input {
        return None;
    }
    let reasoning = parse_reasoning(usage, output)?;
    Some(CursorTokens {
        input,
        cache_read,
        cache_write,
        output,
        reasoning,
    })
}

fn parse_simple_tokens(usage: &Map<String, Value>) -> Option<CursorTokens> {
    let uncached = optional_count(usage.get("input"))?;
    let output = optional_count(usage.get("output"))?;
    let cache_read = optional_count(usage.get("cacheRead"))?;
    let cache_write = optional_count(usage.get("cacheWrite"))?;
    let reasoning = parse_reasoning(usage, output)?;
    Some(CursorTokens {
        input: safe_sum(&[uncached, cache_read, cache_write])?,
        cache_read,
        cache_write,
        output,
        reasoning,
    })
}

fn parse_reasoning(usage: &Map<String, Value>, output: u64) -> Option<u64> {
    let reasoning = if let Some(value) = usage.get("output_tokens_details") {
        if value.is_null() {
            0
        } else {
            optional_count(object(Some(value))?.get("thinking_tokens"))?
        }
    } else if usage.contains_key("reasoningTokens") {
        optional_count(usage.get("reasoningTokens"))?
    } else if usage.contains_key("reasoning") {
        optional_count(usage.get("reasoning"))?
    } else {
        0
    };
    (reasoning <= output).then_some(reasoning)
}

fn model_value(value: &Map<String, Value>) -> Option<&Value> {
    object(value.get("modelInfo"))
        .and_then(|info| info.get("modelName"))
        .or_else(|| value.get("model"))
        .or_else(|| value.get("modelName"))
        .or_else(|| object(value.get("message")).and_then(|message| message.get("model")))
}

fn provider_value(value: &Map<String, Value>) -> Option<String> {
    value
        .get("provider")
        .or_else(|| value.get("providerID"))
        .or_else(|| value.get("providerId"))
        .or_else(|| value.get("modelProvider"))
        .or_else(|| object(value.get("message")).and_then(|message| message.get("provider")))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn occurred_at(value: &Map<String, Value>) -> Option<String> {
    instant_value(value.get("createdAt"))
        .or_else(|| instant_value(value.get("timestamp")))
        .or_else(|| {
            object(value.get("message")).and_then(|message| instant_value(message.get("timestamp")))
        })
}

fn instant_value(value: Option<&Value>) -> Option<String> {
    let value = value?;
    if let Some(text) = value.as_str() {
        return canonical_instant(text);
    }
    let count = safe_count(Some(value))?;
    let millis = if count >= 10_000_000_000 {
        i64::try_from(count).ok()?
    } else {
        i64::try_from(count).ok()?.checked_mul(1_000)?
    };
    chrono::DateTime::<chrono::Utc>::from_timestamp_millis(millis)
        .map(|value| value.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}

fn is_assistant(value: &Map<String, Value>) -> bool {
    match value.get("type") {
        Some(Value::Number(value)) if value.as_u64() == Some(2) => return true,
        Some(Value::Number(value)) if value.as_u64() == Some(1) => return false,
        Some(Value::String(value)) if value.eq_ignore_ascii_case("assistant") || value == "ai" => {
            return true;
        }
        Some(Value::String(value)) if value.eq_ignore_ascii_case("user") => return false,
        _ => {}
    }
    match value
        .get("role")
        .and_then(Value::as_str)
        .or_else(|| object(value.get("message")).and_then(|message| message.get("role")?.as_str()))
    {
        Some("assistant") => true,
        Some("user") => false,
        _ => true,
    }
}

fn billing_channel(provider: Option<&str>) -> (BillingChannel, ChannelSource) {
    match provider {
        Some("openai") => (BillingChannel::OpenaiDirect, ChannelSource::Explicit),
        Some("anthropic") => (BillingChannel::AnthropicDirect, ChannelSource::Explicit),
        Some("azure-openai") | Some("azure_openai") => {
            (BillingChannel::AzureOpenai, ChannelSource::Explicit)
        }
        Some("amazon-bedrock") | Some("bedrock") => {
            (BillingChannel::AwsBedrock, ChannelSource::Explicit)
        }
        Some("google-vertex") | Some("google_vertex") => {
            (BillingChannel::GoogleVertex, ChannelSource::Explicit)
        }
        Some("openrouter") => (BillingChannel::Openrouter, ChannelSource::Explicit),
        Some("xai") => (BillingChannel::XaiDirect, ChannelSource::Explicit),
        Some("moonshotai") | Some("kimi-for-coding") => {
            (BillingChannel::MoonshotDirect, ChannelSource::Explicit)
        }
        Some("deepseek") => (BillingChannel::DeepseekDirect, ChannelSource::Explicit),
        _ => (BillingChannel::Unknown, ChannelSource::Unknown),
    }
}

fn cost_value<'a>(
    value: &'a Map<String, Value>,
    usage: &'a Map<String, Value>,
) -> Option<&'a Value> {
    value
        .get("costUSD")
        .or_else(|| value.get("cost"))
        .or_else(|| usage.get("costUSD"))
        .or_else(|| object(usage.get("cost")).and_then(|cost| cost.get("total")))
        .or_else(|| usage.get("cost"))
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

fn composer_id_from_value(value: &Map<String, Value>) -> String {
    value
        .get("composerId")
        .or_else(|| value.get("conversationId"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn composer_id_from_key(key: &str) -> Option<String> {
    let rest = key.strip_prefix("bubbleId:")?;
    rest.split_once(':')
        .map(|(composer, _)| composer.to_owned())
}

fn decode_json_object(raw: &[u8]) -> Option<Map<String, Value>> {
    if let Ok(text) = std::str::from_utf8(raw) {
        if let Some(value) = parse_object(text) {
            return Some(value);
        }
        let stripped = text.trim();
        if stripped.len() % 2 == 0
            && !stripped.is_empty()
            && stripped.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            let decoded = decode_hex(stripped)?;
            return parse_object(std::str::from_utf8(&decoded).ok()?);
        }
    }
    None
}

fn parse_object(text: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(text).ok()? {
        Value::Object(value) => Some(value),
        _ => None,
    }
}

fn decode_hex(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        let hi = from_hex(pair[0])?;
        let lo = from_hex(pair[1])?;
        out.push((hi << 4) | lo);
    }
    Some(out)
}

fn from_hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn blob_bytes(value: ValueRef<'_>) -> Vec<u8> {
    match value {
        ValueRef::Blob(value) | ValueRef::Text(value) => value.to_vec(),
        _ => Vec::new(),
    }
}

fn optional_text(value: ValueRef<'_>) -> Option<String> {
    match value {
        ValueRef::Text(value) => std::str::from_utf8(value).ok().map(str::to_owned),
        ValueRef::Blob(value) => std::str::from_utf8(value).ok().map(str::to_owned),
        _ => None,
    }
}

fn table_exists(connection: &Connection, table: &str) -> Result<bool, ()> {
    let exists: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get(0),
        )
        .map_err(|_| ())?;
    Ok(exists > 0)
}

fn table_columns(connection: &Connection, table: &str) -> Result<HashSet<String>, ()> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info(\"{table}\")"))
        .map_err(|_| ())?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|_| ())?;
    let mut columns = HashSet::new();
    for row in rows {
        columns.insert(row.map_err(|_| ())?);
    }
    Ok(columns)
}

fn blobs_columns(connection: &Connection) -> Result<Option<(String, String)>, ()> {
    if !table_exists(connection, "blobs")? {
        return Ok(None);
    }
    let columns = table_columns(connection, "blobs")?;
    let key = ["id", "key", "hash"]
        .into_iter()
        .find(|name| columns.contains(*name))
        .map(str::to_owned);
    let value = ["data", "value", "blob"]
        .into_iter()
        .find(|name| columns.contains(*name))
        .map(str::to_owned);
    Ok(key.zip(value))
}

fn is_sqlite_source(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some("state.vscdb" | "store.db")
    )
}

fn options_with_index(
    options: &UsageScanOptions,
    files: &[super::LocalUsageFile],
) -> UsageScanOptions {
    let ids: HashSet<&str> = files
        .iter()
        .map(|file| file.source_file_id.as_str())
        .collect();
    let mut clone = options.clone();
    clone.file_index = options
        .file_index
        .iter()
        .filter(|(source_file_id, _)| ids.contains(source_file_id.as_str()))
        .map(|(source_file_id, index)| (source_file_id.clone(), index.clone()))
        .collect();
    clone
}

fn database_source(
    options: &UsageScanOptions,
    source: super::LocalUsageFile,
    records: Vec<NormalizedUsageRecord>,
    reasons: Vec<CoverageReason>,
) -> UsageSourceScan {
    let record_keys = records
        .iter()
        .map(|record| record.record_key.clone())
        .collect();
    UsageSourceScan {
        append: false,
        index: file_index(&source, &options.parser_revision),
        source,
        records: records.into_iter().map(|record| record.event).collect(),
        record_keys,
        coverage: source_coverage(UsageAgent::Cursor, options, reasons),
    }
}

fn merge_scans(
    options: &UsageScanOptions,
    mut reasons: Vec<CoverageReason>,
    jsonl: UsageScanResult,
    databases: UsageScanResult,
    deleted_source_file_ids: Vec<String>,
) -> UsageScanResult {
    for reason in jsonl
        .coverage
        .reasons
        .into_iter()
        .chain(databases.coverage.reasons)
    {
        super::scan::push_reason_count(&mut reasons, reason.code, reason.count);
    }
    let mut records = jsonl.records;
    records.extend(databases.records);
    let mut unchanged_source_file_ids = jsonl.unchanged_source_file_ids;
    unchanged_source_file_ids.extend(databases.unchanged_source_file_ids);
    let mut sources = jsonl.sources;
    sources.extend(databases.sources);
    finish_scan(
        UsageAgent::Cursor,
        options,
        super::scan::ScanParts {
            records,
            reasons,
            scanned_source_count: jsonl
                .scanned_source_count
                .saturating_add(databases.scanned_source_count),
            skipped_source_count: jsonl
                .skipped_source_count
                .saturating_add(databases.skipped_source_count),
            ignored_empty_records: jsonl
                .ignored_empty_records
                .saturating_add(databases.ignored_empty_records),
            unchanged_source_file_ids,
            deleted_source_file_ids,
            sources,
        },
    )
}
