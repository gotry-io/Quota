use super::scan::{
    UsageParser, discover_usage_files_at, file_index, finish_scan, is_cancelled,
    matching_file_info, parse_range, push_reason, reason_for_io, remember_project_key, roots_for,
    scan_jsonl_files, source_coverage,
};
use super::{
    BillableTools, BillingChannel, ChannelSource, CoverageReason, CoverageReasonCode,
    NormalizedUsageEvent, NormalizedUsageRecord, ParsedLine, UsageAgent, UsageError,
    UsageFileDiscoveryResult, UsageScanResult, UsageSourceScan, bounded_model, canonical_instant,
    context_bucket, cwd_from_value, object, optional_count, project_key_from_cwd,
    project_key_from_source_path, safe_sum,
};
use serde_json::{Map, Value};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::Path;

pub fn scan_gemini_usage(
    options: &super::UsageScanOptions,
) -> Result<super::UsageScanResult, UsageError> {
    let discovery =
        discover_usage_files_at(UsageAgent::Gemini, &roots_for(UsageAgent::Gemini, options))?;
    let mut jsonl = UsageFileDiscoveryResult {
        files: Vec::new(),
        reasons: discovery.reasons.clone(),
    };
    let mut json = UsageFileDiscoveryResult {
        files: Vec::new(),
        reasons: discovery.reasons,
    };
    for file in discovery.files {
        if file.path.extension().and_then(|value| value.to_str()) == Some("jsonl") {
            jsonl.files.push(file);
        } else {
            json.files.push(file);
        }
    }
    if json.files.is_empty() {
        return scan_jsonl_files(UsageAgent::Gemini, options, jsonl, |_| GeminiParser);
    }
    let json_ids: HashSet<String> = json
        .files
        .iter()
        .map(|file| file.source_file_id.clone())
        .collect();
    let mut jsonl_options = options.clone();
    jsonl_options
        .file_index
        .retain(|id, _| !json_ids.contains(id));
    let jsonl_result =
        scan_jsonl_files(UsageAgent::Gemini, &jsonl_options, jsonl, |_| GeminiParser)?;
    let json_result = scan_json_conversations(options, json)?;
    Ok(merge_scans(options, jsonl_result, json_result))
}

fn scan_json_conversations(
    options: &super::UsageScanOptions,
    discovery: UsageFileDiscoveryResult,
) -> Result<UsageScanResult, UsageError> {
    let range = parse_range(&options.start_at, &options.end_at)?;
    let json_ids: HashSet<String> = discovery
        .files
        .iter()
        .map(|file| file.source_file_id.clone())
        .collect();
    let mut records = Vec::new();
    let mut reasons = discovery.reasons;
    let mut scanned_source_count = 0usize;
    let mut skipped_source_count = 0usize;
    let mut ignored_empty_records = 0u64;
    let mut unchanged_source_file_ids = Vec::new();
    let mut sources = Vec::new();
    let mut project_keys = HashMap::new();
    for file in discovery.files {
        if is_cancelled(options) {
            push_reason(&mut reasons, CoverageReasonCode::ScanCancelled);
            break;
        }
        remember_project_key(&mut project_keys, &file);
        let current = match matching_file_info(&file, &mut reasons) {
            Some(value) => value,
            None => {
                scanned_source_count += 1;
                sources.push(empty_changed_source(UsageAgent::Gemini, options, file));
                continue;
            }
        };
        if options
            .file_index
            .get(&current.source_file_id)
            .is_some_and(|old| {
                old.identity == current.identity
                    && old.size == current.size
                    && old.modified_ns == current.modified_ns
                    && old.parser_revision == options.parser_revision
            })
        {
            skipped_source_count += 1;
            unchanged_source_file_ids.push(current.source_file_id);
            continue;
        }
        scanned_source_count += 1;
        let mut parser = GeminiParser::default();
        let source_reasons = RefCell::new(Vec::new());
        let mut source_records = Vec::new();
        match read_json_file(&current.path) {
            Ok(value) => {
                let parsed_messages = conversation_messages(&value);
                if parsed_messages.is_empty() && value.is_object() {
                    let parsed = parser.parse(
                        value.as_object().expect("object"),
                        &current.source_file_id,
                        &current.path,
                    );
                    ignored_empty_records = ignored_empty_records.saturating_add(
                        super::scan::collect_parsed_with_prefix(
                            parsed,
                            &mut source_records,
                            &mut source_reasons.borrow_mut(),
                            &range,
                            "json:0",
                        ),
                    );
                } else {
                    for (index, message) in parsed_messages.into_iter().enumerate() {
                        let parsed = parser.parse(&message, &current.source_file_id, &current.path);
                        ignored_empty_records = ignored_empty_records.saturating_add(
                            super::scan::collect_parsed_with_prefix(
                                parsed,
                                &mut source_records,
                                &mut source_reasons.borrow_mut(),
                                &range,
                                &format!("json:{index}"),
                            ),
                        );
                    }
                }
                ignored_empty_records =
                    ignored_empty_records.saturating_add(super::scan::collect_parsed_with_prefix(
                        parser.finish(),
                        &mut source_records,
                        &mut source_reasons.borrow_mut(),
                        &range,
                        "finish",
                    ));
            }
            Err(reason) => push_reason(&mut source_reasons.borrow_mut(), reason),
        }
        let source_reasons = source_reasons.into_inner();
        for reason in &source_reasons {
            super::scan::push_reason_count(&mut reasons, reason.code, reason.count);
        }
        records.extend(source_records.iter().cloned());
        let record_keys = source_records
            .iter()
            .map(|record| record.record_key.clone())
            .collect();
        sources.push(UsageSourceScan {
            append: false,
            index: file_index(&current, &options.parser_revision),
            source: current,
            records: source_records
                .iter()
                .map(|record| record.event.clone())
                .collect(),
            record_keys,
            coverage: source_coverage(UsageAgent::Gemini, options, source_reasons),
        });
    }
    Ok(finish_scan(
        UsageAgent::Gemini,
        options,
        super::scan::ScanParts {
            records,
            reasons,
            scanned_source_count,
            skipped_source_count,
            ignored_empty_records,
            unchanged_source_file_ids,
            deleted_source_file_ids: options
                .file_index
                .keys()
                .filter(|id| !json_ids.contains(*id))
                .cloned()
                .collect(),
            sources,
            project_keys,
        },
    ))
}

fn empty_changed_source(
    agent: UsageAgent,
    options: &super::UsageScanOptions,
    file: super::LocalUsageFile,
) -> UsageSourceScan {
    UsageSourceScan {
        append: false,
        index: file_index(&file, &options.parser_revision),
        source: file,
        records: Vec::new(),
        record_keys: Vec::new(),
        coverage: source_coverage(
            agent,
            options,
            vec![CoverageReason {
                code: CoverageReasonCode::SourceChanged,
                count: 1,
            }],
        ),
    }
}

fn merge_scans(
    options: &super::UsageScanOptions,
    mut jsonl: UsageScanResult,
    mut json: UsageScanResult,
) -> UsageScanResult {
    jsonl.records.append(&mut json.records);
    jsonl.sources.append(&mut json.sources);
    jsonl
        .unchanged_source_file_ids
        .append(&mut json.unchanged_source_file_ids);
    jsonl.scanned_source_count += json.scanned_source_count;
    jsonl.skipped_source_count += json.skipped_source_count;
    jsonl.ignored_empty_records += json.ignored_empty_records;
    jsonl.coverage.reasons.extend(json.coverage.reasons);
    jsonl.coverage.status = if jsonl.coverage.reasons.is_empty() {
        super::CoverageStatus::Complete
    } else {
        super::CoverageStatus::Partial
    };
    let discovered: HashSet<String> = jsonl
        .sources
        .iter()
        .map(|source| source.index.source_file_id.clone())
        .chain(jsonl.unchanged_source_file_ids.iter().cloned())
        .collect();
    jsonl.deleted_source_file_ids = options
        .file_index
        .keys()
        .filter(|id| !discovered.contains(*id))
        .cloned()
        .collect();
    jsonl.deleted_source_file_ids.sort();
    jsonl.project_keys.extend(json.project_keys);
    jsonl
}

fn read_json_file(path: &Path) -> Result<Value, CoverageReasonCode> {
    let file = fs::File::open(path).map_err(|error| reason_for_io(&error))?;
    let mut bytes = Vec::new();
    file.take(super::MAX_JSONL_LINE_BYTES.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| reason_for_io(&error))?;
    if bytes.len() > super::MAX_JSONL_LINE_BYTES {
        return Err(CoverageReasonCode::LineTooLarge);
    }
    if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
        return Ok(value);
    }
    let mut messages = Vec::new();
    for line in bytes.split(|byte| *byte == b'\n') {
        let line = trim_ascii(line);
        if line.is_empty() {
            continue;
        }
        match serde_json::from_slice::<Value>(line) {
            Ok(Value::Object(object)) => messages.push(Value::Object(object)),
            Ok(_) => return Err(CoverageReasonCode::UnknownRecord),
            Err(_) => return Err(CoverageReasonCode::MalformedJson),
        }
    }
    Ok(Value::Array(messages))
}

fn trim_ascii(value: &[u8]) -> &[u8] {
    let start = value
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(value.len());
    let end = value
        .iter()
        .rposition(|byte| !byte.is_ascii_whitespace())
        .map(|index| index + 1)
        .unwrap_or(0);
    if start >= end {
        &[]
    } else {
        &value[start..end]
    }
}

fn conversation_messages(value: &Value) -> Vec<Map<String, Value>> {
    match value {
        Value::Object(object) => object
            .get("messages")
            .and_then(Value::as_array)
            .map(|messages| {
                messages
                    .iter()
                    .filter_map(|message| message.as_object().cloned())
                    .collect()
            })
            .unwrap_or_default(),
        Value::Array(messages) => messages
            .iter()
            .filter_map(|message| message.as_object().cloned())
            .collect(),
        _ => Vec::new(),
    }
}

#[derive(Default)]
struct GeminiParser;

impl UsageParser for GeminiParser {
    const CONTEXT_FREE: bool = true;

    fn parse(
        &mut self,
        value: &Map<String, Value>,
        source_file_id: &str,
        source_path: &Path,
    ) -> ParsedLine {
        if value.get("messages").is_some() {
            let mut records = Vec::new();
            let mut reason = None;
            let mut ignored_empty_records = 0;
            for message in conversation_messages(&Value::Object(value.clone())) {
                let parsed = self.parse(&message, source_file_id, source_path);
                records.extend(parsed.records);
                ignored_empty_records += parsed.ignored_empty_records;
                if reason.is_none() {
                    reason = parsed.reason;
                }
            }
            return ParsedLine {
                records,
                reason,
                ignored_empty_records,
            };
        }
        let message_type = value.get("type").and_then(Value::as_str);
        if message_type.is_some_and(|value| value != "gemini") {
            return ParsedLine::empty();
        }
        if message_type.is_none() && value.get("tokens").is_none() {
            return ParsedLine::empty();
        }
        gemini_message(value, source_file_id, source_path)
    }
}

fn gemini_message(
    value: &Map<String, Value>,
    source_file_id: &str,
    source_path: &Path,
) -> ParsedLine {
    let Some(tokens) = object(value.get("tokens")) else {
        return if value.get("type").and_then(Value::as_str) == Some("gemini") {
            ParsedLine::ignored_empty()
        } else {
            ParsedLine::empty()
        };
    };
    let Some(occurred_at) = value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(canonical_instant)
    else {
        return ParsedLine::reason(CoverageReasonCode::InvalidTimestamp);
    };
    let Some(model) = bounded_model(value.get("model")) else {
        return ParsedLine::reason(CoverageReasonCode::InvalidModel);
    };
    let Some(input) = optional_count(tokens.get("input")) else {
        return ParsedLine::reason(CoverageReasonCode::InvalidUsage);
    };
    let Some(output) = optional_count(tokens.get("output")) else {
        return ParsedLine::reason(CoverageReasonCode::InvalidUsage);
    };
    let Some(cached) = optional_count(tokens.get("cached")) else {
        return ParsedLine::reason(CoverageReasonCode::InvalidUsage);
    };
    let Some(thoughts) = optional_count(tokens.get("thoughts")) else {
        return ParsedLine::reason(CoverageReasonCode::InvalidUsage);
    };
    if cached > input {
        return ParsedLine::reason(CoverageReasonCode::InvalidUsage);
    }
    let output_tokens = if thoughts > output {
        match safe_sum(&[output, thoughts]) {
            Some(total) => total,
            None => return ParsedLine::reason(CoverageReasonCode::InvalidUsage),
        }
    } else {
        output
    };
    if input == 0 && output_tokens == 0 && cached == 0 && thoughts == 0 {
        return ParsedLine::ignored_empty();
    }
    ParsedLine {
        records: vec![NormalizedUsageRecord {
            event: NormalizedUsageEvent {
                occurred_at,
                agent: UsageAgent::Gemini,
                model,
                billing_channel: BillingChannel::Unknown,
                channel_source: ChannelSource::Unknown,
                input_tokens: input,
                cache_read_tokens: cached,
                cache_write_5m_tokens: 0,
                cache_write_1h_tokens: 0,
                cache_write_inferred_tokens: 0,
                output_tokens,
                reasoning_tokens: thoughts,
                requests: 1,
                context_bucket: context_bucket(input),
                service_tier: "unknown".into(),
                speed: "unknown".into(),
                inference_geo: "unknown".into(),
                billable_tools: BillableTools::default(),
                source_cost_microusd: None,
                source_cost_covered_requests: 0,
                project_key: cwd_from_value(value)
                    .and_then(project_key_from_cwd)
                    .or_else(|| project_key_from_source_path(source_path)),
            },
            source_file_id: source_file_id.to_owned(),
            record_key: String::new(),
        }],
        reason: None,
        ignored_empty_records: 0,
    }
}
