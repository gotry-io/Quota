//! Fixed-origin QuotaRelay client and upload-boundary validation.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
#[cfg(target_os = "macos")]
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use crate::protocol::{AccountComponentValue, AuthStatus};
use crate::service::{BackendError, LoginOutcome};
use crate::state::StateStore;
use base64::Engine;
use chrono::Timelike;
use reqwest::blocking::{Client, Response};
use reqwest::header::{
    ACCEPT, AUTHORIZATION, CONTENT_TYPE, ETAG, HeaderMap, HeaderValue, IF_NONE_MATCH,
};
use serde_json::Value;
use sha2::Digest;
use thiserror::Error;
use url::Url;

pub const MANAGED_ORIGIN: &str = "https://quota.gotry.io";
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
pub const MAXIMUM_RESPONSE_BYTES: usize = 1_048_576;
pub const MAXIMUM_REQUEST_BYTES: usize = 1_048_576;
const MAXIMUM_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

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

/// The non-secret portion of a Device Authorization Grant.  The device code itself never leaves
/// this module; callers only receive the values that a person needs to complete authorization.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceAuthorizationPrompt {
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: Option<String>,
    pub expires_in: u64,
    pub interval: u64,
}

struct DeviceAuthorizationGrant {
    device_code: String,
    prompt: DeviceAuthorizationPrompt,
}

struct DevicePollRejection {
    code: String,
    status: u16,
    retry_after: Option<Duration>,
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

    fn begin_device_authorization(
        &self,
        body: &Value,
    ) -> Result<DeviceAuthorizationGrant, RelayError> {
        let response = self.post_json("/oauth/v2/device/code", body, None, 201)?;
        parse_device_authorization_response(&response)
    }

    fn poll_device_token(
        &self,
        device_code: &str,
        expires_in: u64,
        interval: u64,
        cancel: &AtomicBool,
    ) -> Result<Value, RelayError> {
        let mut sleep = |duration| sleep_with_cancel(duration, cancel);
        self.poll_device_token_with_sleep(device_code, expires_in, interval, cancel, &mut sleep)
    }

    fn poll_device_token_with_sleep(
        &self,
        device_code: &str,
        expires_in: u64,
        interval: u64,
        cancel: &AtomicBool,
        sleep: &mut dyn FnMut(Duration),
    ) -> Result<Value, RelayError> {
        if !is_opaque(device_code) || expires_in == 0 || interval == 0 {
            return Err(RelayError::InvalidResponse);
        }
        if cancel.load(Ordering::Acquire) {
            return Err(RelayError::Cancelled);
        }
        let deadline = Instant::now()
            .checked_add(Duration::from_secs(expires_in))
            .ok_or(RelayError::Timeout)?;
        let mut wait = Duration::from_secs(interval);
        let mut has_polled = false;
        loop {
            if cancel.load(Ordering::Acquire) {
                return Err(RelayError::Cancelled);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(RelayError::Timeout);
            }
            if has_polled {
                sleep(wait.min(deadline.saturating_duration_since(now)));
                if cancel.load(Ordering::Acquire) {
                    return Err(RelayError::Cancelled);
                }
                if Instant::now() >= deadline {
                    return Err(RelayError::Timeout);
                }
            }
            match self.poll_device_token_once(device_code)? {
                Ok(value) => return Ok(value),
                Err(rejection) => match rejection.code.as_str() {
                    "authorization_pending" => {
                        wait = rejection.retry_after.unwrap_or(wait);
                        has_polled = true;
                    }
                    "slow_down" => {
                        let increased = wait.saturating_add(Duration::from_secs(5));
                        wait = rejection
                            .retry_after
                            .map_or(increased, |retry_after| retry_after.max(increased));
                        has_polled = true;
                    }
                    _ => {
                        return Err(RelayError::Rejected {
                            code: rejection.code,
                            status: rejection.status,
                        });
                    }
                },
            }
        }
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

    pub fn upload_snapshot(&self, token: &str, envelope: &Value) -> Result<Value, RelayError> {
        validate_snapshot_envelope(envelope)?;
        let response = self.put_json("/api/v3/device/snapshots", envelope, token, 200)?;
        validate_snapshot_response(&response)?;
        Ok(response)
    }

    pub fn upload_usage(&self, token: &str, submission: &Value) -> Result<Value, RelayError> {
        validate_usage_submission(submission)?;
        let response = self.request(
            self.client
                .put(self.url("/api/v3/device/usage"))
                .header(CONTENT_TYPE, "application/json")
                .header(ACCEPT, "application/json")
                .header(AUTHORIZATION, bearer(token)),
            Some(submission),
            Some(token),
        )?;
        let status = response.status().as_u16();
        let response = if status != 200 && status != 409 {
            check_status(response, 200)?
        } else {
            response
        };
        let response = read_json(response)?;
        validate_usage_response(&response)?;
        Ok(response)
    }

    pub fn account_summary(&self, token: &str, query: &str) -> Result<Value, RelayError> {
        self.account_usage_query("/api/v3/account/summary", token, query)
    }

    pub fn account_usage_summary(&self, token: &str, query: &str) -> Result<Value, RelayError> {
        let response = self.account_usage_query("/api/v3/account/usage/summary", token, query)?;
        validate_account_usage_response(&response)?;
        response
            .get("usage")
            .cloned()
            .ok_or(RelayError::InvalidResponse)
    }

    fn account_usage_query(
        &self,
        path: &str,
        token: &str,
        query: &str,
    ) -> Result<Value, RelayError> {
        let mut parts = query
            .split('&')
            .filter(|part| !part.is_empty())
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if !parts.iter().any(|part| part.starts_with("usage_agents=")) {
            parts.push("usage_agents=all".to_owned());
        }
        let added_usage_clients = !parts.iter().any(|part| part.starts_with("usage_clients="));
        if added_usage_clients {
            parts.push("usage_clients=1".to_owned());
        }
        let added_model_catalog = !parts.iter().any(|part| part.starts_with("model_catalog="));
        if added_model_catalog {
            parts.push("model_catalog=1".to_owned());
        }
        let mut result = self.get_json(&format!("{path}?{}", parts.join("&")), token, 200);
        if (added_usage_clients || added_model_catalog)
            && matches!(
                &result,
                Err(RelayError::Rejected { code, status: 400 }) if code == "invalid_request"
            )
        {
            // Released Relay versions reject these new opt-ins. Remove this after QuotaBar and
            // QuotaCLI 0.0.10 have completed their compatibility window.
            parts.retain(|part| {
                !(added_usage_clients && part.starts_with("usage_clients="))
                    && !(added_model_catalog && part.starts_with("model_catalog="))
            });
            result = self.get_json(&format!("{path}?{}", parts.join("&")), token, 200);
        }
        result
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
                .get(self.url("/api/v2/pricing/catalog?usage_agents=all"))
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

fn parse_device_authorization_response(
    value: &Value,
) -> Result<DeviceAuthorizationGrant, RelayError> {
    validate_response_object(
        value,
        &[
            "protocol_version",
            "device_code",
            "user_code",
            "verification_uri",
            "verification_uri_complete",
            "expires_in",
            "interval",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(2) {
        return Err(RelayError::InvalidResponse);
    }
    let device_code = object
        .get("device_code")
        .and_then(Value::as_str)
        .filter(|value| is_opaque(value) && (16..=2_048).contains(&value.len()))
        .ok_or(RelayError::InvalidResponse)?
        .to_owned();
    let user_code = object
        .get("user_code")
        .and_then(Value::as_str)
        .filter(|value| valid_user_code(value))
        .ok_or(RelayError::InvalidResponse)?
        .to_owned();
    let verification_uri = object
        .get("verification_uri")
        .and_then(Value::as_str)
        .filter(|value| valid_https_url(value))
        .ok_or(RelayError::InvalidResponse)?
        .to_owned();
    let verification_uri_complete = match object.get("verification_uri_complete") {
        Some(Value::Null) => None,
        Some(Value::String(value)) if valid_https_url(value) => Some(value.clone()),
        _ => return Err(RelayError::InvalidResponse),
    };
    let expires_in = object
        .get("expires_in")
        .and_then(safe_positive_u64)
        .filter(|value| *value <= 600)
        .ok_or(RelayError::InvalidResponse)?;
    let interval = object
        .get("interval")
        .and_then(safe_positive_u64)
        .filter(|value| *value <= 60)
        .ok_or(RelayError::InvalidResponse)?;
    Ok(DeviceAuthorizationGrant {
        device_code,
        prompt: DeviceAuthorizationPrompt {
            user_code,
            verification_uri,
            verification_uri_complete,
            expires_in,
            interval,
        },
    })
}

fn valid_https_url(value: &str) -> bool {
    let Ok(url) = Url::parse(value) else {
        return false;
    };
    url.scheme() == "https" && url.host_str().is_some() && value.len() <= 2_048
}

fn valid_user_code(value: &str) -> bool {
    valid_display(value, 32)
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
}

impl RelayClient {
    fn poll_device_token_once(
        &self,
        device_code: &str,
    ) -> Result<Result<Value, DevicePollRejection>, RelayError> {
        let body = serde_json::json!({
            "protocol_version": 2,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": "quotacli",
            "device_code": device_code,
        });
        validate_bounded_json(&body)?;
        let response = self.request(
            self.client
                .post(self.url("/oauth/v2/token"))
                .header(CONTENT_TYPE, "application/json")
                .header(ACCEPT, "application/json"),
            Some(&body),
            None,
        )?;
        let retry_after = parse_retry_after(response.headers());
        if response.status().as_u16() == 200 {
            return Ok(Ok(read_json(response)?));
        }
        match check_status(response, 200) {
            Err(RelayError::Rejected { code, status }) => Ok(Err(DevicePollRejection {
                code,
                status,
                retry_after,
            })),
            Err(error) => Err(error),
            Ok(_) => Err(RelayError::InvalidResponse),
        }
    }
}

fn parse_retry_after(headers: &HeaderMap) -> Option<Duration> {
    headers
        .get("retry-after")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0 && *value <= 600)
        .map(Duration::from_secs)
}

fn sleep_with_cancel(duration: Duration, cancel: &AtomicBool) {
    let deadline = Instant::now() + duration;
    while !cancel.load(Ordering::Acquire) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return;
        }
        thread::sleep(remaining.min(Duration::from_millis(100)));
    }
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
    let keys = [
        "protocol_version",
        "device_id",
        "generation",
        "sequence",
        "captured_at",
        "snapshots",
    ];
    if object.len() != keys.len()
        || keys.iter().any(|key| !object.contains_key(*key))
        || object.keys().any(|key| !keys.contains(&key.as_str()))
    {
        return Err(RelayError::InvalidResponse);
    }
    if object.get("protocol_version").and_then(Value::as_i64) != Some(3)
        || !object
            .get("device_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || object
            .get("generation")
            .and_then(safe_positive_u64)
            .is_none()
        || object.get("sequence").and_then(safe_u64).is_none()
        || object
            .get("captured_at")
            .and_then(Value::as_str)
            .is_none_or(|value| !valid_rfc3339(value))
        || object
            .get("snapshots")
            .and_then(Value::as_array)
            .is_none_or(|snapshots| snapshots.len() > 32)
    {
        return Err(RelayError::InvalidResponse);
    }
    for snapshot in object
        .get("snapshots")
        .and_then(Value::as_array)
        .ok_or(RelayError::InvalidResponse)?
    {
        validate_quota_snapshot(snapshot)?;
    }
    Ok(())
}

pub(crate) fn validate_usage_submission(value: &Value) -> Result<(), RelayError> {
    validate_bounded_json(value)?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let keys = [
        "protocol_version",
        "submission_id",
        "device_id",
        "generation",
        "sequence",
        "parser_revision",
        "aggregation_timezone",
        "coverage",
        "rows",
    ];
    if object.len() < keys.len()
        || keys.iter().any(|key| !object.contains_key(*key))
        || object
            .keys()
            .any(|key| !keys.contains(&key.as_str()) && key != "write_mode" && key != "multipart")
    {
        return Err(RelayError::InvalidResponse);
    }
    if object.get("protocol_version").and_then(Value::as_i64) != Some(3) {
        return Err(RelayError::InvalidResponse);
    }
    for key in ["submission_id", "device_id", "parser_revision"] {
        if !object
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        {
            return Err(RelayError::InvalidResponse);
        }
    }
    if !object
        .get("device_id")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || object
            .get("generation")
            .and_then(safe_positive_u64)
            .is_none()
        || object.get("sequence").and_then(safe_u64).is_none()
    {
        return Err(RelayError::InvalidResponse);
    }
    let timezone = object
        .get("aggregation_timezone")
        .and_then(Value::as_str)
        .filter(|value| value.parse::<chrono_tz::Tz>().is_ok())
        .ok_or(RelayError::InvalidResponse)?;
    let coverage = object
        .get("coverage")
        .and_then(Value::as_object)
        .ok_or(RelayError::InvalidResponse)?;
    if coverage.len() != 4
        || !["agent", "start_at", "end_at", "status"]
            .iter()
            .all(|key| coverage.contains_key(*key))
        || !matches!(
            coverage.get("status").and_then(Value::as_str),
            Some("complete") | Some("partial")
        )
    {
        return Err(RelayError::InvalidResponse);
    }
    let partial = coverage.get("status").and_then(Value::as_str) == Some("partial");
    if partial {
        if object.get("write_mode").and_then(Value::as_str) != Some("merge_partial") {
            return Err(RelayError::InvalidResponse);
        }
    } else if object.contains_key("write_mode") {
        return Err(RelayError::InvalidResponse);
    }
    if let Some(multipart) = object.get("multipart").and_then(Value::as_object) {
        if multipart.len() != 3
            || !["batch_id", "part_index", "part_count"]
                .iter()
                .all(|key| multipart.contains_key(*key))
            || !multipart
                .get("batch_id")
                .and_then(Value::as_str)
                .is_some_and(is_opaque)
            || multipart
                .get("part_count")
                .and_then(safe_positive_u64)
                .is_none_or(|count| !(2..=64).contains(&count))
            || multipart
                .get("part_index")
                .and_then(safe_u64)
                .zip(multipart.get("part_count").and_then(safe_positive_u64))
                .is_none_or(|(index, count)| index >= count)
        {
            return Err(RelayError::InvalidResponse);
        }
    } else if object.contains_key("multipart") {
        return Err(RelayError::InvalidResponse);
    }
    let agent = coverage
        .get("agent")
        .and_then(Value::as_str)
        .filter(|value| {
            matches!(
                *value,
                "codex" | "claude_code" | "grok" | "opencode" | "pi" | "cursor"
            )
        })
        .ok_or(RelayError::InvalidResponse)?;
    let start = parse_utc_hour(coverage.get("start_at"))?;
    let end = parse_utc_hour(coverage.get("end_at"))?;
    if end <= start || end - start > chrono::Duration::hours(crate::usage::MAX_USAGE_COVERAGE_HOURS)
    {
        return Err(RelayError::InvalidResponse);
    }
    let rows = object
        .get("rows")
        .and_then(Value::as_array)
        .ok_or(RelayError::InvalidResponse)?;
    if rows.len() > crate::usage::MAX_USAGE_ROWS {
        return Err(RelayError::InvalidResponse);
    }
    let row_keys = [
        "bucket_start_utc",
        "usage_date",
        "usage_hour",
        "agent",
        "billing_channel",
        "channel_source",
        "model",
        "context_bucket",
        "service_tier",
        "speed",
        "inference_geo",
        "input_tokens",
        "cache_read_tokens",
        "cache_write_5m_tokens",
        "cache_write_1h_tokens",
        "cache_write_inferred_tokens",
        "output_tokens",
        "reasoning_tokens",
        "requests",
        "web_search_requests",
        "web_fetch_requests",
        "source_cost_covered_requests",
    ];
    let mut identities = std::collections::BTreeSet::new();
    for row in rows {
        let row_object = row.as_object().ok_or(RelayError::InvalidResponse)?;
        if (row_object.len() != row_keys.len() && row_object.len() != row_keys.len() + 1)
            || row_keys.iter().any(|key| !row_object.contains_key(*key))
            || row_object
                .get("source_cost_microusd")
                .is_some_and(|value| !value.is_string())
        {
            return Err(RelayError::InvalidResponse);
        }
        let row: crate::usage::UsageHourlyFact =
            serde_json::from_value(row.clone()).map_err(|_| RelayError::InvalidResponse)?;
        crate::usage::validate_fact(&row).map_err(|_| RelayError::InvalidResponse)?;
        if row.agent.as_str() != agent {
            return Err(RelayError::InvalidResponse);
        }
        let bucket = parse_utc_hour_value(&row.bucket_start_utc)?;
        if bucket < start || bucket >= end {
            return Err(RelayError::InvalidResponse);
        }
        let local = bucket.with_timezone(
            &timezone
                .parse::<chrono_tz::Tz>()
                .map_err(|_| RelayError::InvalidResponse)?,
        );
        if row.usage_date != local.format("%Y-%m-%d").to_string()
            || row.usage_hour != local.hour() as u8
            || row.usage_hour > 23
        {
            return Err(RelayError::InvalidResponse);
        }
        let identity = serde_json::to_string(&(
            &row.bucket_start_utc,
            &row.usage_date,
            row.usage_hour,
            row.agent,
            row.billing_channel,
            row.channel_source,
            &row.model,
            row.context_bucket,
            &row.service_tier,
            &row.speed,
            &row.inference_geo,
        ))
        .map_err(|_| RelayError::InvalidResponse)?;
        if !identities.insert(identity) {
            return Err(RelayError::InvalidResponse);
        }
    }
    let _ = timezone;
    Ok(())
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

fn validate_snapshot_response(value: &Value) -> Result<(), RelayError> {
    validate_response_object(
        value,
        &[
            "protocol_version",
            "outcome",
            "device_id",
            "device_generation",
            "accepted_sequence",
            "next_snapshot_sequence",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(3)
        || !matches!(
            object.get("outcome").and_then(Value::as_str),
            Some("accepted" | "duplicate")
        )
        || !object
            .get("device_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || object
            .get("device_generation")
            .and_then(safe_positive_u64)
            .is_none()
        || object.get("accepted_sequence").and_then(safe_u64).is_none()
        || object
            .get("next_snapshot_sequence")
            .and_then(safe_u64)
            .is_none()
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_usage_response(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let outcome = object.get("outcome").and_then(Value::as_str);
    let base_keys = [
        "protocol_version",
        "outcome",
        "device_id",
        "device_generation",
        "accepted_sequence",
        "next_sequence",
        "usage_sync_revision",
        "deleted_before",
    ];
    if outcome == Some("rejected") {
        let mut keys = base_keys.to_vec();
        keys.push("rejection_reason");
        validate_response_object(value, &keys)?;
    } else {
        validate_response_object(value, &base_keys)?;
    }
    if object.get("protocol_version").and_then(Value::as_i64) != Some(3)
        || !matches!(
            outcome,
            Some(
                "accepted"
                    | "duplicate"
                    | "rejected"
                    | "partial"
                    | "sequence_conflict"
                    | "stale_generation"
                    | "deleted"
            )
        )
        || !object
            .get("device_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || object
            .get("device_generation")
            .and_then(safe_positive_u64)
            .is_none()
        || object.get("next_sequence").and_then(safe_u64).is_none()
        || object
            .get("usage_sync_revision")
            .and_then(safe_u64)
            .is_none()
        || !object
            .get("deleted_before")
            .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_rfc3339))
    {
        return Err(RelayError::InvalidResponse);
    }
    if (outcome == Some("rejected"))
        != (object.get("rejection_reason").and_then(Value::as_str)
            == Some("duplicate_fact_identity"))
    {
        return Err(RelayError::InvalidResponse);
    }
    let accepted = matches!(outcome, Some("accepted" | "duplicate"));
    if accepted
        != object.get("accepted_sequence").is_some_and(|value| {
            value
                .as_u64()
                .is_some_and(|number| number <= MAXIMUM_SAFE_INTEGER)
        })
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_response_object(value: &Value, keys: &[&str]) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_control_response(value: &Value) -> Result<(), RelayError> {
    validate_response_object(
        value,
        &[
            "protocol_version",
            "account_id",
            "device_id",
            "device_generation",
            "next_snapshot_sequence",
            "next_usage_sequence",
            "usage_deleted_before",
            "usage_sync_revision",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(2)
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
            .get("next_snapshot_sequence")
            .and_then(safe_u64)
            .is_none()
        || object
            .get("next_usage_sequence")
            .and_then(safe_u64)
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

fn validate_account_summary(value: &Value) -> Result<(), RelayError> {
    validate_response_object(
        value,
        &[
            "protocol_version",
            "generated_at",
            "account",
            "devices",
            "quota",
            "usage",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(3)
        || !object
            .get("generated_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
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
    let quota = object
        .get("quota")
        .and_then(Value::as_array)
        .filter(|quota| quota.len() <= 8_192)
        .ok_or(RelayError::InvalidResponse)?;
    for observation in quota {
        validate_quota_observation(observation)?;
    }
    validate_usage_summary(object.get("usage").ok_or(RelayError::InvalidResponse)?)?;
    Ok(())
}

fn validate_account_usage_response(value: &Value) -> Result<(), RelayError> {
    validate_response_object(value, &["protocol_version", "usage"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(3) {
        return Err(RelayError::InvalidResponse);
    }
    validate_usage_summary(object.get("usage").ok_or(RelayError::InvalidResponse)?)
}

fn validate_account_record(value: &Value) -> Result<(), RelayError> {
    validate_response_object(value, &["account_id", "display_label", "created_at"])?;
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

fn validate_account_device(value: &Value) -> Result<(), RelayError> {
    validate_response_object(
        value,
        &[
            "device_id",
            "display_name",
            "platform",
            "device_generation",
            "status",
            "created_at",
            "last_login_at",
            "last_seen_at",
            "signed_out_at",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let status = object.get("status").and_then(Value::as_str);
    let signed_out = object
        .get("signed_out_at")
        .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_rfc3339));
    if !object
        .get("device_id")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || !object
            .get("display_name")
            .and_then(Value::as_str)
            .is_some_and(|value| valid_display(value, 128))
        || !matches!(
            object.get("platform").and_then(Value::as_str),
            Some("macos" | "linux" | "windows")
        )
        || object
            .get("device_generation")
            .and_then(safe_positive_u64)
            .is_none()
        || !matches!(status, Some("active" | "offline" | "signed_out"))
        || !object
            .get("created_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
        || !object
            .get("last_login_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
        || !object
            .get("last_seen_at")
            .is_some_and(|value| value.is_null() || value.as_str().is_some_and(valid_rfc3339))
        || !signed_out
        || (status == Some("signed_out"))
            != object
                .get("signed_out_at")
                .is_some_and(|value| !value.is_null())
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_quota_observation(value: &Value) -> Result<(), RelayError> {
    validate_response_object(
        value,
        &[
            "device_id",
            "sequence",
            "captured_at",
            "snapshot",
            "updated_at",
        ],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if !object
        .get("device_id")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || object.get("sequence").and_then(safe_u64).is_none()
        || !object
            .get("captured_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
        || !object
            .get("updated_at")
            .and_then(Value::as_str)
            .is_some_and(valid_rfc3339)
    {
        return Err(RelayError::InvalidResponse);
    }
    validate_quota_snapshot(object.get("snapshot").ok_or(RelayError::InvalidResponse)?)
}

fn validate_quota_snapshot(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let required = [
        "provider",
        "account",
        "windows",
        "source",
        "status",
        "observed_at",
    ];
    if (object.len() != required.len() && object.len() != required.len() + 1)
        || required.iter().any(|key| !object.contains_key(*key))
        || (object.contains_key("valid_until")
            && !object
                .get("valid_until")
                .and_then(Value::as_str)
                .is_some_and(valid_rfc3339))
    {
        return Err(RelayError::InvalidResponse);
    }
    if !object
        .get("provider")
        .and_then(Value::as_str)
        .and_then(crate::catalog::ProviderId::parse)
        .is_some_and(|provider| {
            provider
                .metadata()
                .account_sync_protocol
                .is_some_and(|version| version <= 3)
        })
        || !object
            .get("source")
            .and_then(Value::as_str)
            .is_some_and(|value| valid_dimension(value, 64))
        || !matches!(
            object.get("status").and_then(Value::as_str),
            Some("available" | "stale" | "auth_required" | "unavailable" | "unsupported" | "error")
        )
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
    if (object.len() < required.len() || object.len() > required.len() + 2)
        || required.iter().any(|key| !object.contains_key(*key))
        || object
            .keys()
            .any(|key| !required.contains(&key.as_str()) && key != "label" && key != "plan")
    {
        return Err(RelayError::InvalidResponse);
    }
    if !object
        .get("fingerprint")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || !matches!(
            object.get("fingerprint_scope").and_then(Value::as_str),
            Some("global" | "source")
        )
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
    let optional = [
        "resets_at",
        "duration_seconds",
        "remaining_value",
        "limit_value",
        "value_unit",
    ];
    if object.len() < required.len()
        || object.len() > required.len() + optional.len()
        || required.iter().any(|key| !object.contains_key(*key))
        || object
            .keys()
            .any(|key| !required.contains(&key.as_str()) && !optional.contains(&key.as_str()))
    {
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
            .is_some_and(|value| !matches!(value.as_str(), Some("usd" | "credits" | "count")))
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_usage_summary(value: &Value) -> Result<(), RelayError> {
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let required = ["range", "totals", "cost", "coverage", "breakdowns"];
    if object.len() < required.len()
        || object.len() > required.len() + 4
        || required.iter().any(|key| !object.contains_key(*key))
        || object.keys().any(|key| {
            !required.contains(&key.as_str())
                && key != "breakdowns_truncated"
                && key != "coverage_truncated"
                && key != "model_catalog_revision"
                && key != "clients"
        })
        || object
            .get("breakdowns_truncated")
            .is_some_and(|value| value != &Value::Bool(true))
        || object
            .get("coverage_truncated")
            .is_some_and(|value| value != &Value::Bool(true))
        || object
            .get("model_catalog_revision")
            .is_some_and(|value| !value.as_str().is_some_and(is_opaque))
    {
        return Err(RelayError::InvalidResponse);
    }
    validate_usage_date_range(object.get("range").ok_or(RelayError::InvalidResponse)?)?;
    validate_usage_totals(object.get("totals").ok_or(RelayError::InvalidResponse)?)?;
    validate_usage_cost(object.get("cost").ok_or(RelayError::InvalidResponse)?)?;
    let coverage = object
        .get("coverage")
        .and_then(Value::as_array)
        .filter(|coverage| coverage.len() <= 2_048)
        .ok_or(RelayError::InvalidResponse)?;
    for item in coverage {
        validate_usage_coverage_item(item)?;
    }
    let breakdowns = object
        .get("breakdowns")
        .and_then(Value::as_array)
        .filter(|breakdowns| breakdowns.len() <= 1_000)
        .ok_or(RelayError::InvalidResponse)?;
    for breakdown in breakdowns {
        validate_response_object(breakdown, &["dimension", "key", "totals", "cost"])?;
        let object = breakdown.as_object().ok_or(RelayError::InvalidResponse)?;
        let dimension = object.get("dimension").and_then(Value::as_str);
        let key = object.get("key").and_then(Value::as_str);
        if !matches!(
            dimension,
            Some(
                "device"
                    | "agent"
                    | "model"
                    | "billing_channel"
                    | "usage_date"
                    | "bucket_start_utc"
            )
        ) || !key.is_some_and(|value| {
            if dimension == Some("model") {
                valid_model_text(value)
            } else {
                valid_display(value, 128)
            }
        }) {
            return Err(RelayError::InvalidResponse);
        }
        validate_usage_totals(object.get("totals").ok_or(RelayError::InvalidResponse)?)?;
        validate_usage_cost(object.get("cost").ok_or(RelayError::InvalidResponse)?)?;
    }
    if let Some(clients) = object.get("clients") {
        validate_usage_clients(clients)?;
    }
    Ok(())
}

fn validate_usage_clients(value: &Value) -> Result<(), RelayError> {
    let clients = value
        .as_array()
        .filter(|clients| clients.len() <= crate::usage::UsageAgent::ALL.len())
        .ok_or(RelayError::InvalidResponse)?;
    for client in clients {
        validate_response_object(client, &["client", "totals", "cost", "providers"])?;
        let object = client.as_object().ok_or(RelayError::InvalidResponse)?;
        if !matches!(
            object.get("client").and_then(Value::as_str),
            Some("codex" | "claude_code" | "grok" | "opencode" | "pi" | "cursor")
        ) {
            return Err(RelayError::InvalidResponse);
        }
        validate_usage_summary_totals(object.get("totals").ok_or(RelayError::InvalidResponse)?)?;
        validate_usage_cost(object.get("cost").ok_or(RelayError::InvalidResponse)?)?;
        let providers = object
            .get("providers")
            .and_then(Value::as_array)
            .filter(|providers| providers.len() <= 8)
            .ok_or(RelayError::InvalidResponse)?;
        for provider in providers {
            validate_response_object(provider, &["provider", "totals", "cost", "models"])?;
            let object = provider.as_object().ok_or(RelayError::InvalidResponse)?;
            if !matches!(
                object.get("provider").and_then(Value::as_str),
                Some(
                    "openai"
                        | "azure_openai"
                        | "anthropic"
                        | "aws_bedrock"
                        | "google_vertex"
                        | "openrouter"
                        | "xai"
                        | "unknown"
                )
            ) {
                return Err(RelayError::InvalidResponse);
            }
            validate_usage_summary_totals(
                object.get("totals").ok_or(RelayError::InvalidResponse)?,
            )?;
            validate_usage_cost(object.get("cost").ok_or(RelayError::InvalidResponse)?)?;
            let models = object
                .get("models")
                .and_then(Value::as_array)
                .filter(|models| models.len() <= 1_000)
                .ok_or(RelayError::InvalidResponse)?;
            for model in models {
                validate_response_object(model, &["model", "totals", "cost"])?;
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
    validate_response_object(value, &keys)?;
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

fn validate_usage_date_range(value: &Value) -> Result<(), RelayError> {
    validate_response_object(value, &["from", "to"])?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let from = object
        .get("from")
        .and_then(Value::as_str)
        .ok_or(RelayError::InvalidResponse)?;
    let to = object
        .get("to")
        .and_then(Value::as_str)
        .ok_or(RelayError::InvalidResponse)?;
    let from_date = chrono::NaiveDate::parse_from_str(from, "%Y-%m-%d")
        .map_err(|_| RelayError::InvalidResponse)?;
    let to_date = chrono::NaiveDate::parse_from_str(to, "%Y-%m-%d")
        .map_err(|_| RelayError::InvalidResponse)?;
    if from.len() != 10 || to.len() != 10 || from_date > to_date {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_usage_totals(value: &Value) -> Result<(), RelayError> {
    let keys = [
        "input_tokens",
        "cache_read_tokens",
        "cache_write_5m_tokens",
        "cache_write_1h_tokens",
        "cache_write_inferred_tokens",
        "output_tokens",
        "reasoning_tokens",
        "requests",
        "web_search_requests",
        "web_fetch_requests",
        "source_cost_microusd",
        "source_cost_covered_requests",
    ];
    validate_response_object(value, &keys)?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    if keys[..keys.len() - 1]
        .iter()
        .any(|key| *key != "source_cost_microusd" && object.get(*key).and_then(safe_u64).is_none())
        || object.get("source_cost_microusd").is_some_and(|value| {
            !value.is_null() && !value.as_str().is_some_and(valid_decimal_integer)
        })
        || object
            .get("source_cost_covered_requests")
            .and_then(safe_u64)
            .is_none()
    {
        return Err(RelayError::InvalidResponse);
    }

    let input_tokens = object["input_tokens"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?;
    let classified_input = [
        "cache_read_tokens",
        "cache_write_5m_tokens",
        "cache_write_1h_tokens",
        "cache_write_inferred_tokens",
    ]
    .into_iter()
    .try_fold(0u64, |total, key| total.checked_add(object[key].as_u64()?))
    .filter(|total| *total <= MAXIMUM_SAFE_INTEGER)
    .ok_or(RelayError::InvalidResponse)?;
    if classified_input > input_tokens {
        return Err(RelayError::InvalidResponse);
    }

    let output_tokens = object["output_tokens"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?;
    if object["reasoning_tokens"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?
        > output_tokens
    {
        return Err(RelayError::InvalidResponse);
    }

    let requests = object["requests"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?;
    let source_cost_covered_requests = object["source_cost_covered_requests"]
        .as_u64()
        .ok_or(RelayError::InvalidResponse)?;
    if source_cost_covered_requests > requests
        || (requests == 0
            && (object["web_search_requests"].as_u64() != Some(0)
                || object["web_fetch_requests"].as_u64() != Some(0)))
    {
        return Err(RelayError::InvalidResponse);
    }
    let has_source_cost = object["source_cost_microusd"].as_str().is_some();
    if has_source_cost != (source_cost_covered_requests > 0) {
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
    if object.len() < required_keys.len()
        || object.len() > required_keys.len() + 1
        || required_keys.iter().any(|key| !object.contains_key(*key))
    {
        return Err(RelayError::InvalidResponse);
    }
    if object
        .keys()
        .any(|key| key != "unpriced_truncated" && !required_keys.contains(&key.as_str()))
    {
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
    if assumptions.iter().any(|value| {
        !matches!(
            value.as_str(),
            Some(
                "agent_default_channel"
                    | "model_alias"
                    | "wildcard_service_tier"
                    | "wildcard_speed"
                    | "wildcard_inference_geo"
                    | "wildcard_context_bucket"
                    | "cache_write_inferred_rate"
                    | "source_reported"
            )
        )
    }) {
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
        validate_response_object(item, &["billing_channel", "model", "reason", "rows"])?;
        let item = item.as_object().ok_or(RelayError::InvalidResponse)?;
        if !valid_billing_channel(item.get("billing_channel").and_then(Value::as_str))
            || !item
                .get("model")
                .and_then(Value::as_str)
                .is_some_and(valid_model_text)
            || !matches!(
                item.get("reason").and_then(Value::as_str),
                Some(
                    "unknown_channel"
                        | "unknown_model"
                        | "outside_effective_range"
                        | "unsupported_dimensions"
                        | "ambiguous_price"
                        | "missing_rate"
                        | "incomplete_source_cost"
                        | "invalid_catalog"
                )
            )
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

fn validate_usage_coverage_item(value: &Value) -> Result<(), RelayError> {
    validate_response_object(
        value,
        &["device_id", "agent", "start_at", "end_at", "status"],
    )?;
    let object = value.as_object().ok_or(RelayError::InvalidResponse)?;
    let start = parse_utc_hour(object.get("start_at"))?;
    let end = parse_utc_hour(object.get("end_at"))?;
    if !object
        .get("device_id")
        .and_then(Value::as_str)
        .is_some_and(is_opaque)
        || !valid_billing_agent(object.get("agent").and_then(Value::as_str))
        || end <= start
        || !matches!(
            object.get("status").and_then(Value::as_str),
            Some("complete" | "partial")
        )
    {
        return Err(RelayError::InvalidResponse);
    }
    Ok(())
}

fn validate_session_refresh_response(
    value: &Value,
    session: &Value,
    audience: &str,
) -> Result<(), BackendError> {
    // Refresh responses contain only the rotated token family and its identity.  Sequence and
    // deletion watermarks are returned by the device sync endpoint, not by this OAuth route.
    let object = value.as_object().ok_or_else(BackendError::unavailable)?;
    if audience == "account" {
        validate_response_object(
            value,
            &[
                "protocol_version",
                "token_type",
                "token_audience",
                "account_id",
                "account_session",
            ],
        )
        .map_err(|_| invalid_response_backend())?;
    } else {
        validate_response_object(
            value,
            &[
                "protocol_version",
                "token_type",
                "token_audience",
                "account_id",
                "device_id",
                "device_generation",
                "device_session",
            ],
        )
        .map_err(|_| invalid_response_backend())?;
    }
    if object.get("protocol_version").and_then(Value::as_i64) != Some(2)
        || object.get("token_type").and_then(Value::as_str) != Some("Bearer")
        || object.get("token_audience").and_then(Value::as_str) != Some(audience)
        || !object
            .get("account_id")
            .and_then(Value::as_str)
            .is_some_and(is_opaque)
        || object.get("account_id").and_then(Value::as_str)
            != session.get("account_id").and_then(Value::as_str)
    {
        return Err(BackendError {
            error: crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            ),
        });
    }
    if audience == "device"
        && (object
            .get("device_id")
            .and_then(Value::as_str)
            .is_none_or(|value| {
                !is_opaque(value) || Some(value) != session.get("device_id").and_then(Value::as_str)
            })
            || object.get("device_generation").and_then(safe_positive_u64)
                != session.get("device_generation").and_then(safe_positive_u64))
    {
        return Err(BackendError {
            error: crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            ),
        });
    }
    let token_key = if audience == "account" {
        "account_session"
    } else {
        "device_session"
    };
    validate_session_token(
        object
            .get(token_key)
            .ok_or_else(BackendError::unavailable)?,
    )
    .map_err(|_| invalid_response_backend())?;
    Ok(())
}

/// Native account/session owner used by the service backend.  It stores only the bounded session
/// envelope in SQLite; browser authorization codes and provider credentials never enter the
/// component state or diagnostics.
pub struct AccountManager {
    client: Arc<RelayClient>,
    state: Arc<StateStore>,
    device_name: String,
    platform: &'static str,
}

impl AccountManager {
    pub fn new(client: Arc<RelayClient>, state: Arc<StateStore>, device_name: String) -> Self {
        Self {
            client,
            state,
            device_name: sanitize_device_name(&device_name),
            platform: current_platform(),
        }
    }

    pub fn login(&self, cancel: &AtomicBool) -> Result<LoginOutcome, BackendError> {
        let installation_id = self
            .state
            .installation_id()
            .map_err(|_| BackendError::unavailable())?;
        let response = self.browser_exchange(&installation_id, cancel)?;
        self.finalize_login(&response)
    }

    /// Runs the Linux/headless OAuth Device Authorization Grant.  The device code is retained only
    /// for the bounded Relay requests; the callback receives display-safe authorization details.
    pub fn login_device<F>(
        &self,
        cancel: &AtomicBool,
        mut on_prompt: F,
    ) -> Result<LoginOutcome, BackendError>
    where
        F: FnMut(&DeviceAuthorizationPrompt),
    {
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        let installation_id = self
            .state
            .installation_id()
            .map_err(|_| BackendError::unavailable())?;
        let body = serde_json::json!({
            "protocol_version": 2,
            "client_id": "quotacli",
            "installation_id": installation_id,
            "device_display_name": self.device_name,
            "platform": self.platform,
        });
        let grant = self
            .client
            .begin_device_authorization(&body)
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })?;
        on_prompt(&grant.prompt);
        let response = self
            .client
            .poll_device_token(
                &grant.device_code,
                grant.prompt.expires_in,
                grant.prompt.interval,
                cancel,
            )
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })?;
        self.finalize_device_login(&response, cancel)
    }

    fn finalize_device_login(
        &self,
        response: &Value,
        cancel: &AtomicBool,
    ) -> Result<LoginOutcome, BackendError> {
        // Building the outcome validates the issued token families but never persists an active
        // session. If cancellation won the issuance race, retain only a durable revoke record.
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

    /// Persists a validated login outcome using the same durable session boundary as the service.
    /// If the first write fails, retain a logout-pending revoke record so issued refresh families
    /// are never abandoned in memory.
    pub fn persist_login(&self, outcome: &LoginOutcome) -> Result<(), BackendError> {
        if self.state.write_session_json(&outcome.session).is_ok() {
            return Ok(());
        }
        if let Some(pending) = pending_session_from_active(&outcome.session) {
            let _ = self.state.write_session_json(&pending);
        }
        Err(BackendError::unavailable())
    }

    fn finalize_login(&self, response: &Value) -> Result<LoginOutcome, BackendError> {
        let mut session = session_from_token_response(response).map_err(|_| BackendError {
            error: crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            ),
        })?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?
            .to_owned();
        let upload_not_before = match self
            .state
            .upload_lower_bound(&account_id, &crate::state::now_rfc3339())
        {
            Ok(value) => value,
            Err(_) => {
                // The Relay has already issued both refresh families.  If the local privacy
                // binding cannot be committed, retain only a durable revoke job instead of
                // returning an error that strands live credentials in memory.
                if let Some(pending) = pending_session_from_active(&session) {
                    let _ = self.state.write_session_json(&pending);
                }
                return Err(BackendError::unavailable());
            }
        };
        session["upload_not_before"] = Value::String(upload_not_before);
        let account = AccountComponentValue {
            auth_status: AuthStatus::SignedIn,
            account_id: Some(account_id),
            device_id: session
                .get("device_id")
                .and_then(Value::as_str)
                .map(str::to_owned),
            device_generation: session.get("device_generation").and_then(Value::as_u64),
            account_summary: None,
        };
        Ok(LoginOutcome { session, account })
    }

    pub fn logout(&self, pending: &Value) -> Result<(), BackendError> {
        let object = pending.as_object().ok_or_else(BackendError::unavailable)?;
        let account = object
            .get("account_refresh_token")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let device = object
            .get("device_refresh_token")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let account_result = self.client.revoke(account);
        let device_result = self.client.revoke(device);
        account_result
            .and(device_result)
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })
    }

    /// Refreshes both token families before an account read.  The server performs compare-and-swap
    /// rotation; this process is the sole local writer, so writing the response is atomic at the
    /// SQLite row boundary.
    pub fn refresh_account_state(&self, cancel: &AtomicBool) -> Result<Value, BackendError> {
        let (summary, session) = self.read_account_summary("cost_mode=calculate", cancel)?;
        let account_id = session
            .get("account_id")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let device_id = session
            .get("device_id")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let device_generation = session.get("device_generation").and_then(Value::as_u64);
        Ok(serde_json::to_value(AccountComponentValue {
            auth_status: AuthStatus::SignedIn,
            account_id,
            device_id,
            device_generation,
            account_summary: Some(summary),
        })
        .unwrap_or(Value::Null))
    }

    pub fn account_usage(&self, query: &str, cancel: &AtomicBool) -> Result<Value, BackendError> {
        // /api/v3/account/usage/summary still materializes hourly facts with a 1_000-row
        // cap and returns 413 for a 30-day window. Account summary uses the 100_000-row path.
        let (summary, _) = self.read_account_summary(query, cancel)?;
        summary
            .get("usage")
            .cloned()
            .ok_or_else(BackendError::unavailable)
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
            .ok_or_else(|| BackendError {
                error: crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::AuthenticationRequired,
                    crate::protocol::RecoveryAction::Login,
                ),
            })?;
        if !is_active_session(&session) {
            return Err(BackendError {
                error: crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::AuthenticationRequired,
                    crate::protocol::RecoveryAction::Login,
                ),
            });
        }
        if cancel.load(Ordering::Acquire) {
            return Err(BackendError::cancelled());
        }
        self.ensure_fresh_session(&mut session, &mut session_epoch, "device")?;
        let account_token =
            self.ensure_fresh_session(&mut session, &mut session_epoch, "account")?;
        let summary = self
            .client
            .account_summary(&account_token, query)
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })?;
        validate_account_summary(&summary).map_err(|_| BackendError {
            error: crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            ),
        })?;
        if !self
            .state
            .active_session_at_epoch(session_epoch)
            .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        session["account"]["last_refreshed_at"] = Value::String(crate::state::now_rfc3339());
        if self
            .state
            .write_session_json_if_epoch(&session, session_epoch)
            .map_err(|_| BackendError::unavailable())?
            .is_none()
        {
            return Err(session_changed_error());
        }
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
        let token = self.ensure_fresh_session(&mut session, &mut session_epoch, "device")?;
        let control = self
            .client
            .sync_control(&token)
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })?;
        validate_control_response(&control).map_err(|_| BackendError {
            error: crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidResponse,
                crate::protocol::RecoveryAction::Retry,
            ),
        })?;
        let object = control.as_object().ok_or_else(BackendError::unavailable)?;
        let expected_account = session.get("account_id").and_then(Value::as_str);
        let expected_device = session.get("device_id").and_then(Value::as_str);
        if object.get("account_id").and_then(Value::as_str) != expected_account
            || object.get("device_id").and_then(Value::as_str) != expected_device
        {
            return Err(BackendError {
                error: crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::InvalidState,
                    crate::protocol::RecoveryAction::Reinstall,
                ),
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
            ("next_snapshot_sequence", "next_snapshot_sequence"),
            ("next_usage_sequence", "next_usage_sequence"),
            ("usage_sync_revision", "usage_sync_revision"),
            ("usage_deleted_before", "usage_deleted_before"),
        ] {
            if let Some(value) = object.get(source) {
                session[target] = value.clone();
            }
        }
        let generation = session.get("device_generation").cloned();
        if let Some(device) = session.get_mut("device").and_then(Value::as_object_mut)
            && let Some(value) = generation
        {
            device.insert("device_generation".to_owned(), value.clone());
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

    pub(crate) fn upload_quota_report(&self, report: &Value) -> Result<Value, BackendError> {
        let (session, session_epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(BackendError::unavailable)?;
        if !is_active_session(&session)
            || !self
                .state
                .active_session_at_epoch(session_epoch)
                .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        let token = session_access_token_from(&session, "device")?;
        let (report_captured_at, snapshots) = snapshot_payload_from_quota_report(report)?;
        let expected_device_id = session
            .get("device_id")
            .and_then(Value::as_str)
            .ok_or_else(BackendError::unavailable)?;
        let expected_generation = session
            .get("device_generation")
            .and_then(Value::as_u64)
            .ok_or_else(BackendError::unavailable)?;
        let expected_sequence = session
            .get("next_snapshot_sequence")
            .and_then(Value::as_u64)
            .ok_or_else(BackendError::unavailable)?;
        let envelope = serde_json::json!({
            "protocol_version": 3,
            "device_id": expected_device_id,
            "generation": expected_generation,
            "sequence": expected_sequence,
            "captured_at": report_captured_at,
            "snapshots": snapshots
        });
        if !self
            .state
            .active_session_at_epoch(session_epoch)
            .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        let response = self
            .client
            .upload_snapshot(&token, &envelope)
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })?;
        if !self
            .state
            .active_session_at_epoch(session_epoch)
            .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        if response.get("device_id").and_then(Value::as_str) != Some(expected_device_id)
            || response.get("device_generation").and_then(Value::as_u64)
                != Some(expected_generation)
            || response.get("accepted_sequence").and_then(Value::as_u64) != Some(expected_sequence)
        {
            return Err(BackendError {
                error: crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::InvalidResponse,
                    crate::protocol::RecoveryAction::Retry,
                ),
            });
        }
        if let Some(next) = response.get("next_snapshot_sequence") {
            let mut session = session;
            session["next_snapshot_sequence"] = next.clone();
            if self
                .state
                .write_session_json_if_epoch(&session, session_epoch)
                .map_err(|_| BackendError::unavailable())?
                .is_none()
            {
                return Err(session_changed_error());
            }
        }
        Ok(response)
    }

    pub fn upload_usage(&self, submission: &Value) -> Result<Value, BackendError> {
        let (session, epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(session_changed_error)?;
        if !is_active_session(&session)
            || !self
                .state
                .active_session_at_epoch(epoch)
                .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        validate_usage_submission_session(&session, submission)?;
        let token = session_access_token_from(&session, "device")?;
        if !self
            .state
            .active_session_at_epoch(epoch)
            .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        let response = self
            .client
            .upload_usage(&token, submission)
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })?;
        if !self
            .state
            .active_session_at_epoch(epoch)
            .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        Ok(response)
    }

    pub fn record_usage_response(&self, response: &Value) -> Result<(), BackendError> {
        let outcome = response
            .get("outcome")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !matches!(outcome, "accepted" | "duplicate" | "rejected") {
            return Ok(());
        }
        let (mut session, epoch) = self
            .state
            .session_snapshot()
            .map_err(|_| BackendError::unavailable())?
            .ok_or_else(BackendError::unavailable)?;
        if !is_active_session(&session)
            || !self
                .state
                .active_session_at_epoch(epoch)
                .map_err(|_| BackendError::unavailable())?
        {
            return Err(session_changed_error());
        }
        if let Some(value) = response.get("next_sequence") {
            session["next_usage_sequence"] = value.clone();
        }
        if let Some(value) = response.get("usage_sync_revision") {
            session["usage_sync_revision"] = value.clone();
        }
        if self
            .state
            .write_session_json_if_epoch(&session, epoch)
            .map_err(|_| BackendError::unavailable())?
            .is_none()
        {
            return Err(session_changed_error());
        }
        Ok(())
    }

    fn ensure_fresh_session(
        &self,
        session: &mut Value,
        session_epoch: &mut u64,
        audience: &str,
    ) -> Result<String, BackendError> {
        let needs_refresh = session
            .get(audience)
            .and_then(Value::as_object)
            .and_then(|value| value.get("access_expires_at"))
            .and_then(Value::as_str)
            .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
            .is_none_or(|expires| {
                expires.with_timezone(&chrono::Utc)
                    <= chrono::Utc::now() + chrono::Duration::seconds(60)
            });
        if needs_refresh {
            if !self
                .state
                .active_session_at_epoch(*session_epoch)
                .map_err(|_| BackendError::unavailable())?
            {
                return Err(session_changed_error());
            }
            refresh_session_family(&self.client, session, audience)?;
            // Persist each rotated family before issuing any subsequent network request.  A
            // compare-and-swap refresh token is single-use on Relay, so a late second failure
            // must not strand the first newly issued token only in memory.
            *session_epoch = self
                .state
                .write_session_json_if_epoch(session, *session_epoch)
                .map_err(|_| BackendError::unavailable())?
                .ok_or_else(session_changed_error)?;
        }
        session
            .get(audience)
            .and_then(Value::as_object)
            .and_then(|value| value.get("access_token"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| BackendError {
                error: crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::AuthenticationRequired,
                    crate::protocol::RecoveryAction::Login,
                ),
            })
    }

    fn browser_exchange(
        &self,
        installation_id: &str,
        cancel: &AtomicBool,
    ) -> Result<Value, BackendError> {
        let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| BackendError::unavailable())?;
        listener
            .set_nonblocking(true)
            .map_err(|_| BackendError::unavailable())?;
        let port = listener
            .local_addr()
            .map_err(|_| BackendError::unavailable())?
            .port();
        let redirect_uri = format!("http://127.0.0.1:{port}/callback");
        let state = random_secret(32);
        let verifier = random_secret(48);
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(sha2::Sha256::digest(verifier.as_bytes()));
        let mut authorize = Url::parse(&format!("{MANAGED_ORIGIN}/oauth/v2/authorize"))
            .map_err(|_| BackendError::unavailable())?;
        authorize
            .query_pairs_mut()
            .append_pair("client_id", "quotacli")
            .append_pair("response_type", "code")
            .append_pair("redirect_uri", &redirect_uri)
            .append_pair("state", &state)
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256");
        open_browser(authorize.as_str())?;
        let callback = wait_for_callback(&listener, &state, cancel)?;
        let body = serde_json::json!({
            "protocol_version": 2,
            "grant_type": "authorization_code",
            "client_id": "quotacli",
            "code": callback,
            "code_verifier": verifier,
            "redirect_uri": redirect_uri,
            "installation_id": installation_id,
            "device_display_name": self.device_name,
            "platform": self.platform
        });
        self.client
            .exchange_browser(&body)
            .map_err(|error| BackendError {
                error: relay_error_for_backend(error),
            })
    }
}

fn current_platform() -> &'static str {
    std::env::consts::OS
}

#[cfg(target_os = "macos")]
fn open_browser(url: &str) -> Result<(), BackendError> {
    let mut browser = Command::new("/usr/bin/open");
    let mut browser = browser
        .arg(url)
        .spawn()
        .map_err(|_| BackendError::unavailable())?;
    if browser
        .wait()
        .map_err(|_| BackendError::unavailable())?
        .success()
    {
        Ok(())
    } else {
        Err(BackendError::unavailable())
    }
}

#[cfg(not(target_os = "macos"))]
fn open_browser(_url: &str) -> Result<(), BackendError> {
    Err(BackendError::unavailable())
}

fn session_changed_error() -> BackendError {
    BackendError {
        error: crate::protocol::IpcError::new(
            crate::protocol::ErrorCode::AuthenticationRequired,
            crate::protocol::RecoveryAction::Login,
        ),
    }
}

fn snapshot_payload_from_quota_report(report: &Value) -> Result<(&str, Vec<Value>), BackendError> {
    let object = report.as_object().ok_or_else(BackendError::unavailable)?;
    if object.get("protocol_version").and_then(Value::as_u64) != Some(2) {
        return Err(BackendError::unavailable());
    }
    let captured_at = object
        .get("captured_at")
        .and_then(Value::as_str)
        .ok_or_else(BackendError::unavailable)?;
    let results = object
        .get("results")
        .and_then(Value::as_array)
        .ok_or_else(BackendError::unavailable)?;
    let mut snapshots = Vec::new();
    for result in results {
        let values = result
            .get("snapshots")
            .and_then(Value::as_array)
            .ok_or_else(BackendError::unavailable)?;
        for snapshot in values {
            let provider = snapshot
                .get("provider")
                .and_then(Value::as_str)
                .and_then(crate::catalog::ProviderId::parse)
                .ok_or_else(BackendError::unavailable)?;
            if provider
                .metadata()
                .account_sync_protocol
                .is_some_and(|version| version <= 3)
            {
                snapshots.push(snapshot.clone());
            }
        }
    }
    Ok((captured_at, snapshots))
}

fn validate_usage_submission_session(
    session: &Value,
    submission: &Value,
) -> Result<(), BackendError> {
    if session.get("device_id").and_then(Value::as_str)
        != submission.get("device_id").and_then(Value::as_str)
        || session.get("device_generation").and_then(Value::as_u64)
            != submission.get("generation").and_then(Value::as_u64)
    {
        return Err(session_changed_error());
    }
    if session.get("next_usage_sequence").and_then(Value::as_u64)
        != submission.get("sequence").and_then(Value::as_u64)
    {
        return Err(BackendError {
            error: crate::protocol::IpcError::new(
                crate::protocol::ErrorCode::InvalidState,
                crate::protocol::RecoveryAction::Reinstall,
            ),
        });
    }
    Ok(())
}

fn session_access_token_from(session: &Value, audience: &str) -> Result<String, BackendError> {
    session
        .get(audience)
        .and_then(Value::as_object)
        .and_then(|value| value.get("access_token"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(session_changed_error)
}

fn pending_session_from_active(session: &Value) -> Option<Value> {
    let object = session.as_object()?;
    let account_id = object.get("account_id").and_then(Value::as_str)?;
    let device_id = object.get("device_id").and_then(Value::as_str)?;
    let account_refresh_token = object
        .get("account")
        .and_then(Value::as_object)
        .and_then(|value| value.get("refresh_token"))
        .and_then(Value::as_str)?;
    let device_refresh_token = object
        .get("device")
        .and_then(Value::as_object)
        .and_then(|value| value.get("refresh_token"))
        .and_then(Value::as_str)?;
    Some(serde_json::json!({
        "schema_version": 1,
        "status": "logout_pending",
        "account_id": account_id,
        "device_id": device_id,
        "account_refresh_token": account_refresh_token,
        "device_refresh_token": device_refresh_token
    }))
}

fn refresh_session_family(
    client: &RelayClient,
    session: &mut Value,
    audience: &str,
) -> Result<(), BackendError> {
    let refresh_token = session
        .get(audience)
        .and_then(Value::as_object)
        .and_then(|value| value.get("refresh_token"))
        .and_then(Value::as_str)
        .ok_or_else(BackendError::unavailable)?;
    let response = client
        .refresh_session(&serde_json::json!({
            "protocol_version": 2,
            "grant_type": "refresh_token",
            "client_id": "quotacli",
            "token_audience": audience,
            "refresh_token": refresh_token
        }))
        .map_err(|error| BackendError {
            error: relay_error_for_backend(error),
        })?;
    validate_session_refresh_response(&response, session, audience)?;
    let token_key = if audience == "account" {
        "account_session"
    } else {
        "device_session"
    };
    let token = response
        .get(token_key)
        .ok_or_else(BackendError::unavailable)?;
    validate_session_token(token).map_err(|_| BackendError::unavailable())?;
    session[audience] = token.clone();
    Ok(())
}

fn session_from_token_response(response: &Value) -> Result<Value, RelayError> {
    let object = response.as_object().ok_or(RelayError::InvalidResponse)?;
    validate_response_object(
        response,
        &[
            "protocol_version",
            "token_type",
            "account_id",
            "device_id",
            "device_generation",
            "next_snapshot_sequence",
            "next_usage_sequence",
            "usage_deleted_before",
            "usage_sync_revision",
            "account_session",
            "device_session",
        ],
    )?;
    if object.get("protocol_version").and_then(Value::as_i64) != Some(2)
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
    let next_snapshot_sequence = object
        .get("next_snapshot_sequence")
        .and_then(safe_u64)
        .ok_or(RelayError::InvalidResponse)?;
    let next_usage_sequence = object
        .get("next_usage_sequence")
        .and_then(safe_u64)
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
    let account = object
        .get("account_session")
        .ok_or(RelayError::InvalidResponse)?;
    let device = object
        .get("device_session")
        .ok_or(RelayError::InvalidResponse)?;
    validate_session_token(account)?;
    validate_session_token(device)?;
    Ok(serde_json::json!({
        "schema_version": 1,
        "status": "active",
        "account_id": account_id,
        "device_id": device_id,
        "device_generation": generation,
        "next_snapshot_sequence": next_snapshot_sequence,
        "next_usage_sequence": next_usage_sequence,
        "usage_sync_revision": usage_sync_revision,
        "usage_deleted_before": usage_deleted_before,
        "upload_not_before": "1970-01-01T00:00:00Z",
        "account": { "account_id": account_id, "access_token": account["access_token"], "access_expires_at": account["access_expires_at"], "refresh_token": account["refresh_token"], "refresh_expires_at": account["refresh_expires_at"] },
        "device": { "account_id": account_id, "device_id": device_id, "device_generation": generation, "access_token": device["access_token"], "access_expires_at": device["access_expires_at"], "refresh_token": device["refresh_token"], "refresh_expires_at": device["refresh_expires_at"] }
    }))
}

fn validate_session_token(value: &Value) -> Result<(), RelayError> {
    validate_response_object(
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
            return Err(BackendError {
                error: crate::protocol::IpcError::new(
                    crate::protocol::ErrorCode::Unavailable,
                    crate::protocol::RecoveryAction::Retry,
                ),
            });
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
            "sequence_conflict" => {
                crate::protocol::IpcError::new(ErrorCode::InvalidState, RecoveryAction::Reinstall)
            }
            "invalid_request" | "invalid_response" => {
                crate::protocol::IpcError::new(ErrorCode::InvalidResponse, RecoveryAction::Retry)
            }
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

fn valid_billing_agent(value: Option<&str>) -> bool {
    matches!(
        value,
        Some("codex" | "claude_code" | "grok" | "opencode" | "pi" | "cursor")
    )
}

fn valid_billing_channel(value: Option<&str>) -> bool {
    matches!(
        value,
        Some(
            "openai_direct"
                | "azure_openai"
                | "anthropic_direct"
                | "aws_bedrock"
                | "google_vertex"
                | "openrouter"
                | "xai_direct"
                | "unknown"
        )
    )
}

fn invalid_response_backend() -> BackendError {
    BackendError {
        error: crate::protocol::IpcError::new(
            crate::protocol::ErrorCode::InvalidResponse,
            crate::protocol::RecoveryAction::Retry,
        ),
    }
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
    let output = Command::new("/usr/bin/scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()?;
    output.status.success().then(|| ())?;
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
            resolve_device_display_name([Some("\u{0007}Kitchen Mac".to_owned())], "QuotaCLI"),
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
                "protocol_version": 3,
                "submission_id": "x",
                "device_id": "d",
                "generation": 1,
                "sequence": 0,
                "parser_revision": "rust-v1",
                "aggregation_timezone": "UTC",
                "coverage": {
                    "agent": "codex",
                    "start_at": "2026-08-10T00:00:00Z",
                    "end_at": "2026-08-10T01:00:00Z",
                    "status": "complete"
                },
                "rows": []
            }))
            .is_ok()
        );
        assert!(validate_usage_submission(&serde_json::json!({"protocol_version": 1})).is_err());

        let opaque_model = serde_json::json!({
            "protocol_version": 3,
            "submission_id": "legacy",
            "device_id": "device",
            "generation": 1,
            "sequence": 0,
            "parser_revision": "rust-v1",
            "aggregation_timezone": "UTC",
            "coverage": {
                "agent": "codex",
                "start_at": "2026-08-10T00:00:00Z",
                "end_at": "2026-08-10T01:00:00Z",
                "status": "complete"
            },
            "rows": [{
                "bucket_start_utc": "2026-08-10T00:00:00Z",
                "usage_date": "2026-08-10",
                "usage_hour": 0,
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
        });
        assert!(validate_usage_submission(&opaque_model).is_ok());
    }

    #[test]
    fn multipart_and_report_truncation_markers_are_strict() {
        let mut submission = serde_json::json!({
            "protocol_version": 3,
            "submission_id": "x",
            "device_id": "d",
            "generation": 1,
            "sequence": 0,
            "parser_revision": "rust-v1",
            "aggregation_timezone": "UTC",
            "coverage": {
                "agent": "codex",
                "start_at": "2026-08-10T00:00:00Z",
                "end_at": "2026-08-10T01:00:00Z",
                "status": "complete"
            },
            "rows": [],
            "multipart": {"batch_id": "batch", "part_index": 63, "part_count": 64}
        });
        assert!(validate_usage_submission(&submission).is_ok());
        submission["multipart"]["part_count"] = serde_json::json!(65);
        assert!(validate_usage_submission(&submission).is_err());

        let mut snapshot = valid_snapshot();
        let mut envelope = serde_json::json!({
            "protocol_version": 3,
            "device_id": "device_1",
            "generation": 1,
            "sequence": 0,
            "captured_at": "2026-08-10T00:00:00Z",
            "snapshots": [snapshot.clone()]
        });
        envelope["multipart"] = serde_json::json!({"batch_id": "batch", "part_index": 0});
        assert!(validate_snapshot_envelope(&envelope).is_err());
        snapshot["status"] = serde_json::json!("available");

        let item = serde_json::json!({
            "billing_channel": "openai_direct",
            "model": "model",
            "reason": "missing_rate",
            "rows": 1
        });
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
            "unpriced": [item.clone()],
            "unpriced_truncated": true
        });
        assert!(validate_usage_cost(&cost).is_ok());
        cost["unpriced"][0]["model"] = serde_json::json!("GPT-5.5[1m]");
        assert!(validate_usage_cost(&cost).is_ok());
        cost["unpriced"][0]["model"] = serde_json::json!("😀".repeat(128));
        assert!(validate_usage_cost(&cost).is_ok());
        cost["unpriced"][0]["model"] = serde_json::json!("model\u{0001}");
        assert!(validate_usage_cost(&cost).is_err());
        cost["unpriced"][0]["model"] = serde_json::json!("model");
        cost["unpriced"][0]["rows"] = serde_json::json!(3);
        assert!(validate_usage_cost(&cost).is_err());
        cost["unpriced"][0]["rows"] = serde_json::json!(1);
        cost["unpriced_truncated"] = serde_json::json!(false);
        assert!(validate_usage_cost(&cost).is_err());

        let totals = serde_json::json!({
            "input_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_5m_tokens": 0,
            "cache_write_1h_tokens": 0,
            "cache_write_inferred_tokens": 0,
            "output_tokens": 0,
            "reasoning_tokens": 0,
            "requests": 0,
            "web_search_requests": 0,
            "web_fetch_requests": 0,
            "source_cost_microusd": null,
            "source_cost_covered_requests": 0
        });
        let mut summary = serde_json::json!({
            "range": {"from": "2026-08-10", "to": "2026-08-10"},
            "totals": totals,
            "cost": cost,
            "coverage": [],
            "breakdowns": [],
            "breakdowns_truncated": true,
            "coverage_truncated": true
        });
        summary["cost"]["unpriced_rows"] = serde_json::json!(1);
        summary["cost"]["unpriced_truncated"] = serde_json::json!(true);
        summary["breakdowns"] = serde_json::json!([{
            "dimension": "model",
            "key": "GPT-5.5[1m]",
            "totals": summary["totals"].clone(),
            "cost": summary["cost"].clone()
        }]);
        assert!(validate_usage_summary(&summary).is_ok());
        summary["coverage_truncated"] = serde_json::json!(false);
        assert!(validate_usage_summary(&summary).is_err());
    }

    #[test]
    fn rejected_usage_response_is_terminal_and_keeps_normal_response_shape() {
        let normal = serde_json::json!({
            "protocol_version": 3,
            "outcome": "accepted",
            "device_id": "device_1",
            "device_generation": 1,
            "accepted_sequence": 4,
            "next_sequence": 5,
            "usage_sync_revision": 2,
            "deleted_before": null
        });
        assert!(validate_usage_response(&normal).is_ok());

        let mut rejected = serde_json::json!({
            "protocol_version": 3,
            "outcome": "rejected",
            "device_id": "device_1",
            "device_generation": 1,
            "accepted_sequence": null,
            "next_sequence": 5,
            "usage_sync_revision": 2,
            "deleted_before": null,
            "rejection_reason": "duplicate_fact_identity"
        });
        assert!(validate_usage_response(&rejected).is_ok());
        rejected
            .as_object_mut()
            .expect("response")
            .remove("rejection_reason");
        assert!(validate_usage_response(&rejected).is_err());
    }

    #[test]
    fn usage_totals_reject_inconsistent_subsets_and_source_cost() {
        let mut totals = serde_json::json!({
            "input_tokens": 1,
            "cache_read_tokens": 1,
            "cache_write_5m_tokens": 0,
            "cache_write_1h_tokens": 0,
            "cache_write_inferred_tokens": 0,
            "output_tokens": 1,
            "reasoning_tokens": 1,
            "requests": 1,
            "web_search_requests": 0,
            "web_fetch_requests": 0,
            "source_cost_microusd": null,
            "source_cost_covered_requests": 0
        });
        assert!(validate_usage_totals(&totals).is_ok());

        totals["input_tokens"] = serde_json::json!(0);
        assert!(validate_usage_totals(&totals).is_err());
        totals["input_tokens"] = serde_json::json!(1);
        totals["reasoning_tokens"] = serde_json::json!(2);
        assert!(validate_usage_totals(&totals).is_err());
        totals["reasoning_tokens"] = serde_json::json!(1);
        totals["source_cost_covered_requests"] = serde_json::json!(2);
        assert!(validate_usage_totals(&totals).is_err());
        totals["source_cost_covered_requests"] = serde_json::json!(1);
        totals["source_cost_microusd"] = serde_json::json!("2");
        assert!(validate_usage_totals(&totals).is_ok());
        totals["source_cost_microusd"] = serde_json::Value::Null;
        assert!(validate_usage_totals(&totals).is_err());
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
    fn usage_submission_must_match_the_current_device_session() {
        let session = serde_json::json!({
            "device_id": "device_1",
            "device_generation": 2,
            "next_usage_sequence": 4
        });
        assert!(
            validate_usage_submission_session(
                &session,
                &serde_json::json!({"device_id": "device_1", "generation": 2, "sequence": 4})
            )
            .is_ok()
        );
        assert_eq!(
            validate_usage_submission_session(
                &session,
                &serde_json::json!({"device_id": "device_2", "generation": 2, "sequence": 4})
            )
            .expect_err("device mismatch")
            .error
            .code,
            crate::protocol::ErrorCode::AuthenticationRequired
        );
        assert_eq!(
            validate_usage_submission_session(
                &session,
                &serde_json::json!({"device_id": "device_1", "generation": 3, "sequence": 4})
            )
            .expect_err("generation mismatch")
            .error
            .code,
            crate::protocol::ErrorCode::AuthenticationRequired
        );
        assert_eq!(
            validate_usage_submission_session(
                &session,
                &serde_json::json!({"device_id": "device_1", "generation": 2, "sequence": 3})
            )
            .expect_err("sequence mismatch")
            .error
            .code,
            crate::protocol::ErrorCode::InvalidState
        );
    }

    #[test]
    fn snapshot_envelope_has_strict_count_identity_and_integer_bounds() {
        let snapshot = valid_snapshot();
        let mut envelope = serde_json::json!({
            "protocol_version": 3,
            "device_id": "device_1",
            "generation": 1,
            "sequence": 0,
            "captured_at": "2026-08-10T00:00:00Z",
            "snapshots": [snapshot.clone()]
        });
        assert!(validate_snapshot_envelope(&envelope).is_ok());
        envelope["generation"] = serde_json::json!(0);
        assert!(validate_snapshot_envelope(&envelope).is_err());
        envelope["generation"] = serde_json::json!(1);
        envelope["device_id"] = serde_json::json!("_not_opaque");
        assert!(validate_snapshot_envelope(&envelope).is_err());
        envelope["device_id"] = serde_json::json!("device_1");
        envelope["snapshots"] = serde_json::json!(vec![snapshot; 33]);
        assert!(validate_snapshot_envelope(&envelope).is_err());
        envelope["snapshots"] = serde_json::json!([]);
        envelope["sequence"] = serde_json::json!(9_007_199_254_740_992u64);
        assert!(validate_snapshot_envelope(&envelope).is_err());
    }

    #[test]
    fn token_and_utc_hour_validation_does_not_default_missing_or_unsafe_state() {
        let response = serde_json::json!({
            "protocol_version": 2,
            "token_type": "Bearer",
            "account_id": "account_1",
            "device_id": "device_1",
            "device_generation": 1,
            "next_snapshot_sequence": 0,
            "next_usage_sequence": 0,
            "usage_deleted_before": null,
            "usage_sync_revision": 0,
            "account_session": valid_token(),
            "device_session": valid_token()
        });
        assert!(session_from_token_response(&response).is_ok());
        let mut unsafe_response = response.clone();
        unsafe_response["next_usage_sequence"] = serde_json::json!(9_007_199_254_740_992u64);
        assert!(session_from_token_response(&unsafe_response).is_err());
        let mut invalid_expiry = response;
        invalid_expiry["account_session"]["access_expires_at"] = serde_json::json!("tomorrow");
        assert!(session_from_token_response(&invalid_expiry).is_err());
        assert!(parse_utc_hour_value("2026-08-10T00:00:00Z").is_ok());
        assert!(parse_utc_hour_value("2026-08-10T00:00:00+00:00").is_err());
        assert!(parse_utc_hour_value("2026-08-10T00:00:60Z").is_err());
    }

    #[test]
    fn cancelled_issued_device_login_persists_only_a_revoke_record() {
        let root = std::env::temp_dir().join(format!("quota-device-cancel-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let state = Arc::new(StateStore::open(&root).expect("state"));
        let manager = AccountManager::new(
            Arc::new(RelayClient::for_test("http://127.0.0.1:1").expect("client")),
            state.clone(),
            "Linux".into(),
        );
        let response = serde_json::json!({
            "protocol_version": 2,
            "token_type": "Bearer",
            "account_id": "account_1",
            "device_id": "device_1",
            "device_generation": 1,
            "next_snapshot_sequence": 0,
            "next_usage_sequence": 0,
            "usage_deleted_before": null,
            "usage_sync_revision": 0,
            "account_session": valid_token(),
            "device_session": valid_token()
        });

        let error = manager
            .finalize_device_login(&response, &AtomicBool::new(true))
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
        assert!(session.get("account").is_none());
        assert!(session.get("device").is_none());

        drop(manager);
        drop(state);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn quota_report_snapshot_extraction_is_strict() {
        let snapshot = valid_snapshot();
        let report = serde_json::json!({
            "protocol_version": 2,
            "captured_at": "2026-08-10T00:00:00Z",
            "results": [{"snapshots": [snapshot.clone()]}]
        });
        let (captured_at, snapshots) =
            snapshot_payload_from_quota_report(&report).expect("quota report");
        assert_eq!(captured_at, "2026-08-10T00:00:00Z");
        assert_eq!(snapshots, [snapshot.clone()]);

        let mut cursor = snapshot.clone();
        cursor["provider"] = serde_json::json!("cursor");
        let (_, mixed) = snapshot_payload_from_quota_report(&serde_json::json!({
            "protocol_version": 2,
            "captured_at": "2026-08-10T00:00:00Z",
            "results": [{"snapshots": [snapshot.clone(), cursor.clone()]}]
        }))
        .expect("mixed local report");
        assert_eq!(mixed, [snapshot.clone(), cursor.clone()]);
        let (_, cursor_only) = snapshot_payload_from_quota_report(&serde_json::json!({
            "protocol_version": 2,
            "captured_at": "2026-08-10T00:00:00Z",
            "results": [{"snapshots": [cursor.clone()]}]
        }))
        .expect("cursor report");
        assert_eq!(cursor_only, [cursor.clone()]);
        let mut unknown = cursor.clone();
        unknown["provider"] = serde_json::json!("unknown-provider");
        assert!(
            snapshot_payload_from_quota_report(&serde_json::json!({
                "protocol_version": 2,
                "captured_at": "2026-08-10T00:00:00Z",
                "results": [{"snapshots": [unknown]}]
            }))
            .is_err()
        );
        assert!(validate_quota_snapshot(&cursor).is_ok());

        assert!(
            snapshot_payload_from_quota_report(&serde_json::json!({
                "protocol_version": 2,
                "captured_at": "2026-08-10T00:00:00Z",
                "snapshots": []
            }))
            .is_err()
        );
        assert!(
            snapshot_payload_from_quota_report(&serde_json::json!({
                "protocol_version": 2,
                "captured_at": "2026-08-10T00:00:00Z",
                "results": [{}]
            }))
            .is_err()
        );
    }

    #[test]
    fn account_summary_nested_shape_is_checked() {
        let value = serde_json::json!({
            "protocol_version": 3,
            "generated_at": "2026-08-10T00:00:00Z",
            "account": {
                "account_id": "account_1",
                "display_label": null,
                "created_at": "2026-08-09T00:00:00Z"
            },
            "devices": [],
            "quota": [],
            "usage": {
                "range": {"from": "2026-08-09", "to": "2026-08-10"},
                "totals": valid_totals(),
                "cost": valid_cost(),
                "coverage": [],
                "breakdowns": []
            }
        });
        assert!(validate_account_summary(&value).is_ok());
        let mut structured = value.clone();
        structured["usage"]["clients"] = serde_json::json!([{
            "client": "codex",
            "totals": {
                "total_tokens": 12,
                "input_tokens": 10,
                "output_tokens": 2,
                "cache_read_input_tokens": 0,
                "cache_write_input_tokens": 0,
                "reasoning_tokens": 0,
                "messages": 1
            },
            "cost": valid_cost(),
            "providers": [{
                "provider": "openai",
                "totals": {
                    "total_tokens": 12,
                    "input_tokens": 10,
                    "output_tokens": 2,
                    "cache_read_input_tokens": 0,
                    "cache_write_input_tokens": 0,
                    "reasoning_tokens": 0,
                    "messages": 1
                },
                "cost": valid_cost(),
                "models": [{
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
                }]
            }]
        }]);
        assert!(validate_account_summary(&structured).is_ok());
        structured["usage"]["clients"][0]["totals"]["total_tokens"] = serde_json::json!(13);
        assert!(validate_account_summary(&structured).is_err());

        let mut extra = value;
        extra["account"]["unexpected"] = serde_json::json!(true);
        assert!(validate_account_summary(&extra).is_err());
    }

    #[test]
    fn account_usage_retries_once_without_new_opt_ins_for_released_relay() {
        let usage = serde_json::json!({
            "range": {"from": "2026-08-06", "to": "2026-08-12"},
            "totals": valid_totals(),
            "cost": valid_cost(),
            "coverage": [],
            "breakdowns": []
        });
        let (origin, server) = spawn_mock_server(vec![
            http_json(
                400,
                None,
                &serde_json::json!({"error": {"code": "invalid_request"}}),
            ),
            http_json(
                200,
                None,
                &serde_json::json!({"protocol_version": 3, "usage": usage}),
            ),
        ]);
        let client = RelayClient::for_test(&origin).expect("test client");
        let result = client
            .account_usage_summary(
                "account-token",
                "cost_mode=calculate&from=2026-08-06&to=2026-08-12",
            )
            .expect("Usage summary");
        assert_eq!(result["range"]["from"], "2026-08-06");
        server.join().expect("mock server");
    }

    #[test]
    fn device_authorization_response_is_strict_and_prompt_does_not_contain_device_code() {
        let response = serde_json::json!({
            "protocol_version": 2,
            "device_code": "qdc_secret_value",
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://quota.gotry.io/activate",
            "verification_uri_complete": "https://quota.gotry.io/activate?user_code=ABCD-EFGH",
            "expires_in": 600,
            "interval": 5
        });
        let grant = parse_device_authorization_response(&response).expect("valid device grant");
        assert_eq!(grant.device_code, "qdc_secret_value");
        assert_eq!(grant.prompt.user_code, "ABCD-EFGH");
        assert!(!format!("{:?}", grant.prompt).contains("qdc_secret_value"));

        let mut invalid = response;
        invalid["verification_uri"] = serde_json::json!("http://quota.gotry.io/activate");
        assert!(parse_device_authorization_response(&invalid).is_err());
        invalid["verification_uri"] = serde_json::json!("https://quota.gotry.io/activate");
        invalid["verification_uri_complete"] = serde_json::json!(42);
        assert!(parse_device_authorization_response(&invalid).is_err());
        invalid["verification_uri_complete"] = serde_json::Value::Null;
        invalid["expires_in"] = serde_json::json!(601);
        assert!(parse_device_authorization_response(&invalid).is_err());
        invalid["expires_in"] = serde_json::json!(600);
        invalid["interval"] = serde_json::json!(0);
        assert!(parse_device_authorization_response(&invalid).is_err());
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
    fn device_poll_handles_pending_slow_down_retry_after_and_issued() {
        let issued = serde_json::json!({"device_session": "issued"});
        let (origin, server) = spawn_mock_server(vec![
            http_json(
                400,
                Some(1),
                &serde_json::json!({"error": {"code": "authorization_pending"}}),
            ),
            http_json(
                400,
                Some(1),
                &serde_json::json!({"error": {"code": "slow_down"}}),
            ),
            http_json(200, None, &issued),
        ]);
        let client = RelayClient::for_test(&origin).expect("test client");
        let cancel = AtomicBool::new(false);
        let mut waits = Vec::new();
        let value = client
            .poll_device_token_with_sleep("qdc_test_value", 10, 1, &cancel, &mut |duration| {
                waits.push(duration)
            })
            .expect("device token");
        server.join().expect("mock server");
        assert_eq!(value, issued);
        assert_eq!(waits, vec![Duration::from_secs(1), Duration::from_secs(6)]);
    }

    #[test]
    fn device_poll_denied_and_expired_are_fixed_errors_without_secret_echo() {
        for code in ["access_denied", "expired_token"] {
            let (origin, server) = spawn_mock_server(vec![http_json(
                400,
                Some(1),
                &serde_json::json!({
                    "error": {"code": code, "description": "qdc_secret_value must not echo"}
                }),
            )]);
            let client = RelayClient::for_test(&origin).expect("test client");
            let cancel = AtomicBool::new(false);
            let error = client
                .poll_device_token_with_sleep("qdc_secret_value", 5, 1, &cancel, &mut |_| {})
                .expect_err("device grant should not issue");
            server.join().expect("mock server");
            assert!(matches!(
                error,
                RelayError::Rejected { code: ref value, .. } if value == code
            ));
            assert!(!format!("{error:?}").contains("qdc_secret_value"));
        }
    }

    #[test]
    fn device_poll_honors_cancel_and_timeout() {
        let cancel = AtomicBool::new(true);
        let client = RelayClient::for_test("http://127.0.0.1:1").expect("test client");
        assert!(matches!(
            client.poll_device_token_with_sleep("qdc_test_value", 5, 1, &cancel, &mut |_| {},),
            Err(RelayError::Cancelled)
        ));

        let (origin, server) = spawn_mock_server(vec![http_json(
            400,
            Some(1),
            &serde_json::json!({"error": {"code": "authorization_pending"}}),
        )]);
        let client = RelayClient::for_test(&origin).expect("test client");
        let cancel = AtomicBool::new(false);
        let result =
            client.poll_device_token_with_sleep("qdc_test_value", 1, 1, &cancel, &mut |duration| {
                thread::sleep(duration + Duration::from_millis(20))
            });
        server.join().expect("mock server");
        assert!(matches!(result, Err(RelayError::Timeout)));
    }

    fn http_json(status: u16, retry_after: Option<u64>, value: &Value) -> String {
        let body = serde_json::to_vec(value).expect("json");
        let reason = match status {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
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

    fn spawn_mock_server(responses: Vec<String>) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("mock listener");
        let address = listener.local_addr().expect("mock address");
        let server = thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().expect("mock request");
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .expect("mock timeout");
                let mut request = [0_u8; 8_192];
                let _ = stream.read(&mut request);
                stream
                    .write_all(response.as_bytes())
                    .expect("mock response");
            }
        });
        (format!("http://{address}"), server)
    }

    fn valid_snapshot() -> Value {
        serde_json::json!({
            "provider": "codex",
            "account": {"fingerprint": "fingerprint_1", "fingerprint_scope": "global"},
            "windows": [],
            "source": "oauth",
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
            "input_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_5m_tokens": 0,
            "cache_write_1h_tokens": 0,
            "cache_write_inferred_tokens": 0,
            "output_tokens": 0,
            "reasoning_tokens": 0,
            "requests": 0,
            "web_search_requests": 0,
            "web_fetch_requests": 0,
            "source_cost_microusd": null,
            "source_cost_covered_requests": 0
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
}
