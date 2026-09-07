//! Remaining quota and reset copy, in the words every Quota surface prints.
//!
//! `packages/protocol/fixtures/remaining-copy-conformance.json` and
//! `reset-copy-conformance.json` state these rules once; `packages/quota-model`,
//! `packages/apple-shared`, `apps/web/src/lib/format.ts`, and this module all answer them, so
//! a phrase one surface changes cannot drift from the others. This runtime answers for the
//! `quota` command, which prints a window without QuotaBar in front of it.

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;

/// How far remaining/limit may drift from `used_percent` and still be the same quantity.
pub const AMOUNT_OF_LIMIT_PERCENT_TOLERANCE: f64 = 1.0;

/// Whether a reset is stated as a countdown or as the local clock time it lands on.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResetStyle {
    Relative,
    Absolute,
}

/// What is left of a budget, as a percent of it.
pub fn remaining_percent(used_percent: f64) -> f64 {
    (100.0 - used_percent).clamp(0.0, 100.0)
}

/// A wallet: an absolute remaining amount with no budget to be a fraction of.
pub fn is_balance_only(window: &Value) -> bool {
    number(window, "remaining_value").is_some() && number(window, "limit_value").is_none()
}

/// A usd or credits window whose remaining and limit describe the same quantity as
/// `used_percent`. Those print remaining of limit and drop the meter; included dollars that
/// are a different quantity keep it.
pub fn is_amount_of_limit(window: &Value) -> bool {
    let (Some(remaining), Some(limit)) = (
        number(window, "remaining_value"),
        number(window, "limit_value"),
    ) else {
        return false;
    };
    if !(limit > 0.0) {
        return false;
    }
    if !matches!(unit(window), Some("usd" | "credits")) {
        return false;
    }
    let Some(used_percent) = number(window, "used_percent") else {
        return true;
    };
    let from_amount = (remaining / limit * 100.0).clamp(0.0, 100.0);
    (from_amount - remaining_percent(used_percent)).abs() < AMOUNT_OF_LIMIT_PERCENT_TOLERANCE
}

/// Rate-limit and budget meters need a percent bar; wallets and amount-of-limit windows do not.
pub fn shows_percent_meter(window: &Value) -> bool {
    !is_balance_only(window) && !is_amount_of_limit(window)
}

pub fn format_percent(value: f64) -> String {
    let remaining = value.clamp(0.0, 100.0);
    if (remaining.round() - remaining).abs() < 0.05 {
        return format!("{}%", remaining.round() as i64);
    }
    format!("{remaining:.1}%")
}

/// Remaining copy for one window: a remaining percent, a wallet amount, or remaining of limit.
pub fn format_remaining(window: &Value) -> String {
    let remaining_pct = remaining_percent(number(window, "used_percent").unwrap_or(0.0));
    if is_amount_of_limit(window)
        && let (Some(remaining), Some(limit)) = (
            number(window, "remaining_value"),
            number(window, "limit_value"),
        )
    {
        if unit(window) == Some("usd") {
            return format!("{} of {}", usd(remaining), usd(limit));
        }
        return format!("{remaining:.2} of {limit:.2} credits");
    }
    let Some(absolute) = absolute_remaining(window) else {
        return format_percent(remaining_pct);
    };
    if is_balance_only(window) {
        return absolute;
    }
    format!("{} · {}", format_percent(remaining_pct), absolute)
}

/// The title a window prints, which drops the unit a wallet already states in its amount.
pub fn format_window_title(title: &str, window: &Value) -> String {
    if is_balance_only(window) && title.to_lowercase().starts_with("balance") {
        return "Balance".to_owned();
    }
    title.to_owned()
}

/// The phrase under a window that still has a future refill, or `None` once it has passed.
///
/// Minutes round up, and anything under a minute still reads as one. Past a day the countdown
/// gives way to the local weekday and 24-hour time, and past a week to the month and day;
/// absolute always starts there.
pub fn reset_copy<Zone: TimeZone>(
    resets_at: DateTime<Utc>,
    now: DateTime<Utc>,
    zone: &Zone,
    style: ResetStyle,
) -> Option<String>
where
    Zone::Offset: std::fmt::Display,
{
    let seconds = (resets_at - now).num_milliseconds() as f64 / 1_000.0;
    if !(seconds > 0.0) {
        return None;
    }
    if style == ResetStyle::Relative {
        let whole_minutes = (seconds / 60.0).ceil().max(1.0) as i64;
        if whole_minutes < 60 {
            return Some(format!("Resets in {whole_minutes}m"));
        }
        if seconds < 86_400.0 {
            let mut hours = (seconds / 3_600.0).floor() as i64;
            let mut minutes = ((seconds - hours as f64 * 3_600.0) / 60.0).ceil() as i64;
            if minutes == 60 {
                hours += 1;
                minutes = 0;
            }
            return Some(if minutes == 0 {
                format!("Resets in {hours}h")
            } else {
                format!("Resets in {hours}h {minutes}m")
            });
        }
    }
    let local = resets_at.with_timezone(zone);
    if seconds < 604_800.0 {
        return Some(format!("Resets {}", local.format("%a %H:%M")));
    }
    Some(format!("Resets {}", local.format("%b %-d")))
}

fn absolute_remaining(window: &Value) -> Option<String> {
    let remaining = number(window, "remaining_value")?;
    match unit(window) {
        Some("usd") => Some(usd(remaining)),
        Some("credits") => Some(format!("{remaining:.2} credits")),
        Some("count") => Some(format!("{remaining:.0}")),
        _ if is_balance_only(window) => Some(format!("{remaining:.2}")),
        _ => None,
    }
}

fn usd(value: f64) -> String {
    format!("${value:.2}")
}

fn number(window: &Value, key: &str) -> Option<f64> {
    window.get(key)?.as_f64()
}

fn unit(window: &Value) -> Option<&str> {
    window.get("value_unit")?.as_str()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    const REMAINING_FIXTURE: &str =
        include_str!("../../protocol/fixtures/remaining-copy-conformance.json");
    const RESET_FIXTURE: &str = include_str!("../../protocol/fixtures/reset-copy-conformance.json");

    #[test]
    fn answers_every_remaining_copy_case() {
        let fixture: Value = serde_json::from_str(REMAINING_FIXTURE).expect("fixture parses");
        assert_eq!(
            fixture["amount_of_limit_percent_tolerance"].as_f64(),
            Some(AMOUNT_OF_LIMIT_PERCENT_TOLERANCE)
        );
        let cases = fixture["cases"].as_array().expect("cases");
        assert!(cases.len() > 1);
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let window = &case["window"];
            assert_eq!(format_remaining(window), case["expected"], "{name} copy");
            assert_eq!(
                shows_percent_meter(window),
                case["shows_percent_meter"],
                "{name} meter"
            );
            assert_eq!(
                is_balance_only(window),
                case["is_balance_only"],
                "{name} balance"
            );
            assert_eq!(
                is_amount_of_limit(window),
                case["is_amount_of_limit"],
                "{name} amount"
            );
        }
    }

    #[test]
    fn answers_every_reset_copy_case_relative_and_absolute() {
        let fixture: Value = serde_json::from_str(RESET_FIXTURE).expect("fixture parses");
        let cases = fixture["cases"].as_array().expect("cases");
        assert!(cases.len() > 1);
        for case in cases {
            let name = case["name"].as_str().expect("name");
            let now = instant(&case["now"]);
            let resets_at = DateTime::parse_from_rfc3339(case["resets_at"].as_str().expect("at"))
                .expect("resets_at parses");
            // The fixture pins both instants with the offset the reader is in, so the reset's
            // own offset is that local zone.
            let zone: FixedOffset = *resets_at.offset();
            let resets_at = resets_at.with_timezone(&Utc);
            for (style, expected) in [
                (ResetStyle::Relative, &case["relative"]),
                (ResetStyle::Absolute, &case["absolute"]),
            ] {
                let answer = reset_copy(resets_at, now, &zone, style);
                match expected.as_str() {
                    Some(text) => assert_eq!(answer.as_deref(), Some(text), "{name} {style:?}"),
                    None => assert_eq!(answer, None, "{name} {style:?}"),
                }
            }
        }
    }

    fn instant(value: &Value) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(value.as_str().expect("instant"))
            .expect("instant parses")
            .with_timezone(&Utc)
    }
}
