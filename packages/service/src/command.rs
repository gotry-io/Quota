//! `quota` — what this Mac already knows, printed in a terminal.
//!
//! The command reads the last valid state QuotaBar published and prints it. It starts no
//! collection, opens no credential, and holds no lock, so running it says nothing about this
//! Mac that QuotaBar was not already showing
//! ([ADR 0046](../../../docs/decisions/0046-a-read-only-quota-command.md)).

use std::collections::BTreeMap;
use std::process::ExitCode;

use chrono::{DateTime, Utc};
use chrono_tz::Tz;
use quota_service::catalog::ProviderId;
use quota_service::config::default_state_root;
use quota_service::copy::{ResetStyle, format_remaining, format_window_title, reset_copy};
use quota_service::protocol::UsagePeriod;
use quota_service::readonly::{ReadOnlyState, ReadOnlyStateError};
use serde_json::Value;

const USAGE: &str = "\
Usage:
  quota status [--json]
  quota usage [--period today|7d|30d] [--json]

Prints what QuotaBar last collected on this Mac. It reads local state only.";

/// How many models one period names in the terminal, largest first.
const TOP_MODELS: usize = 5;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(Failure::State(error)) => {
            eprintln!("{}", error.message());
            ExitCode::FAILURE
        }
        Err(Failure::Usage(message)) => {
            eprintln!("{message}\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

enum Failure {
    State(ReadOnlyStateError),
    Usage(String),
}

fn run(arguments: &[String]) -> Result<String, Failure> {
    let mut rest = arguments.iter().map(String::as_str);
    let command = rest.next().unwrap_or("");
    let options = Options::parse(rest)?;
    let state = open_state()?;
    match command {
        "status" => status(&state, options.json),
        "usage" => usage(&state, options.period()?, options.json),
        "" | "-h" | "--help" => Err(Failure::Usage("Name a command.".to_owned())),
        other => Err(Failure::Usage(format!("Unknown command: {other}"))),
    }
}

struct Options {
    json: bool,
    period: Option<String>,
}

impl Options {
    fn parse<'a>(arguments: impl Iterator<Item = &'a str>) -> Result<Self, Failure> {
        let mut options = Self {
            json: false,
            period: None,
        };
        let mut arguments = arguments.peekable();
        while let Some(argument) = arguments.next() {
            match argument {
                "--json" => options.json = true,
                "--period" => {
                    let value = arguments
                        .next()
                        .ok_or_else(|| Failure::Usage("--period needs a period.".to_owned()))?;
                    options.period = Some(value.to_owned());
                }
                other => return Err(Failure::Usage(format!("Unknown option: {other}"))),
            }
        }
        Ok(options)
    }

    /// The period a Usage read asks for. Today is what a person standing at a terminal means.
    fn period(&self) -> Result<UsagePeriod, Failure> {
        match self.period.as_deref() {
            None | Some("today") => Ok(UsagePeriod::Today),
            Some("7d") => Ok(UsagePeriod::Last7Days),
            Some("30d") => Ok(UsagePeriod::Last30Days),
            Some(other) => Err(Failure::Usage(format!("Unknown period: {other}"))),
        }
    }
}

fn open_state() -> Result<ReadOnlyState, Failure> {
    let root = default_state_root().ok_or(Failure::State(ReadOnlyStateError::Missing))?;
    ReadOnlyState::open(root).map_err(Failure::State)
}

/// One line per provider: what is left of each window, and when it refills.
///
/// The wording is the shared one every Quota surface prints, so a window here and the same
/// window in the menu bar cannot say different things
/// (`packages/protocol/fixtures/remaining-copy-conformance.json`).
fn status(state: &ReadOnlyState, json: bool) -> Result<String, Failure> {
    let overview = state.overview().map_err(Failure::State)?;
    if json {
        return Ok(render_json(&overview));
    }
    if overview.is_empty() {
        return Ok("No quota has been collected on this Mac yet.".to_owned());
    }
    let now = Utc::now();
    let zone = local_timezone();
    Ok(overview
        .iter()
        .map(|item| status_line(&item.snapshot, now, &zone))
        .collect::<Vec<_>>()
        .join("\n"))
}

fn status_line(snapshot: &Value, now: DateTime<Utc>, zone: &Tz) -> String {
    let provider = snapshot
        .get("provider")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let name = ProviderId::parse(provider)
        .map(|id| id.metadata().display_name)
        .unwrap_or(provider);
    let windows = snapshot
        .get("windows")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    if windows.is_empty() {
        return format!("{name}  No windows");
    }
    let printed = windows
        .iter()
        .map(|window| window_phrase(window, now, zone))
        .collect::<Vec<_>>()
        .join("  ·  ");
    format!("{name}  {printed}")
}

fn window_phrase(window: &Value, now: DateTime<Utc>, zone: &Tz) -> String {
    let title = window
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let phrase = format!(
        "{} {}",
        format_window_title(title, window),
        format_remaining(window)
    );
    let Some(reset) = window
        .get("resets_at")
        .and_then(Value::as_str)
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .and_then(|at| reset_copy(at.with_timezone(&Utc), now, zone, ResetStyle::Relative))
    else {
        return phrase;
    };
    format!("{phrase} · {reset}")
}

/// This Mac's own Usage for one period, as the service already folded it.
///
/// The stored period is read as the JSON it is rather than decoded into the summary type: it
/// is a disposable cache the service rewrites on every scan, and the command prints the fold
/// it finds rather than making a second one out of the same rows
/// ([ADR 0040](../../../docs/decisions/0040-a-period-is-folded-where-its-days-already-are.md)).
fn usage(state: &ReadOnlyState, period: UsagePeriod, json: bool) -> Result<String, Failure> {
    let stored = state.local_usage_period(period).map_err(Failure::State)?;
    if json {
        return Ok(render_json(&stored));
    }
    let Some(stored) = stored else {
        return Ok("No Usage has been folded on this Mac yet.".to_owned());
    };
    let summary = &stored["usage"];
    let totals = &summary["totals"];
    let mut lines = vec![format!(
        "{} {}  {} tokens · {} messages · {}{}",
        period_title(period),
        printed_range(&stored["range"]),
        count(totals["total_tokens"].as_u64().unwrap_or_default()),
        count(totals["messages"].as_u64().unwrap_or_default()),
        cost(&summary["cost"]),
        if stored["incomplete"] == Value::Bool(true) {
            " · still scanning"
        } else {
            ""
        },
    )];
    let models = top_models(summary);
    if models.is_empty() {
        lines.push("  No model has been attributed yet.".to_owned());
    }
    let width = models
        .iter()
        .map(|(model, _)| model.chars().count())
        .max()
        .unwrap_or(0);
    for (model, tokens) in models {
        lines.push(format!("  {model:width$}  {}", count(tokens)));
    }
    Ok(lines.join("\n"))
}

/// The days a period covers, which is one date when the period is one day.
fn printed_range(range: &Value) -> String {
    let from = range["from"].as_str().unwrap_or_default();
    let to = range["to"].as_str().unwrap_or_default();
    if from == to {
        return from.to_owned();
    }
    format!("{from} – {to}")
}

/// The models of a period, largest first, folded across the agents that used them.
///
/// A model is one thing whichever agent reached it, and a terminal line naming the same model
/// twice would be reporting the tree rather than the answer.
fn top_models(summary: &Value) -> Vec<(String, u64)> {
    let mut totals: BTreeMap<String, u64> = BTreeMap::new();
    for agent in summary["agents"].as_array().into_iter().flatten() {
        for provider in agent["providers"].as_array().into_iter().flatten() {
            for model in provider["models"].as_array().into_iter().flatten() {
                let Some(name) = model["model"].as_str() else {
                    continue;
                };
                *totals.entry(name.to_owned()).or_default() +=
                    model["totals"]["total_tokens"].as_u64().unwrap_or_default();
            }
        }
    }
    let mut models: Vec<(String, u64)> = totals.into_iter().collect();
    models.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    models.truncate(TOP_MODELS);
    models
}

const fn period_title(period: UsagePeriod) -> &'static str {
    match period {
        UsagePeriod::Today => "Today",
        UsagePeriod::Last7Days => "Last 7 days",
        UsagePeriod::Last30Days => "Last 30 days",
        UsagePeriod::All => "All time",
    }
}

/// `--json` is the state itself, so a script reads exactly what QuotaBar reads over IPC.
fn render_json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| "null".to_owned())
}

fn count(value: u64) -> String {
    let digits = value.to_string();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    grouped
}

/// The same amount `/my/usage` prints: microdollars rounded to cents, and `≥` when only part
/// of the period could be priced.
fn cost(cost: &Value) -> String {
    let Some(amount) = cost["amount_microusd"]
        .as_str()
        .and_then(|value| value.parse::<u128>().ok())
    else {
        return "no cost".to_owned();
    };
    let cents = (amount + 5_000) / 10_000;
    let prefix = if cost["status"] == Value::String("partial".to_owned()) {
        "≥ "
    } else {
        ""
    };
    format!(
        "{prefix}${}.{:02}",
        count((cents / 100) as u64),
        cents % 100
    )
}

fn local_timezone() -> Tz {
    std::env::var("TZ")
        .ok()
        .and_then(|value| value.parse::<Tz>().ok())
        .or_else(|| {
            iana_time_zone::get_timezone()
                .ok()
                .and_then(|value| value.parse::<Tz>().ok())
        })
        .unwrap_or(Tz::UTC)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 7, 21, 0, 0).unwrap()
    }

    #[test]
    fn a_status_line_names_the_provider_then_each_window_in_the_shared_words() {
        let snapshot = json!({
            "provider": "codex",
            "windows": [
                {
                    "id": "five_hour",
                    "title": "5 Hours",
                    "used_percent": 38,
                    "resets_at": "2026-09-08T00:12:00Z",
                },
                { "id": "weekly", "title": "Weekly", "used_percent": 82 },
            ],
        });

        assert_eq!(
            status_line(&snapshot, now(), &Tz::UTC),
            "Codex  5 Hours 62% · Resets in 3h 12m  ·  Weekly 18%"
        );
    }

    #[test]
    fn a_window_whose_reset_has_passed_states_only_what_is_left() {
        let snapshot = json!({
            "provider": "grok",
            "windows": [{
                "id": "weekly",
                "title": "Weekly",
                "used_percent": 51,
                "resets_at": "2026-09-07T20:59:00Z",
            }],
        });

        assert_eq!(status_line(&snapshot, now(), &Tz::UTC), "Grok  Weekly 49%");
    }

    #[test]
    fn a_provider_this_build_does_not_know_prints_the_id_it_was_given() {
        let snapshot = json!({ "provider": "someone-else", "windows": [] });
        assert_eq!(
            status_line(&snapshot, now(), &Tz::UTC),
            "someone-else  No windows"
        );
    }

    #[test]
    fn models_fold_across_agents_and_keep_the_largest_first() {
        let summary = json!({
            "agents": [
                {
                    "providers": [{
                        "models": [
                            { "model": "claude-opus-5", "totals": { "total_tokens": 10 } },
                            { "model": "gpt-5.6-sol", "totals": { "total_tokens": 30 } },
                        ],
                    }],
                },
                {
                    "providers": [{
                        "models": [
                            { "model": "claude-opus-5", "totals": { "total_tokens": 40 } },
                        ],
                    }],
                },
            ],
        });

        assert_eq!(
            top_models(&summary),
            vec![
                ("claude-opus-5".to_owned(), 50),
                ("gpt-5.6-sol".to_owned(), 30)
            ]
        );
    }

    #[test]
    fn a_partly_priced_period_says_the_amount_is_a_floor() {
        assert_eq!(
            cost(&json!({ "amount_microusd": "1052000", "status": "complete" })),
            "$1.05"
        );
        assert_eq!(
            cost(&json!({ "amount_microusd": "863325000", "status": "partial" })),
            "≥ $863.33"
        );
        assert_eq!(
            cost(&json!({ "amount_microusd": null, "status": "unavailable" })),
            "no cost"
        );
    }

    #[test]
    fn a_period_is_one_date_or_the_days_it_spans() {
        assert_eq!(
            printed_range(&json!({ "from": "2026-09-06", "to": "2026-09-06" })),
            "2026-09-06"
        );
        assert_eq!(
            printed_range(&json!({ "from": "2026-08-31", "to": "2026-09-06" })),
            "2026-08-31 – 2026-09-06"
        );
    }

    #[test]
    fn counts_are_grouped_rather_than_rounded() {
        assert_eq!(count(0), "0");
        assert_eq!(count(999), "999");
        assert_eq!(count(1_204_620), "1,204,620");
    }

    #[test]
    fn the_period_option_names_the_three_windows_a_person_can_ask_for() {
        let period = |value: Option<&str>| {
            Options {
                json: false,
                period: value.map(str::to_owned),
            }
            .period()
        };
        assert_eq!(period(None).ok(), Some(UsagePeriod::Today));
        assert_eq!(period(Some("today")).ok(), Some(UsagePeriod::Today));
        assert_eq!(period(Some("7d")).ok(), Some(UsagePeriod::Last7Days));
        assert_eq!(period(Some("30d")).ok(), Some(UsagePeriod::Last30Days));
        // `all` is folded for the app, not offered here: a terminal asks for a window.
        assert!(period(Some("all")).is_err());
    }
}
