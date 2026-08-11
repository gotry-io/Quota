//! Exact, protocol-compatible Usage pricing.
//!
//! Rates are decimal USD per million tokens (or USD per request).  No binary
//! floating-point operation participates in the calculation: each stored row
//! is rounded half-up once and the resulting integer micro-USD amounts are
//! summed.

use crate::usage::{
    BillingChannel, ChannelSource, ContextBucket, MAX_SAFE_COUNT, UsageError, UsageHourlyFact,
};
use num_bigint::BigUint;
use num_traits::{One, Zero};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

const MAX_PRICING_ENTRIES: usize = 4_096;
const MAX_UNPRICED_ITEMS: usize = 100;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum UsageCostMode {
    Calculate,
    Auto,
    Reported,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum UsageCostBasis {
    Calculated,
    Reported,
    Mixed,
    None,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum UsageCostStatus {
    Complete,
    Partial,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageCostAssumption {
    AgentDefaultChannel,
    ModelAlias,
    WildcardServiceTier,
    WildcardSpeed,
    WildcardInferenceGeo,
    WildcardContextBucket,
    CacheWriteInferredRate,
    SourceReported,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageUnpricedReason {
    UnknownChannel,
    UnknownModel,
    OutsideEffectiveRange,
    UnsupportedDimensions,
    AmbiguousPrice,
    MissingRate,
    IncompleteSourceCost,
    InvalidCatalog,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct UsageUnpricedItem {
    pub billing_channel: BillingChannel,
    pub model: String,
    pub reason: UsageUnpricedReason,
    pub rows: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct UsageCostOutcome {
    pub mode: UsageCostMode,
    pub basis: UsageCostBasis,
    pub status: UsageCostStatus,
    pub amount_microusd: Option<String>,
    pub catalog_revision: Option<String>,
    pub calculated_rows: u64,
    pub reported_rows: u64,
    pub unpriced_rows: u64,
    pub assumptions: Vec<UsageCostAssumption>,
    pub unpriced: Vec<UsageUnpricedItem>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub unpriced_truncated: bool,
}

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PricingRates {
    pub uncached_input_per_million: Option<String>,
    pub cache_read_per_million: Option<String>,
    pub cache_write_5m_per_million: Option<String>,
    pub cache_write_1h_per_million: Option<String>,
    pub cache_write_inferred_per_million: Option<String>,
    pub output_per_million: Option<String>,
    pub web_search_per_request: Option<String>,
    pub web_fetch_per_request: Option<String>,
}

impl PricingRates {
    fn all(&self) -> [(&'static str, Option<&String>); 8] {
        [
            (
                "uncached_input_per_million",
                self.uncached_input_per_million.as_ref(),
            ),
            (
                "cache_read_per_million",
                self.cache_read_per_million.as_ref(),
            ),
            (
                "cache_write_5m_per_million",
                self.cache_write_5m_per_million.as_ref(),
            ),
            (
                "cache_write_1h_per_million",
                self.cache_write_1h_per_million.as_ref(),
            ),
            (
                "cache_write_inferred_per_million",
                self.cache_write_inferred_per_million.as_ref(),
            ),
            ("output_per_million", self.output_per_million.as_ref()),
            (
                "web_search_per_request",
                self.web_search_per_request.as_ref(),
            ),
            ("web_fetch_per_request", self.web_fetch_per_request.as_ref()),
        ]
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PricingCatalogEntry {
    pub entry_id: String,
    pub billing_channel: BillingChannel,
    pub model: String,
    pub aliases: Vec<String>,
    pub effective_from: String,
    pub effective_to: Option<String>,
    pub service_tier: String,
    pub speed: String,
    pub inference_geo: String,
    pub context_bucket: String,
    pub currency: String,
    pub rates: PricingRates,
    pub source_url: String,
    pub verified_at: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PricingCatalog {
    pub protocol_version: u8,
    pub revision: String,
    pub published_at: String,
    pub entries: Vec<PricingCatalogEntry>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PricingCatalogValidationIssue {
    InvalidSchema { path: String, message: String },
    DuplicateEntryId { entry_ids: (String, String) },
    AmbiguousEntries { entry_ids: (String, String) },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PricingCatalogValidationResult {
    pub valid: bool,
    pub catalog: Option<PricingCatalog>,
    pub issues: Vec<PricingCatalogValidationIssue>,
}

/// Validate both the wire shape and catalogue-wide resolution ambiguity.
pub fn validate_pricing_catalog(input: &serde_json::Value) -> PricingCatalogValidationResult {
    let catalog = match serde_json::from_value::<PricingCatalog>(input.clone()) {
        Ok(value) => value,
        Err(error) => {
            return PricingCatalogValidationResult {
                valid: false,
                catalog: None,
                issues: vec![PricingCatalogValidationIssue::InvalidSchema {
                    path: String::new(),
                    message: error.to_string(),
                }],
            };
        }
    };
    validate_catalog(&catalog)
}

pub fn validate_catalog(catalog: &PricingCatalog) -> PricingCatalogValidationResult {
    let mut issues = Vec::new();
    if catalog.protocol_version != 2 {
        issues.push(invalid("protocol_version", "expected protocol version 2"));
    }
    if !opaque_id(&catalog.revision) {
        issues.push(invalid("revision", "invalid pricing revision"));
    }
    if super::usage::parse_instant(&catalog.published_at).is_none() {
        issues.push(invalid("published_at", "invalid RFC3339 instant"));
    }
    if catalog.entries.len() > MAX_PRICING_ENTRIES {
        issues.push(invalid("entries", "too many pricing entries"));
    }
    let mut ids = BTreeSet::new();
    for entry in &catalog.entries {
        validate_entry(entry, &mut issues);
        if !ids.insert(entry.entry_id.clone()) {
            issues.push(PricingCatalogValidationIssue::DuplicateEntryId {
                entry_ids: (entry.entry_id.clone(), entry.entry_id.clone()),
            });
        }
    }
    for left in 0..catalog.entries.len() {
        for right in left + 1..catalog.entries.len() {
            let a = &catalog.entries[left];
            let b = &catalog.entries[right];
            if pricing_entries_ambiguous(a, b) {
                issues.push(PricingCatalogValidationIssue::AmbiguousEntries {
                    entry_ids: (a.entry_id.clone(), b.entry_id.clone()),
                });
            }
        }
    }
    PricingCatalogValidationResult {
        valid: issues.is_empty(),
        catalog: issues.is_empty().then(|| catalog.clone()),
        issues,
    }
}

#[derive(Clone, Debug)]
pub enum PricingResolution {
    Priced {
        entry: Box<PricingCatalogEntry>,
        assumptions: Vec<UsageCostAssumption>,
    },
    Unpriced(UsageUnpricedReason),
}

pub fn resolve_pricing_entry(catalog: &PricingCatalog, row: &UsageHourlyFact) -> PricingResolution {
    if row.billing_channel == BillingChannel::Unknown {
        return PricingResolution::Unpriced(UsageUnpricedReason::UnknownChannel);
    }
    let by_model: Vec<&PricingCatalogEntry> = catalog
        .entries
        .iter()
        .filter(|entry| {
            entry.billing_channel == row.billing_channel
                && (entry.model == row.model
                    || entry.aliases.iter().any(|alias| alias == &row.model))
        })
        .collect();
    if by_model.is_empty() {
        return PricingResolution::Unpriced(UsageUnpricedReason::UnknownModel);
    }
    let date = row.bucket_start_utc.get(..10).unwrap_or_default();
    let by_date: Vec<&PricingCatalogEntry> = by_model
        .into_iter()
        .filter(|entry| {
            entry.effective_from.as_str() <= date
                && entry.effective_to.as_deref().is_none_or(|end| date < end)
        })
        .collect();
    if by_date.is_empty() {
        return PricingResolution::Unpriced(UsageUnpricedReason::OutsideEffectiveRange);
    }
    let mut matches: Vec<(&PricingCatalogEntry, u8)> = by_date
        .into_iter()
        .filter(|entry| {
            dimension_matches(&entry.service_tier, &row.service_tier)
                && dimension_matches(&entry.speed, &row.speed)
                && dimension_matches(&entry.inference_geo, &row.inference_geo)
                && context_matches(&entry.context_bucket, row.context_bucket)
        })
        .map(|entry| (entry, pricing_specificity(entry, &row.model)))
        .collect();
    if matches.is_empty() {
        return PricingResolution::Unpriced(UsageUnpricedReason::UnsupportedDimensions);
    }
    matches.sort_by_key(|(_, specificity)| std::cmp::Reverse(*specificity));
    let (entry, specificity) = matches[0];
    if matches
        .get(1)
        .is_some_and(|(_, other)| *other == specificity)
    {
        return PricingResolution::Unpriced(UsageUnpricedReason::AmbiguousPrice);
    }
    let mut assumptions = Vec::new();
    if entry.model != row.model {
        assumptions.push(UsageCostAssumption::ModelAlias);
    }
    if entry.service_tier == "*" {
        assumptions.push(UsageCostAssumption::WildcardServiceTier);
    }
    if entry.speed == "*" {
        assumptions.push(UsageCostAssumption::WildcardSpeed);
    }
    if entry.inference_geo == "*" {
        assumptions.push(UsageCostAssumption::WildcardInferenceGeo);
    }
    if entry.context_bucket == "*" {
        assumptions.push(UsageCostAssumption::WildcardContextBucket);
    }
    PricingResolution::Priced {
        entry: Box::new(entry.clone()),
        assumptions,
    }
}

#[derive(Clone, Debug)]
pub enum PreparedUsageCostRow {
    Priced {
        billing_channel: BillingChannel,
        model: String,
        amount_microusd: BigUint,
        basis: UsageCostBasis,
        assumptions: Vec<UsageCostAssumption>,
    },
    Unpriced {
        billing_channel: BillingChannel,
        model: String,
        reason: UsageUnpricedReason,
    },
}

#[derive(Clone, Debug)]
pub struct PreparedUsageCosts {
    pub mode: UsageCostMode,
    pub catalog_revision: Option<String>,
    pub rows: Vec<PreparedUsageCostRow>,
}

pub fn calculate_usage_cost(
    rows: &[UsageHourlyFact],
    catalog: Option<&PricingCatalog>,
    mode: UsageCostMode,
) -> Result<UsageCostOutcome, UsageError> {
    let prepared = prepare_usage_costs(rows, catalog, mode)?;
    fold_prepared_usage_costs(&prepared, None)
}

/// Resolve and round each row once.  An empty index list means all rows.
pub fn prepare_usage_costs(
    rows: &[UsageHourlyFact],
    catalog: Option<&PricingCatalog>,
    mode: UsageCostMode,
) -> Result<PreparedUsageCosts, UsageError> {
    let catalog_valid = if mode == UsageCostMode::Reported {
        None
    } else {
        catalog.and_then(|catalog| validate_catalog(catalog).valid.then_some(catalog))
    };
    let catalog_revision = catalog_valid.map(|catalog| catalog.revision.clone());
    let mut prepared = Vec::with_capacity(rows.len());
    for row in rows {
        super::usage::validate_fact(row)?;
        let calculated = match mode {
            UsageCostMode::Reported => None,
            UsageCostMode::Calculate | UsageCostMode::Auto => Some(match catalog_valid {
                None => Err(UsageUnpricedReason::InvalidCatalog),
                Some(catalog) => match calculate_row_from_catalog(catalog, row) {
                    CalculatedUsageRowCost::Priced {
                        amount_microusd,
                        assumptions,
                        ..
                    } => Ok((amount_microusd, assumptions)),
                    CalculatedUsageRowCost::Unpriced(reason) => Err(reason),
                },
            }),
        };
        let calculated_row = calculated.clone().and_then(Result::ok);
        if let Some((amount, mut assumptions)) = calculated_row {
            if row.channel_source == ChannelSource::AgentDefault {
                assumptions.push(UsageCostAssumption::AgentDefaultChannel);
            }
            prepared.push(PreparedUsageCostRow::Priced {
                billing_channel: row.billing_channel,
                model: row.model.clone(),
                amount_microusd: amount,
                basis: UsageCostBasis::Calculated,
                assumptions,
            });
            continue;
        }
        let can_use_reported = matches!(mode, UsageCostMode::Reported)
            || (mode == UsageCostMode::Auto && catalog_valid.is_some());
        if can_use_reported
            && row.source_cost_microusd.is_some()
            && row.source_cost_covered_requests == row.requests
        {
            let amount = parse_biguint(row.source_cost_microusd.as_deref().unwrap_or("0"))?;
            let mut assumptions = vec![UsageCostAssumption::SourceReported];
            if row.channel_source == ChannelSource::AgentDefault {
                assumptions.push(UsageCostAssumption::AgentDefaultChannel);
            }
            prepared.push(PreparedUsageCostRow::Priced {
                billing_channel: row.billing_channel,
                model: row.model.clone(),
                amount_microusd: amount,
                basis: UsageCostBasis::Reported,
                assumptions,
            });
        } else {
            let reason = match mode {
                UsageCostMode::Reported => UsageUnpricedReason::IncompleteSourceCost,
                UsageCostMode::Calculate | UsageCostMode::Auto => calculated
                    .and_then(Result::err)
                    .unwrap_or(UsageUnpricedReason::InvalidCatalog),
            };
            prepared.push(PreparedUsageCostRow::Unpriced {
                billing_channel: row.billing_channel,
                model: row.model.clone(),
                reason,
            });
        }
    }
    Ok(PreparedUsageCosts {
        mode,
        catalog_revision,
        rows: prepared,
    })
}

pub fn fold_prepared_usage_costs(
    prepared: &PreparedUsageCosts,
    indexes: Option<&[usize]>,
) -> Result<UsageCostOutcome, UsageError> {
    let selected: Vec<usize> = indexes.map_or_else(
        || (0..prepared.rows.len()).collect(),
        |value| value.to_vec(),
    );
    let mut amount = BigUint::zero();
    let mut calculated_rows = 0u64;
    let mut reported_rows = 0u64;
    let mut assumptions = BTreeSet::new();
    let mut unpriced = BTreeMap::<(BillingChannel, String, UsageUnpricedReason), u64>::new();
    for index in selected.iter().copied() {
        let Some(row) = prepared.rows.get(index) else {
            return Err(UsageError(format!(
                "missing prepared Usage row at index {index}"
            )));
        };
        match row {
            PreparedUsageCostRow::Priced {
                amount_microusd: value,
                basis,
                assumptions: row_assumptions,
                ..
            } => {
                amount += value;
                match basis {
                    UsageCostBasis::Calculated => {
                        calculated_rows = checked_add(calculated_rows, 1)?
                    }
                    UsageCostBasis::Reported => reported_rows = checked_add(reported_rows, 1)?,
                    _ => return Err(UsageError("prepared row has invalid pricing basis".into())),
                }
                assumptions.extend(row_assumptions.iter().copied());
            }
            PreparedUsageCostRow::Unpriced {
                billing_channel,
                model,
                reason,
            } => {
                let key = (*billing_channel, model.clone(), *reason);
                let count = unpriced.entry(key).or_default();
                *count = checked_add(*count, 1)?;
            }
        }
    }
    let selected_rows = selected.len() as u64;
    let priced_rows = calculated_rows
        .checked_add(reported_rows)
        .ok_or_else(|| UsageError("pricing row count overflow".into()))?;
    let unpriced_rows = selected_rows
        .checked_sub(priced_rows)
        .ok_or_else(|| UsageError("pricing row count invariant failed".into()))?;
    let basis = if calculated_rows > 0 && reported_rows > 0 {
        UsageCostBasis::Mixed
    } else if calculated_rows > 0 {
        UsageCostBasis::Calculated
    } else if reported_rows > 0 {
        UsageCostBasis::Reported
    } else {
        UsageCostBasis::None
    };
    let status = if unpriced_rows == 0 {
        UsageCostStatus::Complete
    } else if priced_rows > 0 {
        UsageCostStatus::Partial
    } else {
        UsageCostStatus::Unavailable
    };
    let unpriced_truncated = unpriced.len() > MAX_UNPRICED_ITEMS;
    let mut assumptions = assumptions.into_iter().collect::<Vec<_>>();
    assumptions.sort_by_key(|value| assumption_key(*value));
    let mut unpriced = unpriced
        .into_iter()
        .map(
            |((billing_channel, model, reason), rows)| UsageUnpricedItem {
                billing_channel,
                model,
                reason,
                rows,
            },
        )
        .collect::<Vec<_>>();
    unpriced.sort_by(|left, right| {
        (
            left.billing_channel.as_str(),
            left.model.as_str(),
            reason_key(left.reason),
        )
            .cmp(&(
                right.billing_channel.as_str(),
                right.model.as_str(),
                reason_key(right.reason),
            ))
    });
    let amount_microusd = if priced_rows > 0 {
        let value = amount.to_string();
        if value.len() > 32 {
            return Err(UsageError(
                "Usage cost amount exceeds protocol bound".into(),
            ));
        }
        Some(value)
    } else {
        None
    };
    Ok(UsageCostOutcome {
        mode: prepared.mode,
        basis,
        status,
        amount_microusd,
        catalog_revision: prepared.catalog_revision.clone(),
        calculated_rows,
        reported_rows,
        unpriced_rows,
        assumptions,
        unpriced: unpriced.into_iter().take(MAX_UNPRICED_ITEMS).collect(),
        unpriced_truncated,
    })
}

#[derive(Clone, Debug)]
pub enum CalculatedUsageRowCost {
    Priced {
        amount_microusd: BigUint,
        assumptions: Vec<UsageCostAssumption>,
        entry_id: String,
    },
    Unpriced(UsageUnpricedReason),
}

pub fn calculate_usage_row_cost(
    catalog: &PricingCatalog,
    row: &UsageHourlyFact,
) -> Result<CalculatedUsageRowCost, UsageError> {
    super::usage::validate_fact(row)?;
    Ok(calculate_row_from_catalog(catalog, row))
}

fn calculate_row_from_catalog(
    catalog: &PricingCatalog,
    row: &UsageHourlyFact,
) -> CalculatedUsageRowCost {
    let resolution = resolve_pricing_entry(catalog, row);
    let (entry, mut assumptions) = match resolution {
        PricingResolution::Priced { entry, assumptions } => (entry, assumptions),
        PricingResolution::Unpriced(reason) => return CalculatedUsageRowCost::Unpriced(reason),
    };
    let classified = row.cache_read_tokens
        + row.cache_write_5m_tokens
        + row.cache_write_1h_tokens
        + row.cache_write_inferred_tokens;
    let components = [
        (
            row.input_tokens - classified,
            entry.rates.uncached_input_per_million.as_ref(),
            false,
        ),
        (
            row.cache_read_tokens,
            entry.rates.cache_read_per_million.as_ref(),
            false,
        ),
        (
            row.cache_write_5m_tokens,
            entry.rates.cache_write_5m_per_million.as_ref(),
            false,
        ),
        (
            row.cache_write_1h_tokens,
            entry.rates.cache_write_1h_per_million.as_ref(),
            false,
        ),
        (
            row.cache_write_inferred_tokens,
            entry.rates.cache_write_inferred_per_million.as_ref(),
            false,
        ),
        (
            row.output_tokens,
            entry.rates.output_per_million.as_ref(),
            false,
        ),
        (
            row.web_search_requests,
            entry.rates.web_search_per_request.as_ref(),
            true,
        ),
        (
            row.web_fetch_requests,
            entry.rates.web_fetch_per_request.as_ref(),
            true,
        ),
    ];
    if components
        .iter()
        .any(|(count, rate, _)| *count > 0 && rate.is_none())
    {
        return CalculatedUsageRowCost::Unpriced(UsageUnpricedReason::MissingRate);
    }
    if row.cache_write_inferred_tokens > 0 {
        assumptions.push(UsageCostAssumption::CacheWriteInferredRate);
    }
    let amount = match round_decimal_components(&components) {
        Ok(value) => value,
        Err(()) => return CalculatedUsageRowCost::Unpriced(UsageUnpricedReason::MissingRate),
    };
    CalculatedUsageRowCost::Priced {
        amount_microusd: amount,
        assumptions,
        entry_id: entry.entry_id,
    }
}

fn round_decimal_components(components: &[(u64, Option<&String>, bool)]) -> Result<BigUint, ()> {
    let mut parsed = Vec::new();
    let mut scale = 0usize;
    for (count, rate, per_request) in components {
        if *count == 0 {
            continue;
        }
        let rate = rate.ok_or(())?;
        let (numerator, component_scale) = parse_decimal(rate)?;
        scale = scale.max(component_scale);
        let count = BigUint::from(*count)
            * if *per_request {
                BigUint::from(1_000_000u64)
            } else {
                BigUint::one()
            };
        parsed.push((count, numerator, component_scale));
    }
    let denominator = BigUint::from(10u8).pow(scale as u32);
    let numerator =
        parsed
            .into_iter()
            .fold(BigUint::zero(), |sum, (count, rate, component_scale)| {
                sum + count * rate * BigUint::from(10u8).pow((scale - component_scale) as u32)
            });
    Ok((numerator * 2u8 + &denominator) / (denominator * 2u8))
}

fn parse_decimal(value: &str) -> Result<(BigUint, usize), ()> {
    if !decimal_amount(value) {
        return Err(());
    }
    let (integer, fraction) = value.split_once('.').unwrap_or((value, ""));
    let digits = format!("{integer}{fraction}");
    Ok((digits.parse::<BigUint>().map_err(|_| ())?, fraction.len()))
}

fn validate_entry(entry: &PricingCatalogEntry, issues: &mut Vec<PricingCatalogValidationIssue>) {
    if !opaque_id(&entry.entry_id) {
        issues.push(invalid("entry_id", "invalid entry id"));
    }
    if entry.billing_channel == BillingChannel::Unknown {
        issues.push(invalid("billing_channel", "channel is not priceable"));
    }
    if !model_name(&entry.model) {
        issues.push(invalid("model", "invalid model"));
    }
    if entry.aliases.len() > 16 {
        issues.push(invalid("aliases", "too many aliases"));
    }
    let mut names = BTreeSet::new();
    if !names.insert(entry.model.clone()) {
        issues.push(invalid("aliases", "duplicate model"));
    }
    for alias in &entry.aliases {
        if !model_name(alias) || !names.insert(alias.clone()) {
            issues.push(invalid("aliases", "invalid or duplicate alias"));
        }
    }
    if !calendar_date(&entry.effective_from) {
        issues.push(invalid("effective_from", "invalid calendar date"));
    }
    if let Some(to) = &entry.effective_to
        && (!calendar_date(to) || to <= &entry.effective_from)
    {
        issues.push(invalid("effective_to", "effective_to must be later"));
    }
    for (name, value) in [
        ("service_tier", &entry.service_tier),
        ("speed", &entry.speed),
        ("inference_geo", &entry.inference_geo),
    ] {
        if !pricing_dimension(value) {
            issues.push(invalid(name, "invalid pricing dimension"));
        }
    }
    if !context_dimension(&entry.context_bucket) {
        issues.push(invalid("context_bucket", "invalid context bucket"));
    }
    if entry.currency != "USD" {
        issues.push(invalid("currency", "currency must be USD"));
    }
    if !entry.rates.all().iter().any(|(_, value)| value.is_some()) {
        issues.push(invalid("rates", "at least one rate is required"));
    }
    for (name, value) in entry.rates.all() {
        if value.is_some_and(|value| !decimal_amount(value)) {
            issues.push(invalid(name, "invalid decimal amount"));
        }
    }
    if !https_source_url(&entry.source_url) || entry.source_url.len() > 2_048 {
        issues.push(invalid("source_url", "source_url must be HTTPS"));
    }
    if super::usage::parse_instant(&entry.verified_at).is_none() {
        issues.push(invalid("verified_at", "invalid RFC3339 instant"));
    }
}

fn pricing_entries_ambiguous(left: &PricingCatalogEntry, right: &PricingCatalogEntry) -> bool {
    left.billing_channel == right.billing_channel
        && ranges_overlap(
            &left.effective_from,
            left.effective_to.as_deref(),
            &right.effective_from,
            right.effective_to.as_deref(),
        )
        && dimensions_overlap(&left.service_tier, &right.service_tier)
        && dimensions_overlap(&left.speed, &right.speed)
        && dimensions_overlap(&left.inference_geo, &right.inference_geo)
        && dimensions_overlap(&left.context_bucket, &right.context_bucket)
        && model_names(left).iter().any(|model| {
            model_names(right).contains(model)
                && pricing_specificity(left, model) == pricing_specificity(right, model)
        })
}

fn model_names(entry: &PricingCatalogEntry) -> Vec<String> {
    std::iter::once(entry.model.clone())
        .chain(entry.aliases.iter().cloned())
        .collect()
}
fn ranges_overlap(
    left_from: &str,
    left_to: Option<&str>,
    right_from: &str,
    right_to: Option<&str>,
) -> bool {
    (right_to.is_none_or(|to| left_from < to)) && (left_to.is_none_or(|to| right_from < to))
}
fn dimensions_overlap(left: &str, right: &str) -> bool {
    left == "*" || right == "*" || left == right
}
fn dimension_matches(expected: &str, actual: &str) -> bool {
    expected == "*" || expected == actual
}
fn context_matches(expected: &str, actual: ContextBucket) -> bool {
    expected == "*" || expected == actual.as_str()
}
fn pricing_specificity(entry: &PricingCatalogEntry, model: &str) -> u8 {
    (if entry.model == model { 16 } else { 0 })
        + [
            entry.service_tier.as_str(),
            entry.speed.as_str(),
            entry.inference_geo.as_str(),
            entry.context_bucket.as_str(),
        ]
        .into_iter()
        .filter(|value| *value != "*")
        .count() as u8
}

fn invalid(path: &str, message: &str) -> PricingCatalogValidationIssue {
    PricingCatalogValidationIssue::InvalidSchema {
        path: path.into(),
        message: message.into(),
    }
}
fn assumption_key(value: UsageCostAssumption) -> &'static str {
    match value {
        UsageCostAssumption::AgentDefaultChannel => "agent_default_channel",
        UsageCostAssumption::ModelAlias => "model_alias",
        UsageCostAssumption::WildcardServiceTier => "wildcard_service_tier",
        UsageCostAssumption::WildcardSpeed => "wildcard_speed",
        UsageCostAssumption::WildcardInferenceGeo => "wildcard_inference_geo",
        UsageCostAssumption::WildcardContextBucket => "wildcard_context_bucket",
        UsageCostAssumption::CacheWriteInferredRate => "cache_write_inferred_rate",
        UsageCostAssumption::SourceReported => "source_reported",
    }
}
fn reason_key(value: UsageUnpricedReason) -> &'static str {
    match value {
        UsageUnpricedReason::UnknownChannel => "unknown_channel",
        UsageUnpricedReason::UnknownModel => "unknown_model",
        UsageUnpricedReason::OutsideEffectiveRange => "outside_effective_range",
        UsageUnpricedReason::UnsupportedDimensions => "unsupported_dimensions",
        UsageUnpricedReason::AmbiguousPrice => "ambiguous_price",
        UsageUnpricedReason::MissingRate => "missing_rate",
        UsageUnpricedReason::IncompleteSourceCost => "incomplete_source_cost",
        UsageUnpricedReason::InvalidCatalog => "invalid_catalog",
    }
}
fn opaque_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || b"._:-".contains(&value))
}
fn model_name(value: &str) -> bool {
    crate::usage::bounded_model_text(Some(value)).is_some()
}
fn pricing_dimension(value: &str) -> bool {
    value == "*"
        || (!value.is_empty()
            && value.len() <= 64
            && value.as_bytes()[0].is_ascii_alphanumeric()
            && value
                .bytes()
                .all(|value| value.is_ascii_alphanumeric() || b"._:+-".contains(&value)))
}
fn context_dimension(value: &str) -> bool {
    value == "*"
        || matches!(
            value,
            "le_128k" | "gt_128k_le_200k" | "gt_200k_le_256k" | "gt_256k_le_272k" | "gt_272k"
        )
}
fn decimal_amount(value: &str) -> bool {
    if value.is_empty() || value.len() > 32 {
        return false;
    }
    let (integer, fraction) = value.split_once('.').unwrap_or((value, ""));
    !integer.is_empty()
        && (!value.contains('.') || !fraction.is_empty())
        && integer.bytes().all(|value| value.is_ascii_digit())
        && (integer == "0" || !integer.starts_with('0'))
        && fraction.len() <= 12
        && fraction.bytes().all(|value| value.is_ascii_digit())
}

fn https_source_url(value: &str) -> bool {
    url::Url::parse(value)
        .ok()
        .is_some_and(|url| url.scheme() == "https" && url.host_str().is_some())
}

fn calendar_date(value: &str) -> bool {
    value.len() == 10
        && value.as_bytes()[4] == b'-'
        && value.as_bytes()[7] == b'-'
        && value.as_bytes()[0..4].iter().all(u8::is_ascii_digit)
        && value.as_bytes()[5..7].iter().all(u8::is_ascii_digit)
        && value.as_bytes()[8..10].iter().all(u8::is_ascii_digit)
        && chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").is_ok()
}
fn parse_biguint(value: &str) -> Result<BigUint, UsageError> {
    if value.is_empty() || !value.bytes().all(|value| value.is_ascii_digit()) {
        return Err(UsageError("invalid micro-USD amount".into()));
    }
    value
        .parse::<BigUint>()
        .map_err(|_| UsageError("invalid micro-USD amount".into()))
}
fn checked_add(value: u64, increment: u64) -> Result<u64, UsageError> {
    let value = value
        .checked_add(increment)
        .ok_or_else(|| UsageError("Usage cost count overflow".into()))?;
    (value <= MAX_SAFE_COUNT)
        .then_some(value)
        .ok_or_else(|| UsageError("Usage cost count exceeds safe integer range".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const FIXTURE: &str = include_str!("../../protocol/fixtures/pricing-conformance.json");

    fn fixture() -> Value {
        serde_json::from_str(FIXTURE).expect("pricing conformance fixture")
    }

    fn catalog(root: &Value, name: &str) -> PricingCatalog {
        serde_json::from_value(
            root.get("catalogs")
                .and_then(Value::as_object)
                .and_then(|catalogs| catalogs.get(name))
                .cloned()
                .expect("catalog fixture"),
        )
        .expect("pricing catalog")
    }

    fn row(root: &Value, name: &str) -> UsageHourlyFact {
        serde_json::from_value(
            root.get("rows")
                .and_then(Value::as_object)
                .and_then(|rows| rows.get(name))
                .cloned()
                .expect("Usage row fixture"),
        )
        .expect("Usage row")
    }

    fn issue_code(issue: &PricingCatalogValidationIssue) -> &'static str {
        match issue {
            PricingCatalogValidationIssue::InvalidSchema { .. } => "invalid_schema",
            PricingCatalogValidationIssue::DuplicateEntryId { .. } => "duplicate_entry_id",
            PricingCatalogValidationIssue::AmbiguousEntries { .. } => "ambiguous_entries",
        }
    }

    #[test]
    fn pricing_validation_matches_shared_fixture() {
        let root = fixture();
        for case in root
            .get("validation")
            .and_then(Value::as_array)
            .expect("validation cases")
        {
            let name = case
                .get("name")
                .and_then(Value::as_str)
                .expect("validation name");
            let catalog_name = case
                .get("catalog")
                .and_then(Value::as_str)
                .expect("validation catalog");
            let expected = case.get("expected").expect("validation expected");
            let result = validate_catalog(&catalog(&root, catalog_name));
            let actual = json!({
                "valid": result.valid,
                "issue_codes": result.issues.iter().map(issue_code).collect::<Vec<_>>()
            });
            assert_eq!(&actual, expected, "{name}");
        }
    }

    #[test]
    fn pricing_resolution_matches_shared_fixture() {
        let root = fixture();
        for case in root
            .get("resolution")
            .and_then(Value::as_array)
            .expect("resolution cases")
        {
            let name = case
                .get("name")
                .and_then(Value::as_str)
                .expect("resolution name");
            let catalog_name = case
                .get("catalog")
                .and_then(Value::as_str)
                .expect("resolution catalog");
            let row_name = case
                .get("row")
                .and_then(Value::as_str)
                .expect("resolution row");
            let expected = case.get("expected").expect("resolution expected");
            let actual = match resolve_pricing_entry(
                &catalog(&root, catalog_name),
                &row(&root, row_name),
            ) {
                PricingResolution::Priced { entry, assumptions } => json!({
                    "status": "priced",
                    "entry_id": entry.entry_id,
                    "assumptions": assumptions.iter().map(|value| assumption_key(*value)).collect::<Vec<_>>()
                }),
                PricingResolution::Unpriced(reason) => {
                    json!({"status": "unpriced", "reason": reason_key(reason)})
                }
            };
            assert_eq!(&actual, expected, "{name}");
        }
    }

    #[test]
    fn pricing_cost_matches_shared_fixture() {
        let root = fixture();
        for case in root
            .get("cost")
            .and_then(Value::as_array)
            .expect("cost cases")
        {
            let name = case.get("name").and_then(Value::as_str).expect("cost name");
            let catalog_name = case
                .get("catalog")
                .and_then(Value::as_str)
                .expect("cost catalog");
            let mode: UsageCostMode =
                serde_json::from_value(case.get("mode").cloned().expect("cost mode"))
                    .expect("cost mode value");
            let rows = case
                .get("rows")
                .and_then(Value::as_array)
                .expect("cost rows")
                .iter()
                .map(|name| row(&root, name.as_str().expect("cost row name")))
                .collect::<Vec<_>>();
            let expected = case.get("expected").expect("cost expected");
            let actual = serde_json::to_value(
                calculate_usage_cost(&rows, Some(&catalog(&root, catalog_name)), mode)
                    .expect("cost outcome"),
            )
            .expect("serialize cost outcome");
            assert_eq!(&actual, expected, "{name}");
        }
    }
}
