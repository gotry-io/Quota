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

mod config;
mod http;
mod identity;
mod io;
mod json;
mod types;

pub use config::{ApiKeyCredentials, resolve_api_key};
pub use http::{HTTP_BODY_LIMIT, HTTP_TIMEOUT, HttpClient, VALIDATION_TIMEOUT};
pub use identity::{
    account_identity, api_key_identity, mask_display_name, mask_email, mask_secret, sha256_hex,
};
pub use io::{LOCAL_FILE_LIMIT, is_executable_file, read_bounded_file, run_bounded_command};
pub use json::{
    clamp_percent, decode_jwt_payload, duration_seconds, number, obj_get, obj_get_any, parse_date,
    provider_source, slug, string, unix_now, unix_seconds_to_iso, url_encode,
};
pub use types::{
    BROWSER_COOKIE_HEADER_LIMIT, BROWSER_SESSION_SOURCE, CollectionContext, ErrorCategory,
    ProviderError, ProviderSession, QuotaAccount, QuotaSnapshot, QuotaWindow,
    ValidatedBrowserSession, collect_official_or_browser, cookie_named_value,
    discover_official_or_browser, normalize_browser_cookie_header, resolve_timezone,
};
