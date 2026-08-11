use super::scan::{
    UsageParser, discover_usage_files_at, file_index, finish_scan, is_cancelled,
    matching_file_info, parse_range, push_reason, roots_for, scan_jsonl_files, source_coverage,
};
use super::{
    BillableTools, BillingChannel, ChannelSource, CoverageReason, CoverageReasonCode,
    NormalizedUsageEvent, NormalizedUsageRecord, ParsedLine, UsageAgent, UsageError,
    UsageFileDiscoveryResult, UsageFileIndex, UsageScanResult, UsageSourceScan, bounded_model,
    context_bucket, object, safe_count, safe_sum,
};
use rusqlite::{Connection, OpenFlags, params};
use serde_json::{Map, Number, Value};
use std::collections::HashSet;
use std::path::PathBuf;

const MAXIMUM_OPENCODE_ROWS: usize = 2_000_000;

pub fn scan_opencode_usage(
    options: &super::UsageScanOptions,
) -> Result<UsageScanResult, UsageError> {
    let roots = roots_for(UsageAgent::OpenCode, options);
    let database_roots: Vec<PathBuf> = roots
        .iter()
        .map(|root| {
            if root.file_name().and_then(|name| name.to_str()) == Some("opencode.db") {
                root.clone()
            } else {
                root.join("opencode.db")
            }
        })
        .collect();
    let database_discovery = discover_usage_files_at(UsageAgent::OpenCode, &database_roots)?;
    if database_discovery
        .files
        .iter()
        .any(|file| file.path.file_name().and_then(|name| name.to_str()) == Some("opencode.db"))
        || !database_discovery.reasons.is_empty()
    {
        return scan_databases(options, database_discovery);
    }
    let legacy_roots: Vec<PathBuf> = if options.roots.is_some() {
        roots
    } else {
        roots
            .into_iter()
            .map(|root| root.join("storage").join("message"))
            .collect()
    };
    let discovery = discover_usage_files_at(UsageAgent::OpenCode, &legacy_roots)?;
    scan_jsonl_files(UsageAgent::OpenCode, options, discovery, || OpenCodeParser)
}

struct OpenCodeParser;

impl UsageParser for OpenCodeParser {
    fn parse(&mut self, value: &Map<String, Value>, source_file_id: &str) -> ParsedLine {
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
            tokens.and_then(|tokens| cache.and_then(|cache| parse_tokens(tokens, cache)))
        else {
            return ParsedLine::reason(CoverageReasonCode::InvalidUsage);
        };
        let source_cost = match source_cost_microusd(value.get("cost")) {
            Ok(value) => value,
            Err(()) => return ParsedLine::reason(CoverageReasonCode::InvalidUsage),
        };
        if input == 0 && output == 0 && source_cost.is_none() {
            return ParsedLine::empty();
        }
        let channel = provider_billing_channel(value.get("providerID").and_then(Value::as_str));
        ParsedLine {
            records: vec![NormalizedUsageRecord {
                event: NormalizedUsageEvent {
                    occurred_at,
                    agent: UsageAgent::OpenCode,
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
            }],
            reason: None,
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
                }];
                sources.push(UsageSourceScan {
                    index: file_index(&file, &options.parser_revision),
                    source: file.clone(),
                    records: Vec::new(),
                    coverage: source_coverage(UsageAgent::OpenCode, options, source_reasons),
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
                    let source = current.clone();
                    for reason in &source_reasons {
                        push_reason(&mut reasons, reason.code);
                    }
                    sources.push(UsageSourceScan {
                        index: file_index(&source, &options.parser_revision),
                        source,
                        records: Vec::new(),
                        coverage: source_coverage(UsageAgent::OpenCode, options, source_reasons),
                    });
                    continue;
                }
            };
        let mut statement = match connection.prepare(DATABASE_QUERY) {
            Ok(value) => value,
            Err(_) => {
                push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable);
                for reason in &source_reasons {
                    push_reason(&mut reasons, reason.code);
                }
                sources.push(UsageSourceScan {
                    index: file_index(&current, &options.parser_revision),
                    source: current.clone(),
                    records: Vec::new(),
                    coverage: source_coverage(UsageAgent::OpenCode, options, source_reasons),
                });
                continue;
            }
        };
        {
            let queried =
                statement.query_map(params![range.start_ms, range.end_ms], map_database_row);
            match queried {
                Ok(rows) => {
                    for row in rows {
                        if is_cancelled(options) {
                            push_reason(&mut source_reasons, CoverageReasonCode::ScanCancelled);
                            stopped = true;
                            break;
                        }
                        rows_seen += 1;
                        if rows_seen > MAXIMUM_OPENCODE_ROWS {
                            push_reason(&mut source_reasons, CoverageReasonCode::RecordLimit);
                            stopped = true;
                            break;
                        }
                        let db_row = match row {
                            Ok(value) => value,
                            Err(_) => {
                                push_reason(
                                    &mut source_reasons,
                                    CoverageReasonCode::SourceUnreadable,
                                );
                                continue;
                            }
                        };
                        let value = db_row.value();
                        let mut parser = OpenCodeParser;
                        let parsed = parser.parse(&value, &current.source_file_id);
                        super::scan::collect_parsed(
                            parsed,
                            &mut source_records,
                            &mut source_reasons,
                            &range,
                        );
                    }
                }
                Err(_) => push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable),
            }
        }
        drop(statement);
        drop(connection);
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
            push_reason(&mut reasons, reason.code);
        }
        records.extend(source_records.iter().cloned());
        sources.push(UsageSourceScan {
            index: file_index(&source, &options.parser_revision),
            source,
            records: source_records
                .into_iter()
                .map(|record| record.event)
                .collect(),
            coverage: source_coverage(UsageAgent::OpenCode, options, source_reasons),
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
        UsageAgent::OpenCode,
        options,
        super::scan::ScanParts {
            records,
            reasons,
            scanned_source_count: scanned_sources,
            skipped_source_count: skipped_sources,
            unchanged_source_file_ids,
            deleted_source_file_ids,
            sources,
        },
    ))
}

struct DatabaseRow {
    _id: String,
    role: Option<String>,
    model_id: Option<String>,
    provider_id: Option<String>,
    created_at: Option<i64>,
    completed_at: Option<i64>,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    reasoning_tokens: Option<i64>,
    cache_read_tokens: Option<i64>,
    cache_write_tokens: Option<i64>,
    cost: Option<f64>,
}

impl DatabaseRow {
    fn value(&self) -> Map<String, Value> {
        let mut value = Map::new();
        value.insert(
            "role".into(),
            self.role.clone().map(Value::String).unwrap_or(Value::Null),
        );
        value.insert(
            "modelID".into(),
            self.model_id
                .clone()
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
        value.insert(
            "providerID".into(),
            self.provider_id
                .clone()
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
        let mut time = Map::new();
        time.insert(
            "created".into(),
            self.created_at
                .map(|value| Value::Number(value.into()))
                .unwrap_or(Value::Null),
        );
        time.insert(
            "completed".into(),
            self.completed_at
                .map(|value| Value::Number(value.into()))
                .unwrap_or(Value::Null),
        );
        value.insert("time".into(), Value::Object(time));
        let mut cache = Map::new();
        cache.insert(
            "read".into(),
            self.cache_read_tokens
                .map(|value| Value::Number(value.into()))
                .unwrap_or(Value::Null),
        );
        cache.insert(
            "write".into(),
            self.cache_write_tokens
                .map(|value| Value::Number(value.into()))
                .unwrap_or(Value::Null),
        );
        let mut tokens = Map::new();
        tokens.insert(
            "input".into(),
            self.input_tokens
                .map(|value| Value::Number(value.into()))
                .unwrap_or(Value::Null),
        );
        tokens.insert(
            "output".into(),
            self.output_tokens
                .map(|value| Value::Number(value.into()))
                .unwrap_or(Value::Null),
        );
        tokens.insert(
            "reasoning".into(),
            self.reasoning_tokens
                .map(|value| Value::Number(value.into()))
                .unwrap_or(Value::Null),
        );
        tokens.insert("cache".into(), Value::Object(cache));
        value.insert("tokens".into(), Value::Object(tokens));
        value.insert(
            "cost".into(),
            self.cost
                .and_then(Number::from_f64)
                .map(Value::Number)
                .unwrap_or(Value::Null),
        );
        value
    }
}

fn map_database_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DatabaseRow> {
    Ok(DatabaseRow {
        _id: row.get(0)?,
        role: row.get(1)?,
        model_id: row.get(2)?,
        provider_id: row.get(3)?,
        created_at: row.get(4)?,
        completed_at: row.get(5)?,
        input_tokens: row.get(6)?,
        output_tokens: row.get(7)?,
        reasoning_tokens: row.get(8)?,
        cache_read_tokens: row.get(9)?,
        cache_write_tokens: row.get(10)?,
        cost: row.get(11)?,
    })
}

const DATABASE_QUERY: &str = r#"
SELECT
  id,
  json_extract(data, '$.role'),
  json_extract(data, '$.modelID'),
  json_extract(data, '$.providerID'),
  json_extract(data, '$.time.created'),
  json_extract(data, '$.time.completed'),
  json_extract(data, '$.tokens.input'),
  json_extract(data, '$.tokens.output'),
  json_extract(data, '$.tokens.reasoning'),
  json_extract(data, '$.tokens.cache.read'),
  json_extract(data, '$.tokens.cache.write'),
  json_extract(data, '$.cost')
FROM message
WHERE json_extract(data, '$.role') = 'assistant'
  AND COALESCE(json_extract(data, '$.time.completed'), json_extract(data, '$.time.created'), time_created) >= ?1
  AND COALESCE(json_extract(data, '$.time.completed'), json_extract(data, '$.time.created'), time_created) < ?2
ORDER BY time_created, id
"#;

fn parse_tokens(
    tokens: &Map<String, Value>,
    cache: &Map<String, Value>,
) -> Option<(u64, u64, u64, u64, u64)> {
    let uncached_input = safe_count(tokens.get("input"))?;
    let output = safe_count(tokens.get("output"))?;
    let reasoning = safe_count(tokens.get("reasoning"))?;
    let cache_read = safe_count(cache.get("read"))?;
    let cache_write = safe_count(cache.get("write"))?;
    if reasoning > output {
        return None;
    }
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
        Some("openrouter") => BillingChannel::Openrouter,
        Some("xai") => BillingChannel::XaiDirect,
        _ => BillingChannel::Unknown,
    }
}
