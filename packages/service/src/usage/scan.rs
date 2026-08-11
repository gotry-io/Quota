use super::{
    CoverageReason, CoverageReasonCode, CoverageStatus, LocalUsageFile, MAX_COVERAGE_REASONS,
    MAX_DISCOVERY_DEPTH, MAX_DISCOVERY_ENTRIES, MAX_JSONL_LINE_BYTES, MAX_JSONL_RECORDS,
    MAX_USAGE_FILES, NormalizedUsageRecord, ParsedLine, ScanCoverage, UsageAgent, UsageError,
    UsageFileDiscoveryResult, UsageFileIndex, UsageScanResult, UsageSourceScan,
};
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, Metadata};
use std::io::{self, BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

pub const DEFAULT_PARSER_REVISION: &str = "usage-rust-v3";

#[derive(Clone, Debug)]
pub struct UsageScanOptions {
    pub home_directory: Option<PathBuf>,
    pub environment: HashMap<String, String>,
    /// Explicit roots are test and service inputs.  When present, no default
    /// roots are added and the values are used verbatim.
    pub roots: Option<Vec<PathBuf>>,
    pub start_at: String,
    pub end_at: String,
    pub cancelled: Option<Arc<AtomicBool>>,
    /// Parser revision stored with the file index. A revision change forces a
    /// complete replacement of every affected source file.
    pub parser_revision: String,
    /// SQLite-backed file index supplied by the service layer. The scanner
    /// never persists this map and never exports local paths.
    pub file_index: HashMap<String, UsageFileIndex>,
}

impl Default for UsageScanOptions {
    fn default() -> Self {
        Self {
            home_directory: None,
            environment: HashMap::new(),
            roots: None,
            start_at: String::new(),
            end_at: String::new(),
            cancelled: None,
            parser_revision: DEFAULT_PARSER_REVISION.into(),
            file_index: HashMap::new(),
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ScanRange {
    pub start_ms: i64,
    pub end_ms: i64,
}

#[derive(Default)]
struct DiscoveryState {
    files: Vec<LocalUsageFile>,
    reasons: Vec<CoverageReason>,
    seen: HashSet<String>,
    entries_visited: usize,
    limit_reached: bool,
}

pub(crate) struct ScanParts {
    pub records: Vec<NormalizedUsageRecord>,
    pub reasons: Vec<CoverageReason>,
    pub scanned_source_count: usize,
    pub skipped_source_count: usize,
    pub unchanged_source_file_ids: Vec<String>,
    pub deleted_source_file_ids: Vec<String>,
    pub sources: Vec<UsageSourceScan>,
}

pub(crate) trait UsageParser {
    fn parse(
        &mut self,
        value: &serde_json::Map<String, serde_json::Value>,
        source_file_id: &str,
    ) -> ParsedLine;
    fn finish(&mut self) -> ParsedLine {
        ParsedLine::empty()
    }
}

pub fn scan_local_usage(
    agent: UsageAgent,
    options: &UsageScanOptions,
) -> Result<UsageScanResult, UsageError> {
    match agent {
        UsageAgent::Codex => super::codex::scan_codex_usage(options),
        UsageAgent::ClaudeCode => super::claude::scan_claude_usage(options),
        UsageAgent::Grok => super::grok::scan_grok_usage(options),
        UsageAgent::OpenCode => super::opencode::scan_opencode_usage(options),
        UsageAgent::Pi => super::pi::scan_pi_usage(options),
    }
}

pub fn discover_usage_files(
    agent: UsageAgent,
    options: &UsageScanOptions,
) -> Result<UsageFileDiscoveryResult, UsageError> {
    let roots = roots_for(agent, options);
    discover_usage_files_at(agent, &roots)
}

pub(crate) fn roots_for(agent: UsageAgent, options: &UsageScanOptions) -> Vec<PathBuf> {
    if let Some(roots) = &options.roots {
        return roots.clone();
    }
    let home = options
        .home_directory
        .clone()
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."));
    let env = |name: &str| {
        options
            .environment
            .get(name)
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
    };
    match agent {
        UsageAgent::Codex => {
            let root = env("CODEX_HOME").unwrap_or_else(|| home.join(".codex"));
            vec![root.join("sessions"), root.join("archived_sessions")]
        }
        UsageAgent::ClaudeCode => {
            let root = env("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home.join(".claude"));
            vec![root.join("projects")]
        }
        UsageAgent::Grok => {
            let root = env("GROK_HOME").unwrap_or_else(|| home.join(".grok"));
            vec![root.join("sessions"), root.join("trace-exports")]
        }
        UsageAgent::OpenCode => {
            let root = env("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local").join("share"));
            vec![root.join("opencode")]
        }
        UsageAgent::Pi => {
            if let Some(root) = env("PI_CODING_AGENT_DIR") {
                vec![root.join("sessions")]
            } else {
                vec![
                    home.join(".pi").join("agent").join("sessions"),
                    home.join(".local")
                        .join("share")
                        .join("pi-coding-agent")
                        .join("sessions"),
                ]
            }
        }
    }
}

pub(crate) fn discover_usage_files_at(
    agent: UsageAgent,
    roots: &[PathBuf],
) -> Result<UsageFileDiscoveryResult, UsageError> {
    let mut state = DiscoveryState::default();

    for root in roots
        .iter()
        .cloned()
        .collect::<std::collections::BTreeSet<_>>()
    {
        walk_usage_tree(agent, &root, 0, &mut state)?;
        if state.limit_reached {
            break;
        }
    }
    state
        .files
        .sort_by(|left, right| left.path.cmp(&right.path));
    Ok(UsageFileDiscoveryResult {
        files: state.files,
        reasons: state.reasons,
    })
}

fn walk_usage_tree(
    agent: UsageAgent,
    path: &Path,
    depth: usize,
    state: &mut DiscoveryState,
) -> Result<(), UsageError> {
    if state.limit_reached {
        return Ok(());
    }
    if depth > MAX_DISCOVERY_DEPTH || state.entries_visited >= MAX_DISCOVERY_ENTRIES {
        push_reason(&mut state.reasons, CoverageReasonCode::DiscoveryLimit);
        state.limit_reached = true;
        return Ok(());
    }
    let metadata = match fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            push_reason(&mut state.reasons, reason_for_io(&error));
            return Ok(());
        }
    };
    if metadata.file_type().is_file() {
        if accepts_file(agent, path) {
            let identity = source_identity_material(&metadata, path);
            let source_file_id = sha256(&format!("{}\0{}", agent, identity));
            if state.seen.insert(source_file_id.clone()) {
                if state.files.len() >= MAX_USAGE_FILES {
                    push_reason(&mut state.reasons, CoverageReasonCode::DiscoveryLimit);
                    state.limit_reached = true;
                } else {
                    state.files.push(LocalUsageFile {
                        path: path.to_path_buf(),
                        source_file_id,
                        size: metadata.len(),
                        modified_ns: modified_ns(&metadata),
                        identity,
                    });
                }
            }
        }
        return Ok(());
    }
    if !metadata.file_type().is_dir() {
        if accepts_file(agent, path) {
            push_reason(&mut state.reasons, CoverageReasonCode::SourceUnreadable);
        }
        return Ok(());
    }

    let mut entries = Vec::new();
    let directory = match fs::read_dir(path) {
        Ok(value) => value,
        Err(error) => {
            push_reason(&mut state.reasons, reason_for_io(&error));
            return Ok(());
        }
    };
    for entry in directory {
        match entry {
            Ok(value) => entries.push(value),
            Err(error) => push_reason(&mut state.reasons, reason_for_io(&error)),
        }
    }
    state.entries_visited = state.entries_visited.saturating_add(entries.len());
    if state.entries_visited > MAX_DISCOVERY_ENTRIES {
        push_reason(&mut state.reasons, CoverageReasonCode::DiscoveryLimit);
        state.limit_reached = true;
        return Ok(());
    }
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if state.limit_reached {
            break;
        }
        let file_type = match entry.file_type() {
            Ok(value) => value,
            Err(error) => {
                push_reason(&mut state.reasons, reason_for_io(&error));
                continue;
            }
        };
        if file_type.is_dir() || file_type.is_file() {
            walk_usage_tree(agent, &entry.path(), depth + 1, state)?;
        } else if accepts_file(agent, &entry.path()) {
            push_reason(&mut state.reasons, CoverageReasonCode::SourceUnreadable);
        }
    }
    Ok(())
}

pub(crate) fn scan_jsonl_files<P, F>(
    agent: UsageAgent,
    options: &UsageScanOptions,
    discovery: UsageFileDiscoveryResult,
    parser_factory: F,
) -> Result<UsageScanResult, UsageError>
where
    P: UsageParser,
    F: Fn() -> P,
{
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
    let mut scanned_source_count = 0usize;
    let mut skipped_source_count = 0usize;
    let mut unchanged_source_file_ids = Vec::new();
    let mut sources = Vec::new();
    let mut records_seen = 0usize;
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
                scanned_source_count += 1;
                let source_reasons = vec![CoverageReason {
                    code: CoverageReasonCode::SourceChanged,
                }];
                sources.push(UsageSourceScan {
                    index: file_index(&file, &options.parser_revision),
                    source: file.clone(),
                    records: Vec::new(),
                    coverage: source_coverage(agent, options, source_reasons),
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
            skipped_source_count += 1;
            unchanged_source_file_ids.push(current.source_file_id);
            continue;
        }
        scanned_source_count += 1;
        let mut parser = parser_factory();
        let mut source_records = Vec::new();
        let source_reasons = RefCell::new(Vec::new());
        match File::open(&file.path) {
            Ok(input) => {
                let mut reader = BufReader::new(input);
                if let Err(_error) = read_jsonl(
                    &mut reader,
                    |line, unterminated| {
                        if is_cancelled(options) {
                            push_reason(
                                &mut source_reasons.borrow_mut(),
                                CoverageReasonCode::ScanCancelled,
                            );
                            stopped = true;
                            return false;
                        }
                        records_seen += 1;
                        if records_seen > MAX_JSONL_RECORDS {
                            push_reason(
                                &mut source_reasons.borrow_mut(),
                                CoverageReasonCode::RecordLimit,
                            );
                            stopped = true;
                            return false;
                        }
                        let value: serde_json::Value = match serde_json::from_slice(line) {
                            Ok(value) => value,
                            Err(_) => {
                                push_reason(
                                    &mut source_reasons.borrow_mut(),
                                    if unterminated {
                                        CoverageReasonCode::TruncatedTail
                                    } else {
                                        CoverageReasonCode::MalformedJson
                                    },
                                );
                                return true;
                            }
                        };
                        let object = match value {
                            serde_json::Value::Object(value) => value,
                            _ => {
                                push_reason(
                                    &mut source_reasons.borrow_mut(),
                                    CoverageReasonCode::UnknownRecord,
                                );
                                return true;
                            }
                        };
                        let parsed = parser.parse(&object, &current.source_file_id);
                        let mut reasons = source_reasons.borrow_mut();
                        collect_parsed(parsed, &mut source_records, &mut reasons, &range);
                        true
                    },
                    |reason| push_reason(&mut source_reasons.borrow_mut(), reason),
                ) {
                    push_reason(
                        &mut source_reasons.borrow_mut(),
                        CoverageReasonCode::SourceUnreadable,
                    );
                }
                if !stopped && !is_cancelled(options) {
                    let mut reasons = source_reasons.borrow_mut();
                    collect_parsed(parser.finish(), &mut source_records, &mut reasons, &range);
                }
            }
            Err(error) => push_reason(&mut source_reasons.borrow_mut(), reason_for_io(&error)),
        }
        let mut source_reasons = source_reasons.into_inner();
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
            coverage: source_coverage(agent, options, source_reasons),
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
        agent,
        options,
        ScanParts {
            records,
            reasons,
            scanned_source_count,
            skipped_source_count,
            unchanged_source_file_ids,
            deleted_source_file_ids,
            sources,
        },
    ))
}

pub(crate) fn collect_parsed(
    parsed: ParsedLine,
    records: &mut Vec<NormalizedUsageRecord>,
    reasons: &mut Vec<CoverageReason>,
    range: &ScanRange,
) {
    if let Some(reason) = parsed.reason {
        push_reason(reasons, reason);
    }
    for record in parsed.records {
        let Some(instant) = super::parse_instant(&record.event.occurred_at) else {
            continue;
        };
        let millis = instant.timestamp_millis();
        if millis >= range.start_ms && millis < range.end_ms {
            records.push(record);
        }
    }
}

pub(crate) fn finish_scan(
    agent: UsageAgent,
    options: &UsageScanOptions,
    parts: ScanParts,
) -> UsageScanResult {
    let status = if parts.reasons.is_empty() {
        CoverageStatus::Complete
    } else {
        CoverageStatus::Partial
    };
    UsageScanResult {
        records: parts.records,
        coverage: ScanCoverage {
            agent,
            start_at: options.start_at.clone(),
            end_at: options.end_at.clone(),
            status,
            reasons: parts
                .reasons
                .into_iter()
                .take(MAX_COVERAGE_REASONS)
                .collect(),
        },
        scanned_source_count: parts.scanned_source_count,
        skipped_source_count: parts.skipped_source_count,
        unchanged_source_file_ids: parts.unchanged_source_file_ids,
        deleted_source_file_ids: parts.deleted_source_file_ids,
        sources: parts.sources,
    }
}

pub(crate) fn source_coverage(
    agent: UsageAgent,
    options: &UsageScanOptions,
    reasons: Vec<CoverageReason>,
) -> ScanCoverage {
    ScanCoverage {
        agent,
        start_at: options.start_at.clone(),
        end_at: options.end_at.clone(),
        status: if reasons.is_empty() {
            CoverageStatus::Complete
        } else {
            CoverageStatus::Partial
        },
        reasons: reasons.into_iter().take(MAX_COVERAGE_REASONS).collect(),
    }
}

pub(crate) fn file_index(file: &LocalUsageFile, parser_revision: &str) -> UsageFileIndex {
    UsageFileIndex {
        source_file_id: file.source_file_id.clone(),
        identity: file.identity.clone(),
        size: file.size,
        modified_ns: file.modified_ns,
        parser_revision: parser_revision.to_owned(),
    }
}

pub(crate) fn parse_range(start: &str, end: &str) -> Result<ScanRange, UsageError> {
    let start = super::parse_utc_hour(start)
        .ok_or_else(|| UsageError("invalid Usage scan start".into()))?;
    let end =
        super::parse_utc_hour(end).ok_or_else(|| UsageError("invalid Usage scan end".into()))?;
    let start_ms = start.timestamp_millis();
    let end_ms = end.timestamp_millis();
    if start_ms >= end_ms {
        return Err(UsageError("Usage scan range must be increasing".into()));
    }
    Ok(ScanRange { start_ms, end_ms })
}

pub(crate) fn matching_file_info(
    file: &LocalUsageFile,
    reasons: &mut Vec<CoverageReason>,
) -> Option<LocalUsageFile> {
    let metadata = match fs::symlink_metadata(&file.path) {
        Ok(value) => value,
        Err(error) => {
            push_reason(
                reasons,
                if error.kind() == io::ErrorKind::NotFound {
                    CoverageReasonCode::SourceChanged
                } else {
                    reason_for_io(&error)
                },
            );
            return None;
        }
    };
    if !metadata.file_type().is_file() {
        push_reason(reasons, CoverageReasonCode::SourceChanged);
        return None;
    }
    let identity = source_identity_material(&metadata, &file.path);
    if identity != file.identity {
        push_reason(reasons, CoverageReasonCode::SourceChanged);
        return None;
    }
    Some(LocalUsageFile {
        path: file.path.clone(),
        source_file_id: file.source_file_id.clone(),
        size: metadata.len(),
        modified_ns: modified_ns(&metadata),
        identity,
    })
}

fn read_jsonl<R, L, O>(
    reader: &mut R,
    mut on_line: L,
    mut on_oversized: O,
) -> Result<(), UsageError>
where
    R: BufRead,
    L: FnMut(&[u8], bool) -> bool,
    O: FnMut(CoverageReasonCode),
{
    let mut pending = Vec::new();
    let mut discarding = false;
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            if !discarding && !pending.is_empty() {
                let line = trim_cr(&pending);
                if !line.is_empty() {
                    on_line(line, true);
                }
            }
            return Ok(());
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(buffer.len(), |index| index + 1);
        let segment_end = newline.unwrap_or(buffer.len());
        let segment = &buffer[..segment_end];
        if !discarding {
            if pending.len().saturating_add(segment.len()) > MAX_JSONL_LINE_BYTES {
                on_oversized(CoverageReasonCode::LineTooLarge);
                pending.clear();
                discarding = true;
            } else {
                pending.extend_from_slice(segment);
            }
        }
        reader.consume(consumed);
        if newline.is_some() {
            if !discarding && !pending.is_empty() {
                let line = trim_cr(&pending);
                if !line.is_empty() && !on_line(line, false) {
                    return Ok(());
                }
            }
            pending.clear();
            discarding = false;
        }
    }
}

fn trim_cr(value: &[u8]) -> &[u8] {
    value.strip_suffix(b"\r").unwrap_or(value)
}

pub(crate) fn push_reason(reasons: &mut Vec<CoverageReason>, code: CoverageReasonCode) {
    if reasons.len() < MAX_COVERAGE_REASONS {
        reasons.push(CoverageReason { code });
    }
}

pub(crate) fn is_cancelled(options: &UsageScanOptions) -> bool {
    options
        .cancelled
        .as_ref()
        .is_some_and(|flag| flag.load(Ordering::Relaxed))
}

pub(crate) fn accepts_file(agent: UsageAgent, path: &Path) -> bool {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    match agent {
        UsageAgent::Codex => name.starts_with("rollout-") && name.ends_with(".jsonl"),
        UsageAgent::ClaudeCode | UsageAgent::Pi => name.ends_with(".jsonl"),
        UsageAgent::Grok => {
            name == "events.jsonl"
                || (path
                    .components()
                    .any(|component| component.as_os_str().to_str() == Some("trace-exports"))
                    && name.ends_with(".jsonl"))
        }
        UsageAgent::OpenCode => name == "opencode.db" || name.ends_with(".json"),
    }
}

pub(crate) fn reason_for_io(error: &io::Error) -> CoverageReasonCode {
    match error.kind() {
        io::ErrorKind::PermissionDenied => CoverageReasonCode::PermissionDenied,
        _ => CoverageReasonCode::SourceUnreadable,
    }
}

fn source_identity_material(metadata: &Metadata, path: &Path) -> String {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let device = metadata.dev();
        let inode = metadata.ino();
        if device != 0 || inode != 0 {
            return format!("{}:{}", device, inode);
        }
    }
    format!(
        "fallback:{}:{}",
        sha256_bytes(path.to_string_lossy().as_bytes()),
        created_ns(metadata)
    )
}

fn modified_ns(metadata: &Metadata) -> u128 {
    metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|value| value.as_nanos())
        .unwrap_or(0)
}

fn created_ns(metadata: &Metadata) -> u128 {
    metadata
        .created()
        .ok()
        .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|value| value.as_nanos())
        .unwrap_or_else(|| modified_ns(metadata))
}

pub(crate) fn sha256(value: &str) -> String {
    sha256_bytes(value.as_bytes())
}

pub(crate) fn sha256_bytes(value: &[u8]) -> String {
    let mut digest = Sha256::new();
    digest.update(value);
    format!("{:x}", digest.finalize())
}
