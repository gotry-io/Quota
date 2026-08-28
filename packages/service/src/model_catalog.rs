//! Report-time model identity normalization.
//!
//! Model catalog data is never applied to Usage facts or pricing inputs.  It only supplies a
//! deterministic canonical key, and the vendor a model name belongs to, while a report is built
//! from the retained raw model text.

use std::collections::BTreeSet;

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::usage::{InferenceProvider, UsageAgent, UsageRow};

pub const MAX_MODEL_CATALOG_MODELS: usize = 512;
pub const MAX_MODEL_CATALOG_ALIASES_PER_MODEL: usize = 32;
pub const MAX_MODEL_CATALOG_ALIASES: usize = 4_096;
pub const MAX_MODEL_CATALOG_FAMILIES: usize = 256;
pub const MAX_MODEL_CATALOG_FAMILY_PREFIX_LENGTH: usize = 64;

/// A model family: every reported model whose name begins with `prefix`, compared ASCII
/// case-insensitively, belongs to `provider`. The longest matching prefix decides.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ModelCatalogFamily {
    pub prefix: String,
    pub provider: InferenceProvider,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ModelCatalogAlias {
    pub reported_model: String,
    pub provider: InferenceProvider,
    #[serde(default)]
    pub agent: Option<UsageAgent>,
    #[serde(default)]
    pub effective_from: Option<String>,
    #[serde(default)]
    pub effective_to: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ModelCatalogModel {
    pub canonical_id: String,
    pub aliases: Vec<ModelCatalogAlias>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ModelCatalog {
    pub schema_version: u8,
    pub revision: String,
    /// Absent from catalogs published before families existed; those name no vendor.
    #[serde(default)]
    pub families: Vec<ModelCatalogFamily>,
    pub models: Vec<ModelCatalogModel>,
}

/// The catalog this build shipped with, for a device that has not yet read a newer one from
/// Relay — a first launch, or a Mac that is offline — so vendor grouping does not wait on it.
pub fn bundled_model_catalog() -> ModelCatalog {
    serde_json::from_str(include_str!("../../protocol/catalog/model-catalog.json"))
        .expect("the checked-in model catalog parses")
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelCatalogValidationIssue {
    InvalidSchema {
        path: String,
        message: String,
    },
    DuplicateCanonicalID(String),
    AmbiguousAlias {
        reported_model: String,
        provider: InferenceProvider,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelCatalogValidationResult {
    pub valid: bool,
    pub issues: Vec<ModelCatalogValidationIssue>,
}

pub fn validate_model_catalog_value(input: &Value) -> ModelCatalogValidationResult {
    let catalog = match serde_json::from_value::<ModelCatalog>(input.clone()) {
        Ok(catalog) => catalog,
        Err(error) => {
            return ModelCatalogValidationResult {
                valid: false,
                issues: vec![ModelCatalogValidationIssue::InvalidSchema {
                    path: String::new(),
                    message: error.to_string(),
                }],
            };
        }
    };
    validate_model_catalog(&catalog)
}

pub fn validate_model_catalog(catalog: &ModelCatalog) -> ModelCatalogValidationResult {
    let mut issues = Vec::new();
    if catalog.schema_version != 2 {
        issues.push(invalid(
            "schema_version",
            "expected model catalog schema version 2",
        ));
    }
    if !opaque_id(&catalog.revision) {
        issues.push(invalid("revision", "invalid model catalog revision"));
    }
    if catalog.models.is_empty() || catalog.models.len() > MAX_MODEL_CATALOG_MODELS {
        issues.push(invalid("models", "invalid model catalog model count"));
    }
    if catalog.families.len() > MAX_MODEL_CATALOG_FAMILIES {
        issues.push(invalid("families", "too many model catalog families"));
    }
    let mut prefixes = BTreeSet::new();
    for (index, family) in catalog.families.iter().enumerate() {
        if !family_prefix(&family.prefix) {
            issues.push(invalid(
                &format!("families[{index}].prefix"),
                "invalid family prefix",
            ));
        }
        if family.provider == InferenceProvider::Unknown {
            issues.push(invalid(
                &format!("families[{index}].provider"),
                "a family names a vendor",
            ));
        }
        if !prefixes.insert(family.prefix.clone()) {
            issues.push(invalid(
                &format!("families[{index}].prefix"),
                "duplicate family prefix",
            ));
        }
    }
    let mut ids = BTreeSet::new();
    let mut alias_count = 0usize;
    for (index, model) in catalog.models.iter().enumerate() {
        if !opaque_id(&model.canonical_id) {
            issues.push(invalid(
                &format!("models[{index}].canonical_id"),
                "invalid canonical model id",
            ));
        }
        if !ids.insert(model.canonical_id.clone()) {
            issues.push(ModelCatalogValidationIssue::DuplicateCanonicalID(
                model.canonical_id.clone(),
            ));
        }
        if model.aliases.is_empty() || model.aliases.len() > MAX_MODEL_CATALOG_ALIASES_PER_MODEL {
            issues.push(invalid(
                &format!("models[{index}].aliases"),
                "invalid alias count for model",
            ));
        }
        alias_count = alias_count.saturating_add(model.aliases.len());
        for (alias_index, alias) in model.aliases.iter().enumerate() {
            validate_alias(
                alias,
                &format!("models[{index}].aliases[{alias_index}]"),
                &mut issues,
            );
        }
    }
    if alias_count > MAX_MODEL_CATALOG_ALIASES {
        issues.push(invalid("models", "too many model catalog aliases"));
    }

    let aliases = catalog
        .models
        .iter()
        .flat_map(|model| model.aliases.iter())
        .collect::<Vec<_>>();
    for alias in &aliases {
        if ids.contains(&alias.reported_model) {
            issues.push(ModelCatalogValidationIssue::AmbiguousAlias {
                reported_model: alias.reported_model.clone(),
                provider: alias.provider,
            });
        }
    }
    for left in 0..aliases.len() {
        for right in left + 1..aliases.len() {
            if aliases_overlap(aliases[left], aliases[right]) {
                issues.push(ModelCatalogValidationIssue::AmbiguousAlias {
                    reported_model: aliases[left].reported_model.clone(),
                    provider: aliases[left].provider,
                });
            }
        }
    }
    ModelCatalogValidationResult {
        valid: issues.is_empty(),
        issues,
    }
}

/// The company whose model answered this row.
///
/// The model's name decides, through the catalog's family rules: the longest prefix that
/// matches, ASCII case-insensitively, names the provider. A name no family claims is unknown —
/// the channel that billed it says who was paid, not who made the model, so it is not consulted.
pub fn resolve_provider(catalog: Option<&ModelCatalog>, row: &UsageRow) -> InferenceProvider {
    let model = row.model.to_ascii_lowercase();
    catalog
        .into_iter()
        .flat_map(|catalog| catalog.families.iter())
        .filter(|family| model.starts_with(family.prefix.as_str()))
        .max_by_key(|family| family.prefix.len())
        .map_or(InferenceProvider::Unknown, |family| family.provider)
}

/// The canonical model this row reports, as of the day it was measured.
///
/// An alias carries an effective range, so the day the row fell in is what decides which
/// alias speaks for it.
pub fn resolve_model(catalog: &ModelCatalog, row: &UsageRow, date: &str) -> Option<String> {
    if let Some(model) = catalog
        .models
        .iter()
        .find(|model| model.canonical_id == row.model)
    {
        return Some(model.canonical_id.clone());
    }
    let provider = resolve_provider(Some(catalog), row);
    let matches = catalog
        .models
        .iter()
        .filter(|model| {
            model.aliases.iter().any(|alias| {
                alias.reported_model == row.model
                    && alias.provider == provider
                    && alias.agent.is_none_or(|agent| agent == row.agent)
                    && alias
                        .effective_from
                        .as_deref()
                        .is_none_or(|from| from <= date)
                    && alias.effective_to.as_deref().is_none_or(|to| date < to)
            })
        })
        .collect::<Vec<_>>();
    (matches.len() == 1).then(|| matches[0].canonical_id.clone())
}

fn validate_alias(
    alias: &ModelCatalogAlias,
    path: &str,
    issues: &mut Vec<ModelCatalogValidationIssue>,
) {
    if !model_text(&alias.reported_model) {
        issues.push(invalid(
            &format!("{path}.reported_model"),
            "invalid reported model",
        ));
    }
    let from = alias.effective_from.as_deref().map(parse_date);
    let to = alias.effective_to.as_deref().map(parse_date);
    if from.is_some_and(|value| value.is_none()) {
        issues.push(invalid(
            &format!("{path}.effective_from"),
            "invalid effective_from date",
        ));
    }
    if to.is_some_and(|value| value.is_none()) {
        issues.push(invalid(
            &format!("{path}.effective_to"),
            "invalid effective_to date",
        ));
    }
    if let (Some(Some(from)), Some(Some(to))) = (from, to)
        && to <= from
    {
        issues.push(invalid(
            &format!("{path}.effective_to"),
            "effective_to must be later than effective_from",
        ));
    }
}

fn aliases_overlap(left: &ModelCatalogAlias, right: &ModelCatalogAlias) -> bool {
    if left.reported_model != right.reported_model
        || left.provider != right.provider
        || left
            .agent
            .is_some_and(|agent| right.agent.is_some_and(|other| agent != other))
    {
        return false;
    }
    let left_from = left.effective_from.as_deref().and_then(parse_date);
    let left_to = left.effective_to.as_deref().and_then(parse_date);
    let right_from = right.effective_from.as_deref().and_then(parse_date);
    let right_to = right.effective_to.as_deref().and_then(parse_date);
    (left_to.is_none() || right_from.is_none() || right_from < left_to)
        && (right_to.is_none() || left_from.is_none() || left_from < right_to)
}

fn parse_date(value: &str) -> Option<NaiveDate> {
    (value.len() == 10)
        .then(|| NaiveDate::parse_from_str(value, "%Y-%m-%d").ok())
        .flatten()
}

fn opaque_id(value: &str) -> bool {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    value.chars().count() <= 128
        && first.is_ascii_alphanumeric()
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._:-".contains(character))
}

fn model_text(value: &str) -> bool {
    !value.is_empty() && value.chars().count() <= 128 && !value.chars().any(char::is_control)
}

/// Lowercase ASCII model text, so one spelling of a family exists and a match is exact.
fn family_prefix(value: &str) -> bool {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    value.len() <= MAX_MODEL_CATALOG_FAMILY_PREFIX_LENGTH
        && (first.is_ascii_lowercase() || first.is_ascii_digit())
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || "._-".contains(character)
        })
}

fn invalid(path: &str, message: &str) -> ModelCatalogValidationIssue {
    ModelCatalogValidationIssue::InvalidSchema {
        path: path.to_owned(),
        message: message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn catalog() -> ModelCatalog {
        serde_json::from_value(json!({
            "schema_version": 2,
            "revision": "test-1",
            "families": [
                {"prefix": "g", "provider": "google"},
                {"prefix": "gpt-", "provider": "openai"},
                {"prefix": "grok", "provider": "xai"},
                {"prefix": "claude", "provider": "anthropic"}
            ],
            "models": [{
                "canonical_id": "gpt-5.5",
                "aliases": [{
                    "reported_model": "GPT-5.5[1m]",
                    "provider": "openai",
                    "agent": "codex",
                    "effective_from": "2026-04-24"
                }]
            }]
        }))
        .expect("catalog")
    }

    #[test]
    fn resolves_exact_canonical_and_scoped_alias_without_touching_raw_text() {
        const DATE: &str = "2026-08-10";
        let catalog = catalog();
        let mut alias = row("GPT-5.5[1m]");
        assert_eq!(
            resolve_model(&catalog, &alias, DATE).as_deref(),
            Some("gpt-5.5")
        );
        // The alias is scoped to OpenAI, and the name says OpenAI whoever billed it.
        alias.billing_channel = crate::usage::BillingChannel::Openrouter;
        assert_eq!(
            resolve_model(&catalog, &alias, DATE).as_deref(),
            Some("gpt-5.5")
        );
        alias.agent = UsageAgent::ClaudeCode;
        assert_eq!(resolve_model(&catalog, &alias, DATE), None);
        alias.agent = UsageAgent::Codex;
        alias.model = "gpt-5.5".into();
        assert_eq!(
            resolve_model(&catalog, &alias, DATE).as_deref(),
            Some("gpt-5.5")
        );
        assert_eq!(alias.model, "gpt-5.5");
    }

    /// The name decides the vendor; the agent and the channel do not. A name no family claims
    /// is unknown whatever channel billed it: an endpoint alias reached through a vendor's own
    /// provider id still says nothing about whose model answered.
    #[test]
    fn a_models_name_decides_its_vendor_and_an_unclaimed_name_is_unknown() {
        use crate::usage::BillingChannel;
        let catalog = catalog();

        let mut grok = row("grok-4.5");
        grok.agent = UsageAgent::ClaudeCode;
        grok.billing_channel = BillingChannel::Unknown;
        assert_eq!(
            resolve_provider(Some(&catalog), &grok),
            InferenceProvider::Xai
        );

        let mut via_gateway = row("Claude-Opus-5");
        via_gateway.billing_channel = BillingChannel::Openrouter;
        assert_eq!(
            resolve_provider(Some(&catalog), &via_gateway),
            InferenceProvider::Anthropic
        );

        // The longest family wins: `gpt-` is OpenAI even though `g` alone would be Google here.
        assert_eq!(
            resolve_provider(Some(&catalog), &row("GPT-5.5[1m]")),
            InferenceProvider::Openai
        );

        for channel in [
            BillingChannel::OpenaiDirect,
            BillingChannel::AzureOpenai,
            BillingChannel::Openrouter,
        ] {
            let mut unclaimed = row("ep-20260811103923-jzct4");
            unclaimed.billing_channel = channel;
            assert_eq!(
                resolve_provider(Some(&catalog), &unclaimed),
                InferenceProvider::Unknown,
                "{channel:?}"
            );
        }
        assert_eq!(
            resolve_provider(None, &grok),
            InferenceProvider::Unknown,
            "without a catalog no name is claimed"
        );
    }

    #[test]
    fn rejects_duplicate_or_misspelt_families() {
        let mut value = serde_json::to_value(catalog()).expect("json");
        value["families"] = json!([
            {"prefix": "grok", "provider": "xai"},
            {"prefix": "grok", "provider": "xai"},
            {"prefix": "GPT-", "provider": "openai"},
            {"prefix": "mystery", "provider": "unknown"}
        ]);
        let result = validate_model_catalog_value(&value);
        assert!(!result.valid);
        assert_eq!(result.issues.len(), 3, "{:?}", result.issues);
    }

    #[test]
    fn the_bundled_catalog_is_the_checked_in_one() {
        let bundled = bundled_model_catalog();
        assert!(validate_model_catalog(&bundled).valid);
        assert!(!bundled.families.is_empty());
    }

    #[test]
    fn rejects_overlapping_alias_scopes() {
        let mut value = serde_json::to_value(catalog()).expect("json");
        value["models"][0]["aliases"] = json!([
            {"reported_model":"same","provider":"openai","effective_from":"2026-01-01","effective_to":"2026-06-01"},
            {"reported_model":"same","provider":"openai","effective_from":"2026-05-01"}
        ]);
        let result = validate_model_catalog_value(&value);
        assert!(!result.valid);
        assert!(
            result
                .issues
                .iter()
                .any(|issue| matches!(issue, ModelCatalogValidationIssue::AmbiguousAlias { .. }))
        );
    }

    #[test]
    fn checked_in_catalog_is_valid_for_the_rust_resolver() {
        let value: Value =
            serde_json::from_str(include_str!("../../protocol/catalog/model-catalog.json"))
                .expect("checked-in model catalog JSON");
        let result = validate_model_catalog_value(&value);
        assert!(
            result.valid,
            "invalid checked-in catalog: {:?}",
            result.issues
        );
    }

    fn row(model: &str) -> UsageRow {
        UsageRow {
            agent: UsageAgent::Codex,
            billing_channel: crate::usage::BillingChannel::OpenaiDirect,
            channel_source: crate::usage::ChannelSource::Explicit,
            model: model.into(),
            context_bucket: crate::usage::ContextBucket::Le128k,
            service_tier: "unknown".into(),
            speed: "unknown".into(),
            inference_geo: "unknown".into(),
            input_tokens: 0,
            cache_read_tokens: 0,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: 0,
            output_tokens: 0,
            reasoning_tokens: 0,
            requests: 1,
            web_search_requests: 0,
            web_fetch_requests: 0,
            source_cost_microusd: None,
            source_cost_covered_requests: 0,
        }
    }
}
