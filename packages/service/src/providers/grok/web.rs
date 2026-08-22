use crate::catalog::ProviderId;
use std::time::Duration;

use super::super::common::{
    CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient, ProviderError, QuotaAccount,
    QuotaSnapshot, QuotaWindow, VALIDATION_TIMEOUT, ValidatedBrowserSession, account_identity,
    clamp_percent, cookie_named_value,
};
use super::now_seconds;

pub const WEB_SOURCE: &str = "grok_web_billing_api";
const WEB_BILLING_URL: &str = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";
const GRPC_EMPTY_FRAME: &[u8] = &[0x00, 0x00, 0x00, 0x00, 0x00];

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    sso_token(cookie_header).ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let _ = fetch_web_billing(WebAuth::Cookie(cookie_header), context, VALIDATION_TIMEOUT)?;
    let (account_fingerprint, _) = account_identity("grok", "user_id", None);
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: Some("Grok".to_owned()),
    })
}

pub fn collect(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let cookie_header = context
        .browser_session(ProviderId::Grok)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE))?;
    sso_token(cookie_header).ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let billing = fetch_web_billing(WebAuth::Cookie(cookie_header), context, HTTP_TIMEOUT)?;
    let (fingerprint, scope) = account_identity("grok", "user_id", None);
    Ok(QuotaSnapshot {
        provider: ProviderId::Grok,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some("Grok".to_owned()),
            plan: None,
        },
        windows: vec![billing_window(&billing, now_seconds(context))],
        source: WEB_SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

/// The billing-cycle window from grok.com's gRPC-web billing RPC using the local
/// OAuth access token instead of browser cookies. CodexBar's last Automatic step.
pub(super) fn bearer_billing_window(
    access_token: &str,
    context: &CollectionContext,
) -> Result<QuotaWindow, ProviderError> {
    let bearer = format!("Bearer {access_token}");
    let billing = fetch_web_billing(WebAuth::Bearer(&bearer), context, HTTP_TIMEOUT)?;
    Ok(billing_window(&billing, now_seconds(context)))
}

enum WebAuth<'a> {
    Cookie(&'a str),
    Bearer(&'a str),
}

fn fetch_web_billing(
    auth: WebAuth<'_>,
    context: &CollectionContext,
    timeout: Duration,
) -> Result<WebBilling, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE));
    }
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let auth_header = match auth {
        WebAuth::Cookie(header) => ("Cookie", header),
        WebAuth::Bearer(header) => ("Authorization", header),
    };
    let headers = [
        auth_header,
        ("Origin", "https://grok.com"),
        ("Referer", "https://grok.com/?_s=usage"),
        ("Accept", "*/*"),
        ("Content-Type", "application/grpc-web+proto"),
        ("x-grpc-web", "1"),
        ("x-user-agent", "connect-es/2.1.1"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, body) = client.post_bytes(WEB_BILLING_URL, &headers, GRPC_EMPTY_FRAME, WEB_SOURCE)?;
    parse_grpc_web_billing(&body, now_seconds(context))
}

fn sso_token(header: &str) -> Option<&str> {
    cookie_named_value(header, "sso")
        .or_else(|| cookie_named_value(header, "sso-rw"))
        .map(str::trim)
        .filter(|value| {
            !value.is_empty() && value.len() <= 8_192 && !value.chars().any(char::is_control)
        })
}

#[derive(Debug)]
struct WebBilling {
    used_percent: f64,
    resets_at: Option<i64>,
}

/// The RPC exposes only the reset instant, not the cadence. A reset 20–45 days out
/// reads as monthly; anything nearer is the weekly credit pool, even late in the
/// week (CodexBar's untyped-window rule), and no reset at all stays generic.
fn billing_window(billing: &WebBilling, now: i64) -> QuotaWindow {
    let delta = billing.resets_at.and_then(|end| end.checked_sub(now));
    let title = match delta {
        Some(seconds) if (20 * 86_400..=45 * 86_400).contains(&seconds) => "Monthly",
        Some(_) => "Weekly",
        None => "Billing cycle",
    };
    QuotaWindow {
        id: "billing_cycle".to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(billing.used_percent),
        resets_at: billing
            .resets_at
            .map(super::super::common::unix_seconds_to_iso),
        duration_seconds: None,
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    }
}

fn parse_grpc_web_billing(data: &[u8], now: i64) -> Result<WebBilling, ProviderError> {
    let trailers = grpc_web_trailer_fields(data);
    if let Some(status) = trailers
        .get("grpc-status")
        .and_then(|value| value.parse::<i32>().ok())
        && status != 0
    {
        let message = trailers
            .get("grpc-message")
            .map(String::as_str)
            .unwrap_or("");
        return Err(grpc_status_error(status, message));
    }
    let mut payloads = grpc_web_data_frames(data);
    if payloads.is_empty() && looks_like_protobuf(data) {
        payloads.push(data.to_vec());
    }
    if payloads.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE));
    }
    let mut scan = ProtobufScan::default();
    for payload in &payloads {
        scan.merge(&scan_protobuf(payload, 0, &[]));
    }
    let parsed_percent = scan
        .fixed32
        .iter()
        .filter(|field| {
            field.path.last() == Some(&1)
                && field.value.is_finite()
                && (0.0..=100.0).contains(&field.value)
        })
        .min_by(|lhs, rhs| {
            lhs.path
                .len()
                .cmp(&rhs.path.len())
                .then(lhs.order.cmp(&rhs.order))
        })
        .map(|field| field.value as f64);
    let reset_fields = scan
        .varints
        .iter()
        .filter_map(|field| {
            let raw = field.value;
            (1_700_000_000..=2_100_000_000)
                .contains(&raw)
                .then_some((field.path.as_slice(), raw as i64))
        })
        .collect::<Vec<_>>();
    let future = reset_fields
        .iter()
        .copied()
        .filter(|(_, date)| *date > now)
        .collect::<Vec<_>>();
    let reset = future
        .iter()
        .find(|(path, _)| *path == [1, 5, 1])
        .or(future.first())
        .map(|(_, date)| *date);
    let has_usage_period = scan.varints.iter().any(|field| {
        field.path.starts_with(&[1, 6]) || (field.path == [1, 8, 1] && matches!(field.value, 1 | 2))
    });
    let percent = match parsed_percent {
        Some(value) => value,
        None if reset.is_some() && has_usage_period && scan.fixed32.is_empty() => 0.0,
        None => return Err(ProviderError::new(ErrorCategory::Error, WEB_SOURCE)),
    };
    Ok(WebBilling {
        used_percent: percent,
        resets_at: reset,
    })
}

fn grpc_status_error(status: i32, message: &str) -> ProviderError {
    let lower = message.to_ascii_lowercase();
    if status == 16
        || (status == 7
            && (lower.contains("unauthenticated")
                || lower.contains("bad-credentials")
                || lower.contains("no-credentials")
                || lower.contains("no credentials")))
    {
        return ProviderError::new(ErrorCategory::AuthRequired, WEB_SOURCE);
    }
    if status == 9 && lower.contains("no personal team") {
        return ProviderError::new(ErrorCategory::Unsupported, WEB_SOURCE);
    }
    if status == 4 || status == 14 {
        return ProviderError::new(ErrorCategory::Unavailable, WEB_SOURCE);
    }
    ProviderError::new(ErrorCategory::Error, WEB_SOURCE)
}

fn grpc_web_data_frames(data: &[u8]) -> Vec<Vec<u8>> {
    let mut frames = Vec::new();
    let mut index = 0;
    while index + 5 <= data.len() {
        let flags = data[index];
        let length = u32::from_be_bytes([
            data[index + 1],
            data[index + 2],
            data[index + 3],
            data[index + 4],
        ]) as usize;
        let start = index + 5;
        let end = start.saturating_add(length);
        if end > data.len() {
            return Vec::new();
        }
        if flags & 0x80 == 0 {
            frames.push(data[start..end].to_vec());
        }
        index = end;
    }
    frames
}

fn grpc_web_trailer_fields(data: &[u8]) -> std::collections::BTreeMap<String, String> {
    let mut fields = std::collections::BTreeMap::new();
    let mut index = 0;
    while index + 5 <= data.len() {
        let flags = data[index];
        let length = u32::from_be_bytes([
            data[index + 1],
            data[index + 2],
            data[index + 3],
            data[index + 4],
        ]) as usize;
        let start = index + 5;
        let end = start.saturating_add(length);
        if end > data.len() {
            break;
        }
        if flags & 0x80 != 0
            && let Ok(text) = std::str::from_utf8(&data[start..end])
        {
            for line in text.split(['\n', '\r']) {
                let Some((key, value)) = line.split_once(':') else {
                    continue;
                };
                fields.insert(key.trim().to_ascii_lowercase(), value.trim().to_owned());
            }
        }
        index = end;
    }
    fields
}

fn looks_like_protobuf(data: &[u8]) -> bool {
    let Some(first) = data.first() else {
        return false;
    };
    let field_number = first >> 3;
    let wire_type = first & 0x07;
    field_number > 0 && matches!(wire_type, 0 | 1 | 2 | 5)
}

#[derive(Clone, Debug, Default)]
struct ProtobufScan {
    fixed32: Vec<Fixed32Field>,
    varints: Vec<VarintField>,
}

#[derive(Clone, Debug)]
struct Fixed32Field {
    path: Vec<u64>,
    value: f32,
    order: usize,
}

#[derive(Clone, Debug)]
struct VarintField {
    path: Vec<u64>,
    value: u64,
}

impl ProtobufScan {
    fn merge(&mut self, other: &Self) {
        self.fixed32.extend(other.fixed32.iter().cloned());
        self.varints.extend(other.varints.iter().cloned());
    }
}

fn scan_protobuf(data: &[u8], depth: usize, path: &[u64]) -> ProtobufScan {
    let mut scan = ProtobufScan::default();
    let mut index = 0;
    let mut order = 0;
    while index < data.len() {
        let field_start = index;
        let Some(key) = read_varint(data, &mut index) else {
            break;
        };
        if key == 0 {
            index = field_start + 1;
            continue;
        }
        let field_number = key >> 3;
        let wire_type = key & 0x07;
        let mut field_path = path.to_vec();
        field_path.push(field_number);
        match wire_type {
            0 => {
                if let Some(value) = read_varint(data, &mut index) {
                    scan.varints.push(VarintField {
                        path: field_path,
                        value,
                    });
                } else {
                    index = field_start + 1;
                }
            }
            1 => {
                if index + 8 > data.len() {
                    break;
                }
                index += 8;
            }
            2 => {
                let Some(length) = read_varint(data, &mut index) else {
                    index = field_start + 1;
                    continue;
                };
                let start = index;
                let end = index.saturating_add(length as usize);
                if end > data.len() {
                    index = field_start + 1;
                    continue;
                }
                if depth < 4 {
                    scan.merge(&scan_protobuf(&data[start..end], depth + 1, &field_path));
                }
                index = end;
            }
            5 => {
                if index + 4 > data.len() {
                    break;
                }
                let bits = u32::from_le_bytes([
                    data[index],
                    data[index + 1],
                    data[index + 2],
                    data[index + 3],
                ]);
                scan.fixed32.push(Fixed32Field {
                    path: field_path,
                    value: f32::from_bits(bits),
                    order,
                });
                order += 1;
                index += 4;
            }
            _ => index = field_start + 1,
        }
    }
    scan
}

fn read_varint(data: &[u8], index: &mut usize) -> Option<u64> {
    let mut value = 0_u64;
    let mut shift = 0;
    while *index < data.len() && shift < 64 {
        let byte = data[*index];
        *index += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browser_session_catalog_and_sso_rules() {
        let spec = ProviderId::Grok
            .metadata()
            .browser_session
            .expect("grok browser session");
        assert_eq!(spec.cookie_names, &["sso", "sso-rw"]);
        assert_eq!(sso_token("sso=session-value"), Some("session-value"));
        assert_eq!(sso_token("sso-rw=alt"), Some("alt"));
        assert!(sso_token("sessionKey=sk-ant-ok").is_none());
    }

    #[test]
    fn parses_grpc_web_percent_and_auth_trailer() {
        let payload = {
            let mut bytes = vec![0x0d, 0x00, 0x00, 0xc8, 0x41];
            let mut frame = vec![0x00];
            frame.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
            frame.append(&mut bytes);
            frame
        };
        let billing = parse_grpc_web_billing(&payload, 1_786_320_000).unwrap();
        assert_eq!(billing.used_percent, 25.0);

        let trailer = b"grpc-status: 16\r\ngrpc-message: no-credentials\r\n";
        let mut failed = vec![0x80];
        failed.extend_from_slice(&(trailer.len() as u32).to_be_bytes());
        failed.extend_from_slice(trailer);
        let error = parse_grpc_web_billing(&failed, 1_786_320_000).unwrap_err();
        assert_eq!(error.category, ErrorCategory::AuthRequired);
    }
}
