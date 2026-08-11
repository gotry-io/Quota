//! Local Usage discovery, parsing, aggregation, and protocol-shaped facts.
//!
//! This module deliberately keeps source paths and file-index metadata local.  The public
//! `UsageHourlyFact` and `NormalizedUsageEvent` types contain only the
//! allow-listed fields that may cross the service boundary.

mod claude;
mod codex;
mod grok;
mod opencode;
mod pi;
mod scan;

#[cfg(test)]
mod tests;

pub use claude::scan_claude_usage;
pub use codex::scan_codex_usage;
pub use grok::scan_grok_usage;
pub use opencode::scan_opencode_usage;
pub use pi::scan_pi_usage;
pub use scan::{UsageScanOptions, discover_usage_files, scan_local_usage};

use chrono::{DateTime, SecondsFormat, Utc};
use chrono_tz::Tz;
use num_bigint::BigUint;
use num_traits::Zero;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;
use std::str::FromStr;

pub const MAX_DISCOVERY_DEPTH: usize = 8;
pub const MAX_DISCOVERY_ENTRIES: usize = 100_000;
pub const MAX_USAGE_FILES: usize = 20_000;
pub const MAX_JSONL_RECORDS: usize = 2_000_000;
pub const MAX_JSONL_LINE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_COVERAGE_REASONS: usize = 128;
/// Protocol v2 `UsageSubmission.rows` bound. Internal retained-history aggregation is unbounded
/// by this submission limit; service_core chunks complete UTC hours before upload.
pub const MAX_USAGE_ROWS: usize = 2_048;
/// Protocol v2 model-cardinality bound per upload submission. Internal retained-history
/// aggregation may contain more models and is chunked at the upload boundary.
pub const MAX_USAGE_MODELS: usize = 64;
/// Protocol v2 local/account report breakdown bound. Unlike hourly rows, this is enforced when
/// materializing the IPC breakdown array, with an explicit error rather than truncation.
pub const MAX_USAGE_BREAKDOWNS: usize = 1_000;
pub const MAX_USAGE_COVERAGE_ITEMS: usize = 2_048;
pub const MAX_USAGE_COVERAGE_HOURS: i64 = 24 * 31;
pub const MAX_SAFE_COUNT: u64 = 9_007_199_254_740_991;

/// The five local Usage sources supported by protocol v2.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, Serialize, PartialOrd)]
pub enum UsageAgent {
    #[serde(rename = "codex")]
    Codex,
    #[serde(rename = "claude_code")]
    ClaudeCode,
    #[serde(rename = "grok")]
    Grok,
    #[serde(rename = "opencode")]
    OpenCode,
    #[serde(rename = "pi")]
    Pi,
}

impl UsageAgent {
    pub const ALL: [Self; 5] = [
        Self::Codex,
        Self::ClaudeCode,
        Self::Grok,
        Self::OpenCode,
        Self::Pi,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude_code",
            Self::Grok => "grok",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
        }
    }
}

impl fmt::Display for UsageAgent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, Serialize, PartialOrd)]
#[serde(rename_all = "snake_case")]
pub enum BillingChannel {
    OpenaiDirect,
    AzureOpenai,
    AnthropicDirect,
    AwsBedrock,
    GoogleVertex,
    Openrouter,
    XaiDirect,
    Unknown,
}

impl BillingChannel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OpenaiDirect => "openai_direct",
            Self::AzureOpenai => "azure_openai",
            Self::AnthropicDirect => "anthropic_direct",
            Self::AwsBedrock => "aws_bedrock",
            Self::GoogleVertex => "google_vertex",
            Self::Openrouter => "openrouter",
            Self::XaiDirect => "xai_direct",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, Serialize, PartialOrd)]
#[serde(rename_all = "snake_case")]
pub enum ChannelSource {
    Explicit,
    AgentDefault,
    Unknown,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, Serialize, PartialOrd)]
pub enum ContextBucket {
    #[serde(rename = "le_128k")]
    Le128k,
    #[serde(rename = "gt_128k_le_200k")]
    Gt128kLe200k,
    #[serde(rename = "gt_200k_le_256k")]
    Gt200kLe256k,
    #[serde(rename = "gt_256k_le_272k")]
    Gt256kLe272k,
    #[serde(rename = "gt_272k")]
    Gt272k,
}

impl ContextBucket {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Le128k => "le_128k",
            Self::Gt128kLe200k => "gt_128k_le_200k",
            Self::Gt200kLe256k => "gt_200k_le_256k",
            Self::Gt256kLe272k => "gt_256k_le_272k",
            Self::Gt272k => "gt_272k",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageStatus {
    Complete,
    Partial,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageReasonCode {
    PermissionDenied,
    SourceUnreadable,
    SourceChanged,
    DiscoveryLimit,
    RecordLimit,
    LineTooLarge,
    TruncatedTail,
    MalformedJson,
    UnknownRecord,
    InvalidTimestamp,
    InvalidModel,
    InvalidUsage,
    ScanCancelled,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CoverageReason {
    pub code: CoverageReasonCode,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ScanCoverage {
    pub agent: UsageAgent,
    pub start_at: String,
    pub end_at: String,
    pub status: CoverageStatus,
    pub reasons: Vec<CoverageReason>,
}

/// Stable identity used by the SQLite file index.  It intentionally has no
/// byte checkpoint or per-record hash: changed files are replaced atomically.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UsageFileIndex {
    pub source_file_id: String,
    pub identity: String,
    pub size: u64,
    pub modified_ns: u128,
    pub parser_revision: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct BillableTools {
    pub web_search: u64,
    pub web_fetch: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct NormalizedUsageEvent {
    pub occurred_at: String,
    pub agent: UsageAgent,
    pub model: String,
    pub billing_channel: BillingChannel,
    pub channel_source: ChannelSource,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_5m_tokens: u64,
    pub cache_write_1h_tokens: u64,
    pub cache_write_inferred_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub requests: u64,
    pub context_bucket: ContextBucket,
    pub service_tier: String,
    pub speed: String,
    pub inference_geo: String,
    pub billable_tools: BillableTools,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_cost_microusd: Option<String>,
    pub source_cost_covered_requests: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NormalizedUsageRecord {
    pub event: NormalizedUsageEvent,
    pub source_file_id: String,
}

#[derive(Clone, Debug)]
pub struct LocalUsageFile {
    /// Local-only path.  Do not derive Serialize for this type.
    pub path: PathBuf,
    pub source_file_id: String,
    pub size: u64,
    pub modified_ns: u128,
    pub identity: String,
}

#[derive(Clone, Debug)]
pub struct UsageFileDiscoveryResult {
    pub files: Vec<LocalUsageFile>,
    pub reasons: Vec<CoverageReason>,
}

/// Scanner delta consumed by `service_core` in one SQLite transaction:
/// replace rows/index/coverage for every `sources` item, delete all rows/index
/// for `deleted_source_file_ids`, and leave unchanged IDs untouched. The
/// transaction computes affected UTC hours by comparing old and new rows;
/// the scanner never emits upload ranges.
#[derive(Clone, Debug)]
pub struct UsageScanResult {
    /// Flat view of records for changed/new sources only. Skipped source rows
    /// are intentionally omitted; the service must read their persisted rows.
    pub records: Vec<NormalizedUsageRecord>,
    pub coverage: ScanCoverage,
    pub scanned_source_count: usize,
    pub skipped_source_count: usize,
    pub unchanged_source_file_ids: Vec<String>,
    pub deleted_source_file_ids: Vec<String>,
    /// Complete replacement units for changed/new files. Each unit's records
    /// cover the requested range and replace that source's persisted rows.
    pub sources: Vec<UsageSourceScan>,
}

impl UsageScanResult {
    /// Return whether the changed/deleted source units are complete enough
    /// for service_core to commit and compare old/new normalized rows. This is
    /// only an eligibility signal; it is not a dirty range or an upload hint.
    pub fn replacement_scan_complete(&self) -> bool {
        if self.coverage.status != CoverageStatus::Complete
            || (self.scanned_source_count == 0 && self.deleted_source_file_ids.is_empty())
        {
            return false;
        }
        true
    }
}

/// Per-file replacement unit for the service's SQLite transaction.
/// `source` contains a local-only path and is never serialized.
#[derive(Clone, Debug)]
pub struct UsageSourceScan {
    /// Persistence-only identity and metadata; no path is included.
    pub index: UsageFileIndex,
    /// Local-only source path and stat snapshot. This type is intentionally
    /// not serializable and must never be put in IPC or upload payloads.
    pub source: LocalUsageFile,
    pub records: Vec<NormalizedUsageEvent>,
    pub coverage: ScanCoverage,
}

#[derive(Clone, Debug)]
pub struct ParsedLine {
    pub records: Vec<NormalizedUsageRecord>,
    pub reason: Option<CoverageReasonCode>,
}

impl ParsedLine {
    pub fn empty() -> Self {
        Self {
            records: Vec::new(),
            reason: None,
        }
    }

    pub fn reason(reason: CoverageReasonCode) -> Self {
        Self {
            records: Vec::new(),
            reason: Some(reason),
        }
    }
}

#[derive(Debug)]
pub struct UsageError(pub String);

impl fmt::Display for UsageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for UsageError {}

impl From<std::io::Error> for UsageError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct UsageHourlyFact {
    pub bucket_start_utc: String,
    pub usage_date: String,
    pub usage_hour: u8,
    pub agent: UsageAgent,
    pub billing_channel: BillingChannel,
    pub channel_source: ChannelSource,
    pub model: String,
    pub context_bucket: ContextBucket,
    pub service_tier: String,
    pub speed: String,
    pub inference_geo: String,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_5m_tokens: u64,
    pub cache_write_1h_tokens: u64,
    pub cache_write_inferred_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub requests: u64,
    pub web_search_requests: u64,
    pub web_fetch_requests: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_cost_microusd: Option<String>,
    pub source_cost_covered_requests: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct UsageTokenTotals {
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_5m_tokens: u64,
    pub cache_write_1h_tokens: u64,
    pub cache_write_inferred_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub requests: u64,
    pub web_search_requests: u64,
    pub web_fetch_requests: u64,
    pub source_cost_microusd: Option<String>,
    pub source_cost_covered_requests: u64,
}

/// Aggregate normalized request facts into deterministic sparse UTC-hour rows.
pub fn aggregate_usage_events(
    events: &[NormalizedUsageEvent],
    aggregation_timezone: &str,
) -> Result<Vec<UsageHourlyFact>, UsageError> {
    let timezone = Tz::from_str(aggregation_timezone)
        .map_err(|_| UsageError("invalid IANA aggregation timezone".into()))?;
    let mut rows: BTreeMap<Vec<String>, UsageHourlyFact> = BTreeMap::new();
    for event in events {
        validate_event(event)?;
        let instant = parse_instant(&event.occurred_at)
            .ok_or_else(|| UsageError("Usage event has an invalid timestamp".into()))?;
        let bucket_start = floor_utc_hour(instant);
        let local = instant.with_timezone(&timezone);
        let row = UsageHourlyFact {
            bucket_start_utc: format_utc_hour(bucket_start),
            usage_date: local.format("%Y-%m-%d").to_string(),
            usage_hour: local.hour() as u8,
            agent: event.agent,
            billing_channel: event.billing_channel,
            channel_source: event.channel_source,
            model: event.model.clone(),
            context_bucket: event.context_bucket,
            service_tier: event.service_tier.clone(),
            speed: event.speed.clone(),
            inference_geo: event.inference_geo.clone(),
            input_tokens: event.input_tokens,
            cache_read_tokens: event.cache_read_tokens,
            cache_write_5m_tokens: event.cache_write_5m_tokens,
            cache_write_1h_tokens: event.cache_write_1h_tokens,
            cache_write_inferred_tokens: event.cache_write_inferred_tokens,
            output_tokens: event.output_tokens,
            reasoning_tokens: event.reasoning_tokens,
            requests: event.requests,
            web_search_requests: event.billable_tools.web_search,
            web_fetch_requests: event.billable_tools.web_fetch,
            source_cost_microusd: event.source_cost_microusd.clone(),
            source_cost_covered_requests: event.source_cost_covered_requests,
        };
        let key = fact_key(&row);
        if let Some(existing) = rows.get_mut(&key) {
            add_fact(existing, &row)?;
        } else {
            rows.insert(key, row);
        }
    }
    Ok(rows.into_values().collect())
}

/// Add validated rows while preserving source-cost coverage.
pub fn fold_usage_facts(rows: &[UsageHourlyFact]) -> Result<UsageTokenTotals, UsageError> {
    let mut totals = UsageTokenTotals::default();
    let mut source_cost = BigUint::zero();
    for row in rows {
        validate_fact(row)?;
        add_totals(&mut totals, row)?;
        if let Some(value) = &row.source_cost_microusd {
            source_cost += parse_nonnegative_decimal_integer(value)
                .ok_or_else(|| UsageError("invalid source_cost_microusd".into()))?;
        }
    }
    totals.source_cost_microusd = if totals.source_cost_covered_requests == 0 {
        None
    } else {
        let value = source_cost.to_string();
        if value.len() > 32 {
            return Err(UsageError(
                "Usage source cost total exceeds protocol bound".into(),
            ));
        }
        Some(value)
    };
    Ok(totals)
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum BreakdownDimension {
    Agent,
    Model,
    BillingChannel,
    UsageDate,
    BucketStartUtc,
}

impl BreakdownDimension {
    pub const LOCAL: [Self; 5] = [
        Self::Agent,
        Self::Model,
        Self::BillingChannel,
        Self::UsageDate,
        Self::BucketStartUtc,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::Model => "model",
            Self::BillingChannel => "billing_channel",
            Self::UsageDate => "usage_date",
            Self::BucketStartUtc => "bucket_start_utc",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct UsageBreakdown {
    pub dimension: String,
    pub key: String,
    pub totals: UsageTokenTotals,
    pub cost: crate::pricing::UsageCostOutcome,
}

/// Build deterministic local breakdowns.  Device breakdowns are assembled by
/// the account/Relay layer because a local fact has no device identity.
pub fn build_usage_breakdowns(
    rows: &[UsageHourlyFact],
    catalog: Option<&crate::pricing::PricingCatalog>,
    mode: crate::pricing::UsageCostMode,
    include_hourly: bool,
) -> Result<Vec<UsageBreakdown>, UsageError> {
    let mut groups: BTreeMap<(BreakdownDimension, String), Vec<usize>> = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        validate_fact(row)?;
        for dimension in BreakdownDimension::LOCAL
            .into_iter()
            .take(if include_hourly { 5 } else { 3 })
        {
            let key = match dimension {
                BreakdownDimension::Agent => row.agent.to_string(),
                BreakdownDimension::Model => row.model.clone(),
                BreakdownDimension::BillingChannel => row.billing_channel.as_str().to_string(),
                BreakdownDimension::UsageDate => row.usage_date.clone(),
                BreakdownDimension::BucketStartUtc => row.bucket_start_utc.clone(),
            };
            groups.entry((dimension, key)).or_default().push(index);
        }
    }
    if groups.len() > MAX_USAGE_BREAKDOWNS {
        return Err(UsageError(
            "Usage breakdown count exceeds protocol limit".into(),
        ));
    }
    let prepared = crate::pricing::prepare_usage_costs(rows, catalog, mode)?;
    groups
        .into_iter()
        .map(|((dimension, key), indexes)| {
            let grouped_rows: Vec<UsageHourlyFact> =
                indexes.iter().map(|index| rows[*index].clone()).collect();
            Ok(UsageBreakdown {
                dimension: dimension.as_str().to_string(),
                key,
                totals: fold_usage_facts(&grouped_rows)?,
                cost: crate::pricing::fold_prepared_usage_costs(&prepared, Some(&indexes))?,
            })
        })
        .collect()
}

pub(crate) fn parse_instant(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|instant| instant.with_timezone(&Utc))
}

pub(crate) fn canonical_instant(value: &str) -> Option<String> {
    parse_instant(value).map(|instant| instant.to_rfc3339_opts(SecondsFormat::Millis, true))
}

pub(crate) fn parse_utc_hour(value: &str) -> Option<DateTime<Utc>> {
    if value.len() != 20 {
        return None;
    }
    let instant = DateTime::parse_from_rfc3339(value)
        .ok()?
        .with_timezone(&Utc);
    if instant.minute() != 0
        || instant.second() != 0
        || instant.nanosecond() != 0
        || format_utc_hour(instant) != value
    {
        return None;
    }
    Some(instant)
}

pub(crate) fn format_utc_hour(instant: DateTime<Utc>) -> String {
    instant.to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub(crate) fn floor_utc_hour(instant: DateTime<Utc>) -> DateTime<Utc> {
    instant
        .with_minute(0)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .expect("UTC instant always has a valid hour boundary")
}

pub(crate) fn context_bucket(input_tokens: u64) -> ContextBucket {
    match input_tokens {
        0..=128_000 => ContextBucket::Le128k,
        128_001..=200_000 => ContextBucket::Gt128kLe200k,
        200_001..=256_000 => ContextBucket::Gt200kLe256k,
        256_001..=272_000 => ContextBucket::Gt256kLe272k,
        _ => ContextBucket::Gt272k,
    }
}

pub(crate) fn safe_count(value: Option<&serde_json::Value>) -> Option<u64> {
    value?.as_u64().filter(|value| *value <= MAX_SAFE_COUNT)
}

pub(crate) fn safe_sum(values: &[u64]) -> Option<u64> {
    let total = values
        .iter()
        .try_fold(0u64, |sum, value| sum.checked_add(*value))?;
    (total <= MAX_SAFE_COUNT).then_some(total)
}

pub(crate) fn bounded_dimension(value: Option<&serde_json::Value>) -> Option<String> {
    bounded_string(value, 64)
}

pub(crate) fn bounded_model(value: Option<&serde_json::Value>) -> Option<String> {
    let value = bounded_string(value, 128)?;
    (value != "unknown").then_some(value)
}

fn bounded_string(value: Option<&serde_json::Value>, max: usize) -> Option<String> {
    let value = value?.as_str()?;
    if value.is_empty() || value.len() > max || !value.is_ascii() {
        return None;
    }
    let mut chars = value.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphanumeric()
        || !chars.all(|character| character.is_ascii_alphanumeric() || "._:+-/".contains(character))
    {
        return None;
    }
    Some(value.to_string())
}

pub(crate) fn object(
    value: Option<&serde_json::Value>,
) -> Option<&serde_json::Map<String, serde_json::Value>> {
    match value? {
        serde_json::Value::Object(value) => Some(value),
        _ => None,
    }
}

pub(crate) fn string_field<'a>(
    value: &'a serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Option<&'a str> {
    value.get(key)?.as_str()
}

pub(crate) fn optional_count(value: Option<&serde_json::Value>) -> Option<u64> {
    match value {
        None | Some(serde_json::Value::Null) => Some(0),
        value => safe_count(value),
    }
}

pub(crate) fn parse_nonnegative_decimal_integer(value: &str) -> Option<BigUint> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    value.parse().ok()
}

fn validate_event(event: &NormalizedUsageEvent) -> Result<(), UsageError> {
    if bounded_text(&event.model, 128).is_none() {
        return Err(UsageError("invalid Usage model".into()));
    }
    if event.billing_channel == BillingChannel::Unknown {
        if event.channel_source != ChannelSource::Unknown {
            return Err(UsageError("unknown channel requires unknown source".into()));
        }
    } else if event.channel_source == ChannelSource::Unknown {
        return Err(UsageError(
            "known channel cannot have unknown source".into(),
        ));
    }
    for dimension in [&event.service_tier, &event.speed, &event.inference_geo] {
        if bounded_text(dimension, 64).is_none() || dimension.contains('/') {
            return Err(UsageError("invalid Usage dimension".into()));
        }
    }
    if event.requests == 0 || event.requests > MAX_SAFE_COUNT {
        return Err(UsageError("invalid Usage request count".into()));
    }
    for count in [
        event.input_tokens,
        event.cache_read_tokens,
        event.cache_write_5m_tokens,
        event.cache_write_1h_tokens,
        event.cache_write_inferred_tokens,
        event.output_tokens,
        event.reasoning_tokens,
        event.billable_tools.web_search,
        event.billable_tools.web_fetch,
        event.source_cost_covered_requests,
    ] {
        if count > MAX_SAFE_COUNT {
            return Err(UsageError(
                "Usage count exceeds JSON safe integer range".into(),
            ));
        }
    }
    let classified = event
        .cache_read_tokens
        .checked_add(event.cache_write_5m_tokens)
        .and_then(|value| value.checked_add(event.cache_write_1h_tokens))
        .and_then(|value| value.checked_add(event.cache_write_inferred_tokens))
        .ok_or_else(|| UsageError("Usage input count overflow".into()))?;
    if classified > event.input_tokens || event.reasoning_tokens > event.output_tokens {
        return Err(UsageError("Usage token subset invariant failed".into()));
    }
    if event.source_cost_covered_requests > event.requests {
        return Err(UsageError("source cost coverage exceeds requests".into()));
    }
    if let Some(cost) = &event.source_cost_microusd {
        if cost.len() > 32 {
            return Err(UsageError("source cost exceeds protocol bound".into()));
        }
        parse_nonnegative_decimal_integer(cost)
            .ok_or_else(|| UsageError("invalid source cost".into()))?;
        if event.source_cost_covered_requests == 0 {
            return Err(UsageError("source cost requires covered requests".into()));
        }
    } else if event.source_cost_covered_requests != 0 {
        return Err(UsageError(
            "source cost coverage requires source cost".into(),
        ));
    }
    Ok(())
}

pub(crate) fn validate_fact(row: &UsageHourlyFact) -> Result<(), UsageError> {
    if parse_utc_hour(&row.bucket_start_utc).is_none()
        || !calendar_date(&row.usage_date)
        || row.usage_hour > 23
        || bounded_text(&row.model, 128).is_none()
    {
        return Err(UsageError("invalid Usage hourly fact".into()));
    }
    if row.requests == 0 {
        return Err(UsageError(
            "Usage facts require a positive request count".into(),
        ));
    }
    if row.billing_channel == BillingChannel::Unknown {
        if row.channel_source != ChannelSource::Unknown {
            return Err(UsageError("unknown channel requires unknown source".into()));
        }
    } else if row.channel_source == ChannelSource::Unknown {
        return Err(UsageError(
            "known channel cannot have unknown source".into(),
        ));
    }
    for count in [
        row.input_tokens,
        row.cache_read_tokens,
        row.cache_write_5m_tokens,
        row.cache_write_1h_tokens,
        row.cache_write_inferred_tokens,
        row.output_tokens,
        row.reasoning_tokens,
        row.requests,
        row.web_search_requests,
        row.web_fetch_requests,
        row.source_cost_covered_requests,
    ] {
        if count > MAX_SAFE_COUNT {
            return Err(UsageError(
                "Usage count exceeds JSON safe integer range".into(),
            ));
        }
    }
    for dimension in [&row.service_tier, &row.speed, &row.inference_geo] {
        if bounded_text(dimension, 64).is_none() || dimension.contains('/') {
            return Err(UsageError("invalid Usage dimension".into()));
        }
    }
    let classified = row
        .cache_read_tokens
        .checked_add(row.cache_write_5m_tokens)
        .and_then(|value| value.checked_add(row.cache_write_1h_tokens))
        .and_then(|value| value.checked_add(row.cache_write_inferred_tokens))
        .ok_or_else(|| UsageError("Usage input count overflow".into()))?;
    if classified > row.input_tokens || row.reasoning_tokens > row.output_tokens {
        return Err(UsageError("Usage token subset invariant failed".into()));
    }
    if row.source_cost_covered_requests > row.requests {
        return Err(UsageError("source cost coverage exceeds requests".into()));
    }
    if let Some(cost) = &row.source_cost_microusd {
        if cost.len() > 32 {
            return Err(UsageError("source cost exceeds protocol bound".into()));
        }
        parse_nonnegative_decimal_integer(cost)
            .ok_or_else(|| UsageError("invalid source cost".into()))?;
        if row.source_cost_covered_requests == 0 {
            return Err(UsageError("source cost requires covered requests".into()));
        }
    } else if row.source_cost_covered_requests != 0 {
        return Err(UsageError(
            "source cost coverage requires source cost".into(),
        ));
    }
    Ok(())
}

fn calendar_date(value: &str) -> bool {
    value.len() == 10
        && value.as_bytes().get(4) == Some(&b'-')
        && value.as_bytes().get(7) == Some(&b'-')
        && chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").is_ok()
}

fn add_fact(target: &mut UsageHourlyFact, source: &UsageHourlyFact) -> Result<(), UsageError> {
    add_row_counts(target, source)?;
    let left = parse_optional_source_cost(target.source_cost_microusd.as_deref())?;
    let right = parse_optional_source_cost(source.source_cost_microusd.as_deref())?;
    target.source_cost_microusd = if target.source_cost_covered_requests == 0 {
        None
    } else {
        Some((left + right).to_string())
    };
    validate_fact(target)
}

fn add_row_counts(
    target: &mut UsageHourlyFact,
    source: &UsageHourlyFact,
) -> Result<(), UsageError> {
    for pair in [
        (&mut target.input_tokens, source.input_tokens),
        (&mut target.cache_read_tokens, source.cache_read_tokens),
        (
            &mut target.cache_write_5m_tokens,
            source.cache_write_5m_tokens,
        ),
        (
            &mut target.cache_write_1h_tokens,
            source.cache_write_1h_tokens,
        ),
        (
            &mut target.cache_write_inferred_tokens,
            source.cache_write_inferred_tokens,
        ),
        (&mut target.output_tokens, source.output_tokens),
        (&mut target.reasoning_tokens, source.reasoning_tokens),
        (&mut target.requests, source.requests),
        (&mut target.web_search_requests, source.web_search_requests),
        (&mut target.web_fetch_requests, source.web_fetch_requests),
        (
            &mut target.source_cost_covered_requests,
            source.source_cost_covered_requests,
        ),
    ] {
        let next = (*pair.0)
            .checked_add(pair.1)
            .ok_or_else(|| UsageError("Usage count overflow".into()))?;
        if next > MAX_SAFE_COUNT {
            return Err(UsageError(
                "Usage count exceeds JSON safe integer range".into(),
            ));
        }
        *pair.0 = next;
    }
    Ok(())
}

fn add_totals(target: &mut UsageTokenTotals, source: &UsageHourlyFact) -> Result<(), UsageError> {
    for pair in [
        (&mut target.input_tokens, source.input_tokens),
        (&mut target.cache_read_tokens, source.cache_read_tokens),
        (
            &mut target.cache_write_5m_tokens,
            source.cache_write_5m_tokens,
        ),
        (
            &mut target.cache_write_1h_tokens,
            source.cache_write_1h_tokens,
        ),
        (
            &mut target.cache_write_inferred_tokens,
            source.cache_write_inferred_tokens,
        ),
        (&mut target.output_tokens, source.output_tokens),
        (&mut target.reasoning_tokens, source.reasoning_tokens),
        (&mut target.requests, source.requests),
        (&mut target.web_search_requests, source.web_search_requests),
        (&mut target.web_fetch_requests, source.web_fetch_requests),
        (
            &mut target.source_cost_covered_requests,
            source.source_cost_covered_requests,
        ),
    ] {
        let next = (*pair.0)
            .checked_add(pair.1)
            .ok_or_else(|| UsageError("Usage total overflow".into()))?;
        if next > MAX_SAFE_COUNT {
            return Err(UsageError(
                "Usage total exceeds JSON safe integer range".into(),
            ));
        }
        *pair.0 = next;
    }
    Ok(())
}

fn fact_key(row: &UsageHourlyFact) -> Vec<String> {
    vec![
        row.bucket_start_utc.clone(),
        row.usage_date.clone(),
        row.usage_hour.to_string(),
        row.agent.to_string(),
        row.billing_channel.as_str().to_string(),
        serde_json::to_string(&row.channel_source).unwrap_or_default(),
        row.model.clone(),
        row.context_bucket.as_str().to_string(),
        row.service_tier.clone(),
        row.speed.clone(),
        row.inference_geo.clone(),
    ]
}

fn bounded_text(value: &str, max: usize) -> Option<&str> {
    if value.is_empty()
        || value.len() > max
        || !value.is_ascii()
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._:+-/*".contains(character))
        || !value.chars().next()?.is_ascii_alphanumeric()
    {
        None
    } else {
        Some(value)
    }
}

fn parse_optional_source_cost(value: Option<&str>) -> Result<BigUint, UsageError> {
    match value {
        None => Ok(BigUint::zero()),
        Some(value) => parse_nonnegative_decimal_integer(value)
            .ok_or_else(|| UsageError("invalid source cost".into())),
    }
}

use chrono::Timelike;
