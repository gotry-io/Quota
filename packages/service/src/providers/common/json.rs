use base64::Engine as _;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

pub fn number(value: Option<&Value>) -> Option<f64> {
    match value {
        Some(Value::Number(number)) => number.as_f64().filter(|value| value.is_finite()),
        Some(Value::String(value)) if !value.trim().is_empty() => value
            .trim()
            .parse::<f64>()
            .ok()
            .filter(|value| value.is_finite()),
        _ => None,
    }
}

pub fn clamp_percent(value: f64) -> f64 {
    if !value.is_finite() {
        0.0
    } else {
        value.clamp(0.0, 100.0)
    }
}

pub fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

pub fn unix_seconds_to_iso(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let remainder = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        remainder / 3600,
        (remainder % 3600) / 60,
        remainder % 60
    )
}

/// Percent-encodes `value` for a URL query or path segment, keeping only the
/// RFC 3986 unreserved set.
pub fn url_encode(value: &str) -> String {
    value.bytes().fold(String::new(), |mut result, byte| {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            result.push(byte as char);
        } else {
            result.push_str(&format!("%{byte:02X}"));
        }
        result
    })
}

/// A lowercase ASCII-alphanumeric identifier: every other run of characters
/// collapses to one `separator`, and leading and trailing separators are dropped.
pub fn slug(value: &str, separator: char) -> String {
    let mut output = String::new();
    for character in value.chars() {
        if character.is_ascii_alphanumeric() {
            output.push(character.to_ascii_lowercase());
        } else if !output.is_empty() && !output.ends_with(separator) {
            output.push(separator);
        }
    }
    while output.ends_with(separator) {
        output.pop();
    }
    output
}

/// The claim set of a JWT, without verifying its signature. Callers use it only
/// for locally issued provider tokens whose bearer already proves possession.
pub fn decode_jwt_payload(token: &str) -> Option<Value> {
    let payload = token.split('.').nth(1)?;
    let mut normalized = payload.replace('-', "+").replace('_', "/");
    while !normalized.len().is_multiple_of(4) {
        normalized.push('=');
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(normalized)
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Who a locally held bearer token says it belongs to, when it is a JWT that says.
///
/// A stored browser session is the one credential whose provider response names nobody, so
/// without this every cookie on a machine hashes to one fingerprint and two accounts read as
/// one. The signature is not checked — the bearer already proves possession, and a forged
/// subject would only give this device a second fingerprint for an account it cannot read.
pub fn jwt_subject(token: &str) -> Option<String> {
    let payload = decode_jwt_payload(token)?;
    ["sub", "user_id", "userId", "uid"]
        .into_iter()
        .find_map(|claim| string(obj_get(&payload, claim)))
        .map(|value| value.trim().to_owned())
        .filter(|value| {
            !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
        })
}

pub fn parse_date(value: Option<&Value>) -> Option<i64> {
    match value {
        Some(Value::Number(number)) => number.as_f64().and_then(parse_numeric_date),
        Some(Value::String(value)) => {
            let value = value.trim();
            if value.is_empty() {
                return None;
            }
            if let Ok(number) = value.parse::<f64>() {
                return parse_numeric_date(number);
            }
            parse_rfc3339(value)
        }
        _ => None,
    }
}

fn parse_numeric_date(value: f64) -> Option<i64> {
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    Some(if value > 10_000_000_000.0 {
        (value / 1000.0).floor() as i64
    } else {
        value.floor() as i64
    })
}

pub(super) fn parse_rfc3339(value: &str) -> Option<i64> {
    let (date, time_and_zone) = value.split_once('T').or_else(|| value.split_once(' '))?;
    let mut date_parts = date.split('-');
    let year: i32 = date_parts.next()?.parse().ok()?;
    let month: u32 = date_parts.next()?.parse().ok()?;
    let day: u32 = date_parts.next()?.parse().ok()?;
    let (time, offset) = if let Some(time) = time_and_zone.strip_suffix('Z') {
        (time, 0i64)
    } else {
        let marker = time_and_zone.rfind(['+', '-'])?;
        let (time, zone) = time_and_zone.split_at(marker);
        let sign = if zone.starts_with('-') { -1 } else { 1 };
        let mut parts = zone[1..].split(':');
        let hours: i64 = parts.next()?.parse().ok()?;
        let minutes: i64 = parts.next().unwrap_or("0").parse().ok()?;
        (time, sign * (hours * 3600 + minutes * 60))
    };
    let mut time_parts = time.split(':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let second = time_parts.next()?.split('.').next()?.parse::<i64>().ok()?;
    if month == 0 || month > 12 || day == 0 || day > 31 || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset)
}

fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let year = year - i32::from(month <= 2);
    let era = (year as i64).div_euclid(400);
    let year_of_era = year as i64 - era * 400;
    let month = month as i64;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day as i64 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }).div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_part = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_part + 2) / 5 + 1;
    let month = month_part + if month_part < 10 { 3 } else { -9 };
    (
        year as i32 + i32::from(month <= 2),
        month as u32,
        day as u32,
    )
}

pub fn duration_seconds(start: Option<i64>, end: Option<i64>) -> Option<u64> {
    let seconds = end?.checked_sub(start?)?;
    (seconds >= 0).then_some(seconds as u64)
}

pub fn obj_get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.as_object()?.get(key)
}

pub fn obj_get_any<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| obj_get(value, key))
}
