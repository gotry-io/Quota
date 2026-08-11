//! Release-boundary behavior retained only through the native cutover window.
//!
//! The current provider configuration path, `ProviderConfigLock`, OAuth client id, and SQLite
//! state are live interfaces. This module contains only the released 0.0.5 outbox identity and
//! imported-cache handoff rules; remove it, its call sites, and focused tests in 0.0.8.

use rusqlite::{Transaction, params};
use serde_json::Value;

use crate::state::StateStore;

pub(crate) const RELEASED_USAGE_PARSER_REVISION: &str = "quota-usage-4";

pub(crate) fn accepts_released_unknown_usage_model(parser_revision: &str, model: &str) -> bool {
    model != "unknown" || parser_revision == RELEASED_USAGE_PARSER_REVISION
}

#[derive(Clone, Default)]
pub(crate) struct ReleasedPricingCache {
    pub(crate) catalog: Option<Value>,
    pub(crate) etag: Option<String>,
}

/// Keep a matching 0.0.5 immutable outbox queue on the first native open. A later identity switch
/// always starts a fresh queue, so old-account entries cannot be replayed.
pub(crate) fn retain_released_outbox(
    tx: &Transaction<'_>,
    first_context: bool,
    account_id: &str,
    device_id: &str,
    generation: u64,
) -> rusqlite::Result<()> {
    if first_context {
        tx.execute(
            "DELETE FROM usage_outbox
             WHERE account_id != ?1 OR device_id != ?2 OR generation != ?3",
            params![account_id, device_id, generation],
        )?;
    } else {
        tx.execute("DELETE FROM usage_outbox", [])?;
    }
    Ok(())
}

/// Read the one-time pricing cache imported from the released JSON state. The native state remains
/// the source of truth once the cache has been committed to SQLite.
pub(crate) fn released_pricing_cache(state: &StateStore) -> ReleasedPricingCache {
    let Some(value) = state.legacy_artifact("pricing-catalog.json").ok().flatten() else {
        return ReleasedPricingCache::default();
    };
    ReleasedPricingCache {
        catalog: value.get("catalog").cloned(),
        etag: value.get("etag").and_then(Value::as_str).map(str::to_owned),
    }
}

/// Remove the imported Usage cursor only after the file-index scan is complete.
pub(crate) fn finish_released_usage_cache(state: &StateStore) {
    let _ = state.consume_legacy_artifact("usage-cache.json");
}
