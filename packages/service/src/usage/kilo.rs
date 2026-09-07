use super::scan::{
    UsageParser, discover_usage_files_at, file_index, finish_scan, is_cancelled,
    matching_file_info, parse_range, push_reason, remember_project_key, roots_for, source_coverage,
};
use super::{
    BillableTools, BillingChannel, ChannelSource, CoverageReason, CoverageReasonCode,
    NormalizedUsageEvent, NormalizedUsageRecord, ParsedLine, UsageAgent, UsageError,
    UsageFileDiscoveryResult, UsageFileIndex, UsageScanResult, UsageSourceScan, bounded_model,
    context_bucket, cwd_from_value, object, optional_count, project_key_from_cwd, safe_sum,
};
use rusqlite::{Connection, OpenFlags, params};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

const MAXIMUM_KILO_ROWS: usize = 2_000_000;

pub fn scan_kilo_usage(options: &super::UsageScanOptions) -> Result<UsageScanResult, UsageError> {
    let roots = roots_for(UsageAgent::Kilo, options);
    let database_roots: Vec<PathBuf> = roots
        .iter()
        .map(|root| {
            if root.file_name().and_then(|name| name.to_str()) == Some("kilo.db") {
                root.clone()
            } else {
                root.join("kilo.db")
            }
        })
        .collect();
    let discovery = discover_usage_files_at(UsageAgent::Kilo, &database_roots)?;
    scan_databases(options, discovery)
}

struct KiloParser;

impl UsageParser for KiloParser {
    fn parse(
        &mut self,
        value: &Map<String, Value>,
        source_file_id: &str,
        _source_path: &Path,
    ) -> ParsedLine {
        if value.get("role").and_then(Value::as_str) != Some("assistant") {
            return ParsedLine::empty();
        }
        if value.get("modelID").and_then(Value::as_str) == Some("unknown") {
            return ParsedLine::empty();
        }
        let Some(model) = bounded_model(value.get("modelID")) else {
            return ParsedLine::reason(CoverageReasonCode::InvalidModel);
        };
        let time = object(value.get("time"));
        let occurred_at = time
            .and_then(|value| {
                value
                    .get("completed")
                    .filter(|value| !value.is_null())
                    .or_else(|| value.get("created").filter(|value| !value.is_null()))
            })
            .and_then(milliseconds_instant);
        let Some(occurred_at) = occurred_at else {
            return ParsedLine::reason(CoverageReasonCode::InvalidTimestamp);
        };
        let tokens = object(value.get("tokens"));
        let cache = tokens.and_then(|value| object(value.get("cache")));
        let Some((input, cache_read, cache_write, output, reasoning)) =
            tokens.and_then(|tokens| parse_tokens(tokens, cache))
        else {
            return ParsedLine::reason(CoverageReasonCode::InvalidUsage);
        };
        let source_cost = match source_cost_microusd(value.get("cost")) {
            Ok(value) => value,
            Err(()) => return ParsedLine::reason(CoverageReasonCode::InvalidUsage),
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
        let channel = provider_billing_channel(value.get("providerID").and_then(Value::as_str));
        ParsedLine {
            records: vec![NormalizedUsageRecord {
                event: NormalizedUsageEvent {
                    occurred_at,
                    agent: UsageAgent::Kilo,
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
                    project_key: cwd_from_value(value).and_then(project_key_from_cwd),
                },
                source_file_id: source_file_id.to_owned(),
                record_key: String::new(),
            }],
            reason: None,
            ignored_empty_records: 0,
        }
    }
}

fn scan_databases(
    options: &super::UsageScanOptions,
    discovery: UsageFileDiscoveryResult,
) -> Result<UsageScanResult, UsageError> {
    let range = parse_range(&options.start_at, &options.end_at)?;
    let discovery_files = discovery.files;
    let discovered_ids: HashSet<String> = discovery_files
        .iter()
        .map(|file| file.source_file_id.clone())
        .collect();
    let allow_deleted_cleanup = discovery.reasons.iter().all(|reason| {
        !matches!(
            reason.code,
            CoverageReasonCode::PermissionDenied
                | CoverageReasonCode::SourceUnreadable
                | CoverageReasonCode::DiscoveryLimit
        )
    });
    let mut records = Vec::new();
    let mut reasons = discovery.reasons;
    let mut scanned_sources = 0usize;
    let mut skipped_sources = 0usize;
    let mut ignored_empty_records = 0u64;
    let mut unchanged_source_file_ids = Vec::new();
    let mut sources = Vec::new();
    let mut project_keys = HashMap::new();
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
        remember_project_key(&mut project_keys, &file);
        let current = match matching_file_info(&file, &mut reasons) {
            Some(value) => value,
            None => {
                scanned_sources += 1;
                sources.push(UsageSourceScan {
                    append: false,
                    index: file_index(&file, &options.parser_revision),
                    source: file.clone(),
                    records: Vec::new(),
                    record_keys: Vec::new(),
                    coverage: source_coverage(
                        UsageAgent::Kilo,
                        options,
                        vec![CoverageReason {
                            code: CoverageReasonCode::SourceChanged,
                            count: 1,
                        }],
                    ),
                });
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
                    sources.push(UsageSourceScan {
                        append: false,
                        index: file_index(&current, &options.parser_revision),
                        source: current.clone(),
                        records: Vec::new(),
                        record_keys: Vec::new(),
                        coverage: source_coverage(UsageAgent::Kilo, options, source_reasons),
                    });
                    continue;
                }
            };
        let mut statement = match connection.prepare(
            "SELECT id, data FROM message WHERE json_valid(data) AND json_extract(data, '$.role') = 'assistant'",
        ) {
            Ok(value) => value,
            Err(_) => {
                push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable);
                for reason in &source_reasons {
                    super::scan::push_reason_count(&mut reasons, reason.code, reason.count);
                }
                sources.push(UsageSourceScan {
                    append: false,
                    index: file_index(&current, &options.parser_revision),
                    source: current.clone(),
                    records: Vec::new(),
                    record_keys: Vec::new(),
                    coverage: source_coverage(UsageAgent::Kilo, options, source_reasons),
                });
                continue;
            }
        };
        match statement.query_map(params![], |row| {
            let data: String = row.get(1)?;
            Ok(data)
        }) {
            Ok(rows) => {
                for row in rows {
                    if is_cancelled(options) {
                        push_reason(&mut source_reasons, CoverageReasonCode::ScanCancelled);
                        stopped = true;
                        break;
                    }
                    rows_seen += 1;
                    if rows_seen > MAXIMUM_KILO_ROWS {
                        push_reason(&mut source_reasons, CoverageReasonCode::RecordLimit);
                        stopped = true;
                        break;
                    }
                    let Ok(data) = row else {
                        push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable);
                        continue;
                    };
                    let Ok(Value::Object(mut value)) = serde_json::from_str::<Value>(&data) else {
                        push_reason(&mut source_reasons, CoverageReasonCode::InvalidUsage);
                        continue;
                    };
                    if let Some(directory) = session_directory(&connection, &value) {
                        value.insert("directory".into(), Value::String(directory));
                    }
                    let parsed = KiloParser.parse(&value, &current.source_file_id, &current.path);
                    ignored_empty_records =
                        ignored_empty_records.saturating_add(super::scan::collect_parsed(
                            parsed,
                            &mut source_records,
                            &mut source_reasons,
                            &range,
                            rows_seen as u64,
                        ));
                }
            }
            Err(_) => push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable),
        }
        drop(statement);
        drop(connection);
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
            source: current.clone(),
            records: source_records
                .iter()
                .map(|record| record.event.clone())
                .collect(),
            record_keys,
            coverage: source_coverage(UsageAgent::Kilo, options, source_reasons),
        });
    }
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
    Ok(finish_scan(
        UsageAgent::Kilo,
        options,
        super::scan::ScanParts {
            records,
            reasons,
            scanned_source_count: scanned_sources,
            skipped_source_count: skipped_sources,
            ignored_empty_records,
            unchanged_source_file_ids,
            deleted_source_file_ids,
            sources,
            project_keys,
        },
    ))
}

fn session_directory(connection: &Connection, value: &Map<String, Value>) -> Option<String> {
    if cwd_from_value(value).is_some() {
        return None;
    }
    let session_id = value.get("session_id").and_then(Value::as_str)?;
    connection
        .query_row(
            "SELECT directory FROM session WHERE id = ?1 LIMIT 1",
            params![session_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .ok()
        .flatten()
        .filter(|value| !value.is_empty())
}

fn parse_tokens(
    tokens: &Map<String, Value>,
    cache: Option<&Map<String, Value>>,
) -> Option<(u64, u64, u64, u64, u64)> {
    let uncached_input = optional_count(tokens.get("input"))?;
    let output = optional_count(tokens.get("output"))?;
    let reasoning = optional_count(tokens.get("reasoning"))?;
    let cache_read = cache
        .map(|cache| optional_count(cache.get("read")))
        .unwrap_or(Some(0))?;
    let cache_write = cache
        .map(|cache| optional_count(cache.get("write")))
        .unwrap_or(Some(0))?;
    if reasoning > output && output > 0 {
        return None;
    }
    let output = output.max(reasoning);
    Some((
        safe_sum(&[uncached_input, cache_read, cache_write])?,
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

fn provider_billing_channel(value: Option<&str>) -> BillingChannel {
    match value {
        Some("openai") => BillingChannel::OpenaiDirect,
        Some("anthropic") => BillingChannel::AnthropicDirect,
        Some("azure-openai") => BillingChannel::AzureOpenai,
        Some("amazon-bedrock") | Some("bedrock") => BillingChannel::AwsBedrock,
        Some("google-vertex") => BillingChannel::GoogleVertex,
        Some("google") | Some("gemini") => BillingChannel::GoogleDirect,
        Some("openrouter") => BillingChannel::Openrouter,
        Some("xai") => BillingChannel::XaiDirect,
        Some("moonshotai") | Some("kimi-for-coding") => BillingChannel::MoonshotDirect,
        Some("deepseek") => BillingChannel::DeepseekDirect,
        _ => BillingChannel::Unknown,
    }
}
