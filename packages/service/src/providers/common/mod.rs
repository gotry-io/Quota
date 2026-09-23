//! Shared collector types and helpers.
//!
//! Provider-specific HTTP, credential, and mapping logic stays in the collector modules.
//! This package only owns the reusable boundaries: errors, collection context, config
//! resolution, HTTP, identity, and bounded IO.
//!
//! A failed read reports a category, not prose. What a failure means for the user depends
//! on collection context the provider does not have — whether this device holds a sign-in
//! at all, whether the provider is explicitly configured here — so the copy is written at
//! the boundary that knows those, and there is exactly one such place.

mod cli_version;
mod config;
mod http;
mod identity;
mod io;
mod json;
mod renewal;
mod types;
#[cfg(test)]
pub mod web_conformance;

pub use cli_version::{
    CliTool, ProbeCache, ProbeEnvironment, resolve as resolve_cli_versions, resolve_binary,
};
pub use config::{ApiKeyCredentials, resolve_api_key};
#[cfg(test)]
pub use http::serve_responses;
pub use http::{HTTP_BODY_LIMIT, HTTP_TIMEOUT, HttpClient, VALIDATION_TIMEOUT};
pub use identity::{
    account_identity, api_key_identity, mask_display_name, mask_email, mask_secret, sha256_hex,
};
pub use io::{BoundedExchange, LOCAL_FILE_LIMIT, read_bounded_file, run_bounded_command};
pub use json::{
    clamp_percent, decode_jwt_payload, display_window_title, duration_seconds, jwt_subject, number,
    obj_get, obj_get_any, parse_date, plan_slug, slug, string, unix_now, unix_seconds_to_iso,
    url_encode,
};
pub use renewal::{
    RENEWAL_FLOOR_SECONDS, RenewalAttempt, RenewalAttempts, RenewalOutcome, RenewalPlan,
    json_rpc_reply, renew_sign_in,
};
/// One recorded response body from `packages/provider/fixtures/quota-responses.json`, which the
/// capability matrix cites as `/<provider>/<response>`. Every section there is read by a test in
/// that provider's collector, so a cited pointer is a body the parser was shown to accept.
#[cfg(test)]
pub fn quota_response_fixture(provider: &str, response: &str) -> serde_json::Value {
    const FIXTURE: &str = include_str!("../../../../provider/fixtures/quota-responses.json");
    let root: serde_json::Value = serde_json::from_str(FIXTURE).expect("provider quota fixture");
    root.pointer(&format!("/{provider}/{response}"))
        .cloned()
        .unwrap_or_else(|| panic!("quota-responses.json has no /{provider}/{response}"))
}

pub use types::{
    BROWSER_COOKIE_HEADER_LIMIT, BROWSER_SESSION_SOURCE, Cadence, CollectionContext, ErrorCategory,
    KeychainSecret, ProviderError, ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow,
    ValidatedBrowserSession, collect_official_or_browser, cookie_named_value,
    discover_official_or_browser, normalize_browser_cookie_header, resolve_timezone,
};
