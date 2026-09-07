use super::scan::{
    discover_usage_files_at, file_index, finish_scan, is_cancelled, matching_file_info,
    parse_range, push_reason, remember_project_key, roots_for, source_coverage,
};
use super::{
    BillableTools, BillingChannel, ChannelSource, CoverageReason, CoverageReasonCode,
    NormalizedUsageEvent, NormalizedUsageRecord, UsageAgent, UsageError, UsageFileDiscoveryResult,
    UsageScanResult, UsageSourceScan, bounded_model_text, context_bucket, safe_sum,
};
use rusqlite::{Connection, OpenFlags};
use std::collections::{HashMap, HashSet};
use std::path::Path;

const MAXIMUM_ANTIGRAVITY_ROWS: usize = 2_000_000;

pub fn scan_antigravity_usage(
    options: &super::UsageScanOptions,
) -> Result<UsageScanResult, UsageError> {
    let discovery = discover_usage_files_at(
        UsageAgent::Antigravity,
        &roots_for(UsageAgent::Antigravity, options),
    )?;
    scan_databases(options, discovery)
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
                sources.push(empty_changed(options, file));
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
            skipped_sources += 1;
            unchanged_source_file_ids.push(current.source_file_id);
            continue;
        }
        scanned_sources += 1;
        let mut source_records = Vec::new();
        let mut source_reasons = Vec::new();
        match parse_sqlite_file(&current.path) {
            Ok(events) => {
                let mut seen = HashSet::new();
                for event in events {
                    if is_cancelled(options) {
                        push_reason(&mut source_reasons, CoverageReasonCode::ScanCancelled);
                        stopped = true;
                        break;
                    }
                    rows_seen += 1;
                    if rows_seen > MAXIMUM_ANTIGRAVITY_ROWS {
                        push_reason(&mut source_reasons, CoverageReasonCode::RecordLimit);
                        stopped = true;
                        break;
                    }
                    if event.identities.iter().any(|id| !seen.insert(id.clone())) {
                        continue;
                    }
                    match record_from_event(&event, &current.source_file_id) {
                        Ok(Some(record)) => {
                            if let Some(instant) = super::parse_instant(&record.event.occurred_at) {
                                let millis = instant.timestamp_millis();
                                if millis >= range.start_ms && millis < range.end_ms {
                                    source_records.push(record);
                                }
                            }
                        }
                        Ok(None) => ignored_empty_records = ignored_empty_records.saturating_add(1),
                        Err(code) => push_reason(&mut source_reasons, code),
                    }
                }
            }
            Err(()) => push_reason(&mut source_reasons, CoverageReasonCode::SourceUnreadable),
        }
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
            coverage: source_coverage(UsageAgent::Antigravity, options, source_reasons),
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
        UsageAgent::Antigravity,
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

fn empty_changed(
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
            UsageAgent::Antigravity,
            options,
            vec![CoverageReason {
                code: CoverageReasonCode::SourceChanged,
                count: 1,
            }],
        ),
    }
}

struct UsageEvent {
    timestamp_ms: i64,
    model: Option<String>,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    reasoning_tokens: u64,
    identities: Vec<String>,
}

fn record_from_event(
    event: &UsageEvent,
    source_file_id: &str,
) -> Result<Option<NormalizedUsageRecord>, CoverageReasonCode> {
    let Some(occurred_at) =
        chrono::DateTime::<chrono::Utc>::from_timestamp_millis(event.timestamp_ms)
            .map(|value| value.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
    else {
        return Err(CoverageReasonCode::InvalidTimestamp);
    };
    let Some(model) = bounded_model_text(event.model.as_deref()).filter(|value| value != "unknown")
    else {
        return Err(CoverageReasonCode::InvalidModel);
    };
    let output = event.output_tokens.max(event.reasoning_tokens);
    if event.reasoning_tokens > output {
        return Err(CoverageReasonCode::InvalidUsage);
    }
    let Some(input) = safe_sum(&[
        event.input_tokens,
        event.cache_creation_tokens,
        event.cache_read_tokens,
    ]) else {
        return Err(CoverageReasonCode::InvalidUsage);
    };
    if input == 0 && output == 0 {
        return Ok(None);
    }
    Ok(Some(NormalizedUsageRecord {
        event: NormalizedUsageEvent {
            occurred_at,
            agent: UsageAgent::Antigravity,
            model,
            billing_channel: BillingChannel::Unknown,
            channel_source: ChannelSource::Unknown,
            input_tokens: input,
            cache_read_tokens: event.cache_read_tokens,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: event.cache_creation_tokens,
            output_tokens: output,
            reasoning_tokens: event.reasoning_tokens,
            requests: 1,
            context_bucket: context_bucket(input),
            service_tier: "unknown".into(),
            speed: "unknown".into(),
            inference_geo: "unknown".into(),
            billable_tools: BillableTools::default(),
            source_cost_microusd: None,
            source_cost_covered_requests: 0,
            project_key: None,
        },
        source_file_id: source_file_id.to_owned(),
        record_key: String::new(),
    }))
}

fn parse_sqlite_file(path: &Path) -> Result<Vec<UsageEvent>, ()> {
    let connection =
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|_| ())?;
    let fallback = file_modified_ms(path);
    let trajectory = read_trajectory_timestamp(&connection).ok().flatten();
    let mut events = Vec::new();
    if let Ok(rows) = read_blobs(
        &connection,
        "SELECT idx, metadata FROM steps ORDER BY idx ASC",
    ) {
        for blob in rows {
            if let Ok(mut parsed) = parse_step_events(&blob, trajectory.or(fallback)) {
                events.append(&mut parsed);
            }
        }
    }
    let generation = read_blobs(
        &connection,
        "SELECT idx, data FROM gen_metadata ORDER BY idx ASC",
    );
    match generation {
        Ok(rows) => {
            let mut current_model = None;
            for blob in rows {
                if let Ok((model, mut parsed)) = parse_generation_events(
                    &blob,
                    current_model.as_deref(),
                    trajectory.or(fallback),
                ) {
                    if let Some(model) = model {
                        current_model = Some(model);
                    }
                    events.append(&mut parsed);
                }
            }
        }
        Err(()) if events.is_empty() => return Err(()),
        Err(()) => {}
    }
    Ok(events)
}

fn read_blobs(connection: &Connection, sql: &str) -> Result<Vec<Vec<u8>>, ()> {
    let mut statement = connection.prepare(sql).map_err(|_| ())?;
    let rows = statement
        .query_map([], |row| row.get::<_, Vec<u8>>(1))
        .map_err(|_| ())?;
    let mut blobs = Vec::new();
    for row in rows {
        blobs.push(row.map_err(|_| ())?);
    }
    Ok(blobs)
}

fn read_trajectory_timestamp(connection: &Connection) -> Result<Option<i64>, ()> {
    let mut statement =
        match connection.prepare("SELECT data FROM trajectory_metadata_blob LIMIT 1") {
            Ok(value) => value,
            Err(_) => return Ok(None),
        };
    let blob = statement.query_row([], |row| row.get::<_, Vec<u8>>(0)).ok();
    Ok(blob.and_then(|blob| parse_trajectory_timestamp(&blob).ok().flatten()))
}

fn file_modified_ms(path: &Path) -> Option<i64> {
    std::fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|value| value.as_millis() as i64)
}

fn parse_generation_events(
    blob: &[u8],
    inherited_model: Option<&str>,
    fallback: Option<i64>,
) -> Result<(Option<String>, Vec<UsageEvent>), ()> {
    let root = decode_fields(blob)?;
    let chat_model = field_bytes(&root, 1).ok_or(())?;
    let fields = decode_fields(chat_model)?;
    let model = field_text(&fields, 19)
        .or_else(|| field_text(&fields, 21))
        .or_else(|| inherited_model.map(str::to_owned));
    let timestamp = field_bytes(&fields, 9)
        .and_then(|blob| parse_generation_info_timestamp(blob).ok().flatten())
        .or(fallback);
    let mut events = Vec::new();
    if let Some(usage) = field_bytes(&fields, 4).and_then(|blob| parse_model_usage(blob).ok()) {
        if let Some(event) = usage_event(usage, model.as_deref(), timestamp) {
            events.push(event);
        }
    }
    for retry in field_bytes_all(&fields, 17) {
        if let Ok(Some(usage)) = parse_retry_info(retry)
            && let Some(event) = usage_event(usage, model.as_deref(), timestamp)
        {
            events.push(event);
        }
    }
    Ok((model, events))
}

fn parse_step_events(blob: &[u8], fallback: Option<i64>) -> Result<Vec<UsageEvent>, ()> {
    let fields = decode_fields(blob)?;
    let model_info = field_bytes(&fields, 24)
        .and_then(|blob| parse_model_info(blob).ok())
        .unwrap_or_default();
    let timestamp = field_bytes(&fields, 8)
        .or_else(|| field_bytes(&fields, 1))
        .and_then(|blob| parse_timestamp_message(blob).ok().flatten())
        .or(fallback);
    let mut events = Vec::new();
    if let Some(usage) = field_bytes(&fields, 9).and_then(|blob| parse_model_usage(blob).ok())
        && let Some(event) = usage_event(usage, model_info.model.as_deref(), timestamp)
    {
        events.push(event);
    }
    for retry in field_bytes_all(&fields, 28) {
        if let Ok(Some(usage)) = parse_retry_info(retry)
            && let Some(event) = usage_event(usage, model_info.model.as_deref(), timestamp)
        {
            events.push(event);
        }
    }
    Ok(events)
}

#[derive(Default)]
struct ModelInfo {
    model: Option<String>,
}

fn parse_model_info(blob: &[u8]) -> Result<ModelInfo, ()> {
    let fields = decode_fields(blob)?;
    Ok(ModelInfo {
        model: field_text(&fields, 12).or_else(|| field_text(&fields, 8)),
    })
}

struct ModelUsage {
    input_tokens: u64,
    total_output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    reasoning_tokens: u64,
    visible_output_tokens: u64,
    message_id: Option<String>,
    response_id: Option<String>,
    provider_assigned_message_id: Option<String>,
}

fn parse_retry_info(blob: &[u8]) -> Result<Option<ModelUsage>, ()> {
    let fields = decode_fields(blob)?;
    field_bytes(&fields, 2).map(parse_model_usage).transpose()
}

fn parse_model_usage(blob: &[u8]) -> Result<ModelUsage, ()> {
    let fields = decode_fields(blob)?;
    Ok(ModelUsage {
        input_tokens: field_varint(&fields, 2).unwrap_or(0),
        total_output_tokens: field_varint(&fields, 3).unwrap_or(0),
        cache_creation_tokens: field_varint(&fields, 4).unwrap_or(0),
        cache_read_tokens: field_varint(&fields, 5).unwrap_or(0),
        reasoning_tokens: field_varint(&fields, 9).unwrap_or(0),
        visible_output_tokens: field_varint(&fields, 10).unwrap_or(0),
        message_id: field_text(&fields, 7),
        response_id: field_text(&fields, 11),
        provider_assigned_message_id: field_text(&fields, 12),
    })
}

fn usage_event(
    usage: ModelUsage,
    model: Option<&str>,
    timestamp: Option<i64>,
) -> Option<UsageEvent> {
    let output = if usage.total_output_tokens > 0 {
        usage.total_output_tokens
    } else {
        usage
            .visible_output_tokens
            .saturating_add(usage.reasoning_tokens)
    };
    if usage.input_tokens == 0
        && output == 0
        && usage.cache_creation_tokens == 0
        && usage.cache_read_tokens == 0
        && usage.reasoning_tokens == 0
    {
        return None;
    }
    let timestamp_ms = timestamp?;
    let mut identities = Vec::new();
    if let Some(value) = usage.response_id.filter(|value| !value.is_empty()) {
        identities.push(format!("response:{value}"));
    }
    if let Some(value) = usage
        .provider_assigned_message_id
        .filter(|value| !value.is_empty())
    {
        identities.push(format!("provider:{value}"));
    }
    if let Some(value) = usage.message_id.filter(|value| !value.is_empty()) {
        identities.push(format!("message:{value}"));
    }
    Some(UsageEvent {
        timestamp_ms,
        model: model.map(str::to_owned),
        input_tokens: usage.input_tokens,
        output_tokens: output,
        cache_creation_tokens: usage.cache_creation_tokens,
        cache_read_tokens: usage.cache_read_tokens,
        reasoning_tokens: usage.reasoning_tokens,
        identities,
    })
}

fn parse_generation_info_timestamp(blob: &[u8]) -> Result<Option<i64>, ()> {
    let fields = decode_fields(blob)?;
    let Some(timestamp) = field_bytes(&fields, 4) else {
        return Ok(None);
    };
    parse_timestamp_message(timestamp)
}

fn parse_trajectory_timestamp(blob: &[u8]) -> Result<Option<i64>, ()> {
    let fields = decode_fields(blob)?;
    field_bytes(&fields, 2)
        .map(parse_timestamp_message)
        .transpose()
        .map(Option::flatten)
}

fn parse_timestamp_message(blob: &[u8]) -> Result<Option<i64>, ()> {
    let fields = decode_fields(blob)?;
    let Some(seconds) = field_varint(&fields, 1)
        .and_then(|value| i64::try_from(value).ok())
        .filter(|seconds| *seconds > 0)
    else {
        return Ok(None);
    };
    let nanos = field_varint(&fields, 2).unwrap_or(0).min(999_999_999);
    Ok(Some(
        seconds
            .saturating_mul(1_000)
            .saturating_add((nanos / 1_000_000) as i64),
    ))
}

#[derive(Clone, Copy)]
enum ProtoValue<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Other,
}

struct ProtoField<'a> {
    number: u32,
    value: ProtoValue<'a>,
}

fn decode_fields(mut blob: &[u8]) -> Result<Vec<ProtoField<'_>>, ()> {
    let mut fields = Vec::new();
    while !blob.is_empty() {
        let tag = read_varint(&mut blob)?;
        let number = u32::try_from(tag >> 3).map_err(|_| ())?;
        if number == 0 {
            return Err(());
        }
        let value = match tag & 7 {
            0 => ProtoValue::Varint(read_varint(&mut blob)?),
            1 => {
                take_bytes(&mut blob, 8)?;
                ProtoValue::Other
            }
            2 => ProtoValue::Bytes(take_length_delimited(&mut blob)?),
            5 => {
                take_bytes(&mut blob, 4)?;
                ProtoValue::Other
            }
            _ => return Err(()),
        };
        fields.push(ProtoField { number, value });
    }
    Ok(fields)
}

fn read_varint(blob: &mut &[u8]) -> Result<u64, ()> {
    let mut value = 0_u64;
    for shift in (0..10).map(|index| index * 7) {
        let byte = *blob.first().ok_or(())?;
        *blob = &blob[1..];
        let payload = u64::from(byte & 0x7f);
        if shift == 63 && payload > 1 {
            return Err(());
        }
        value |= payload << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
        if shift == 63 {
            return Err(());
        }
    }
    Err(())
}

fn take_bytes<'a>(blob: &mut &'a [u8], length: usize) -> Result<&'a [u8], ()> {
    if blob.len() < length {
        return Err(());
    }
    let (value, rest) = blob.split_at(length);
    *blob = rest;
    Ok(value)
}

fn take_length_delimited<'a>(blob: &mut &'a [u8]) -> Result<&'a [u8], ()> {
    let length = usize::try_from(read_varint(blob)?).map_err(|_| ())?;
    take_bytes(blob, length)
}

fn field_varint(fields: &[ProtoField<'_>], number: u32) -> Option<u64> {
    fields.iter().rev().find_map(|field| match field {
        ProtoField {
            number: field_number,
            value: ProtoValue::Varint(value),
        } if *field_number == number => Some(*value),
        _ => None,
    })
}

fn field_bytes<'a>(fields: &'a [ProtoField<'a>], number: u32) -> Option<&'a [u8]> {
    fields.iter().find_map(|field| match field {
        ProtoField {
            number: field_number,
            value: ProtoValue::Bytes(value),
        } if *field_number == number => Some(*value),
        _ => None,
    })
}

fn field_bytes_all<'a>(fields: &'a [ProtoField<'a>], number: u32) -> Vec<&'a [u8]> {
    fields
        .iter()
        .filter_map(|field| match field {
            ProtoField {
                number: field_number,
                value: ProtoValue::Bytes(value),
            } if *field_number == number => Some(*value),
            _ => None,
        })
        .collect()
}

fn field_text(fields: &[ProtoField<'_>], number: u32) -> Option<String> {
    fields
        .iter()
        .rev()
        .find_map(|field| match field {
            ProtoField {
                number: field_number,
                value: ProtoValue::Bytes(value),
            } if *field_number == number => Some(*value),
            _ => None,
        })
        .and_then(|value| std::str::from_utf8(value).ok())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

#[cfg(test)]
pub(crate) fn encode_generation_blob(
    model: &str,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    reasoning: u64,
    seconds: u64,
) -> Vec<u8> {
    let mut usage = Vec::new();
    field_varint_out(2, input, &mut usage);
    field_varint_out(3, output, &mut usage);
    field_varint_out(4, cache_write, &mut usage);
    field_varint_out(5, cache_read, &mut usage);
    field_varint_out(9, reasoning, &mut usage);
    let mut timestamp = Vec::new();
    field_varint_out(1, seconds, &mut timestamp);
    let mut generation_info = Vec::new();
    field_bytes_out(4, &timestamp, &mut generation_info);
    let mut chat_model = Vec::new();
    field_bytes_out(4, &usage, &mut chat_model);
    field_bytes_out(9, &generation_info, &mut chat_model);
    field_bytes_out(19, model.as_bytes(), &mut chat_model);
    let mut metadata = Vec::new();
    field_bytes_out(1, &chat_model, &mut metadata);
    metadata
}

#[cfg(test)]
fn field_varint_out(number: u64, value: u64, output: &mut Vec<u8>) {
    write_varint((number << 3) | 0, output);
    write_varint(value, output);
}

#[cfg(test)]
fn field_bytes_out(number: u64, value: &[u8], output: &mut Vec<u8>) {
    write_varint((number << 3) | 2, output);
    write_varint(value.len() as u64, output);
    output.extend_from_slice(value);
}

#[cfg(test)]
fn write_varint(mut value: u64, output: &mut Vec<u8>) {
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        output.push(byte);
        if value == 0 {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    #[test]
    fn parses_generation_usage_from_conversation_db() {
        let path = std::env::temp_dir().join(format!(
            "quota-antigravity-usage-{}.db",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("time")
                .as_nanos()
        ));
        let connection = Connection::open(&path).expect("db");
        connection
            .execute_batch(
                "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB NOT NULL);",
            )
            .expect("schema");
        let blob = encode_generation_blob("gemini-3-pro", 100, 40, 10, 5, 8, 1_786_356_060);
        connection
            .execute(
                "INSERT INTO gen_metadata(idx, data) VALUES (1, ?1)",
                params![blob],
            )
            .expect("insert");
        drop(connection);
        let events = parse_sqlite_file(&path).expect("parse");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].model.as_deref(), Some("gemini-3-pro"));
        assert_eq!(events[0].input_tokens, 100);
        assert_eq!(events[0].output_tokens, 40);
        assert_eq!(events[0].cache_read_tokens, 10);
        assert_eq!(events[0].cache_creation_tokens, 5);
        assert_eq!(events[0].reasoning_tokens, 8);
        let _ = std::fs::remove_file(path);
    }
}
