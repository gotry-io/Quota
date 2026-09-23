//! Fixed-origin QuotaRelay client and upload-boundary validation.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
#[cfg(target_os = "macos")]
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::protocol::{
    AccountComponentValue, AccountSettingsMutationResult, AccountSettingsWriteDocument,
    AccountSettingsWriteOutcome, AuthStatus, CONTROL_PROTOCOL, MANAGED_DATA_PROTOCOL,
};
use crate::service::{BackendError, LoginOutcome};
use crate::state::StateStore;
use base64::Engine;
use chrono::Timelike;
use reqwest::blocking::{Client, Response};
use reqwest::header::{
    ACCEPT, AUTHORIZATION, CONTENT_TYPE, ETAG, HeaderMap, HeaderValue, IF_MATCH, IF_NONE_MATCH,
};
use serde_json::Value;
use sha2::Digest;
use thiserror::Error;
use url::Url;

mod history;

pub const MANAGED_ORIGIN: &str = "https://quota.gotry.io";
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
pub const MAXIMUM_RESPONSE_BYTES: usize = 1_048_576;
pub const MAXIMUM_REQUEST_BYTES: usize = 1_048_576;
const MAXIMUM_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
const USAGE_HOUR_GRID_RULE: &str =
    "first_whole_hour_of_local_date; fractional_midnight_to_previous_day; no_proration";
const MAXIMUM_ACCOUNT_PERIOD_CACHE: usize = 32;

/// What `PUT /api/v2/account/settings` answers. 412 carries the current document, not an error.
#[derive(Debug, Clone, PartialEq)]
pub enum AccountSettingsWrite {
    Written {
        document: Value,
        etag: Option<String>,
    },
    Conflict {
        document: Value,
        etag: Option<String>,
    },
}

#[derive(Debug, Error)]
pub enum RelayError {
    #[error("Quota authentication is required")]
    AuthenticationRequired,
    #[error("Quota request was rejected")]
    Rejected { code: String, status: u16 },
    #[error("Quota service is unavailable")]
    Unavailable,
    #[error("Quota response was invalid")]
    InvalidResponse,
    #[error("Quota response was too large")]
    ResponseTooLarge,
    #[error("Quota request timed out")]
    Timeout,
    #[error("Quota request was cancelled")]
    Cancelled,
    #[error("Quota redirect was refused")]
    RedirectRefused,
}

impl RelayError {
    /// Relay refused this payload with HTTP 400 `invalid_request`. Network, auth, 5xx,
    /// rate limits, and unparsable responses are not this.
    pub(crate) fn is_payload_refusal(&self) -> bool {
        matches!(
            self,
            Self::Rejected {
                status: 400,
                code
            } if code == "invalid_request"
        )
    }
}

pub struct RelayClient {
    origin: String,
    client: Client,
}

impl RelayClient {
    pub fn new() -> Result<Self, RelayError> {
        Self::from_origin(MANAGED_ORIGIN, false)
    }

    fn from_origin(origin: &str, test_override: bool) -> Result<Self, RelayError> {
        let normalized = normalize_origin(origin, test_override)?;
        let client = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| RelayError::Unavailable)?;
        Ok(Self {
            origin: normalized,
            client,
        })
    }

    #[cfg(test)]
    pub(crate) fn for_test(origin: &str) -> Result<Self, RelayError> {
        Self::from_origin(origin, true)
    }

    pub fn exchange_browser(&self, body: &Value) -> Result<Value, RelayError> {
        self.post_json("/oauth/v2/token", body, None, 200)
    }

    pub fn refresh_session(&self, body: &Value) -> Result<Value, RelayError> {
        self.post_json("/oauth/v2/token", body, None, 200)
    }

    pub fn revoke(&self, token: &str) -> Result<(), RelayError> {
        let _ = self.post_json("/oauth/v2/revoke", &Value::Null, Some(token), 200)?;
        Ok(())
    }

    pub fn sync_control(&self, token: &str) -> Result<Value, RelayError> {
        self.get_json("/api/v2/device/sync", token, 200)
    }

    pub fn update_device_profile(
        &self,
        token: &str,
        display_name: &str,
        platform: &str,
    ) -> Result<Value, RelayError> {
        self.put_json(
            "/api/v2/device/profile",
            &serde_json::json!({
                "protocol_version": CONTROL_PROTOCOL,
                "display_name": display_name,
                "platform": platform,
            }),
            token,
            200,
        )
    }

    pub fn upload_snapshot(&self, token: &str, envelope: &Value) -> Result<Value, RelayError> {
        validate_snapshot_envelope(envelope)?;
        let named = envelope
            .get("snapshots")
            .and_then(Value::as_array)
            .ok_or(RelayError::InvalidResponse)?
            .iter()
            .filter_map(|snapshot| snapshot.get("provider")?.as_str().map(str::to_owned))
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        let response = self.put_json("/api/v6/device/snapshots", envelope, token, 200)?;
        validate_upload_response(&response, &named)?;
        Ok(response)
    }

    pub fn upload_usage(&self, token: &str, submission: &Value) -> Result<Value, RelayError> {
        validate_usage_submission(submission)?;
        let named = submission
            .get("hours")
            .and_then(Value::as_array)
            .ok_or(RelayError::InvalidResponse)?
            .iter()
            .filter_map(|hour| hour.get("bucket_start_utc")?.as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        let response = self.put_json("/api/v6/device/usage", submission, token, 200)?;
        validate_upload_response(&response, &named)?;
        Ok(response)
    }

    /// Reads the Account, offering the validator the caller already holds.
    ///
    /// One read answers the whole account: the devices, the resolved subscriptions, and the
    /// four periods. Returns the ETag this read is now current at, and the body only when the
    /// server sent one. `None` means 304: the caller's stored summary is still the answer.
    pub fn account_summary(
        &self,
        token: &str,
        query: &str,
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<Value>), RelayError> {
        self.conditional_get_json(&format!("/api/v6/account/summary?{query}"), token, etag)
    }

    /// Conditional `GET /api/v2/account/settings`. 304 returns no body.
    pub fn account_settings(
        &self,
        token: &str,
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<Value>), RelayError> {
        let (next_etag, body) =
            self.conditional_get_json("/api/v2/account/settings", token, etag)?;
        if let Some(document) = &body {
            validate_account_settings(document)?;
        }
        Ok((next_etag, body))
    }

    /// `PUT /api/v6/device/quota-history`. 409 `history_sync_off` and 413 `quota_history_full`
    /// are [`RelayError::Rejected`] with those codes.
    pub(crate) fn put_quota_history(&self, token: &str, body: &Value) -> Result<Value, RelayError> {
        let response = self.put_json("/api/v6/device/quota-history", body, token, 200)?;
        history::validate_quota_history_upload_response(&response)?;
        Ok(response)
    }

    /// Conditional `GET /api/v6/account/quota-history` for one global-scope subscription.
    /// 304 returns no body.
    pub(crate) fn account_quota_history(
        &self,
        token: &str,
        provider: &str,
        fingerprint: &str,
        since: &str,
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<Value>), RelayError> {
        let (next_etag, body) = self.conditional_get_json(
            &history::quota_history_read_path(provider, fingerprint, since),
            token,
            etag,
        )?;
        if let Some(document) = &body {
            history::validate_quota_history_read(document)?;
        }
        Ok((next_etag, body))
    }

    /// Compare-and-set write. 412 is `Conflict` with the current document as the body.
    pub fn put_account_settings(
        &self,
        token: &str,
        body: &Value,
        if_match: &str,
    ) -> Result<AccountSettingsWrite, RelayError> {
        validate_bounded_json(body)?;
        let mut headers = HeaderMap::new();
        headers.insert(
            IF_MATCH,
            HeaderValue::from_str(if_match).map_err(|_| RelayError::InvalidResponse)?,
        );
        let response = self.request(
            self.client
                .put(self.url("/api/v2/account/settings"))
                .header(CONTENT_TYPE, "application/json")
                .header(ACCEPT, "application/json")
                .header(AUTHORIZATION, bearer(token))
                .headers(headers),
            Some(body),
            Some(token),
        )?;
        let status = response.status().as_u16();
        if status == 401 {
            return Err(RelayError::AuthenticationRequired);
        }
        if status == 200 || status == 412 {
            let etag = response
                .headers()
                .get(ETAG)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            let document = read_json(response)?;
            validate_account_settings(&document)?;
            return Ok(if status == 200 {
                AccountSettingsWrite::Written { document, etag }
            } else {
                AccountSettingsWrite::Conflict { document, etag }
            });
        }
        let _ = check_status(response, 200)?;
        Err(RelayError::InvalidResponse)
    }

    /// Inclusive local-date Account period. Offers the caller's ETag; 304 returns no body.
    pub fn account_usage_period(
        &self,
        from: &str,
        to: &str,
        timezone: &str,
        breakdown: bool,
        token: &str,
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<Value>), RelayError> {
        self.conditional_get_json(
            &account_usage_period_path(from, to, timezone, breakdown),
            token,
            etag,
        )
    }

    /// The activity read with `detail=hours`, so Account Usage can draw the same rhythm This Mac
    /// already has. This is the one Account read that opens stored hours.
    pub fn account_usage_hours(
        &self,
        token: &str,
        from: &str,
        to: &str,
        timezone: &str,
    ) -> Result<Value, RelayError> {
        self.get_json(
            &format!(
                "/api/v6/account/usage/activity?from={from}&to={to}&detail=hours&tz={timezone}"
            ),
            token,
            200,
        )
    }

    pub fn pricing_catalog(
        &self,
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<Value>), RelayError> {
        let mut headers = HeaderMap::new();
        if let Some(etag) = etag {
            headers.insert(
                IF_NONE_MATCH,
                HeaderValue::from_str(etag).map_err(|_| RelayError::InvalidResponse)?,
            );
        }
        let response = self.request(
            self.client
                .get(self.url("/api/v2/pricing/catalog"))
                .headers(headers),
            None,
            None,
        )?;
        let next_etag = response
            .headers()
            .get(ETAG)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        if response.status().as_u16() == 304 {
            return Ok((next_etag, None));
        }
        let response = check_status(response, 200)?;
        Ok((next_etag, Some(read_json(response)?)))
    }

    pub fn model_catalog(
        &self,
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<Value>), RelayError> {
        let mut headers = HeaderMap::new();
        if let Some(etag) = etag {
            headers.insert(
                IF_NONE_MATCH,
                HeaderValue::from_str(etag).map_err(|_| RelayError::InvalidResponse)?,
            );
        }
        let response = self.request(
            self.client
                .get(self.url("/api/v2/model/catalog"))
                .headers(headers),
            None,
            None,
        )?;
        let next_etag = response
            .headers()
            .get(ETAG)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        if response.status().as_u16() == 304 {
            return Ok((next_etag, None));
        }
        let response = check_status(response, 200)?;
        Ok((next_etag, Some(read_json(response)?)))
    }

    fn conditional_get_json(
        &self,
        path: &str,
        token: &str,
        etag: Option<&str>,
    ) -> Result<(Option<String>, Option<Value>), RelayError> {
        let mut headers = HeaderMap::new();
        if let Some(etag) = etag {
            headers.insert(
                IF_NONE_MATCH,
                HeaderValue::from_str(etag).map_err(|_| RelayError::InvalidResponse)?,
            );
        }
        let response = self.request(
            self.client
                .get(self.url(path))
                .header(AUTHORIZATION, bearer(token))
                .headers(headers),
            None,
            Some(token),
        )?;
        let next_etag = response
            .headers()
            .get(ETAG)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        if response.status().as_u16() == 304 {
            return Ok((next_etag, None));
        }
        let response = check_status(response, 200)?;
        Ok((next_etag, Some(read_json(response)?)))
    }

    fn get_json(&self, path: &str, token: &str, expected_status: u16) -> Result<Value, RelayError> {
        let response = self.request(
            self.client
                .get(self.url(path))
                .header(AUTHORIZATION, bearer(token)),
            None,
            Some(token),
        )?;
        read_json(check_status(response, expected_status)?)
    }

    fn post_json(
        &self,
        path: &str,
        body: &Value,
        token: Option<&str>,
        expected_status: u16,
    ) -> Result<Value, RelayError> {
        validate_bounded_json(body)?;
        let mut request = self
            .client
            .post(self.url(path))
            .header(CONTENT_TYPE, "application/json")
            .header(ACCEPT, "application/json");
        if let Some(token) = token {
            request = request.header(AUTHORIZATION, bearer(token));
        }
        let response = self.request(request, Some(body), token)?;
        let response = check_status(response, expected_status)?;
        if response.status().as_u16() == 204 {
            return Ok(Value::Null);
        }
        read_json(response)
    }

    fn put_json(
        &self,
        path: &str,
        body: &Value,
        token: &str,
        expected_status: u16,
    ) -> Result<Value, RelayError> {
        let response = self.request(
            self.client
                .put(self.url(path))
                .header(CONTENT_TYPE, "application/json")
                .header(ACCEPT, "application/json")
                .header(AUTHORIZATION, bearer(token)),
            Some(body),
            Some(token),
        )?;
        read_json(check_status(response, expected_status)?)
    }

    fn request(
        &self,
        builder: reqwest::blocking::RequestBuilder,
        body: Option<&Value>,
        _token: Option<&str>,
    ) -> Result<Response, RelayError> {
        let builder = if let Some(body) = body {
            let encoded = serde_json::to_vec(body).map_err(|_| RelayError::InvalidResponse)?;
            if encoded.len() > MAXIMUM_REQUEST_BYTES {
                return Err(RelayError::ResponseTooLarge);
            }
            builder.body(encoded)
        } else {
            builder
        };
        builder.send().map_err(|error| {
            if error.is_timeout() {
                RelayError::Timeout
            } else if error.is_redirect() {
                RelayError::RedirectRefused
            } else {
                RelayError::Unavailable
            }
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.origin, path)
    }
}

/// `alerts` and `budget` are always sent. `history` is sent only when this write names the switch.
pub(crate) fn account_settings_put_body(document: &AccountSettingsWriteDocument) -> Value {
    let mut body = serde_json::json!({
        "protocol_version": CONTROL_PROTOCOL,
        "alerts": document.alerts,
        "budget": document.budget,
    });
    if let Some(history) = &document.history {
        body["history"] = serde_json::json!({ "sync": history.sync });
    }
    body
}

fn account_usage_period_path(from: &str, to: &str, timezone: &str, breakdown: bool) -> String {
    let mut query = url::form_urlencoded::Serializer::new(String::new());
    query.append_pair("from", from);
    query.append_pair("to", to);
    query.append_pair("timezone", timezone);
    if breakdown {
        query.append_pair("breakdown", "1");
    }
    format!("/api/v6/account/usage/period?{}", query.finish())
}

fn normalize_origin(origin: &str, test_override: bool) -> Result<String, RelayError> {
    let trimmed = origin.trim_end_matches('/');
    if trimmed == MANAGED_ORIGIN {
        return Ok(trimmed.to_owned());
    }
    if !test_override {
        return Err(RelayError::Rejected {
            code: "invalid_origin".to_owned(),
            status: 400,
        });
    }
    if trimmed.starts_with("http://127.0.0.1:") || trimmed.starts_with("http://localhost:") {
        return Ok(trimmed.to_owned());
    }
    Err(RelayError::Rejected {
        code: "invalid_origin".to_owned(),
        status: 400,
    })
}

fn bearer(token: &str) -> HeaderValue {
    // Session tokens are validated before this boundary.  Invalid header values fail as an
    // unavailable request rather than ever being copied into diagnostics.
    HeaderValue::from_str(&format!("Bearer {token}"))
        .unwrap_or_else(|_| HeaderValue::from_static("Bearer invalid"))
}

fn check_status(response: Response, expected_status: u16) -> Result<Response, RelayError> {
    let status = response.status().as_u16();
    if status == expected_status || (expected_status == 200 && status == 204) {
        return Ok(response);
    }
    let header_code = response
        .headers()
        .get("x-quota-error-code")
        .and_then(|value| value.to_str().ok())
        .filter(|value| {
            value.len() <= 64
                && value
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c == '_' || c.is_ascii_digit())
        })
        .map(str::to_owned);
    if status == 401 {
        return Err(RelayError::AuthenticationRequired);
    }
    let body_code = read_json(response).ok().and_then(|value| {
        value
            .get("error")
            .and_then(Value::as_object)
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str)
            .filter(|value| {
                value.len() <= 64
                    && value.chars().all(|character| {
                        character.is_ascii_lowercase()
                            || character == '_'
                            || character.is_ascii_digit()
                    })
            })
            .map(str::to_owned)
    });
    Err(RelayError::Rejected {
        code: header_code
            .or(body_code)
            .unwrap_or_else(|| "request_failed".to_owned()),
        status,
    })
}

fn read_json(response: Response) -> Result<Value, RelayError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAXIMUM_RESPONSE_BYTES as u64)
    {
        return Err(RelayError::ResponseTooLarge);
    }
    let mut bytes = Vec::new();
    response
        .take((MAXIMUM_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| RelayError::Unavailable)?;
    if bytes.len() > MAXIMUM_RESPONSE_BYTES {
        return Err(RelayError::ResponseTooLarge);
    }
    serde_json::from_slice(&bytes).map_err(|_| RelayError::InvalidResponse)
}

fn validate_bounded_json(value: &Value) -> Result<(), RelayError> {
    let bytes = serde_json::to_vec(value).map_err(|_| RelayError::InvalidResponse)?;
    if bytes.len() > MAXIMUM_REQUEST_BYTES {
        return Err(RelayError::ResponseTooLarge);
    }
    Ok(())
}

fn validate_snapshot_envelope(value: &Value) -> Result<(), RelayError> {
    validate_bounded_json(value)?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(MANAGED_DATA_PROTOCOL)
        || object
            .get("generation")
            .and_then(safe_positive_u64)
            .is_none()
        || object
            .get("snapshots")
            .and_then(Value::as_array)
            .is_none_or(|snapshots| snapshots.len() > 32)
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// One agent's rescanned hours, as the outbox packer sizes them.
///
/// What remains is what a type cannot say: byte and item caps, `protocol_version`, hour
/// boundaries, uniqueness, and numeric safety. Shape is the producer types' statement; a
/// payload Relay refuses is answered at the boundary (ADR 0028).
pub(crate) fn validate_usage_submission(value: &Value) -> Result<(), RelayError> {
    validate_bounded_json(value)?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(MANAGED_DATA_PROTOCOL)
        || object
            .get("generation")
            .and_then(safe_positive_u64)
            .is_none()
    {
        return Err(RelayError::InvalidResponse);
    }
    let agent = object
        .get("agent")
        .and_then(Value::as_str)
        .ok_or(RelayError::InvalidResponse)?;
    let hours = object
        .get("hours")
        .and_then(Value::as_array)
        .filter(|hours| hours.len() <= crate::usage::MAX_USAGE_HOURS_PER_UPLOAD)
        .ok_or(RelayError::InvalidResponse)?;
    let mut buckets = std::collections::BTreeSet::new();
    for hour in hours {
        let bucket = validate_usage_hour(hour, agent)?;
        if !buckets.insert(bucket) {
            return Err(RelayError::InvalidResponse);
        }
    }
    Ok(())
}

/// One hour and every row the scan behind it found, returning the hour it names.
fn validate_usage_hour(value: &Value, agent: &str) -> Result<String, RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("scan_version").and_then(safe_u64).is_none()
        || !object.get("partial").is_some_and(Value::is_boolean)
    {
        return Err(RelayError::InvalidResponse);
    }
    let bucket = parse_utc_hour(object.get("bucket_start_utc"))?;
    if bucket < earliest_usage_instant() {
        return Err(RelayError::InvalidResponse);
    }
    let rows = object
        .get("rows")
        .and_then(Value::as_array)
        .filter(|rows| rows.len() <= crate::usage::MAX_USAGE_ROWS_PER_HOUR)
        .ok_or(RelayError::InvalidResponse)?;
    let mut identities = std::collections::BTreeSet::new();
    for row in rows {
        let row_object = row.as_object().ok_or(RelayError::InvalidResponse)?;
        if row_object
            .get("source_cost_microusd")
            .is_some_and(|value| !value.is_string())
        {
            return Err(RelayError::InvalidResponse);
        }
        let row: crate::usage::UsageRow =
            serde_json::from_value(row.clone()).map_err(|_| RelayError::InvalidResponse)?;
        crate::usage::validate_row(&row).map_err(|_| RelayError::InvalidResponse)?;
        if row.agent.as_str() != agent {
            return Err(RelayError::InvalidResponse);
        }
        let identity =
            serde_json::to_string(&row.identity()).map_err(|_| RelayError::InvalidResponse)?;
        if !identities.insert(identity) {
            return Err(RelayError::InvalidResponse);
        }
    }
    Ok(bucket.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

/// The contract's lower bound on a coverage window, as the parser returns instants.
///
/// Checked here as well as at Relay: an hour outside the bound is a request that can only be
/// refused, and spending it to be told so costs a round trip and a diagnostic line.
fn earliest_usage_instant() -> chrono::DateTime<chrono::FixedOffset> {
    chrono::DateTime::parse_from_rfc3339(crate::usage::EARLIEST_USAGE_INSTANT)
        .expect("EARLIEST_USAGE_INSTANT is a valid RFC 3339 instant")
}

fn parse_utc_hour(
    value: Option<&Value>,
) -> Result<chrono::DateTime<chrono::FixedOffset>, RelayError> {
    let value = value
        .and_then(Value::as_str)
        .ok_or(RelayError::InvalidResponse)?;
    parse_utc_hour_value(value)
}

fn parse_utc_hour_value(value: &str) -> Result<chrono::DateTime<chrono::FixedOffset>, RelayError> {
    if value.len() != 20 || !value.ends_with('Z') {
        return Err(RelayError::InvalidResponse);
    }
    let parsed =
        chrono::DateTime::parse_from_rfc3339(value).map_err(|_| RelayError::InvalidResponse)?;
    if parsed.offset().local_minus_utc() != 0
        || parsed.minute() != 0
        || parsed.second() != 0
        || parsed.nanosecond() != 0
        || parsed.to_rfc3339_opts(chrono::SecondsFormat::Secs, true) != value
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(parsed)
}

/// What Relay answers an upload with: every name it was given, in exactly one of two lists.
fn validate_upload_response(value: &Value, named: &[String]) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "protocol_version",
            "device_id",
            "device_generation",
            "accepted",
            "ignored",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(MANAGED_DATA_PROTOCOL)
        || !object
            .get("device_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || object
            .get("device_generation")
            .and_then(safe_positive_u64)
            .is_none()
    {
        return Err(RelayError::InvalidResponse);
    }
    let mut answered = std::collections::BTreeSet::new();
    for key in ["accepted", "ignored"] {
        let list = object
            .get(key)
            .and_then(Value::as_array)
            .ok_or(RelayError::InvalidResponse)?;
        for item in list {
            let item = item.as_str().ok_or(RelayError::InvalidResponse)?;
            if !answered.insert(item.to_owned()) {
                return Err(RelayError::InvalidResponse);
            }
        }
    }
    if answered.len() != named.len() || named.iter().any(|name| !answered.contains(name)) {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// A response object carries every field this build reads. It may carry more.
fn require_response_fields(value: &Value, keys: &[&str]) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// A closed enum in a payload this build receives: bounded text, membership unchecked.
fn valid_read_enum(value: Option<&str>) -> bool {
    value.is_some_and(|value| valid_dimension(value, 64))
}

fn validate_control_response(value: &Value) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "protocol_version",
            "account_id",
            "device_id",
            "device_generation",
            "usage_deleted_before",
            "usage_sync_revision",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(CONTROL_PROTOCOL)
        || !object
            .get("account_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || !object
            .get("device_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || object
            .get("device_generation")
            .and_then(safe_positive_u64)
            .is_none()
        || object
            .get("usage_sync_revision")
            .and_then(safe_u64)
            .is_none()
        || !object
            .get("usage_deleted_before")
            .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_rfc3339))
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// `GET`/`PUT /api/v2/account/settings` as a tolerant read: required fields and invariants,
/// unknown keys ignored ([ADR 0023](../../../docs/decisions/0023-strict-writes-tolerant-reads.md)).
fn validate_account_settings(value: &Value) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "protocol_version",
            "revision",
            "updated_at",
            "alerts",
            "budget",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(CONTROL_PROTOCOL)
        || object.get("revision").and_then(safe_u64).is_none()
        || !object
            .get("updated_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
    {
        return Err(RelayError::InvalidResponse);
    }
    validate_account_settings_alerts(object.get("alerts").ok_or(RelayError::InvalidResponse)?)?;
    validate_account_settings_budget(object.get("budget").ok_or(RelayError::InvalidResponse)?)
}

fn validate_account_settings_alerts(value: &Value) -> Result<(), RelayError> {
    require_response_fields(value, &["reset_reminders", "pace_alerts", "thresholds"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object.get("reset_reminders").is_some_and(Value::is_boolean)
        || !object.get("pace_alerts").is_some_and(Value::is_boolean)
    {
        return Err(RelayError::InvalidResponse);
    }
    let thresholds = object
        .get("thresholds")
        .and_then(Value::as_object)
        .filter(|thresholds| thresholds.len() <= 256)
        .ok_or(RelayError::InvalidResponse)?;
    for (selector, values) in thresholds {
        if !is_account_settings_selector(selector) {
            return Err(RelayError::InvalidResponse);
        }
        let list = values
            .as_array()
            .filter(|list| (1..=2).contains(&list.len()))
            .ok_or(RelayError::InvalidResponse)?;
        let mut previous: Option<i64> = None;
        for item in list {
            let number = item.as_i64().ok_or(RelayError::InvalidResponse)?;
            if !(1..=99).contains(&number) || previous.is_some_and(|prior| number >= prior) {
                return Err(RelayError::InvalidResponse);
            }
            previous = Some(number);
        }
    }
    Ok(())
}

fn validate_account_settings_budget(value: &Value) -> Result<(), RelayError> {
    require_response_fields(value, &["amount_usd", "alerts"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object.get("alerts").is_some_and(Value::is_boolean) {
        return Err(RelayError::InvalidResponse);
    }
    match object.get("amount_usd") {
        Some(Value::Null) => Ok(()),
        Some(Value::String(amount)) if valid_budget_amount_usd(amount) => Ok(()),
        _ => Err(RelayError::InvalidResponse),
    }
}

fn is_account_settings_selector(value: &str) -> bool {
    value.len() == 12
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn valid_budget_amount_usd(value: &str) -> bool {
    let (whole, fraction) = match value.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (value, None),
    };
    if whole.is_empty() || whole.len() > 7 || !whole.bytes().all(|byte| byte.is_ascii_digit()) {
        return false;
    }
    if let Some(fraction) = fraction
        && (fraction.is_empty()
            || fraction.len() > 2
            || !fraction.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return false;
    }
    value
        .parse::<f64>()
        .ok()
        .is_some_and(|amount| amount > 0.0 && amount <= 1_000_000.0)
}

fn validate_account_summary(value: &Value) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "protocol_version",
            "account",
            "devices",
            "subscriptions",
            "usage",
            "pricing_revision",
            "model_catalog_revision",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(MANAGED_DATA_PROTOCOL)
        || ["pricing_revision", "model_catalog_revision"]
            .iter()
            .any(|key| {
                !object
                    .get(*key)
                    .and_then(Value::as_str)
                    .is_some_and(is_opaque)
            })
    {
        return Err(RelayError::InvalidResponse);
    }
    validate_account_record(object.get("account").ok_or(RelayError::InvalidResponse)?)?;
    let devices = object
        .get("devices")
        .and_then(Value::as_array)
        .filter(|devices| devices.len() <= 256)
        .ok_or(RelayError::InvalidResponse)?;
    for device in devices {
        validate_account_device(device)?;
    }
    let subscriptions = object
        .get("subscriptions")
        .and_then(Value::as_array)
        .filter(|subscriptions| subscriptions.len() <= 1_024)
        .ok_or(RelayError::InvalidResponse)?;
    for subscription in subscriptions {
        validate_quota_subscription(subscription)?;
    }
    validate_account_usage(object.get("usage").ok_or(RelayError::InvalidResponse)?)?;
    Ok(())
}

fn validate_account_record(value: &Value) -> Result<(), RelayError> {
    require_response_fields(value, &["account_id", "display_label", "created_at"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object
        .get("account_id")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || !object
            .get("created_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
        || !object.get("display_label").is_some_and(|label| {
            label.is_null()
                || label
                    .as_str()
                    .is_some_and(|value| valid_display(value, 128))
        })
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// A device as an Account reads it: the two instants Relay witnessed.
fn validate_account_device(value: &Value) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "id",
            "display_name",
            "platform",
            "last_seen_at",
            "last_observed_at",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || !object
            .get("display_name")
            .and_then(Value::as_str)
            .is_some_and(|value| valid_display(value, 128))
        || !valid_read_enum(object.get("platform").and_then(Value::as_str))
        || ["last_seen_at", "last_observed_at"].iter().any(|key| {
            !object
                .get(*key)
                .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_rfc3339))
        })
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// One subscription, already resolved, and every device whose reading stands behind it.
fn validate_quota_subscription(value: &Value) -> Result<(), RelayError> {
    require_response_fields(value, &["key", "provider", "snapshot", "sources"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object
        .get("key")
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty() && value.len() <= 512)
        || !valid_read_enum(object.get("provider").and_then(Value::as_str))
    {
        return Err(RelayError::InvalidResponse);
    }
    let sources = object
        .get("sources")
        .and_then(Value::as_array)
        .filter(|sources| sources.len() <= 256)
        .ok_or(RelayError::InvalidResponse)?;
    for source in sources {
        require_response_fields(source, &["device_id", "observed_at"])?;
        let source = source.as_object().ok_or(RelayError::InvalidResponse)?;
        if !source
            .get("device_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
            || !source
                .get("observed_at")
                .and_then(Value::as_str)
                .is_some_and(valid_rfc3339)
        {
            return Err(RelayError::InvalidResponse);
        }
        if let Some(snapshot) = source.get("snapshot") {
            validate_quota_snapshot(snapshot)?;
        }
    }
    validate_quota_snapshot(object.get("snapshot").ok_or(RelayError::InvalidResponse)?)
}

fn validate_quota_snapshot(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let required = ["provider", "account", "windows", "status", "observed_at"];
    if required.iter().any(|key| !object.contains_key(*key)) {
        return Err(RelayError::InvalidResponse);
    }
    // A reading this build is handed for a provider it has never heard of still belongs to
    // the account it came from.
    if !valid_read_enum(object.get("provider").and_then(Value::as_str))
        || !valid_read_enum(object.get("status").and_then(Value::as_str))
        || !object
            .get("observed_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
    {
        return Err(RelayError::InvalidResponse);
    }
    validate_quota_account(object.get("account").ok_or(RelayError::InvalidResponse)?)?;
    let windows = object
        .get("windows")
        .and_then(Value::as_array)
        .filter(|windows| windows.len() <= 16)
        .ok_or(RelayError::InvalidResponse)?;
    for window in windows {
        validate_quota_window(window)?;
    }
    Ok(())
}

fn validate_quota_account(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let required = ["fingerprint", "fingerprint_scope"];
    if required.iter().any(|key| !object.contains_key(*key)) {
        return Err(RelayError::InvalidResponse);
    }
    if !object
        .get("fingerprint")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || !valid_read_enum(object.get("fingerprint_scope").and_then(Value::as_str))
        || object.get("label").is_some_and(|value| {
            !value
                .as_str()
                .is_some_and(|value| valid_display(value, 128))
        })
        || object
            .get("plan")
            .is_some_and(|value| !value.as_str().is_some_and(|value| valid_display(value, 64)))
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_quota_window(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let required = ["id", "title", "used_percent"];
    if required.iter().any(|key| !object.contains_key(*key)) {
        return Err(RelayError::InvalidResponse);
    }
    let used_percent = object.get("used_percent").and_then(Value::as_f64);
    if !object
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(|value| valid_dimension(value, 64))
        || !object
            .get("title")
            .and_then(Value::as_str)
            .is_some_and(|value| valid_display(value, 128))
        || !used_percent.is_some_and(|value| value.is_finite() && (0.0..=100.0).contains(&value))
        || object
            .get("resets_at")
            .is_some_and(|value| !value.as_str().is_some_and(valid_rfc3339))
        || object
            .get("duration_seconds")
            .is_some_and(|value| safe_u64(value).is_none())
        || object
            .get("remaining_value")
            .is_some_and(|value| !value.as_f64().is_some_and(f64::is_finite))
        || object.get("limit_value").is_some_and(|value| {
            !value
                .as_f64()
                .is_some_and(|number| number.is_finite() && number >= 0.0)
        })
        || object
            .get("value_unit")
            .is_some_and(|value| !valid_read_enum(value.as_str()))
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// The four periods an Account read answers.
fn validate_account_usage(value: &Value) -> Result<(), RelayError> {
    let keys = ["today", "last_7_days", "last_30_days", "all"];
    require_response_fields(value, &keys)?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    for key in keys {
        validate_usage_period(object.get(key).ok_or(RelayError::InvalidResponse)?)?;
    }
    Ok(())
}

/// One period: its totals, its cost, whether an hour behind it was scanned incompletely, and
/// the agent tree that makes up the difference.
fn validate_usage_period(value: &Value) -> Result<(), RelayError> {
    require_response_fields(value, &["totals", "cost", "partial", "agents"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object.get("partial").is_some_and(Value::is_boolean) {
        return Err(RelayError::InvalidResponse);
    }
    validate_usage_summary_totals(object.get("totals").ok_or(RelayError::InvalidResponse)?)?;
    validate_usage_cost(object.get("cost").ok_or(RelayError::InvalidResponse)?)?;
    validate_usage_agents(object.get("agents").ok_or(RelayError::InvalidResponse)?)
}

/// `GET /api/v6/account/usage/period` as a tolerant read of the protocol write schema.
fn validate_account_usage_period(
    value: &Value,
    from: &str,
    to: &str,
    timezone: &str,
) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "protocol_version",
            "request",
            "bounds",
            "totals",
            "cost",
            "cache_saved",
            "days",
            "coverage",
            "revision",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(MANAGED_DATA_PROTOCOL) {
        return Err(RelayError::InvalidResponse);
    }
    let request = object
        .get("request")
        .and_then(Value::as_object)
        .ok_or(RelayError::InvalidResponse)?;
    if request.get("from").and_then(Value::as_str) != Some(from)
        || request.get("to").and_then(Value::as_str) != Some(to)
        || request.get("timezone").and_then(Value::as_str) != Some(timezone)
    {
        return Err(RelayError::InvalidResponse);
    }
    let bounds = object
        .get("bounds")
        .and_then(Value::as_object)
        .ok_or(RelayError::InvalidResponse)?;
    let start = bounds
        .get("start")
        .and_then(Value::as_str)
        .filter(|value| valid_utc_hour(value))
        .ok_or(RelayError::InvalidResponse)?;
    let end = bounds
        .get("end")
        .and_then(Value::as_str)
        .filter(|value| valid_utc_hour(value))
        .ok_or(RelayError::InvalidResponse)?;
    if start >= end || bounds.get("grid").and_then(Value::as_str) != Some(USAGE_HOUR_GRID_RULE) {
        return Err(RelayError::InvalidResponse);
    }
    validate_usage_summary_totals(object.get("totals").ok_or(RelayError::InvalidResponse)?)?;
    validate_usage_cost(object.get("cost").ok_or(RelayError::InvalidResponse)?)?;
    validate_usage_cache_saved(
        object
            .get("cache_saved")
            .ok_or(RelayError::InvalidResponse)?,
    )?;
    let days = object
        .get("days")
        .and_then(Value::as_array)
        .filter(|days| days.len() as i64 <= crate::protocol::MAXIMUM_USAGE_PERIOD_DAYS)
        .ok_or(RelayError::InvalidResponse)?;
    let mut previous_date: Option<&str> = None;
    for day in days {
        require_response_fields(day, &["date", "totals", "cost", "partial"])?;
        let day = day.as_object().ok_or(RelayError::InvalidResponse)?;
        let date = day
            .get("date")
            .and_then(Value::as_str)
            .filter(|value| valid_usage_date(value))
            .ok_or(RelayError::InvalidResponse)?;
        if previous_date.is_some_and(|previous| date <= previous)
            || !day.get("partial").is_some_and(Value::is_boolean)
        {
            return Err(RelayError::InvalidResponse);
        }
        validate_usage_summary_totals(day.get("totals").ok_or(RelayError::InvalidResponse)?)?;
        validate_usage_cost(day.get("cost").ok_or(RelayError::InvalidResponse)?)?;
        previous_date = Some(date);
    }
    if let Some(agents) = object.get("agents") {
        validate_usage_agents(agents)?;
    }
    validate_usage_period_coverage(object.get("coverage").ok_or(RelayError::InvalidResponse)?)?;
    validate_usage_period_revision(object.get("revision").ok_or(RelayError::InvalidResponse)?)
}

fn validate_usage_cache_saved(value: &Value) -> Result<(), RelayError> {
    require_response_fields(value, &["amount_microusd", "status", "unpriced_rows"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let status = object.get("status").and_then(Value::as_str);
    if !matches!(status, Some("complete" | "partial" | "unavailable")) {
        return Err(RelayError::InvalidResponse);
    }
    let amount = object
        .get("amount_microusd")
        .ok_or(RelayError::InvalidResponse)?;
    let amount_null = amount.is_null();
    if !amount_null && !amount.as_str().is_some_and(valid_decimal_integer) {
        return Err(RelayError::InvalidResponse);
    }
    let unpriced = object
        .get("unpriced_rows")
        .and_then(safe_u64)
        .ok_or(RelayError::InvalidResponse)?;
    if (status == Some("unavailable")) != amount_null
        || (status == Some("complete")) != (unpriced == 0)
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_usage_period_coverage(value: &Value) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "partial",
            "daily_retained_from",
            "hourly_retained_from",
            "truncated_by_retention",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object.get("partial").is_some_and(Value::is_boolean)
        || !object
            .get("truncated_by_retention")
            .is_some_and(Value::is_boolean)
        || !object
            .get("daily_retained_from")
            .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_usage_date))
        || !object
            .get("hourly_retained_from")
            .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_utc_hour))
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_usage_period_revision(value: &Value) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "usage_revision",
            "device_generation",
            "account_updated_at",
            "pricing_revision",
            "model_catalog_revision",
            "fold_version",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("usage_revision").and_then(safe_u64).is_none()
        || object.get("device_generation").and_then(safe_u64).is_none()
        || object.get("fold_version").and_then(safe_u64).is_none()
        || !object
            .get("account_updated_at")
            .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_rfc3339))
        || ["pricing_revision", "model_catalog_revision"]
            .iter()
            .any(|key| {
                !object
                    .get(*key)
                    .and_then(Value::as_str)
                    .is_some_and(is_opaque)
            })
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn valid_usage_date(value: &str) -> bool {
    value.len() == 10
        && chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d")
            .is_ok_and(|parsed| parsed.format("%Y-%m-%d").to_string() == value)
}

fn valid_utc_hour(value: &str) -> bool {
    value.len() == 20
        && value.as_bytes().get(13) == Some(&b':')
        && value.ends_with(":00:00Z")
        && chrono::DateTime::parse_from_rfc3339(value).is_ok()
}

fn validate_usage_agents(value: &Value) -> Result<(), RelayError> {
    let agents = value
        .as_array()
        .filter(|agents| agents.len() <= crate::usage::UsageAgent::ALL.len())
        .ok_or(RelayError::InvalidResponse)?;
    for agent in agents {
        require_response_fields(agent, &["agent", "providers"])?;
        let object = agent.as_object().ok_or(RelayError::InvalidResponse)?;
        if !valid_read_enum(object.get("agent").and_then(Value::as_str)) {
            return Err(RelayError::InvalidResponse);
        }
        // Bounded by the wire's leaf cap, not by the vocabulary this build knows: a vendor a
        // newer Relay names is read as unknown, not refused along with the whole summary.
        let providers = object
            .get("providers")
            .and_then(Value::as_array)
            .filter(|providers| providers.len() <= 200)
            .ok_or(RelayError::InvalidResponse)?;
        for provider in providers {
            require_response_fields(provider, &["provider", "models"])?;
            let object = provider.as_object().ok_or(RelayError::InvalidResponse)?;
            if !valid_read_enum(object.get("provider").and_then(Value::as_str)) {
                return Err(RelayError::InvalidResponse);
            }
            let models = object
                .get("models")
                .and_then(Value::as_array)
                .filter(|models| models.len() <= 1_000)
                .ok_or(RelayError::InvalidResponse)?;
            for model in models {
                require_response_fields(model, &["model", "totals", "cost"])?;
                let object = model.as_object().ok_or(RelayError::InvalidResponse)?;
                if !object
                    .get("model")
                    .and_then(Value::as_str)
                    .is_some_and(valid_model_text)
                {
                    return Err(RelayError::InvalidResponse);
                }
                validate_usage_summary_totals(
                    object.get("totals").ok_or(RelayError::InvalidResponse)?,
                )?;
                validate_usage_cost(object.get("cost").ok_or(RelayError::InvalidResponse)?)?;
            }
        }
    }
    Ok(())
}

fn validate_usage_summary_totals(value: &Value) -> Result<(), RelayError> {
    let keys = [
        "total_tokens",
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_write_input_tokens",
        "reasoning_tokens",
        "messages",
    ];
    require_response_fields(value, &keys)?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let count = |key: &str| object.get(key).and_then(safe_u64);
    let input = count("input_tokens").ok_or(RelayError::InvalidResponse)?;
    let output = count("output_tokens").ok_or(RelayError::InvalidResponse)?;
    let cache_read = count("cache_read_input_tokens").ok_or(RelayError::InvalidResponse)?;
    let cache_write = count("cache_write_input_tokens").ok_or(RelayError::InvalidResponse)?;
    if count("total_tokens") != input.checked_add(output)
        || cache_read
            .checked_add(cache_write)
            .is_none_or(|cached| cached > input)
        || count("reasoning_tokens").is_none_or(|reasoning| reasoning > output)
        || count("messages").is_none()
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_usage_cost(value: &Value) -> Result<(), RelayError> {
    let required_keys = [
        "mode",
        "basis",
        "status",
        "amount_microusd",
        "catalog_revision",
        "calculated_rows",
        "reported_rows",
        "unpriced_rows",
        "assumptions",
        "unpriced",
    ];
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if required_keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(RelayError::InvalidResponse);
    }
    if !matches!(
        object.get("mode").and_then(Value::as_str),
        Some("calculate" | "auto" | "reported")
    ) || !matches!(
        object.get("basis").and_then(Value::as_str),
        Some("calculated" | "reported" | "mixed" | "none")
    ) || !matches!(
        object.get("status").and_then(Value::as_str),
        Some("complete" | "partial" | "unavailable")
    ) || object
        .get("amount_microusd")
        .is_some_and(|value| !value.is_null() && !value.as_str().is_some_and(valid_decimal_integer))
        || object
            .get("catalog_revision")
            .is_some_and(|value| !value.is_null() && !value.as_str().is_some_and(is_opaque))
        || object.get("calculated_rows").and_then(safe_u64).is_none()
        || object.get("reported_rows").and_then(safe_u64).is_none()
        || object.get("unpriced_rows").and_then(safe_u64).is_none()
        || object
            .get("unpriced_truncated")
            .is_some_and(|value| value != &Value::Bool(true))
    {
        return Err(RelayError::InvalidResponse);
    }
    let assumptions = object
        .get("assumptions")
        .and_then(Value::as_array)
        .filter(|values| values.len() <= 16)
        .ok_or(RelayError::InvalidResponse)?;
    if assumptions
        .iter()
        .any(|value| !valid_read_enum(value.as_str()))
    {
        return Err(RelayError::InvalidResponse);
    }
    if assumptions
        .iter()
        .filter_map(Value::as_str)
        .collect::<std::collections::BTreeSet<_>>()
        .len()
        != assumptions.len()
    {
        return Err(RelayError::InvalidResponse);
    }
    let unpriced = object
        .get("unpriced")
        .and_then(Value::as_array)
        .filter(|values| values.len() <= 100)
        .ok_or(RelayError::InvalidResponse)?;
    for item in unpriced {
        require_response_fields(item, &["billing_channel", "model", "reason", "rows"])?;
        let item = item.as_object().ok_or(RelayError::InvalidResponse)?;
        if !valid_read_enum(item.get("billing_channel").and_then(Value::as_str))
            || !item
                .get("model")
                .and_then(Value::as_str)
                .is_some_and(valid_model_text)
            || !valid_read_enum(item.get("reason").and_then(Value::as_str))
            || item.get("rows").and_then(safe_positive_u64).is_none()
        {
            return Err(RelayError::InvalidResponse);
        }
    }
    let unpriced_truncated = object
        .get("unpriced_truncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let calculated_rows = object["calculated_rows"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?;
    let reported_rows = object["reported_rows"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?;
    let unpriced_rows = object["unpriced_rows"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?;
    let priced_rows = calculated_rows
        .checked_add(reported_rows)
        .filter(|rows| *rows <= MAXIMUM_SAFE_INTEGER)
        .ok_or(RelayError::InvalidResponse)?;
    let expected_basis = match (calculated_rows > 0, reported_rows > 0) {
        (true, true) => "mixed",
        (true, false) => "calculated",
        (false, true) => "reported",
        (false, false) => "none",
    };
    let expected_status = if unpriced_rows == 0 {
        "complete"
    } else if priced_rows > 0 {
        "partial"
    } else {
        "unavailable"
    };
    if object["basis"].as_str() != Some(expected_basis)
        || object["status"].as_str() != Some(expected_status)
        || (priced_rows > 0)
            != object
                .get("amount_microusd")
                .is_some_and(|amount| !amount.is_null())
    {
        return Err(RelayError::InvalidResponse);
    }
    let listed_rows = object["unpriced"]
        .as_array()
        .and_then(|items| {
            items.iter().try_fold(0u64, |total, item| {
                total.checked_add(item.get("rows")?.as_u64()?)
            })
        })
        .ok_or(RelayError::InvalidResponse)?;
    if listed_rows > unpriced_rows || (!unpriced_truncated && listed_rows != unpriced_rows) {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// Checks that a rotation answers for the session it rotated.
///
/// A refresh response carries the new token family and the identity it still belongs to. The
/// deletion watermark and sync revision are the device sync endpoint's answer, not this route's.
fn validate_session_refresh_response(value: &Value, session: &Value) -> Result<(), BackendError> {
    let object = value.as_object().ok_or_else(BackendError::unavailable)?;
    require_response_fields(
        value,
        &[
            "protocol_version",
            "token_type",
            "account_id",
            "device_id",
            "device_generation",
            "session",
        ],
    )
    .map_err(|_| invalid_response_backend())?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(CONTROL_PROTOCOL)
        || object.get("token_type").and_then(Value::as_str) != Some("Bearer")
        || !object
            .get("account_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || object.get("account_id").and_then(Value::as_str)
            != session.get("account_id").and_then(Value::as_str)
        || object
            .get("device_id")
            .and_then(Value::as_str)
            .is_none_or(|value| {
                !is_opaque(value) || Some(value) != session.get("device_id").and_then(Value::as_str)
            })
        || object.get("device_generation").and_then(safe_positive_u64)
            != session.get("device_generation").and_then(safe_positive_u64)
    {
        return Err(invalid_response_backend());
    }
    validate_session_token(
        object
            .get("session")
            .ok_or_else(BackendError::unavailable)?,
    )
    .map_err(|_| invalid_response_backend())?;
    Ok(())
}

/// Native account/session owner used by the service backend.  It stores only the bounded session
/// envelope in SQLite; browser authorization codes and provider credentials never enter the
/// component state or diagnostics.
struct PendingBrowserLogin {
    listener: TcpListener,
    redirect_uri: String,
    state: String,
    verifier: String,
}

#[derive(Clone, Eq, Hash, PartialEq)]
struct AccountPeriodCacheKey {
    from: String,
    to: String,
    timezone: String,
    account_id: String,
}

struct AccountPeriodCacheEntry {
    etag: String,
    body: Value,
}

pub struct AccountManager {
    client: Arc<RelayClient>,
    state: Arc<StateStore>,
    device_name: String,
    platform: &'static str,
    /// Serializes access-token refresh so two lanes cannot spend the same single-use refresh token.
    refresh_lock: Mutex<()>,
    /// Loopback listener and PKCE values for the login in flight. Set by `begin_login`, taken by
    /// `login`.
    pending_login: Mutex<Option<PendingBrowserLogin>>,
    /// Last Account period bodies, keyed by range and session. Memory only; 304 keeps the body.
    period_cache: Mutex<HashMap<AccountPeriodCacheKey, AccountPeriodCacheEntry>>,
    /// One history upload at a time, so a settings transition and a collection cannot backfill twice.
    history_lock: Mutex<()>,
    /// Set when Relay answers `413 quota_history_full`. The next collection clears it and may try again.
    history_full: AtomicBool,
}

impl AccountManager {
    pub fn new(client: Arc<RelayClient>, state: Arc<StateStore>, device_name: String) -> Self {
        Self {
            client,
            state,
            device_name: sanitize_device_name(&device_name),
            platform: current_platform(),
            refresh_lock: Mutex::new(()),
            pending_login: Mutex::new(None),
            period_cache: Mutex::new(HashMap::new()),
            history_lock: Mutex::new(()),
            history_full: AtomicBool::new(false),
        }
    }

    /// Bind the loopback listener, generate PKCE/`state`, and return the authorize URL.
    ///
    /// The app opens the URL. This process never launches a browser.
    pub fn begin_login(&self) -> Result<String, BackendError> {
        let pending = prepare_browser_login()?;
        let authorize_url = pending_authorize_url(&pending)?;
        let mut slot = self
            .pending_login
            .lock()
            .map_err(|_| BackendError::unavailable())?;
        *slot = Some(pending);
        Ok(authorize_url)
    }

    pub fn abort_pending_login(&self) {
        if let Ok(mut slot) = self.pending_login.lock() {
            slot.take();
        }
    }

    pub fn login(&self, cancel: &AtomicBool) -> Result<LoginOutcome, BackendError> {
        let pending = self
            .pending_login
            .lock()
            .map_err(|_| BackendError::unavailable())?
            .take()
            .ok_or_else(BackendError::unavailable)?;
        let installation_id = self
            .state
            .installation_id()
            .map_err(|_| BackendError::unavailable())?;
        let response = self.complete_browser_exchange(pending, &installation_id, cancel)?;
        self.finalize_login_unless_cancelled(&response, cancel)
    }

    /// Builds the login outcome, unless cancellation won the race against issuance.
    ///
    /// Relay has already issued the family by the time this runs, so a cancelled login cannot
    /// simply drop it: retain a durable revoke record instead of leaving a live token in memory.
    fn finalize_login_unless_cancelled(
        &self,
        response: &Value,
        cancel: &AtomicBool,
    ) -> Result<LoginOutcome, BackendError> {
        let outcome = self.finalize_login(response)?;
        if cancel.load(Ordering::Acquire) {
            let pending = pending_session_from_active(&outcome.session)
                .ok_or_else(BackendError::unavailable)?;
            self.state
                .write_session_json(&pending)
                .map_err(|_| BackendError::unavailable())?;
            return Err(BackendError::cancelled());
        }
        Ok(outcome)
    }

    fn finalize_login(&self, response: &Value) -> Result<LoginOutcome, BackendError> {
        let session = session_from_token_response(response).map_err(|_| {
            BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            ))
        })?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?
            .to_owned();
        let account = AccountComponentValue {
            auth_status: AuthStatus::SignedIn,
            account_id: Some(account_id),
            display_label: session
                .get("display_label")
                .and_then(Value::as_str)
                .map(str::to_owned),
            device_id: session
                .get("device_id")
                .and_then(Value::as_str)
                .map(str::to_owned),
            device_generation: session.get("device_generation").and_then(Value::as_u64),
            account_summary: None,
        };
        Ok(LoginOutcome { session, account })
    }

    /// Ends this device's session: one family, so one revocation.
    pub fn logout(&self, pending: &Value) -> Result<(), BackendError> {
        self.clear_period_cache();
        let refresh_token = pending
            .as_object()
            .and_then(|object| object.get("refresh_token"))
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        self.client
            .revoke(refresh_token)
            .map_err(|error| BackendError::new(relay_error_for_backend(error)))
    }

    /// Reads the whole Account once, in the calendar this device keeps.
    ///
    /// `timezone` is this device's IANA zone, and it decides where the three trailing periods
    /// begin and end: a local day starts at local midnight. `all` is every retained day.
    pub fn refresh_account_state(
        &self,
        timezone: &str,
        cancel: &AtomicBool,
    ) -> Result<Value, BackendError> {
        let query = format!("tz={timezone}");
        let (summary, session) = self.read_account_summary(&query, cancel)?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let device_id = session
            .get("device_id")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let device_generation = session.get("device_generation").and_then(Value::as_u64);
        match self.fetch_account_settings(cancel, false) {
            Ok(Some((settings_account_id, document))) => {
                self.note_history_settings(&settings_account_id, &document, cancel);
            }
            Ok(None) => {}
            Err(error) if error.error.code.requires_login() => return Err(error),
            Err(_) => {}
        }
        Ok(serde_json::to_value(AccountComponentValue {
            auth_status: AuthStatus::SignedIn,
            account_id,
            display_label: session
                .get("display_label")
                .and_then(Value::as_str)
                .map(str::to_owned),
            device_id,
            device_generation,
            account_summary: Some(summary),
        })
        .unwrap_or(Value::Null))
    }

    /// The 24-hour rhythm of one UTC date range, in this device's calendar.
    pub fn account_usage_hours(
        &self,
        from: &str,
        to: &str,
        timezone: &str,
        cancel: &AtomicBool,
    ) -> Result<Value, BackendError> {
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        let (mut session, mut session_epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(|| {
                BackendError::new(crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::AuthenticationRequired,
                    crate::protocol::RecoveryAction::Login,
                ))
            })?;
        if !is_active_session(&session) {
            return Err(BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::AuthenticationRequired,
                crate::protocol::RecoveryAction::Login,
            )));
        }
        let access_token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        self.client
            .account_usage_hours(&access_token, from, to, timezone)
            .map_err(|error| relay_backend_error(error, session_epoch))
    }

    /// One Account period from Relay, with an in-memory ETag cache. No session → typed refusal.
    pub fn account_usage_period(
        &self,
        from: &str,
        to: &str,
        timezone: &str,
        breakdown: bool,
        cancel: &AtomicBool,
    ) -> Result<Value, BackendError> {
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        let (mut session, mut session_epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(|| {
                BackendError::new(crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::AuthenticationRequired,
                    crate::protocol::RecoveryAction::Login,
                ))
            })?;
        if !is_active_session(&session) {
            return Err(BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::AuthenticationRequired,
                crate::protocol::RecoveryAction::Login,
            )));
        }
        let access_token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let key = AccountPeriodCacheKey {
            from: from.to_owned(),
            to: to.to_owned(),
            timezone: timezone.to_owned(),
            account_id: account_id.clone(),
        };
        let cached = self.cached_period(&key);
        let (next_etag, body) = self
            .client
            .account_usage_period(
                from,
                to,
                timezone,
                breakdown,
                &access_token,
                cached
                    .as_ref()
                    .and_then(|entry| (!entry.etag.is_empty()).then_some(entry.etag.as_str())),
            )
            .map_err(|error| relay_backend_error(error, session_epoch))?;
        match body {
            Some(period) => {
                validate_account_usage_period(&period, from, to, timezone).map_err(|_| {
                    BackendError::new(crate::protocol::IpcError::new(
                        crate::protocol::ErrorCode::InvalidResponse,
                        crate::protocol::RecoveryAction::Retry,
                    ))
                })?;
                if !account_id.is_empty()
                    && let Some(etag) = next_etag.filter(|value| !value.is_empty())
                {
                    self.store_period(
                        key,
                        AccountPeriodCacheEntry {
                            etag,
                            body: period.clone(),
                        },
                    );
                }
                Ok(period)
            }
            None => match cached {
                Some(entry) => {
                    if let Some(etag) = next_etag.filter(|value| !value.is_empty()) {
                        self.store_period(
                            key,
                            AccountPeriodCacheEntry {
                                etag,
                                body: entry.body.clone(),
                            },
                        );
                    }
                    Ok(entry.body)
                }
                None => Err(BackendError::new(crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::InvalidResponse,
                    crate::protocol::RecoveryAction::Retry,
                ))),
            },
        }
    }

    /// Force a GET of the Account settings document and store it.
    pub fn refresh_account_settings(
        self: &Arc<Self>,
        cancel: &AtomicBool,
    ) -> Result<crate::protocol::AccountSettingsState, BackendError> {
        if let Some((account_id, document)) = self.fetch_account_settings(cancel, true)? {
            self.note_history_settings_detached(&account_id, &document);
        }
        self.cached_account_settings()
    }

    /// Compare-and-set write. A 412 is a successful round trip that returns `conflict`.
    pub fn put_account_settings(
        self: &Arc<Self>,
        document: &AccountSettingsWriteDocument,
        if_match: &str,
        cancel: &AtomicBool,
    ) -> Result<AccountSettingsMutationResult, BackendError> {
        let (mut session, mut session_epoch) = self.active_session_pair()?;
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        let access_token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(BackendError::unavailable)?
            .to_owned();
        let body = account_settings_put_body(document);
        let write = self
            .client
            .put_account_settings(&access_token, &body, if_match)
            .map_err(|error| relay_backend_error(error, session_epoch))?;
        let (outcome, document, etag) = match write {
            AccountSettingsWrite::Written { document, etag } => {
                (AccountSettingsWriteOutcome::Written, document, etag)
            }
            AccountSettingsWrite::Conflict { document, etag } => {
                (AccountSettingsWriteOutcome::Conflict, document, etag)
            }
        };
        let revision = document
            .get("revision")
            .and_then(Value::as_u64)
            .ok_or_else(|| {
                BackendError::new(crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::InvalidResponse,
                    crate::protocol::RecoveryAction::Retry,
                ))
            })?;
        if self
            .state
            .set_account_settings_cache(
                &account_id,
                etag.filter(|value| !value.is_empty()).as_deref(),
                &document,
            )
            .is_ok()
        {
            self.note_history_settings_detached(&account_id, &document);
        }
        Ok(AccountSettingsMutationResult {
            outcome,
            document,
            revision,
        })
    }

    /// Answers the document Relay just sent, or `None` on a 304, so the caller can hand the
    /// history switch to the lane it is on: the collection thread backfills inline, the IPC
    /// thread detaches it.
    fn fetch_account_settings(
        &self,
        cancel: &AtomicBool,
        force: bool,
    ) -> Result<Option<(String, Value)>, BackendError> {
        let (mut session, mut session_epoch) = self.active_session_pair()?;
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        let access_token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(BackendError::unavailable)?
            .to_owned();
        let cached = self
            .state
            .account_settings_cache(&account_id)
            .map_err(|_| BackendError::unavailable())?;
        let etag = if force {
            None
        } else {
            cached
                .as_ref()
                .and_then(|entry| (!entry.etag.is_empty()).then_some(entry.etag.as_str()))
        };
        let (next_etag, body) = self
            .client
            .account_settings(&access_token, etag)
            .map_err(|error| relay_backend_error(error, session_epoch))?;
        match body {
            Some(document) => {
                if self
                    .state
                    .set_account_settings_cache(
                        &account_id,
                        next_etag.filter(|value| !value.is_empty()).as_deref(),
                        &document,
                    )
                    .is_ok()
                {
                    return Ok(Some((account_id, document)));
                }
                Ok(None)
            }
            None => {
                if cached.is_some() {
                    Ok(None)
                } else {
                    Err(BackendError::new(crate::protocol::IpcError::new(
                        crate::protocol::ErrorCode::InvalidResponse,
                        crate::protocol::RecoveryAction::Retry,
                    )))
                }
            }
        }
    }

    fn cached_account_settings(
        &self,
    ) -> Result<crate::protocol::AccountSettingsState, BackendError> {
        let session = self
            .state
            .session_json()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(signed_out_error)?;
        if !is_active_session(&session) {
            return Err(signed_out_error());
        }
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(signed_out_error)?;
        self.state
            .account_settings_cache(account_id)
            .map_err(|_| BackendError::unavailable())?
            .map(|cached| cached.state)
            .ok_or_else(|| {
                BackendError::new(crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::InvalidResponse,
                    crate::protocol::RecoveryAction::Retry,
                ))
            })
    }

    fn active_session_pair(&self) -> Result<(Value, u64), BackendError> {
        let (session, epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(signed_out_error)?;
        if !is_active_session(&session) {
            return Err(signed_out_error());
        }
        Ok((session, epoch))
    }

    fn cached_period(&self, key: &AccountPeriodCacheKey) -> Option<AccountPeriodCacheEntry> {
        let cache = self.period_cache.lock().ok()?;
        cache.get(key).map(|entry| AccountPeriodCacheEntry {
            etag: entry.etag.clone(),
            body: entry.body.clone(),
        })
    }

    fn store_period(&self, key: AccountPeriodCacheKey, entry: AccountPeriodCacheEntry) {
        let Ok(mut cache) = self.period_cache.lock() else {
            return;
        };
        if cache.len() >= MAXIMUM_ACCOUNT_PERIOD_CACHE
            && !cache.contains_key(&key)
            && let Some(oldest) = cache.keys().next().cloned()
        {
            cache.remove(&oldest);
        }
        cache.insert(key, entry);
    }

    fn clear_period_cache(&self) {
        if let Ok(mut cache) = self.period_cache.lock() {
            cache.clear();
        }
    }

    fn read_account_summary(
        &self,
        query: &str,
        cancel: &AtomicBool,
    ) -> Result<(Value, Value), BackendError> {
        let (mut session, mut session_epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(|| {
                BackendError::new(crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::AuthenticationRequired,
                    crate::protocol::RecoveryAction::Login,
                ))
            })?;
        if !is_active_session(&session) {
            return Err(BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::AuthenticationRequired,
                crate::protocol::RecoveryAction::Login,
            )));
        }
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        let access_token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        // The stored answer to this exact read, if there is one. Offering its validator is what
        // lets an unchanged account cost one conditional request instead of a full aggregation.
        let cached = if account_id.is_empty() {
            None
        } else {
            self.state
                .account_read_cache(&account_id, query)
                .ok()
                .flatten()
        };
        let (next_etag, body) = self
            .client
            .account_summary(
                &access_token,
                query,
                cached.as_ref().map(|(etag, _)| etag.as_str()),
            )
            .map_err(|error| relay_backend_error(error, session_epoch))?;
        let summary = match body {
            Some(summary) => {
                validate_account_summary(&summary).map_err(|_| {
                    BackendError::new(crate::protocol::IpcError::new(
                        crate::protocol::ErrorCode::InvalidResponse,
                        crate::protocol::RecoveryAction::Retry,
                    ))
                })?;
                if !account_id.is_empty() {
                    let _ = self.state.commit_account_read(
                        &account_id,
                        query,
                        next_etag.as_deref(),
                        &summary,
                    );
                }
                summary
            }
            // 304. The server is asserting the stored body is still the answer, so this read
            // costs nothing and the previous account component value stands unchanged.
            None => match cached {
                Some((_, summary)) => summary,
                None => {
                    return Err(BackendError::new(crate::protocol::IpcError::new(
                        crate::protocol::ErrorCode::InvalidResponse,
                        crate::protocol::RecoveryAction::Retry,
                    )));
                }
            },
        };
        let refreshed_at = crate::state::now_rfc3339();
        session["last_refreshed_at"] = Value::String(refreshed_at.clone());
        // Bookkeeping must not advance epoch: a concurrent lane that still holds the epoch
        // it started with would otherwise treat this stamp as a session replacement.
        let _ = self.state.touch_session_last_refreshed_at(&refreshed_at);
        Ok((summary, session))
    }

    pub fn sync_control_and_update(&self) -> Result<Value, BackendError> {
        let (mut session, mut session_epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(BackendError::unavailable)?;
        if !is_active_session(&session) {
            return Err(session_changed_error());
        }
        let token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        let control = self
            .client
            .sync_control(&token)
            .map_err(|error| relay_backend_error(error, session_epoch))?;
        validate_control_response(&control).map_err(|_| {
            BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            ))
        })?;
        let object = control.as_object().ok_or_else(BackendError::unavailable)?;
        let expected_account = session.get("account_id").and_then(Value::as_str);
        let expected_device = session.get("device_id").and_then(Value::as_str);
        if object.get("account_id").and_then(Value::as_str) != expected_account
            || object.get("device_id").and_then(Value::as_str) != expected_device
        {
            return Err(BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidState,
                crate::protocol::RecoveryAction::Reinstall,
            )));
        }
        let profile_is_current = session
            .get("device_profile")
            .and_then(Value::as_object)
            .is_some_and(|profile| {
                profile.get("display_name").and_then(Value::as_str)
                    == Some(self.device_name.as_str())
                    && profile.get("platform").and_then(Value::as_str) == Some(self.platform)
            });
        if !profile_is_current {
            let response = self
                .client
                .update_device_profile(&token, &self.device_name, self.platform)
                .map_err(|error| relay_backend_error(error, session_epoch))?;
            validate_device_profile_response(&response, expected_device).map_err(|_| {
                BackendError::new(crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::InvalidResponse,
                    crate::protocol::RecoveryAction::Retry,
                ))
            })?;
            session["device_profile"] = serde_json::json!({
                "display_name": self.device_name,
                "platform": self.platform,
            });
        }
        if !self
            .state
            .active_session_at_epoch(session_epoch)
            .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        for (source, target) in [
            ("device_generation", "device_generation"),
            ("usage_sync_revision", "usage_sync_revision"),
            ("usage_deleted_before", "usage_deleted_before"),
        ] {
            if let Some(value) = object.get(source) {
                session[target] = value.clone();
            }
        }
        if self
            .state
            .write_session_json_if_epoch(&session, session_epoch)
            .map_err(|_| BackendError::unavailable())?
            .is_none()
        {
            return Err(session_changed_error());
        }
        Ok(control)
    }

    /// `republished` carries this device's earlier readings restated with the status its
    /// latest collection found. They ride the same envelope and the same provider gate as
    /// the report's own snapshots.
    pub(crate) fn upload_quota_report(
        &self,
        report: &Value,
        republished: &[Value],
    ) -> Result<(Option<Value>, usize), BackendError> {
        let (mut session, mut session_epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(BackendError::unavailable)?;
        if !is_active_session(&session) {
            return Err(session_changed_error());
        }
        let (_, snapshots, dropped) = snapshot_payload_from_quota_report(report, republished)?;
        if snapshots.is_empty() {
            return Ok((None, dropped));
        }
        let token = self.ensure_fresh_session(&mut session, &mut session_epoch)?;
        let expected_device_id = session
            .get("device_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let expected_generation = session
            .get("device_generation")
            .and_then(Value::as_u64)
            .ok_or_else(BackendError::unavailable)?;
        let envelope = snapshot_envelope(expected_generation, snapshots);
        let response = self
            .client
            .upload_snapshot(&token, &envelope)
            .map_err(|error| relay_backend_error(error, session_epoch))?;
        if response.get("device_id").and_then(Value::as_str) != Some(expected_device_id)
            || response.get("device_generation").and_then(Value::as_u64)
                != Some(expected_generation)
        {
            return Err(BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            )));
        }
        Ok((Some(response), dropped))
    }

    pub fn upload_usage(&self, submission: &Value) -> Result<Value, BackendError> {
        let (mut session, mut epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(session_changed_error)?;
        if !is_active_session(&session) {
            return Err(session_changed_error());
        }
        validate_usage_submission_session(&session, submission)?;
        let token = self.ensure_fresh_session(&mut session, &mut epoch)?;
        self.client
            .upload_usage(&token, submission)
            .map_err(|error| {
                if error.is_payload_refusal() {
                    BackendError::payload_refused()
                } else {
                    relay_backend_error(error, epoch)
                }
            })
    }

    /// The access token to use now, rotating the one session first if it is about to expire.
    pub(crate) fn ensure_fresh_session(
        &self,
        session: &mut Value,
        session_epoch: &mut u64,
    ) -> Result<String, BackendError> {
        if !access_token_needs_refresh(session) {
            return session_access_token_from(session);
        }
        let _guard = self
            .refresh_lock
            .lock()
            .map_err(|_| BackendError::unavailable())?;
        let (mut current, mut current_epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(session_changed_error)?;
        if !is_active_session(&current) {
            return Err(session_changed_error());
        }
        if !access_token_needs_refresh(&current) {
            *session = current;
            *session_epoch = current_epoch;
            return session_access_token_from(session);
        }
        refresh_session_family(&self.client, &mut current, current_epoch)?;
        // Persist the rotated family before issuing any subsequent network request. A
        // compare-and-swap refresh token is single-use on Relay, so a later failure must not
        // strand the newly issued token only in memory.
        current_epoch = self
            .state
            .write_session_json_if_epoch(&current, current_epoch)
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(session_changed_error)?;
        *session = current;
        *session_epoch = current_epoch;
        session_access_token_from(session)
    }

    fn complete_browser_exchange(
        &self,
        pending: PendingBrowserLogin,
        installation_id: &str,
        cancel: &AtomicBool,
    ) -> Result<Value, BackendError> {
        let callback = wait_for_callback(&pending.listener, &pending.state, cancel)?;
        let body = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "grant_type": "authorization_code",
            "client_id": "quotabar",
            "code": callback,
            "code_verifier": pending.verifier,
            "redirect_uri": pending.redirect_uri,
            "installation_id": installation_id,
            "device_display_name": self.device_name,
            "platform": self.platform
        });
        self.client
            .exchange_browser(&body)
            .map_err(|error| BackendError::new(relay_error_for_backend(error)))
    }
}

fn prepare_browser_login() -> Result<PendingBrowserLogin, BackendError> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| BackendError::unavailable())?;
    listener
        .set_nonblocking(true)
        .map_err(|_| BackendError::unavailable())?;
    let port = listener
        .local_addr()
        .map_err(|_| BackendError::unavailable())?
        .port();
    Ok(PendingBrowserLogin {
        listener,
        redirect_uri: format!("http://127.0.0.1:{port}/callback"),
        state: random_secret(32),
        verifier: random_secret(48),
    })
}

fn pending_authorize_url(pending: &PendingBrowserLogin) -> Result<String, BackendError> {
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(sha2::Sha256::digest(pending.verifier.as_bytes()));
    let mut authorize = Url::parse(&format!("{MANAGED_ORIGIN}/oauth/v2/authorize"))
        .map_err(|_| BackendError::unavailable())?;
    authorize
        .query_pairs_mut()
        .append_pair("client_id", "quotabar")
        .append_pair("response_type", "code")
        .append_pair("redirect_uri", &pending.redirect_uri)
        .append_pair("state", &pending.state)
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256");
    Ok(authorize.into())
}

fn current_platform() -> &'static str {
    std::env::consts::OS
}

fn session_changed_error() -> BackendError {
    BackendError::session_changed()
}

fn signed_out_error() -> BackendError {
    BackendError::new(crate::protocol::IpcError::new(
        crate::protocol::ErrorCode::AuthenticationRequired,
        crate::protocol::RecoveryAction::Login,
    ))
}

fn relay_backend_error(error: RelayError, observed_epoch: u64) -> BackendError {
    BackendError::relay_rejection(relay_error_for_backend(error), observed_epoch)
}

fn access_token_needs_refresh(session: &Value) -> bool {
    session
        .get("session")
        .and_then(Value::as_object)
        .and_then(|value| value.get("access_expires_at"))
        .and_then(Value::as_str)
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .is_none_or(|expires| {
            expires.with_timezone(&chrono::Utc)
                <= chrono::Utc::now() + chrono::Duration::seconds(60)
        })
}

fn snapshot_payload_from_quota_report<'a>(
    report: &'a Value,
    republished: &[Value],
) -> Result<(&'a str, Vec<Value>, usize), BackendError> {
    let object = report.as_object().ok_or_else(BackendError::unavailable)?;
    let captured_at = object
        .get("captured_at")
        .and_then(Value::as_str)
        .ok_or_else(BackendError::unavailable)?;
    let results = object
        .get("results")
        .and_then(Value::as_array)
        .ok_or_else(BackendError::unavailable)?;
    let collected = results
        .iter()
        .map(|result| {
            result
                .get("snapshots")
                .and_then(Value::as_array)
                .ok_or_else(BackendError::unavailable)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mut snapshots = Vec::new();
    let mut dropped = 0usize;
    for snapshot in collected.into_iter().flatten().chain(republished) {
        let Some(provider) = snapshot
            .get("provider")
            .and_then(Value::as_str)
            .and_then(crate::catalog::ProviderId::parse)
        else {
            dropped += 1;
            continue;
        };
        if !provider.syncs_to_account() {
            continue;
        }
        if !snapshot_is_admissible(snapshot) {
            dropped += 1;
            continue;
        }
        snapshots.push(snapshot.clone());
    }
    Ok((captured_at, snapshots, dropped))
}

/// Value bounds a producer type cannot state. A snapshot that fails is dropped alone;
/// refusing the envelope would discard every reading beside it (ADR 0028).
fn snapshot_is_admissible(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    if !object
        .get("observed_at")
        .and_then(Value::as_str)
        .is_some_and(valid_rfc3339)
    {
        return false;
    }
    let Some(account) = object.get("account") else {
        return false;
    };
    if !quota_account_is_admissible(account) {
        return false;
    }
    let Some(windows) = object
        .get("windows")
        .and_then(Value::as_array)
        .filter(|windows| windows.len() <= 16)
    else {
        return false;
    };
    windows.iter().all(quota_window_is_admissible)
}

fn quota_account_is_admissible(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    object
        .get("fingerprint")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        && !object.get("label").is_some_and(|value| {
            !value
                .as_str()
                .is_some_and(|value| valid_display(value, 128))
        })
        && !object
            .get("plan")
            .is_some_and(|value| !value.as_str().is_some_and(|value| valid_display(value, 64)))
}

fn quota_window_is_admissible(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let used_percent = object.get("used_percent").and_then(Value::as_f64);
    object
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(|value| valid_dimension(value, 64))
        && object
            .get("title")
            .and_then(Value::as_str)
            .is_some_and(|value| valid_display(value, 128))
        && used_percent.is_some_and(|value| value.is_finite() && (0.0..=100.0).contains(&value))
        && !object
            .get("resets_at")
            .is_some_and(|value| !value.as_str().is_some_and(valid_rfc3339))
        && !object
            .get("duration_seconds")
            .is_some_and(|value| safe_u64(value).is_none())
        && !object
            .get("remaining_value")
            .is_some_and(|value| !value.as_f64().is_some_and(f64::is_finite))
        && !object.get("limit_value").is_some_and(|value| {
            !value
                .as_f64()
                .is_some_and(|number| number.is_finite() && number >= 0.0)
        })
}

/// This device's readings, in the shape Relay accepts.
///
/// The device token names the device, so the envelope restates neither an id a caller could
/// get wrong nor a sequence Relay would have to keep for it: an hour is replaced by the
/// version of the scan behind it, and there is no counter to agree on.
pub(crate) fn snapshot_envelope(generation: u64, snapshots: Vec<Value>) -> Value {
    serde_json::json!({
        "protocol_version": MANAGED_DATA_PROTOCOL,
        "generation": generation,
        "snapshots": snapshots
    })
}

/// The upload names the generation it was staged for. A device token names the device, so a
/// generation that has moved on since means this payload belongs to a session that is gone.
fn validate_usage_submission_session(
    session: &Value,
    submission: &Value,
) -> Result<(), BackendError> {
    if session.get("device_generation").and_then(Value::as_u64)
        != submission.get("generation").and_then(Value::as_u64)
    {
        return Err(session_changed_error());
    }
    Ok(())
}

fn session_access_token_from(session: &Value) -> Result<String, BackendError> {
    session
        .get("session")
        .and_then(Value::as_object)
        .and_then(|value| value.get("access_token"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(BackendError::unavailable)
}

fn pending_session_from_active(session: &Value) -> Option<Value> {
    let object = session.as_object()?;
    let account_id = object.get("account_id").and_then(Value::as_str)?;
    let device_id = object.get("device_id").and_then(Value::as_str)?;
    let refresh_token = object
        .get("session")
        .and_then(Value::as_object)
        .and_then(|value| value.get("refresh_token"))
        .and_then(Value::as_str)?;
    Some(serde_json::json!({
        "schema_version": 1,
        "status": "logout_pending",
        "account_id": account_id,
        "device_id": device_id,
        "refresh_token": refresh_token
    }))
}

fn refresh_session_family(
    client: &RelayClient,
    session: &mut Value,
    session_epoch: u64,
) -> Result<(), BackendError> {
    let refresh_token = session
        .get("session")
        .and_then(Value::as_object)
        .and_then(|value| value.get("refresh_token"))
        .and_then(Value::as_str)
        .ok_or_else(BackendError::unavailable)?;
    let response = client
        .refresh_session(&serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "grant_type": "refresh_token",
            "client_id": "quotabar",
            "refresh_token": refresh_token
        }))
        .map_err(|error| relay_backend_error(error, session_epoch))?;
    validate_session_refresh_response(&response, session)?;
    let token = response
        .get("session")
        .ok_or_else(BackendError::unavailable)?;
    validate_session_token(token).map_err(|_| BackendError::unavailable())?;
    session["session"] = token.clone();
    Ok(())
}

fn session_from_token_response(response: &Value) -> Result<Value, RelayError> {
    let object = response.as_object().ok_or(RelayError::InvalidResponse)?;
    require_response_fields(
        response,
        &[
            "protocol_version",
            "token_type",
            "account_id",
            "device_id",
            "device_generation",
            "usage_deleted_before",
            "usage_sync_revision",
            "session",
        ],
    )?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(CONTROL_PROTOCOL)
        || object.get("token_type").and_then(Value::as_str) != Some("Bearer")
    {
        return Err(RelayError::InvalidResponse);
    }
    let account_id = object
        .get("account_id")
        .and_then(Value::as_str)
        .filter(|value| is_opaque(value))
        .ok_or(RelayError::InvalidResponse)?;
    let device_id = object
        .get("device_id")
        .and_then(Value::as_str)
        .filter(|value| is_opaque(value))
        .ok_or(RelayError::InvalidResponse)?;
    let generation = object
        .get("device_generation")
        .and_then(safe_positive_u64)
        .ok_or(RelayError::InvalidResponse)?;
    let usage_sync_revision = object
        .get("usage_sync_revision")
        .and_then(safe_u64)
        .ok_or(RelayError::InvalidResponse)?;
    let usage_deleted_before = object
        .get("usage_deleted_before")
        .filter(|value| value.is_null() || value.as_str().is_some_and(valid_rfc3339))
        .cloned()
        .ok_or(RelayError::InvalidResponse)?;
    let issued = object.get("session").ok_or(RelayError::InvalidResponse)?;
    validate_session_token(issued)?;
    Ok(serde_json::json!({
        "schema_version": 1,
        "status": "active",
        "account_id": account_id,
        "display_label": account_display_label(object.get("display_label")),
        "device_id": device_id,
        "device_generation": generation,
        "usage_sync_revision": usage_sync_revision,
        "usage_deleted_before": usage_deleted_before,
        "session": {
            "access_token": issued["access_token"],
            "access_expires_at": issued["access_expires_at"],
            "refresh_token": issued["refresh_token"],
            "refresh_expires_at": issued["refresh_expires_at"]
        }
    }))
}

/// The Account's name as a payload states it, or nothing.
///
/// A read tolerates a field this build has not been told about and a value it cannot use, so an
/// absent, null, blank, or over-long label is simply no name rather than a refused sign-in
/// ([ADR 0023](../../../docs/decisions/0023-strict-writes-tolerant-reads.md)).
fn account_display_label(value: Option<&Value>) -> Option<String> {
    let label = value?.as_str()?.trim();
    (!label.is_empty() && label.chars().count() <= 128).then(|| label.to_owned())
}

fn validate_session_token(value: &Value) -> Result<(), RelayError> {
    require_response_fields(
        value,
        &[
            "access_token",
            "access_expires_at",
            "refresh_token",
            "refresh_expires_at",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    for key in [
        "access_token",
        "refresh_token",
        "access_expires_at",
        "refresh_expires_at",
    ] {
        let valid = object
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|value| {
                if matches!(key, "access_expires_at" | "refresh_expires_at") {
                    valid_rfc3339(value)
                } else {
                    value.len() >= 16 && value.len() <= 2_048
                }
            });
        if !valid {
            return Err(RelayError::InvalidResponse);
        }
    }
    Ok(())
}

fn wait_for_callback(
    listener: &TcpListener,
    expected_state: &str,
    cancel: &AtomicBool,
) -> Result<String, BackendError> {
    let deadline = Instant::now() + Duration::from_secs(600);
    loop {
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        if Instant::now() >= deadline {
            return Err(BackendError::new(crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::Unavailable,
                crate::protocol::RecoveryAction::Retry,
            )));
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                if let Some(code) = parse_callback(&mut stream, expected_state) {
                    let _ = stream.write_all(BROWSER_CALLBACK_SUCCESS_RESPONSE);
                    return Ok(code);
                }
                let _ = stream.write_all(
                    b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nQuota login callback rejected.",
                );
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(_) => return Err(BackendError::unavailable()),
        }
    }
}

const BROWSER_CALLBACK_SUCCESS_RESPONSE: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'\r\nConnection: close\r\n\r\n<!doctype html><meta charset=utf-8><title>Quota</title><p>Quota login complete. You can close this window.</p><script>history.replaceState(null,'','/callback');window.close()</script>";

fn parse_callback(stream: &mut TcpStream, expected_state: &str) -> Option<String> {
    // The listener polls without blocking, and on macOS a connection it accepts inherits that
    // flag (Linux clears it in `accept4`). Read timeouts do nothing on a non-blocking socket, so
    // a browser whose request lands a moment after the handshake would be answered 400 before it
    // had said anything. The one request this socket carries is read blocking, under a deadline.
    stream.set_nonblocking(false).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    let mut buffer = Vec::with_capacity(1_024);
    let mut chunk = [0_u8; 1_024];
    loop {
        let count = stream.read(&mut chunk).ok()?;
        if count == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..count]);
        if buffer.len() > 8_192 {
            return None;
        }
        if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    let line = std::str::from_utf8(&buffer).ok()?.lines().next()?;
    let mut parts = line.split_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let target = parts.next()?;
    let url = Url::parse(&format!("http://127.0.0.1{target}")).ok()?;
    if url.path() != "/callback" || url.host_str()? != "127.0.0.1" {
        return None;
    }
    let query: Vec<(String, String)> = url.query_pairs().into_owned().collect();
    if query.len() != 2 || query.iter().filter(|(key, _)| key == "state").count() != 1 {
        return None;
    }
    let state = query.iter().find(|(key, _)| key == "state")?.1.as_str();
    if state != expected_state {
        return None;
    }
    let code = query.iter().find(|(key, _)| key == "code")?.1.clone();
    if code.is_empty() || code.len() > 4_096 {
        return None;
    }
    Some(code)
}

pub(crate) fn relay_error_for_backend(error: RelayError) -> crate::protocol::IpcError {
    use crate::protocol::{ErrorCode, RecoveryAction};
    match error {
        RelayError::AuthenticationRequired => {
            crate::protocol::IpcError::new(ErrorCode::AuthenticationRequired, RecoveryAction::Login)
        }
        RelayError::Timeout | RelayError::Unavailable | RelayError::RedirectRefused => {
            crate::protocol::IpcError::new(ErrorCode::NetworkError, RecoveryAction::Retry)
        }
        RelayError::Cancelled => {
            crate::protocol::IpcError::new(ErrorCode::Cancelled, RecoveryAction::None)
        }
        RelayError::Rejected { code, status } => match code.as_str() {
            "invalid_grant" | "unauthorized" | "invalid_token" | "expired_token"
            | "access_denied" => crate::protocol::IpcError::new(
                ErrorCode::AuthenticationRequired,
                RecoveryAction::Login,
            ),
            "deleted" => {
                crate::protocol::IpcError::new(ErrorCode::DeviceDeleted, RecoveryAction::Login)
            }
            "stale_generation" => {
                crate::protocol::IpcError::new(ErrorCode::StaleGeneration, RecoveryAction::Login)
            }
            "invalid_request" | "invalid_response" => {
                crate::protocol::IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry)
            }
            // Relay serves one set of contracts and answers anything else under /api this way.
            // Retrying a route this deployment has retired never succeeds; updating does.
            "client_upgrade_required" => crate::protocol::IpcError::new(
                ErrorCode::ClientUpgradeRequired,
                RecoveryAction::Upgrade,
            ),
            _ if status == 429 || status >= 500 => {
                crate::protocol::IpcError::new(ErrorCode::NetworkError, RecoveryAction::Retry)
            }
            _ => crate::protocol::IpcError::new(ErrorCode::Unavailable, RecoveryAction::Retry),
        },
        RelayError::InvalidResponse | RelayError::ResponseTooLarge => {
            crate::protocol::IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry)
        }
    }
}

fn is_active_session(value: &Value) -> bool {
    value
        .get("status")
        .and_then(Value::as_str)
        .is_some_and(|status| status == "active")
}

fn is_opaque(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.len() <= 128
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

fn safe_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .filter(|number| *number <= MAXIMUM_SAFE_INTEGER)
}

fn safe_positive_u64(value: &Value) -> Option<u64> {
    safe_u64(value).filter(|number| *number > 0)
}

fn valid_rfc3339(value: &str) -> bool {
    value.len() <= 64 && chrono::DateTime::parse_from_rfc3339(value).is_ok()
}

fn valid_display(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && value.trim() == value
}

fn valid_model_text(value: &str) -> bool {
    !value.is_empty() && value.chars().count() <= 128 && !value.chars().any(char::is_control)
}

fn valid_dimension(value: &str, max: usize) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.len() <= max
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"._:+-".contains(&byte))
}

fn valid_decimal_integer(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && (value == "0"
            || (value
                .as_bytes()
                .first()
                .is_some_and(|byte| byte.is_ascii_digit() && *byte != b'0')
                && value.bytes().all(|byte| byte.is_ascii_digit())))
}

fn invalid_response_backend() -> BackendError {
    BackendError::new(crate::protocol::IpcError::new(
        crate::protocol::ErrorCode::InvalidResponse,
        crate::protocol::RecoveryAction::Retry,
    ))
}

fn validate_device_profile_response(
    value: &Value,
    expected_device_id: Option<&str>,
) -> Result<(), RelayError> {
    require_response_fields(value, &["protocol_version", "status", "device_id"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(CONTROL_PROTOCOL)
        || object.get("status").and_then(Value::as_str) != Some("updated")
        || object.get("device_id").and_then(Value::as_str) != expected_device_id
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

/// Host computer name for `device_display_name`. Never the product name unless no host name exists.
pub fn local_device_display_name(fallback: &str) -> String {
    resolve_device_display_name(
        [macos_computer_name(), env_hostname(), posix_hostname()],
        fallback,
    )
}

fn resolve_device_display_name(
    sources: impl IntoIterator<Item = Option<String>>,
    fallback: &str,
) -> String {
    sources
        .into_iter()
        .flatten()
        .chain(std::iter::once(fallback.to_owned()))
        .find_map(|value| cleaned_device_name(&value))
        .unwrap_or_else(|| "Quota".to_owned())
}

fn cleaned_device_name(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let cleaned: String = value
        .chars()
        .filter(|character| !character.is_control())
        .take(128)
        .collect();
    (!cleaned.is_empty()).then_some(cleaned)
}

fn sanitize_device_name(value: &str) -> String {
    cleaned_device_name(value).unwrap_or_else(|| "Quota".to_owned())
}

#[cfg(target_os = "macos")]
fn macos_computer_name() -> Option<String> {
    let output = Command::new("/usr/sbin/scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()?;
    output.status.success().then_some(())?;
    String::from_utf8(output.stdout).ok()
}

#[cfg(not(target_os = "macos"))]
fn macos_computer_name() -> Option<String> {
    None
}

fn env_hostname() -> Option<String> {
    std::env::var("HOSTNAME").ok()
}

fn posix_hostname() -> Option<String> {
    let mut buffer = [0_u8; 256];
    let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if result != 0 {
        return None;
    }
    let end = buffer
        .iter()
        .position(|&byte| byte == 0)
        .unwrap_or(buffer.len());
    let name = std::str::from_utf8(&buffer[..end]).ok()?;
    Some(name.trim_end_matches(".local").to_owned())
}

fn random_secret(bytes: usize) -> String {
    use rand::RngCore;
    let mut value = vec![0_u8; bytes];
    rand::thread_rng().fill_bytes(&mut value);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use uuid::Uuid;

    #[test]
    fn relay_auth_rejections_preserve_disconnect_reason() {
        for (code, expected) in [
            ("deleted", crate::protocol::ErrorCode::DeviceDeleted),
            (
                "stale_generation",
                crate::protocol::ErrorCode::StaleGeneration,
            ),
            (
                "invalid_token",
                crate::protocol::ErrorCode::AuthenticationRequired,
            ),
        ] {
            let error = relay_error_for_backend(RelayError::Rejected {
                code: code.to_owned(),
                status: 401,
            });
            assert_eq!(error.code, expected);
            assert_eq!(
                error.recovery_action,
                crate::protocol::RecoveryAction::Login
            );
        }
    }

    #[test]
    fn device_display_name_uses_first_usable_host_name() {
        assert_eq!(
            resolve_device_display_name(
                [Some("  Studio Mac\n".to_owned()), Some("host".to_owned())],
                "QuotaBar"
            ),
            "Studio Mac"
        );
        assert_eq!(
            resolve_device_display_name([Some(String::new()), None], "QuotaBar"),
            "QuotaBar"
        );
        assert_eq!(
            resolve_device_display_name([Some("\u{0007}Kitchen Mac".to_owned())], "QuotaBar"),
            "Kitchen Mac"
        );
    }

    #[test]
    fn local_device_display_name_is_a_bounded_host_label() {
        let name = local_device_display_name("QuotaBar");
        assert!(!name.is_empty());
        assert!(name.len() <= 128);
        assert!(!name.chars().any(char::is_control));
    }

    #[test]
    fn device_profile_response_must_match_the_current_device() {
        let response = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "status": "updated",
            "device_id": "device_current"
        });
        assert!(validate_device_profile_response(&response, Some("device_current")).is_ok());
        assert!(validate_device_profile_response(&response, Some("device_other")).is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_prefers_computer_name_over_product_fallback() {
        let Some(computer_name) =
            macos_computer_name().and_then(|value| cleaned_device_name(&value))
        else {
            return;
        };
        assert_eq!(local_device_display_name("QuotaBar"), computer_name);
    }

    #[test]
    fn managed_origin_is_fixed() {
        assert!(RelayClient::new().is_ok());
        assert!(RelayClient::from_origin("https://example.invalid", false).is_err());
        assert!(RelayClient::for_test("http://127.0.0.1:8787").is_ok());
        assert!(RelayClient::for_test("http://10.0.0.1:8787").is_err());
    }

    #[test]
    fn usage_limits_are_enforced() {
        assert!(
            validate_usage_submission(&serde_json::json!({
                "protocol_version": MANAGED_DATA_PROTOCOL,
                "generation": 1,
                "agent": "codex",
                "hours": []
            }))
            .is_ok()
        );
        assert!(validate_usage_submission(&serde_json::json!({"protocol_version": 1})).is_err());

        let hour = |bucket_start_utc: &str| {
            serde_json::json!({
                "bucket_start_utc": bucket_start_utc,
                "scan_version": 1,
                "partial": false,
                "rows": [{
                    "agent": "codex",
                    "billing_channel": "openai_direct",
                    "channel_source": "agent_default",
                    "model": "unknown",
                    "context_bucket": "le_128k",
                    "service_tier": "unknown",
                    "speed": "unknown",
                    "inference_geo": "unknown",
                    "input_tokens": 10,
                    "cache_read_tokens": 0,
                    "cache_write_5m_tokens": 0,
                    "cache_write_1h_tokens": 0,
                    "cache_write_inferred_tokens": 0,
                    "output_tokens": 2,
                    "reasoning_tokens": 0,
                    "requests": 1,
                    "web_search_requests": 0,
                    "web_fetch_requests": 0,
                    "source_cost_covered_requests": 0
                }]
            })
        };
        // A model is provider-owned opaque text, and the literal "unknown" is a valid one.
        let mut upload = serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "generation": 1,
            "agent": "codex",
            "hours": [hour("2026-08-10T00:00:00Z")]
        });
        assert!(validate_usage_submission(&upload).is_ok());
        upload["note"] = serde_json::json!("ignored");
        assert!(validate_usage_submission(&upload).is_ok());
        upload.as_object_mut().expect("upload").remove("note");

        upload["hours"] = serde_json::json!(
            (0..=crate::usage::MAX_USAGE_HOURS_PER_UPLOAD)
                .map(|index| hour(
                    &chrono::DateTime::parse_from_rfc3339("2026-08-10T00:00:00Z")
                        .expect("base hour")
                        .checked_add_signed(chrono::Duration::hours(index as i64))
                        .expect("hour")
                        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
                ))
                .collect::<Vec<_>>()
        );
        assert!(validate_usage_submission(&upload).is_err());
    }

    /// Every hour an upload names comes back in exactly one list, and the two lists together
    /// are exactly what was sent.
    #[test]
    fn an_upload_response_answers_for_every_name_it_was_given() {
        let named = vec![
            "2026-08-10T00:00:00Z".to_owned(),
            "2026-08-10T01:00:00Z".to_owned(),
        ];
        let mut response = serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "device_id": "device_1",
            "device_generation": 1,
            "accepted": ["2026-08-10T00:00:00Z"],
            "ignored": ["2026-08-10T01:00:00Z"]
        });
        assert!(validate_upload_response(&response, &named).is_ok());

        // An hour in both lists, or one nobody asked about, is not an answer.
        response["ignored"] = serde_json::json!(["2026-08-10T00:00:00Z"]);
        assert!(validate_upload_response(&response, &named).is_err());
        response["ignored"] = serde_json::json!([]);
        assert!(validate_upload_response(&response, &named).is_err());
        response["ignored"] = serde_json::json!(["2026-08-10T02:00:00Z"]);
        assert!(validate_upload_response(&response, &named).is_err());
    }

    /// A truncation marker means one thing, so a payload that says otherwise is refused.
    #[test]
    fn report_truncation_markers_are_strict() {
        let mut cost = serde_json::json!({
            "mode": "reported",
            "basis": "reported",
            "status": "partial",
            "amount_microusd": "1",
            "catalog_revision": null,
            "calculated_rows": 0,
            "reported_rows": 1,
            "unpriced_rows": 2,
            "assumptions": [],
            "unpriced": [{
                "billing_channel": "openai_direct",
                "model": "model",
                "reason": "missing_rate",
                "rows": 1
            }],
            "unpriced_truncated": true
        });
        assert!(validate_usage_cost(&cost).is_ok());
        // A model is provider-owned opaque text.
        cost["unpriced"][0]["model"] = serde_json::json!("GPT-5.5[1m]");
        assert!(validate_usage_cost(&cost).is_ok());
        cost["unpriced"][0]["model"] = serde_json::json!("model\u{0001}");
        assert!(validate_usage_cost(&cost).is_err());
        cost["unpriced"][0]["model"] = serde_json::json!("model");
        cost["unpriced"][0]["rows"] = serde_json::json!(3);
        assert!(validate_usage_cost(&cost).is_err());
        cost["unpriced"][0]["rows"] = serde_json::json!(1);
        cost["unpriced_truncated"] = serde_json::json!(false);
        assert!(validate_usage_cost(&cost).is_err());
    }

    #[test]
    fn usage_cost_requires_consistent_basis_status_amount_and_assumptions() {
        let mut cost = serde_json::json!({
            "mode": "reported",
            "basis": "reported",
            "status": "partial",
            "amount_microusd": "1",
            "catalog_revision": null,
            "calculated_rows": 0,
            "reported_rows": 1,
            "unpriced_rows": 1,
            "assumptions": [],
            "unpriced": [{
                "billing_channel": "openai_direct",
                "model": "model",
                "reason": "missing_rate",
                "rows": 1
            }]
        });
        assert!(validate_usage_cost(&cost).is_ok());
        cost["basis"] = serde_json::json!("none");
        assert!(validate_usage_cost(&cost).is_err());
        cost["basis"] = serde_json::json!("reported");
        cost["amount_microusd"] = serde_json::Value::Null;
        assert!(validate_usage_cost(&cost).is_err());
        cost["amount_microusd"] = serde_json::json!("1");
        cost["assumptions"] = serde_json::json!(["source_reported", "source_reported"]);
        assert!(validate_usage_cost(&cost).is_err());
    }

    #[test]
    fn an_upload_must_name_the_generation_the_session_was_opened_at() {
        let session = serde_json::json!({"device_id": "device_1", "device_generation": 2});
        assert!(
            validate_usage_submission_session(&session, &serde_json::json!({"generation": 2}))
                .is_ok()
        );
        let mismatch =
            validate_usage_submission_session(&session, &serde_json::json!({"generation": 3}))
                .expect_err("generation mismatch");
        assert_eq!(mismatch.error.code, crate::protocol::ErrorCode::Unavailable);
        assert!(mismatch.is_session_changed());
        assert!(!mismatch.error.code.requires_login());
    }

    #[test]
    fn snapshot_envelope_keeps_resource_and_generation_bounds() {
        let snapshot = valid_snapshot();
        let mut envelope = serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "generation": 1,
            "snapshots": [snapshot.clone()]
        });
        assert!(validate_snapshot_envelope(&envelope).is_ok());
        envelope["generation"] = serde_json::json!(0);
        assert!(validate_snapshot_envelope(&envelope).is_err());
        envelope["generation"] = serde_json::json!(1);
        // Extra keys are the types' and the boundary schema's concern, not a sending-side
        // allowlist (ADR 0028).
        envelope["device_id"] = serde_json::json!("device_1");
        assert!(validate_snapshot_envelope(&envelope).is_ok());
        envelope
            .as_object_mut()
            .expect("envelope")
            .remove("device_id");
        envelope["snapshots"] = serde_json::json!(vec![snapshot; 33]);
        assert!(validate_snapshot_envelope(&envelope).is_err());
    }

    #[test]
    fn token_and_utc_hour_validation_does_not_default_missing_or_unsafe_state() {
        let response = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "token_type": "Bearer",
            "account_id": "account_1",
            "device_id": "device_1",
            "device_generation": 1,
            "usage_deleted_before": null,
            "usage_sync_revision": 0,
            "session": valid_token()
        });
        assert!(session_from_token_response(&response).is_ok());
        // The exchange names the Account, and the session keeps that name so a device that
        // threw its cache away still says whose account it is signed in to.
        let mut named = response.clone();
        named["display_label"] = serde_json::json!("octocat");
        assert_eq!(
            session_from_token_response(&named).expect("named session")["display_label"],
            serde_json::json!("octocat")
        );
        // A read tolerates what it cannot use: no name is a session without one, not a refusal.
        for absent in [
            serde_json::Value::Null,
            serde_json::json!("   "),
            serde_json::json!("x".repeat(129)),
            serde_json::json!(7),
        ] {
            let mut unnamed = response.clone();
            unnamed["display_label"] = absent;
            assert!(
                session_from_token_response(&unnamed).expect("session")["display_label"].is_null()
            );
        }
        assert!(
            session_from_token_response(&response).expect("session")["display_label"].is_null()
        );
        let mut unsafe_response = response.clone();
        unsafe_response["usage_sync_revision"] = serde_json::json!(9_007_199_254_740_992u64);
        assert!(session_from_token_response(&unsafe_response).is_err());
        let mut invalid_expiry = response;
        invalid_expiry["session"]["access_expires_at"] = serde_json::json!("tomorrow");
        assert!(session_from_token_response(&invalid_expiry).is_err());
        assert!(parse_utc_hour_value("2026-08-10T00:00:00Z").is_ok());
        assert!(parse_utc_hour_value("2026-08-10T00:00:00+00:00").is_err());
        assert!(parse_utc_hour_value("2026-08-10T00:00:60Z").is_err());
    }

    #[test]
    fn begin_login_returns_an_authorize_url_and_does_not_open_a_browser() {
        let root = std::env::temp_dir().join(format!("quota-begin-login-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test("http://127.0.0.1:1").expect("client")),
            state.clone(),
            "Studio Mac".into(),
        );

        let url = manager.begin_login().expect("authorize url");
        assert!(url.contains("/oauth/v2/authorize"), "{url}");
        assert!(url.contains("client_id=quotabar"), "{url}");
        assert!(url.contains("code_challenge="), "{url}");
        assert!(
            url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A"),
            "{url}"
        );
        manager.abort_pending_login();

        drop(manager);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn a_cancelled_login_persists_only_a_revoke_record() {
        let root = std::env::temp_dir().join(format!("quota-login-cancel-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test("http://127.0.0.1:1").expect("client")),
            state.clone(),
            "Studio Mac".into(),
        );
        let response = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "token_type": "Bearer",
            "account_id": "account_1",
            "device_id": "device_1",
            "device_generation": 1,
            "usage_deleted_before": null,
            "usage_sync_revision": 0,
            "session": valid_token()
        });

        let error = manager
            .finalize_login_unless_cancelled(&response, &AtomicBool::new(true))
            .expect_err("cancelled login");
        assert_eq!(error.error.code, crate::protocol::ErrorCode::Cancelled);
        let session = state
            .session_json()
            .expect("session")
            .expect("revoke record");
        assert_eq!(
            session.get("status").and_then(Value::as_str),
            Some("logout_pending")
        );
        // The revoke record carries the one refresh token and nothing that could still be spent.
        assert!(session.get("session").is_none());
        assert!(
            session
                .get("refresh_token")
                .and_then(Value::as_str)
                .is_some()
        );

        drop(manager);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn quota_report_snapshot_extraction_is_strict() {
        let snapshot = valid_snapshot();
        let report = serde_json::json!({
            "captured_at": "2026-08-10T00:00:00Z",
            "results": [{"snapshots": [snapshot.clone()]}]
        });
        let (captured_at, snapshots, dropped) =
            snapshot_payload_from_quota_report(&report, &[]).expect("quota report");
        assert_eq!(captured_at, "2026-08-10T00:00:00Z");
        assert_eq!(snapshots, std::slice::from_ref(&snapshot));
        assert_eq!(dropped, 0);

        let mut cursor = snapshot.clone();
        cursor["provider"] = serde_json::json!("cursor");
        let (_, mixed, mixed_dropped) = snapshot_payload_from_quota_report(
            &serde_json::json!({
                "captured_at": "2026-08-10T00:00:00Z",
                "results": [{"snapshots": [snapshot.clone(), cursor.clone()]}]
            }),
            &[],
        )
        .expect("mixed local report");
        assert_eq!(mixed, [snapshot.clone(), cursor.clone()]);
        assert_eq!(mixed_dropped, 0);
        let (_, cursor_only, cursor_dropped) = snapshot_payload_from_quota_report(
            &serde_json::json!({
                "captured_at": "2026-08-10T00:00:00Z",
                "results": [{"snapshots": [cursor.clone()]}]
            }),
            &[],
        )
        .expect("cursor report");
        assert_eq!(cursor_only, [cursor.clone()]);
        assert_eq!(cursor_dropped, 0);
        let mut unknown = cursor.clone();
        unknown["provider"] = serde_json::json!("unknown-provider");
        let (_, none, unknown_dropped) = snapshot_payload_from_quota_report(
            &serde_json::json!({
                "captured_at": "2026-08-10T00:00:00Z",
                "results": [{"snapshots": [unknown]}]
            }),
            &[],
        )
        .expect("unknown provider is dropped, not an envelope error");
        assert!(none.is_empty());
        assert_eq!(unknown_dropped, 1);
        assert!(validate_quota_snapshot(&cursor).is_ok());

        assert!(
            snapshot_payload_from_quota_report(
                &serde_json::json!({
                    "captured_at": "2026-08-10T00:00:00Z",
                    "snapshots": []
                }),
                &[]
            )
            .is_err()
        );
        assert!(
            snapshot_payload_from_quota_report(
                &serde_json::json!({
                    "captured_at": "2026-08-10T00:00:00Z",
                    "results": [{}]
                }),
                &[]
            )
            .is_err()
        );
    }

    /// PR #72 added `primary_cadence` to the types and the schema but not the sent-side
    /// allowlist; the restatement then refused every current quota report. Staging keeps
    /// value bounds and lets the producer types name the keys (ADR 0028).
    #[test]
    fn a_window_with_primary_cadence_is_staged_and_would_be_sent() {
        let mut snapshot = valid_snapshot();
        snapshot["windows"] = serde_json::json!([{
            "id": "five_hour",
            "title": "5 Hours",
            "used_percent": 40.0,
            "primary_cadence": "five_hour"
        }]);
        let report = serde_json::json!({
            "captured_at": "2026-08-10T00:00:00Z",
            "results": [{"snapshots": [snapshot.clone()]}]
        });
        let (_, snapshots, dropped) =
            snapshot_payload_from_quota_report(&report, &[]).expect("staged");
        assert_eq!(dropped, 0);
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0]["windows"][0]["primary_cadence"], "five_hour");
        let envelope = snapshot_envelope(1, snapshots);
        assert!(validate_snapshot_envelope(&envelope).is_ok());
    }

    #[test]
    fn a_malformed_snapshot_is_dropped_alone() {
        let good = valid_snapshot();
        let mut bad = valid_snapshot();
        bad["windows"] = serde_json::json!([{
            "id": "weekly",
            "title": "Weekly",
            "used_percent": 101.0
        }]);
        let (_, snapshots, dropped) = snapshot_payload_from_quota_report(
            &serde_json::json!({
                "captured_at": "2026-08-10T00:00:00Z",
                "results": [{"snapshots": [good.clone(), bad]}]
            }),
            &[],
        )
        .expect("partial");
        assert_eq!(dropped, 1);
        assert_eq!(snapshots, [good]);
    }

    #[test]
    fn account_summary_nested_shape_is_checked() {
        let value = valid_summary(serde_json::json!([]));
        assert!(validate_account_summary(&value).is_ok(), "{value}");

        // A resolved subscription names its key, its reading, and every device behind it.
        let mut resolved = value.clone();
        resolved["subscriptions"] = serde_json::json!([{
            "key": "codex|fingerprint_1|global|",
            "provider": "codex",
            "snapshot": valid_snapshot(),
            "sources": [{"device_id": "device_1", "observed_at": "2026-08-10T00:00:00Z"}]
        }]);
        resolved["devices"] = serde_json::json!([{
            "id": "device_1",
            "display_name": "Studio",
            "platform": "macos",
            "last_seen_at": "2026-08-10T00:01:00Z",
            "last_observed_at": "2026-08-10T00:00:00Z"
        }]);
        assert!(validate_account_summary(&resolved).is_ok());
        resolved["subscriptions"][0]["sources"][0]["snapshot"] = valid_snapshot();
        assert!(validate_account_summary(&resolved).is_ok());
        resolved["subscriptions"][0]["sources"][0]["snapshot"] =
            serde_json::json!({"provider": "codex"});
        assert!(validate_account_summary(&resolved).is_err());
        resolved["subscriptions"][0]["sources"][0]["snapshot"] = valid_snapshot();
        resolved["subscriptions"][0]["sources"][0]["observed_at"] = serde_json::json!("tomorrow");
        assert!(validate_account_summary(&resolved).is_err());

        let mut structured = value.clone();
        let model = serde_json::json!({
            "model": "gpt-5.6-sol",
            "totals": {
                "total_tokens": 12,
                "input_tokens": 10,
                "output_tokens": 2,
                "cache_read_input_tokens": 0,
                "cache_write_input_tokens": 0,
                "reasoning_tokens": 0,
                "messages": 1
            },
            "cost": valid_cost()
        });
        structured["usage"]["today"]["agents"] = serde_json::json!([{
            "agent": "codex",
            "providers": [{"provider": "openai", "models": [model]}]
        }]);
        assert!(validate_account_summary(&structured).is_ok());
        structured["usage"]["today"]["agents"][0]["providers"][0]["models"][0]["totals"]["total_tokens"] =
            serde_json::json!(13);
        assert!(validate_account_summary(&structured).is_err());

        // A summary that still sends the observations Relay resolves is the retired contract.
        let mut retired = value.clone();
        retired
            .as_object_mut()
            .expect("summary")
            .remove("subscriptions");
        retired["quota"] = serde_json::json!([]);
        assert!(validate_account_summary(&retired).is_err());

        // A Relay newer than this build can name a field it does not read; the read stands.
        let mut extra = value;
        extra["account"]["unexpected"] = serde_json::json!(true);
        assert!(validate_account_summary(&extra).is_ok());
    }

    /// A read is never discarded over a member this build has not heard of. Every enum the wire
    /// defines today is accepted, and so is one that does not exist yet: a `moonshot` provider
    /// once failed every account read, and an unknown member is text to show, not a refusal.
    #[test]
    fn every_enum_member_the_wire_can_carry_is_accepted() {
        let totals = serde_json::json!({
            "total_tokens": 12,
            "input_tokens": 10,
            "output_tokens": 2,
            "cache_read_input_tokens": 0,
            "cache_write_input_tokens": 0,
            "reasoning_tokens": 0,
            "messages": 1
        });
        let providers = crate::usage::InferenceProvider::ALL
            .iter()
            .map(|provider| {
                serde_json::json!({
                    "provider": provider.as_str(),
                    "models": [{"model": "gpt-5.6-sol", "totals": totals, "cost": valid_cost()}]
                })
            })
            .collect::<Vec<_>>();
        let agents = crate::usage::UsageAgent::ALL
            .iter()
            .map(|agent| serde_json::json!({"agent": agent.as_str(), "providers": providers}))
            .collect::<Vec<_>>();
        let summary = valid_summary(serde_json::json!(agents));
        assert!(
            validate_account_summary(&summary).is_ok(),
            "{:?}",
            validate_account_summary(&summary)
        );

        let mut unknown = summary;
        unknown["usage"]["today"]["agents"][0]["providers"][0]["provider"] =
            serde_json::json!("not_a_provider");
        unknown["usage"]["today"]["agents"][0]["agent"] = serde_json::json!("an_agent_from_2027");
        assert!(validate_account_summary(&unknown).is_ok());

        // Shape is still shape: a member that is not bounded text is not a member.
        let mut malformed = unknown;
        malformed["usage"]["today"]["agents"][0]["agent"] = serde_json::json!(7);
        assert!(validate_account_summary(&malformed).is_err());
    }

    /// One contract: a rejected read is reported as the error it is, and the request carries
    /// no negotiation keys to drop.
    #[test]
    fn a_rejected_summary_is_an_error_rather_than_a_smaller_answer() {
        let (origin, server) = spawn_mock_server(vec![http_json(
            400,
            None,
            &serde_json::json!({"error": {"code": "invalid_request"}}),
        )]);
        let client = RelayClient::for_test(&origin).expect("test client");

        let result = client.account_summary("account-token", "tz=UTC", None);

        assert!(matches!(
            result,
            Err(RelayError::Rejected { status: 400, .. })
        ));
        let sent = server.join().expect("mock server");
        assert_eq!(sent.len(), 1, "{sent:?}");
        // One read, one contract: the calendar this device keeps and nothing to negotiate.
        assert!(
            sent[0].contains("/api/v6/account/summary?tz=UTC"),
            "{}",
            sent[0]
        );
        for retired in [
            "usage_agents=",
            "cost_mode=",
            "usage_channels=",
            "model_catalog=",
            "usage_clients=",
            "from=",
        ] {
            assert!(!sent[0].contains(retired), "{}", sent[0]);
        }
    }

    type WireValidator = fn(&Value) -> Result<(), RelayError>;

    /// The zod schema is the definition of write contracts. This module no longer restates
    /// their shape: an accepted payload must still pass the remaining Sent bounds, and the
    /// boundary schema answers refusals (ADR 0028). Read contracts still have two statements.
    #[test]
    fn wire_validation_matches_the_shared_conformance_fixture() {
        const FIXTURE: &str = include_str!("../../../protocol/fixtures/wire-conformance.json");
        let fixture: Value = serde_json::from_str(FIXTURE).expect("fixture");
        let contracts = fixture["contracts"].as_object().expect("contracts");
        let validators: [(&str, WireValidator); 3] = [
            ("quota_snapshot_envelope", validate_snapshot_envelope),
            ("account_summary", validate_account_summary),
            ("usage_submission", validate_usage_submission),
        ];
        // This service fetches GET /api/v6/account/usage/activity only for `detail=hours` so
        // Account Usage can draw a rhythm, and never fetches GET /api/v2/account. It has no
        // trust-boundary restatement of either read (ADR 0019). TypeScript answers both, and
        // Swift answers the activity one.
        const SKIPPED_CONTRACTS: &[&str] = &["account_usage_activity", "account_response"];
        let registered = validators.map(|(contract, _)| contract);
        for skipped in SKIPPED_CONTRACTS {
            assert!(
                contracts.contains_key(*skipped),
                "{skipped} is skipped but missing from the fixture"
            );
        }
        for contract in contracts.keys() {
            if SKIPPED_CONTRACTS.contains(&contract.as_str()) {
                continue;
            }
            assert!(
                registered.contains(&contract.as_str()),
                "{contract} has no validator registered here"
            );
        }
        for (contract, validate) in validators {
            let cases = contracts[contract].as_array().expect("cases");
            assert!(cases.len() > 1, "{contract}");
            for case in cases {
                let name = case["name"].as_str().expect("name");
                let accepted = case["accepted"].as_bool().expect("accepted");
                if contract == "account_summary" {
                    assert_eq!(
                        validate(&case["payload"]).is_ok(),
                        accepted,
                        "{contract}: {name}"
                    );
                    continue;
                }
                if accepted {
                    assert!(validate(&case["payload"]).is_ok(), "{contract}: {name}");
                }
            }
        }
    }

    /// The listener is non-blocking so the login loop can watch for cancellation, and macOS
    /// hands an accepted connection that same flag. The request usually arrives with the
    /// handshake, but a browser that sends it a beat later must still be read, not refused.
    #[test]
    fn a_callback_that_arrives_after_accept_is_still_read() {
        use std::io::Read as _;
        use std::net::{TcpListener, TcpStream};
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener
            .set_nonblocking(true)
            .expect("nonblocking listener");
        let address = listener.local_addr().expect("address");
        let browser = std::thread::spawn(move || {
            let mut socket = TcpStream::connect(address).expect("connect");
            std::thread::sleep(Duration::from_millis(300));
            socket
                .write_all(
                    b"GET /callback?code=abc123&state=expected HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
                )
                .expect("request");
            let mut reply = String::new();
            let _ = socket.read_to_string(&mut reply);
            reply
        });
        let (mut stream, _) = loop {
            match listener.accept() {
                Ok(accepted) => break accepted,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept: {error}"),
            }
        };
        let code = parse_callback(&mut stream, "expected");
        assert_eq!(code.as_deref(), Some("abc123"));
        stream
            .write_all(BROWSER_CALLBACK_SUCCESS_RESPONSE)
            .expect("reply");
        drop(stream);
        let reply = browser.join().expect("browser thread");
        assert!(reply.starts_with("HTTP/1.1 200 OK"), "{reply}");
    }

    #[test]
    fn browser_callback_success_page_closes_without_retaining_the_code() {
        let response = std::str::from_utf8(BROWSER_CALLBACK_SUCCESS_RESPONSE).expect("utf8");
        assert!(response.contains("Content-Type: text/html; charset=utf-8"));
        assert!(response.contains("history.replaceState(null,'','/callback')"));
        assert!(response.contains("window.close()"));
        assert!(!response.contains("code="));
    }

    #[test]
    fn an_unchanged_account_read_keeps_the_previous_summary() {
        let mut summary = valid_summary(serde_json::json!([]));
        summary["account"]["display_label"] = serde_json::json!("octocat");
        let settings = default_account_settings_document();
        let (origin, server) = spawn_mock_server(vec![
            http_json_with_etag(200, "\"stamp-one\"", &summary),
            http_json_with_etag(200, "\"0\"", &settings),
            http_not_modified("\"stamp-one\""),
            http_not_modified("\"0\""),
        ]);
        let root =
            std::env::temp_dir().join(format!("quota-account-etag-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        state
            .write_session_json(&serde_json::json!({
                "schema_version": 1,
                "status": "active",
                "account_id": "account_1",
                "device_id": "device_1",
                "device_generation": 1,
                "session": {
                    "access_token": "qb_access",
                    "access_expires_at": "2099-01-01T00:00:00Z",
                    "refresh_token": "qbr_refresh",
                    "refresh_expires_at": "2099-01-01T00:00:00Z"
                }
            }))
            .expect("session");
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("test client")),
            Arc::clone(&state),
            "Test Mac".to_owned(),
        );

        let cancel = AtomicBool::new(false);
        let (_, epoch_before) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session");
        let first = manager
            .refresh_account_state("UTC", &cancel)
            .expect("first account read");
        let second = manager
            .refresh_account_state("UTC", &cancel)
            .expect("conditional account read");
        assert_eq!(first, second);
        assert_eq!(second["account_summary"], summary);
        let (after, epoch_after) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session");
        assert_eq!(
            epoch_after, epoch_before,
            "bookkeeping must not rotate epoch"
        );
        assert!(
            after
                .get("last_refreshed_at")
                .and_then(Value::as_str)
                .is_some()
        );

        let sent = server.join().expect("mock server");
        assert_eq!(sent.len(), 4, "{sent:?}");
        assert!(
            sent[0].contains("GET /api/v6/account/summary"),
            "{}",
            sent[0]
        );
        assert!(
            sent[1].contains("GET /api/v2/account/settings"),
            "{}",
            sent[1]
        );
        assert!(!sent[0].to_ascii_lowercase().contains("if-none-match"));
        assert!(
            sent[2]
                .to_ascii_lowercase()
                .contains("if-none-match: \"stamp-one\""),
            "{}",
            sent[2]
        );
        assert!(
            sent[3]
                .to_ascii_lowercase()
                .contains("if-none-match: \"0\""),
            "{}",
            sent[3]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_epoch_conflict_on_bookkeeping_is_not_a_login_error() {
        let mut summary = valid_summary(serde_json::json!([]));
        summary["account"]["display_label"] = serde_json::json!("octocat");
        let arrived = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let (origin, server) = spawn_gated_mock(
            vec![
                http_json_with_etag(200, "\"stamp-one\"", &summary),
                http_json_with_etag(200, "\"0\"", &default_account_settings_document()),
            ],
            Duration::from_millis(150),
            arrived.clone(),
        );
        let root = std::env::temp_dir().join(format!("quota-bookkeeping-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        state
            .write_session_json(&fresh_session_json())
            .expect("session");
        let (_, epoch) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session");
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("test client")),
            Arc::clone(&state),
            "Test Mac".to_owned(),
        );
        let cancel = AtomicBool::new(false);
        let reader = thread::spawn(move || manager.refresh_account_state("UTC", &cancel));
        wait_gate(&arrived);
        state
            .write_session_json(&fresh_session_json())
            .expect("bump epoch");
        let result = reader.join().expect("reader");
        assert!(
            result.as_ref().ok().is_some()
                || result.as_ref().err().is_some_and(
                    |error| error.is_session_changed() && !error.error.code.requires_login()
                ),
            "{result:?}"
        );
        let (session, after) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session still installed");
        assert_ne!(after, epoch);
        assert_eq!(
            session.get("status").and_then(Value::as_str),
            Some("active")
        );
        let _ = server.join().expect("mock server");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_upload_succeeds_when_the_local_epoch_moves_after_relay_accepts() {
        let snapshot = valid_snapshot();
        let report = serde_json::json!({
            "captured_at": "2026-08-10T00:00:00Z",
            "results": [{"snapshots": [snapshot]}]
        });
        let response = serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "device_id": "device_1",
            "device_generation": 1,
            "accepted": ["codex"],
            "ignored": []
        });
        let arrived = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let (origin, server) = spawn_gated_mock(
            vec![http_json(200, None, &response)],
            Duration::from_millis(150),
            arrived.clone(),
        );
        let root =
            std::env::temp_dir().join(format!("quota-upload-epoch-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        state
            .write_session_json(&fresh_session_json())
            .expect("session");
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("test client")),
            Arc::clone(&state),
            "Test Mac".to_owned(),
        );
        let uploader = thread::spawn(move || manager.upload_quota_report(&report, &[]));
        wait_gate(&arrived);
        state
            .write_session_json(&fresh_session_json())
            .expect("bump epoch");
        let result = uploader.join().expect("uploader");
        assert!(result.is_ok(), "{result:?}");
        let _ = server.join().expect("mock server");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn concurrent_ensure_fresh_session_refreshes_once() {
        let stop = Arc::new(AtomicBool::new(false));
        let (origin, server) = spawn_looping_mock(token_refresh_http(), stop.clone());
        let root =
            std::env::temp_dir().join(format!("quota-refresh-once-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        let mut session = fresh_session_json();
        session["session"]["access_expires_at"] = serde_json::json!(
            chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
        );
        state.write_session_json(&session).expect("session");
        let manager = Arc::new(AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("test client")),
            Arc::clone(&state),
            "Test Mac".to_owned(),
        ));
        let (left_session, mut left_epoch) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session");
        let (right_session, mut right_epoch) = state
            .session_snapshot()
            .expect("snapshot")
            .expect("session");
        let left_manager = Arc::clone(&manager);
        let right_manager = Arc::clone(&manager);
        thread::scope(|scope| {
            scope.spawn(|| {
                let mut session = left_session;
                left_manager
                    .ensure_fresh_session(&mut session, &mut left_epoch)
                    .expect("left refresh");
            });
            scope.spawn(|| {
                let mut session = right_session;
                right_manager
                    .ensure_fresh_session(&mut session, &mut right_epoch)
                    .expect("right refresh");
            });
        });
        stop.store(true, Ordering::Release);
        let sent = server.join().expect("mock server");
        let refreshes = sent
            .iter()
            .filter(|head| head.starts_with("POST /oauth/v2/token"))
            .count();
        assert_eq!(refreshes, 1, "{sent:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    fn http_not_modified(etag: &str) -> String {
        format!("HTTP/1.1 304 Not Modified\r\nETag: {etag}\r\nConnection: close\r\n\r\n")
    }

    fn http_json_with_etag(status: u16, etag: &str, value: &Value) -> String {
        let body = serde_json::to_vec(value).expect("json");
        format!(
            "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nETag: {etag}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            String::from_utf8(body).expect("utf8")
        )
    }

    fn http_json(status: u16, retry_after: Option<u64>, value: &Value) -> String {
        let body = serde_json::to_vec(value).expect("json");
        let reason = match status {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            412 => "Precondition Failed",
            428 => "Precondition Required",
            _ => "Error",
        };
        let retry = retry_after
            .map(|value| format!("Retry-After: {value}\r\n"))
            .unwrap_or_default();
        format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{retry}Connection: close\r\n\r\n{}",
            body.len(),
            String::from_utf8(body).expect("utf8")
        )
    }

    /// Joining the handle yields each request's head, so a test can assert the query and the
    /// headers the client actually sent.
    fn spawn_mock_server(responses: Vec<String>) -> (String, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("mock listener");
        let address = listener.local_addr().expect("mock address");
        let server = thread::spawn(move || {
            let mut recorded = Vec::new();
            for response in responses {
                let (mut stream, _) = listener.accept().expect("mock request");
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .expect("mock timeout");
                let mut request = [0_u8; 8_192];
                let read = stream.read(&mut request).unwrap_or(0);
                recorded.push(String::from_utf8_lossy(&request[..read]).into_owned());
                stream
                    .write_all(response.as_bytes())
                    .expect("mock response");
            }
            recorded
        });
        (format!("http://{address}"), server)
    }

    fn wait_gate(arrived: &Arc<(Mutex<bool>, std::sync::Condvar)>) {
        let (lock, cond) = arrived.as_ref();
        let mut ready = lock.lock().expect("gate");
        let deadline = Instant::now() + Duration::from_secs(2);
        while !*ready {
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "mock never received a request");
            let (guard, _) = cond.wait_timeout(ready, remaining).expect("wait");
            ready = guard;
        }
    }

    fn spawn_gated_mock(
        responses: Vec<String>,
        delay: Duration,
        arrived: Arc<(Mutex<bool>, std::sync::Condvar)>,
    ) -> (String, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("mock listener");
        let address = listener.local_addr().expect("mock address");
        let server = thread::spawn(move || {
            let mut recorded = Vec::new();
            for response in responses {
                let (mut stream, _) = listener.accept().expect("mock request");
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .expect("mock timeout");
                let mut request = [0_u8; 8_192];
                let read = stream.read(&mut request).unwrap_or(0);
                recorded.push(String::from_utf8_lossy(&request[..read]).into_owned());
                {
                    let (lock, cond) = arrived.as_ref();
                    *lock.lock().expect("gate") = true;
                    cond.notify_all();
                }
                thread::sleep(delay);
                stream
                    .write_all(response.as_bytes())
                    .expect("mock response");
            }
            recorded
        });
        (format!("http://{address}"), server)
    }

    fn spawn_looping_mock(
        response: String,
        stop: Arc<AtomicBool>,
    ) -> (String, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("mock listener");
        listener.set_nonblocking(true).expect("nonblocking");
        let address = listener.local_addr().expect("mock address");
        let server = thread::spawn(move || {
            let mut recorded = Vec::new();
            while !stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).expect("blocking stream");
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .expect("mock timeout");
                        let mut request = [0_u8; 8_192];
                        let read = stream.read(&mut request).unwrap_or(0);
                        recorded.push(String::from_utf8_lossy(&request[..read]).into_owned());
                        thread::sleep(Duration::from_millis(80));
                        let _ = stream.write_all(response.as_bytes());
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
            recorded
        });
        (format!("http://{address}"), server)
    }

    fn fresh_session_json() -> Value {
        serde_json::json!({
            "schema_version": 1,
            "status": "active",
            "account_id": "account_1",
            "device_id": "device_1",
            "device_generation": 1,
            "usage_sync_revision": 0,
            "usage_deleted_before": null,
            "session": {
                "access_token": "qb_access_token_synthetic",
                "access_expires_at": "2099-01-01T00:00:00Z",
                "refresh_token": "qbr_refresh_token_synthetic",
                "refresh_expires_at": "2099-01-01T00:00:00Z"
            }
        })
    }

    fn token_refresh_http() -> String {
        http_json(
            200,
            None,
            &serde_json::json!({
                "protocol_version": CONTROL_PROTOCOL,
                "token_type": "Bearer",
                "account_id": "account_1",
                "device_id": "device_1",
                "device_generation": 1,
                "session": {
                    "access_token": "access_token_rotated_xx",
                    "access_expires_at": "2099-01-01T00:00:00Z",
                    "refresh_token": "refresh_token_rotated_xx",
                    "refresh_expires_at": "2099-11-10T01:00:00Z"
                }
            }),
        )
    }

    fn valid_snapshot() -> Value {
        serde_json::json!({
            "provider": "codex",
            "account": {"fingerprint": "fingerprint_1", "fingerprint_scope": "global"},
            "windows": [],
            "status": "available",
            "observed_at": "2026-08-10T00:00:00Z"
        })
    }

    fn valid_token() -> Value {
        serde_json::json!({
            "access_token": "access_token_synthetic",
            "access_expires_at": "2026-08-10T01:00:00Z",
            "refresh_token": "refresh_token_synthetic",
            "refresh_expires_at": "2026-11-10T01:00:00Z"
        })
    }

    fn valid_totals() -> Value {
        serde_json::json!({
            "total_tokens": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_input_tokens": 0,
            "cache_write_input_tokens": 0,
            "reasoning_tokens": 0,
            "messages": 0
        })
    }

    fn valid_period(agents: Value) -> Value {
        serde_json::json!({
            "totals": valid_totals(),
            "cost": valid_cost(),
            "partial": false,
            "agents": agents
        })
    }

    fn valid_usage(agents: Value) -> Value {
        serde_json::json!({
            "today": valid_period(agents.clone()),
            "last_7_days": valid_period(agents.clone()),
            "last_30_days": valid_period(agents.clone()),
            "all": valid_period(agents)
        })
    }

    fn valid_summary(agents: Value) -> Value {
        serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "account": {
                "account_id": "account_1",
                "display_label": null,
                "created_at": "2026-08-09T00:00:00Z"
            },
            "devices": [],
            "subscriptions": [],
            "usage": valid_usage(agents),
            "pricing_revision": "2026-08-01",
            "model_catalog_revision": "2026-08-01"
        })
    }

    fn valid_cost() -> Value {
        serde_json::json!({
            "mode": "calculate",
            "basis": "none",
            "status": "complete",
            "amount_microusd": null,
            "catalog_revision": null,
            "calculated_rows": 0,
            "reported_rows": 0,
            "unpriced_rows": 0,
            "assumptions": [],
            "unpriced": []
        })
    }

    fn valid_cache_saved() -> Value {
        serde_json::json!({
            "amount_microusd": "0",
            "status": "complete",
            "unpriced_rows": 0
        })
    }

    fn valid_account_usage_period(from: &str, to: &str, timezone: &str) -> Value {
        serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "request": { "from": from, "to": to, "timezone": timezone },
            "bounds": {
                "start": "2026-08-25T16:00:00Z",
                "end": "2026-08-26T16:00:00Z",
                "grid": USAGE_HOUR_GRID_RULE
            },
            "totals": valid_totals(),
            "cost": valid_cost(),
            "cache_saved": valid_cache_saved(),
            "days": [{
                "date": from,
                "totals": valid_totals(),
                "cost": valid_cost(),
                "partial": false
            }],
            "agents": [],
            "coverage": {
                "partial": false,
                "daily_retained_from": null,
                "hourly_retained_from": null,
                "truncated_by_retention": false
            },
            "revision": {
                "usage_revision": 1,
                "device_generation": 1,
                "account_updated_at": "2026-08-26T00:00:00Z",
                "pricing_revision": "2026-08-01",
                "model_catalog_revision": "2026-08-01",
                "fold_version": 1
            }
        })
    }

    #[test]
    fn account_usage_period_shape_is_checked() {
        let body = valid_account_usage_period("2026-08-26", "2026-08-26", "Asia/Singapore");
        assert!(
            validate_account_usage_period(&body, "2026-08-26", "2026-08-26", "Asia/Singapore")
                .is_ok()
        );
        let mut extra = body.clone();
        extra["unexpected"] = serde_json::json!(true);
        assert!(
            validate_account_usage_period(&extra, "2026-08-26", "2026-08-26", "Asia/Singapore")
                .is_ok()
        );
        let mut truncated = body.clone();
        truncated["coverage"]["truncated_by_retention"] = serde_json::json!(true);
        truncated["coverage"]["daily_retained_from"] = serde_json::json!("2026-07-01");
        assert!(
            validate_account_usage_period(&truncated, "2026-08-26", "2026-08-26", "Asia/Singapore")
                .is_ok()
        );
        let mut wrong_range = body.clone();
        wrong_range["request"]["from"] = serde_json::json!("2026-08-01");
        assert!(
            validate_account_usage_period(
                &wrong_range,
                "2026-08-26",
                "2026-08-26",
                "Asia/Singapore"
            )
            .is_err()
        );
        let mut inverted_days = body;
        inverted_days["days"] = serde_json::json!([
            {
                "date": "2026-08-26",
                "totals": valid_totals(),
                "cost": valid_cost(),
                "partial": false
            },
            {
                "date": "2026-08-25",
                "totals": valid_totals(),
                "cost": valid_cost(),
                "partial": false
            }
        ]);
        assert!(
            validate_account_usage_period(
                &inverted_days,
                "2026-08-26",
                "2026-08-26",
                "Asia/Singapore"
            )
            .is_err()
        );
    }

    #[test]
    fn account_usage_period_encodes_timezone_and_returns_body_or_304() {
        let body = valid_account_usage_period("2026-08-26", "2026-08-26", "Asia/Singapore");
        let (origin, server) = spawn_mock_server(vec![
            http_json_with_etag(200, "\"period-one\"", &body),
            http_not_modified("\"period-one\""),
            http_json(
                400,
                None,
                &serde_json::json!({"error": {"code": "invalid_request"}}),
            ),
        ]);
        let client = RelayClient::for_test(&origin).expect("test client");

        let (etag, first) = client
            .account_usage_period(
                "2026-08-26",
                "2026-08-26",
                "Asia/Singapore",
                true,
                "account-token",
                None,
            )
            .expect("first period");
        assert_eq!(etag.as_deref(), Some("\"period-one\""));
        assert_eq!(first.as_ref(), Some(&body));

        let (_, second) = client
            .account_usage_period(
                "2026-08-26",
                "2026-08-26",
                "Asia/Singapore",
                true,
                "account-token",
                Some("\"period-one\""),
            )
            .expect("304");
        assert!(second.is_none());

        let refused = client.account_usage_period(
            "2026-08-26",
            "2026-08-26",
            "Asia/Singapore",
            true,
            "account-token",
            None,
        );
        assert!(matches!(
            refused,
            Err(RelayError::Rejected { status: 400, .. })
        ));

        let sent = server.join().expect("mock server");
        assert_eq!(sent.len(), 3, "{sent:?}");
        assert!(
            sent[0].contains(
                "/api/v6/account/usage/period?from=2026-08-26&to=2026-08-26&timezone=Asia%2FSingapore&breakdown=1"
            ),
            "{}",
            sent[0]
        );
        assert!(
            sent[1]
                .to_ascii_lowercase()
                .contains("if-none-match: \"period-one\""),
            "{}",
            sent[1]
        );
    }

    #[test]
    fn account_usage_period_without_a_session_is_the_typed_refusal() {
        let (origin, server) = spawn_mock_server(vec![]);
        let root = std::env::temp_dir().join(format!(
            "quota-account-period-signed-out-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("test client")),
            state,
            "Test Mac".to_owned(),
        );
        let cancel = AtomicBool::new(false);
        let error = manager
            .account_usage_period("2026-08-26", "2026-08-26", "UTC", true, &cancel)
            .expect_err("signed out");
        assert_eq!(
            error.error.code,
            crate::protocol::ErrorCode::AuthenticationRequired
        );
        drop(server);
    }

    #[test]
    fn an_unchanged_account_period_keeps_the_cached_body() {
        let body = valid_account_usage_period("2026-08-01", "2026-08-03", "UTC");
        let (origin, server) = spawn_mock_server(vec![
            http_json_with_etag(200, "\"period-one\"", &body),
            http_not_modified("\"period-one\""),
        ]);
        let root = std::env::temp_dir().join(format!(
            "quota-account-period-etag-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        state
            .write_session_json(&serde_json::json!({
                "schema_version": 1,
                "status": "active",
                "account_id": "account_1",
                "device_id": "device_1",
                "device_generation": 1,
                "session": {
                    "access_token": "qb_access",
                    "access_expires_at": "2099-01-01T00:00:00Z",
                    "refresh_token": "qbr_refresh",
                    "refresh_expires_at": "2099-01-01T00:00:00Z"
                }
            }))
            .expect("session");
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("test client")),
            Arc::clone(&state),
            "Test Mac".to_owned(),
        );
        let cancel = AtomicBool::new(false);
        let first = manager
            .account_usage_period("2026-08-01", "2026-08-03", "UTC", true, &cancel)
            .expect("first");
        let second = manager
            .account_usage_period("2026-08-01", "2026-08-03", "UTC", true, &cancel)
            .expect("304");
        assert_eq!(first, second);
        assert_eq!(first["coverage"]["truncated_by_retention"], false);
        let sent = server.join().expect("mock server");
        assert_eq!(sent.len(), 2, "{sent:?}");
        assert!(!sent[0].to_ascii_lowercase().contains("if-none-match"));
        assert!(
            sent[1]
                .to_ascii_lowercase()
                .contains("if-none-match: \"period-one\""),
            "{}",
            sent[1]
        );
    }

    fn valid_account_settings_document() -> Value {
        serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "revision": 1,
            "updated_at": "2026-09-21T10:00:00Z",
            "alerts": {
                "reset_reminders": true,
                "pace_alerts": true,
                "thresholds": { "a1b2c3d4e5f6": [20, 10] }
            },
            "budget": { "amount_usd": "250.00", "alerts": true }
        })
    }

    fn default_account_settings_document() -> Value {
        serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "revision": 0,
            "updated_at": "1970-01-01T00:00:00Z",
            "alerts": {
                "reset_reminders": true,
                "pace_alerts": true,
                "thresholds": {}
            },
            "budget": { "amount_usd": null, "alerts": true }
        })
    }

    fn signed_in_manager(origin: &str, root: &std::path::Path) -> Arc<AccountManager> {
        std::fs::create_dir_all(root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(root).expect("state"));
        state
            .write_session_json(&fresh_session_json())
            .expect("session");
        Arc::new(AccountManager::new(
            Arc::new(RelayClient::for_test(origin).expect("test client")),
            state,
            "Test Mac".to_owned(),
        ))
    }

    #[test]
    fn account_settings_shape_is_checked() {
        let body = valid_account_settings_document();
        assert!(validate_account_settings(&body).is_ok());
        let mut extra = body.clone();
        extra["future"] = serde_json::json!(true);
        extra["alerts"]["future"] = serde_json::json!(false);
        assert!(validate_account_settings(&extra).is_ok());
        let mut missing = body.clone();
        missing.as_object_mut().expect("object").remove("budget");
        assert!(validate_account_settings(&missing).is_err());
        let mut unsorted = body.clone();
        unsorted["alerts"]["thresholds"]["a1b2c3d4e5f6"] = serde_json::json!([10, 20]);
        assert!(validate_account_settings(&unsorted).is_err());
        let mut amount = body;
        amount["budget"]["amount_usd"] = serde_json::json!("0");
        assert!(validate_account_settings(&amount).is_err());
    }

    #[test]
    fn account_settings_get_returns_body_304_and_412_put_body() {
        let written = valid_account_settings_document();
        let defaults = default_account_settings_document();
        let (origin, server) = spawn_mock_server(vec![
            http_json_with_etag(200, "\"0\"", &defaults),
            http_not_modified("\"0\""),
            http_json_with_etag(200, "\"1\"", &written),
            http_json_with_etag(412, "\"1\"", &written),
            http_json(
                428,
                None,
                &serde_json::json!({
                    "error": { "code": "precondition_required", "message": "If-Match is required." }
                }),
            ),
            "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .to_owned(),
        ]);
        let client = RelayClient::for_test(&origin).expect("test client");

        let (etag, first) = client
            .account_settings("account-token", None)
            .expect("first get");
        assert_eq!(etag.as_deref(), Some("\"0\""));
        assert_eq!(first.as_ref(), Some(&defaults));

        let (_, not_modified) = client
            .account_settings("account-token", Some("\"0\""))
            .expect("304");
        assert!(not_modified.is_none());

        let put_body = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "alerts": written["alerts"],
            "budget": written["budget"]
        });
        let wrote = client
            .put_account_settings("account-token", &put_body, "\"0\"")
            .expect("put");
        assert!(matches!(
            wrote,
            AccountSettingsWrite::Written { ref document, .. } if document == &written
        ));

        let conflict = client
            .put_account_settings("account-token", &put_body, "\"0\"")
            .expect("412");
        assert!(matches!(
            conflict,
            AccountSettingsWrite::Conflict { ref document, .. } if document == &written
        ));

        let missing = client.put_account_settings("account-token", &put_body, "\"0\"");
        assert!(matches!(
            missing,
            Err(RelayError::Rejected {
                status: 428,
                code
            }) if code == "precondition_required"
        ));

        let unauthorized = client.account_settings("account-token", None);
        assert!(matches!(
            unauthorized,
            Err(RelayError::AuthenticationRequired)
        ));

        let sent = server.join().expect("mock server");
        assert_eq!(sent.len(), 6, "{sent:?}");
        assert!(
            sent[0].contains("GET /api/v2/account/settings"),
            "{}",
            sent[0]
        );
        assert!(
            sent[1]
                .to_ascii_lowercase()
                .contains("if-none-match: \"0\""),
            "{}",
            sent[1]
        );
        assert!(
            sent[2].contains("PUT /api/v2/account/settings"),
            "{}",
            sent[2]
        );
        assert!(
            sent[2].to_ascii_lowercase().contains("if-match: \"0\""),
            "{}",
            sent[2]
        );
    }

    #[test]
    fn account_settings_poll_uses_cached_etag_and_401_refreshes_the_session() {
        let defaults = default_account_settings_document();
        let written = valid_account_settings_document();
        let (origin, server) = spawn_mock_server(vec![
            http_json_with_etag(200, "\"0\"", &defaults),
            http_not_modified("\"0\""),
            token_refresh_http(),
            http_json_with_etag(200, "\"1\"", &written),
        ]);
        let root = std::env::temp_dir().join(format!(
            "quota-account-settings-poll-{}",
            uuid::Uuid::new_v4()
        ));
        let manager = signed_in_manager(&origin, &root);
        let cancel = AtomicBool::new(false);
        manager
            .fetch_account_settings(&cancel, false)
            .expect("first");
        manager.fetch_account_settings(&cancel, false).expect("304");
        let cached = manager
            .state
            .account_settings_cache("account_1")
            .expect("cache")
            .expect("present");
        assert_eq!(cached.etag, "\"0\"");
        assert_eq!(cached.state.revision, 0);

        let mut session = manager.state.session_json().expect("session").expect("row");
        session["session"]["access_expires_at"] = serde_json::json!(
            chrono::Utc::now()
                .checked_add_signed(chrono::Duration::seconds(30))
                .expect("expiry")
                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
        );
        manager
            .state
            .write_session_json(&session)
            .expect("near expiry");
        manager
            .fetch_account_settings(&cancel, true)
            .expect("refresh then get");
        let after = manager
            .state
            .account_settings_cache("account_1")
            .expect("cache")
            .expect("updated");
        assert_eq!(after.state.revision, 1);
        let session = manager.state.session_json().expect("session").expect("row");
        assert_eq!(
            session["session"]["access_token"],
            "access_token_rotated_xx"
        );

        let sent = server.join().expect("mock server");
        assert_eq!(sent.len(), 4, "{sent:?}");
        assert!(
            sent[1]
                .to_ascii_lowercase()
                .contains("if-none-match: \"0\""),
            "{}",
            sent[1]
        );
        assert!(sent[2].starts_with("POST /oauth/v2/token"), "{}", sent[2]);
        assert!(
            sent[3].contains("GET /api/v2/account/settings"),
            "{}",
            sent[3]
        );
        assert!(
            !sent[3].to_ascii_lowercase().contains("if-none-match"),
            "{}",
            sent[3]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn account_settings_without_a_session_is_the_typed_refusal() {
        let (origin, server) = spawn_mock_server(vec![]);
        let root = std::env::temp_dir().join(format!(
            "quota-account-settings-signed-out-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("test client")),
            state,
            "Test Mac".to_owned(),
        );
        let manager = Arc::new(manager);
        let cancel = AtomicBool::new(false);
        let error = manager
            .refresh_account_settings(&cancel)
            .expect_err("signed out");
        assert_eq!(
            error.error.code,
            crate::protocol::ErrorCode::AuthenticationRequired
        );
        drop(server);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn account_settings_put_names_history_only_when_the_write_does() {
        let alerts = serde_json::json!({
            "reset_reminders": true,
            "pace_alerts": false,
            "thresholds": {}
        });
        let budget = serde_json::json!({ "amount_usd": null, "alerts": true });
        let bare = AccountSettingsWriteDocument {
            alerts: serde_json::from_value(alerts.clone()).expect("alerts"),
            budget: serde_json::from_value(budget.clone()).expect("budget"),
            history: None,
        };
        let body = account_settings_put_body(&bare);
        assert!(body.get("history").is_none());
        assert_eq!(body["protocol_version"], CONTROL_PROTOCOL);
        let named = AccountSettingsWriteDocument {
            history: Some(crate::protocol::AccountSettingsHistory { sync: true }),
            ..bare
        };
        let body = account_settings_put_body(&named);
        assert_eq!(body["history"]["sync"], true);
        assert!(body.get("revision").is_none());

        let written = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "revision": 2,
            "updated_at": "2026-09-22T00:00:00Z",
            "alerts": alerts,
            "budget": budget,
            "history": { "sync": true }
        });
        let (origin, server) = spawn_mock_server(vec![http_json_with_etag(200, "\"2\"", &written)]);
        let root = std::env::temp_dir().join(format!(
            "quota-history-settings-write-{}",
            uuid::Uuid::new_v4()
        ));
        let manager = signed_in_manager(&origin, &root);
        let cancel = AtomicBool::new(false);
        manager
            .put_account_settings(&named, "\"1\"", &cancel)
            .expect("put");
        let sent = server.join().expect("server");
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert!(
            sent[0].contains("PUT /api/v2/account/settings"),
            "{}",
            sent[0]
        );
        assert!(
            sent[0].contains("\"history\":{\"sync\":true}"),
            "{}",
            sent[0]
        );
        let record = manager
            .state
            .quota_history_sync("account_1")
            .expect("record");
        assert!(record.backfill_done);
        assert!(record.series.is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn quota_history_backfill_uploads_once_and_409_clears_the_watermark() {
        let now = chrono::Utc::now();
        let observed = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let resets =
            (now + chrono::Duration::hours(2)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let answer = serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "series": [{
                "provider": "codex",
                "fingerprint": "account_test",
                "window_id": "five_hour",
                "bucket_start": "2026-09-22T00:00:00Z"
            }]
        });
        let root =
            std::env::temp_dir().join(format!("quota-history-backfill-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        state
            .write_session_json(&fresh_session_json())
            .expect("session");
        let key = crate::protocol::QuotaOverviewIdentity::selector_for(
            "codex",
            "account_test",
            "global",
            None,
        );
        state
            .record_quota_samples(
                &key,
                "codex",
                &observed,
                &[serde_json::json!({
                    "id": "five_hour",
                    "used_percent": 42.5,
                    "resets_at": resets,
                    "duration_seconds": 18000
                })],
                now,
            )
            .expect("sample");
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(serde_json::json!({
                    "captured_at": observed,
                    "results": [{
                        "provider": "codex",
                        "snapshots": [{
                            "provider": "codex",
                            "account": {"fingerprint": "account_test", "fingerprint_scope": "global"},
                            "observed_at": observed,
                            "windows": [{
                                "id": "five_hour",
                                "used_percent": 42.5,
                                "resets_at": resets,
                                "duration_seconds": 18000
                            }]
                        }, {
                            "provider": "codex",
                            "account": {"fingerprint": "fp-source", "fingerprint_scope": "source"},
                            "observed_at": observed,
                            "windows": [{
                                "id": "five_hour",
                                "used_percent": 9,
                                "resets_at": resets,
                                "duration_seconds": 18000
                            }]
                        }]
                    }]
                })),
                Some(observed.clone()),
                None,
                false,
            )
            .expect("quota");
        let document = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "revision": 3,
            "updated_at": observed,
            "alerts": {"reset_reminders": true, "pace_alerts": true, "thresholds": {}},
            "budget": {"amount_usd": null, "alerts": true},
            "history": {"sync": true}
        });
        state
            .set_account_settings_cache("account_1", Some("\"3\""), &document)
            .expect("settings");
        let inputs =
            history::series_inputs(&state, &crate::state::QuotaHistorySyncRecord::default());
        let planned = crate::history::plan_quota_history_upload(&inputs, &observed);
        assert!(
            !planned.is_empty(),
            "inputs {inputs:?} samples {:?}",
            state.quota_samples()
        );
        let (origin, server) = spawn_mock_server(vec![http_json(200, None, &answer)]);
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("client")),
            state.clone(),
            "Test Mac".to_owned(),
        );
        let cancel = AtomicBool::new(false);
        manager.note_history_settings("account_1", &document, &cancel);
        let sent = server.join().expect("server");
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert!(
            sent[0].contains("PUT /api/v6/device/quota-history"),
            "{}",
            sent[0]
        );
        assert!(sent[0].contains("\"used_percent\":42.5"), "{}", sent[0]);
        assert!(!sent[0].contains("fp-source"), "{}", sent[0]);
        assert!(sent[0].contains("\"generation\":1"), "{}", sent[0]);
        let record = state.quota_history_sync("account_1").expect("record");
        assert!(record.backfill_done);
        assert_eq!(record.last_error, None);
        assert_eq!(
            record
                .series
                .get("codex\u{0}account_test\u{0}five_hour")
                .and_then(|series| series.watermark.as_deref()),
            Some("2026-09-22T00:00:00Z")
        );
        manager.note_history_settings("account_1", &document, &cancel);
        assert_eq!(
            state
                .quota_history_sync("account_1")
                .expect("second")
                .last_error,
            None
        );

        let (origin, server) = spawn_mock_server(vec![http_json(
            409,
            None,
            &serde_json::json!({"error": {"code": "history_sync_off", "message": "off"}}),
        )]);
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("client")),
            state.clone(),
            "Test Mac".to_owned(),
        );
        // A new on-period: the stored fact says this one already backfilled, so force the
        // transition the 409 is answering.
        let mut again = state.quota_history_sync("account_1").expect("record");
        again.backfill_done = false;
        again.sync = false;
        again.series.clear();
        state
            .set_quota_history_sync("account_1", &again)
            .expect("reset");
        manager.note_history_settings("account_1", &document, &cancel);
        let sent = server.join().expect("server");
        assert!(
            sent[0].contains("PUT /api/v6/device/quota-history"),
            "{}",
            sent[0]
        );
        let refused = state.quota_history_sync("account_1").expect("refused");
        assert_eq!(refused.last_error.as_deref(), Some("history_sync_off"));
        assert!(refused.series.is_empty());
        assert_eq!(refused.refused_revision, Some(3));
        assert!(!refused.backfill_done);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn quota_history_read_uses_the_cached_body_on_304() {
        let body = serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "sync": true,
            "windows": {
                "five_hour": {
                    "duration_seconds": 18000,
                    "points": [{
                        "resets_at": "2026-09-21T15:00:00Z",
                        "bucket_start": "2026-09-21T10:00:00Z",
                        "used_percent": 42.5
                    }]
                }
            }
        });
        let (origin, server) = spawn_mock_server(vec![
            http_json_with_etag(200, "\"hist-1\"", &body),
            http_not_modified("\"hist-1\""),
        ]);
        let root =
            std::env::temp_dir().join(format!("quota-history-read-{}", uuid::Uuid::new_v4()));
        let manager = signed_in_manager(&origin, &root);
        let cancel = AtomicBool::new(false);
        let first = manager
            .read_account_quota_history("codex", "account_test", "2026-08-22T00:00:00Z", &cancel)
            .expect("read");
        assert_eq!(
            first["windows"]["five_hour"]["points"][0]["used_percent"],
            42.5
        );
        let second = manager
            .read_account_quota_history("codex", "account_test", "2026-08-22T00:00:00Z", &cancel)
            .expect("304");
        assert_eq!(second, first);
        let sent = server.join().expect("server");
        assert!(
            sent[1]
                .to_ascii_lowercase()
                .contains("if-none-match: \"hist-1\""),
            "{}",
            sent[1]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn quota_history_full_stops_until_the_next_collection() {
        let now = chrono::Utc::now();
        let observed = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let resets =
            (now + chrono::Duration::hours(2)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let answer = serde_json::json!({
            "protocol_version": MANAGED_DATA_PROTOCOL,
            "series": [{
                "provider": "codex",
                "fingerprint": "account_test",
                "window_id": "five_hour",
                "bucket_start": "2026-09-22T00:00:00Z"
            }]
        });
        let (origin, server) = spawn_mock_server(vec![
            http_json(
                413,
                None,
                &serde_json::json!({"error": {"code": "quota_history_full", "message": "full"}}),
            ),
            http_json(200, None, &answer),
        ]);
        let root =
            std::env::temp_dir().join(format!("quota-history-full-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("root");
        let state = Arc::new(crate::state::StateStore::open(&root).expect("state"));
        state
            .write_session_json(&fresh_session_json())
            .expect("session");
        let key = crate::protocol::QuotaOverviewIdentity::selector_for(
            "codex",
            "account_test",
            "global",
            None,
        );
        state
            .record_quota_samples(
                &key,
                "codex",
                &observed,
                &[serde_json::json!({
                    "id": "five_hour",
                    "used_percent": 42.5,
                    "resets_at": resets,
                    "duration_seconds": 18000
                })],
                now,
            )
            .expect("sample");
        state
            .set_component(
                crate::protocol::ComponentName::Quota,
                crate::protocol::ComponentStatus::Ready,
                Some(serde_json::json!({
                    "captured_at": observed,
                    "results": [{
                        "provider": "codex",
                        "snapshots": [{
                            "provider": "codex",
                            "account": {
                                "fingerprint": "account_test",
                                "fingerprint_scope": "global"
                            },
                            "observed_at": observed,
                            "windows": [{
                                "id": "five_hour",
                                "used_percent": 42.5,
                                "resets_at": resets,
                                "duration_seconds": 18000
                            }]
                        }]
                    }]
                })),
                Some(observed.clone()),
                None,
                false,
            )
            .expect("quota");
        let document = serde_json::json!({
            "protocol_version": CONTROL_PROTOCOL,
            "revision": 3,
            "updated_at": observed,
            "alerts": {"reset_reminders": true, "pace_alerts": true, "thresholds": {}},
            "budget": {"amount_usd": null, "alerts": true},
            "history": {"sync": true}
        });
        state
            .set_account_settings_cache("account_1", Some("\"3\""), &document)
            .expect("settings");
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test(&origin).expect("client")),
            state.clone(),
            "Test Mac".to_owned(),
        );
        let cancel = AtomicBool::new(false);
        manager.note_history_settings("account_1", &document, &cancel);
        assert_eq!(
            state
                .quota_history_sync("account_1")
                .expect("record")
                .last_error
                .as_deref(),
            Some("quota_history_full")
        );
        assert!(
            !state
                .quota_history_sync("account_1")
                .expect("record")
                .backfill_done
        );
        // Off is honoured while full: the record forgets its watermarks so the next on backfills.
        let mut off = document.clone();
        off["history"] = serde_json::json!({"sync": false});
        off["revision"] = serde_json::json!(4);
        manager.note_history_settings("account_1", &off, &cancel);
        let cleared = state.quota_history_sync("account_1").expect("record");
        assert!(!cleared.sync && !cleared.backfill_done && cleared.series.is_empty());
        assert_eq!(cleared.last_error, None);
        manager.note_history_settings("account_1", &document, &cancel);
        manager.sync_quota_history_after_collection(&cancel);
        let sent = server.join().expect("server");
        assert_eq!(sent.len(), 2, "{sent:?}");
        assert!(
            state
                .quota_history_sync("account_1")
                .expect("done")
                .backfill_done
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
