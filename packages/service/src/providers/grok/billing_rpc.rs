//! grok.com's own gRPC-web billing RPC, called with the local OAuth access token.
//!
//! This is the last rung of Grok's ladder: it needs no credential the proxy did not already
//! have, and it answers when `cli-chat-proxy.grok.com` cannot be reached at all.

use std::time::Duration;

use super::super::common::{
    CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient, ProviderError, QuotaWindow,
    clamp_percent,
};

pub const SOURCE: &str = "grok_billing_rpc";
const BILLING_RPC_URL: &str = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";
const GRPC_EMPTY_FRAME: &[u8] = &[0x00, 0x00, 0x00, 0x00, 0x00];

/// The billing-cycle window from grok.com's gRPC-web billing RPC using the local
/// OAuth access token. CodexBar's last Automatic step.
pub(super) fn bearer_billing_window(
    access_token: &str,
    context: &CollectionContext,
) -> Result<QuotaWindow, ProviderError> {
    let bearer = format!("Bearer {access_token}");
    let billing = fetch_billing(&bearer, context, HTTP_TIMEOUT)?;
    Ok(billing_window(&billing, context.observed_unix()))
}

fn fetch_billing(
    bearer: &str,
    context: &CollectionContext,
    timeout: Duration,
) -> Result<Billing, ProviderError> {
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let headers = [
        ("Authorization", bearer),
        ("Origin", "https://grok.com"),
        ("Referer", "https://grok.com/?_s=usage"),
        ("Accept", "*/*"),
        ("Content-Type", "application/grpc-web+proto"),
        ("x-grpc-web", "1"),
        ("x-user-agent", "connect-es/2.1.1"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, body) = client.post_bytes(BILLING_RPC_URL, &headers, GRPC_EMPTY_FRAME, SOURCE)?;
    parse_grpc_web_billing(&body, context.observed_unix())
}

#[derive(Debug)]
struct Billing {
    used_percent: f64,
    resets_at: Option<i64>,
}

/// The RPC exposes only the reset instant, not the cadence. A reset 20–45 days out
/// reads as monthly; anything nearer is the weekly credit pool, even late in the
/// week (CodexBar's untyped-window rule), and no reset at all stays generic.
fn billing_window(billing: &Billing, now: i64) -> QuotaWindow {
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

fn parse_grpc_web_billing(data: &[u8], now: i64) -> Result<Billing, ProviderError> {
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
        return Err(ProviderError::new(ErrorCategory::Error, SOURCE));
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
        None => return Err(ProviderError::new(ErrorCategory::Error, SOURCE)),
    };
    Ok(Billing {
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
        return ProviderError::new(ErrorCategory::AuthRequired, SOURCE);
    }
    if status == 9 && lower.contains("no personal team") {
        return ProviderError::new(ErrorCategory::Unsupported, SOURCE);
    }
    if status == 4 || status == 14 {
        return ProviderError::new(ErrorCategory::Unavailable, SOURCE);
    }
    ProviderError::new(ErrorCategory::Error, SOURCE)
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
