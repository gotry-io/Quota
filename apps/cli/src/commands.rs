use std::io::{self, BufRead};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::thread;
use std::time::{Duration, Instant};

use quota_service::catalog::ProviderId;
use quota_service::config::default_state_root;
use quota_service::protocol::{
    ComponentName, ComponentStatus, IpcEvent, IpcRequest, Operation, RequestMessageType,
};
use quota_service::providers::source_display_name;
use quota_service::relay::{AccountManager, RelayClient, local_device_display_name};
use quota_service::service::backend::NativeBackend;
use quota_service::service::{BackendError, EventSink, LocalService, validate_provider_config};
use quota_service::state::{StateStore, now_rfc3339};
use serde_json::{Value, json};

use crate::parser::{
    self, Command, ConfigCommand, OutputFormat, OutputOptions, ProviderSelection, StatusOptions,
    SummaryOptions,
};

const QUOTA_CLI_VERSION: &str = env!("CARGO_PKG_VERSION");
const REFRESH_TIMEOUT: Duration = Duration::from_secs(90);

pub trait CliOutput {
    fn stdout(&mut self, message: &str);
    fn stderr(&mut self, message: &str);
}

#[derive(Default)]
pub struct BufferOutput {
    pub stdout: Vec<String>,
    pub stderr: Vec<String>,
}

impl CliOutput for BufferOutput {
    fn stdout(&mut self, message: &str) {
        self.stdout.push(message.to_owned());
    }

    fn stderr(&mut self, message: &str) {
        self.stderr.push(message.to_owned());
    }
}

struct NoopSink;

impl EventSink for NoopSink {
    fn event(&self, _: IpcEvent) {}
}

struct ServiceContext {
    state: Arc<StateStore>,
    relay: Arc<RelayClient>,
    backend: Arc<NativeBackend>,
    service: LocalService,
}

impl Drop for ServiceContext {
    fn drop(&mut self) {
        self.service.shutdown();
    }
}

#[derive(Clone, Copy)]
struct Failure;

pub fn run_cli<I, T>(args: I, output: &mut dyn CliOutput) -> i32
where
    I: IntoIterator<Item = T>,
    T: Into<String>,
{
    run_cli_with_cancel(args, output, &AtomicBool::new(false))
}

pub fn run_cli_with_cancel<I, T>(args: I, output: &mut dyn CliOutput, cancel: &AtomicBool) -> i32
where
    I: IntoIterator<Item = T>,
    T: Into<String>,
{
    let command = match parser::parse(args) {
        Ok(command) => command,
        Err(error) => {
            output.stderr(&error.0);
            return 2;
        }
    };

    match command {
        Command::Help => {
            output.stdout(parser::usage());
            0
        }
        Command::Version => {
            output.stdout(&format!("QuotaCLI {QUOTA_CLI_VERSION}"));
            0
        }
        Command::Status(options) => run_status(options, output),
        Command::Doctor(options) => run_doctor(options, output),
        Command::Login { output: options } => run_login(options, output, cancel),
        Command::Logout(options) => run_logout(options, output),
        Command::AuthStatus(options) => run_auth_status(options, output),
        Command::Sync(options) => run_sync(options, output),
        Command::AccountSummary(options) => run_account_summary(options, output),
        Command::Config(command) => run_config(command, output),
    }
}

fn open_context() -> Result<ServiceContext, Failure> {
    let root = default_state_root().ok_or(Failure)?;
    let state = Arc::new(StateStore::open(root).map_err(|_| Failure)?);
    let relay = Arc::new(RelayClient::new().map_err(|_| Failure)?);
    let backend = Arc::new(NativeBackend::new(
        state.clone(),
        relay.clone(),
        "QuotaCLI",
        QUOTA_CLI_VERSION,
    ));
    let service = LocalService::new(state.clone(), Arc::new(NoopSink), backend.clone());
    Ok(ServiceContext {
        state,
        relay,
        backend,
        service,
    })
}

fn invoke(
    context: &ServiceContext,
    operation: Operation,
    payload: Value,
) -> Result<Value, Failure> {
    let response = context.service.handle(IpcRequest {
        message_type: RequestMessageType::Request,
        request_id: format!("cli-{}", std::process::id()),
        operation,
        payload,
    });
    if response.error.is_some() {
        return Err(Failure);
    }
    response.result.ok_or(Failure)
}

fn run_status(options: StatusOptions, output: &mut dyn CliOutput) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not read local quota state.",
            );
        }
    };
    let providers = match options.providers {
        ProviderSelection::Configured => match context.backend.configured_providers() {
            Ok(providers) => providers,
            Err(_) => {
                return report_failure(
                    Failure,
                    output,
                    "QuotaCLI could not discover local provider credentials.",
                );
            }
        },
        ProviderSelection::All => ProviderId::ALL.to_vec(),
        ProviderSelection::Explicit(providers) => providers,
    };
    let value = match context
        .backend
        .collect_quota_for(&providers, Arc::new(AtomicBool::new(false)))
    {
        Ok(value) => value,
        Err(_) => {
            return report_failure(
                Failure,
                output,
                "QuotaCLI could not collect local provider quota. Run `quotacli doctor` for setup details.",
            );
        }
    };
    let cache = match load_cache(&context) {
        Ok(cache) => cache,
        Err(_) => {
            return report_failure(
                Failure,
                output,
                "QuotaCLI could not read local cache state.",
            );
        }
    };
    if options.output.format == OutputFormat::Json {
        write_json(output, &merge_cache(&value, &cache), options.output.pretty);
    } else {
        render_cache_text(&cache, output);
        render_status_text(&value, output);
    }
    report_exit_code(&value)
}

fn render_status_text(value: &Value, output: &mut dyn CliOutput) {
    let Some(results) = value.get("results").and_then(Value::as_array) else {
        output.stdout("No local quota report is available.");
        return;
    };
    if results.is_empty() {
        output.stdout("No configured providers found. Run `quotacli doctor` for setup details.");
        return;
    }
    for result in results {
        let provider = result
            .get("provider")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let outcome = result
            .get("outcome")
            .and_then(Value::as_str)
            .unwrap_or("error");
        let snapshots = result
            .get("snapshots")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        if snapshots.is_empty() {
            // Which source failed, and what to do about it: "codex unavailable" alone
            // leaves the reader with nothing to go and fix.
            let source = failing_source(result)
                .map(|source_id| format!("\t{}", source_display_name(source_id)))
                .unwrap_or_default();
            let message = result
                .get("message")
                .and_then(Value::as_str)
                .map(|message| format!("\t{message}"))
                .unwrap_or_default();
            output.stdout(&format!("{provider}\t{outcome}{source}{message}"));
            continue;
        }
        for snapshot in snapshots {
            let label = snapshot
                .get("account")
                .and_then(|account| account.get("label"))
                .and_then(Value::as_str);
            let status = snapshot
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or(outcome);
            output.stdout(&match label {
                Some(label) => format!("{provider}\t{label}\t{status}"),
                None => format!("{provider}\t{status}"),
            });
            if let Some(windows) = snapshot.get("windows").and_then(Value::as_array) {
                for window in windows {
                    let title = window
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or("Quota");
                    let remaining = window
                        .get("used_percent")
                        .and_then(Value::as_f64)
                        .map(|used| (100.0 - used).clamp(0.0, 100.0));
                    if let Some(remaining) = remaining {
                        output.stdout(&format!("  {title}\t{remaining:.0}%"));
                    }
                }
            }
        }
    }
}

/// The source whose failure decided this result: the last one that did not answer.
fn failing_source(result: &Value) -> Option<&str> {
    result
        .get("sources")
        .and_then(Value::as_array)?
        .iter()
        .rev()
        .find(|source| source.get("outcome").and_then(Value::as_str) != Some("success"))?
        .get("source_id")
        .and_then(Value::as_str)
}

fn report_exit_code(value: &Value) -> i32 {
    if value
        .get("results")
        .and_then(Value::as_array)
        .filter(|results| !results.is_empty())
        .is_some_and(|results| {
            results
                .iter()
                .all(|result| result.get("outcome").and_then(Value::as_str) == Some("success"))
        })
    {
        0
    } else {
        1
    }
}

fn run_doctor(options: OutputOptions, output: &mut dyn CliOutput) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not complete local diagnostics.",
            );
        }
    };
    let report = match invoke(&context, Operation::Diagnose, json!({})) {
        Ok(report) => report,
        Err(_) => {
            return report_failure(
                Failure,
                output,
                "QuotaCLI could not complete local diagnostics.",
            );
        }
    };
    let cache = match load_cache(&context) {
        Ok(cache) => cache,
        Err(_) => {
            return report_failure(
                Failure,
                output,
                "QuotaCLI could not read local cache state.",
            );
        }
    };
    if options.format == OutputFormat::Json {
        write_json(output, &merge_cache(&report, &cache), options.pretty);
    } else {
        render_cache_text(&cache, output);
        render_diagnostics_text(&report, output);
    }
    diagnostics_exit_code(&report)
}

fn render_diagnostics_text(report: &Value, output: &mut dyn CliOutput) {
    let summary = report.get("summary");
    let field = |value: Option<&Value>, key: &str| -> String {
        value
            .and_then(|value| value.get(key))
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned()
    };
    output.stdout(&format!("Diagnostics: {}", field(summary, "operation")));
    output.stdout(&format!("Attention: {}", field(summary, "attention")));
    if let Some(schema_version) = report.get("schema_version").and_then(Value::as_u64) {
        output.stdout(&format!("Schema version: {schema_version}"));
    }
    if let Some(generated_at) = report.get("generated_at").and_then(Value::as_str) {
        output.stdout(&format!("Generated at: {generated_at}"));
    }
    if let Some(client) = report.get("client") {
        output.stdout(&format!(
            "Client: {} {}",
            field(Some(client), "name"),
            field(Some(client), "version")
        ));
    }

    output.stdout("Surfaces:");
    match report.get("surfaces").and_then(Value::as_array) {
        None => output.stdout("  unavailable"),
        Some(surfaces) => {
            for surface in surfaces {
                let last_success = surface
                    .get("last_success_at")
                    .and_then(Value::as_str)
                    .map(|value| format!("\tlast_success_at={value}"))
                    .unwrap_or_default();
                output.stdout(&format!(
                    "  {}\t{}\tdata={}{}\trecovery={}\t{}",
                    field(Some(surface), "id"),
                    field(Some(surface), "status"),
                    field(Some(surface), "data"),
                    last_success,
                    field(Some(surface), "recovery"),
                    field(Some(surface), "message"),
                ));
            }
        }
    }

    output.stdout("Sources:");
    match report.get("sources").and_then(Value::as_array) {
        None => output.stdout("  unavailable"),
        Some(sources) if sources.is_empty() => output.stdout("  none"),
        Some(sources) => {
            for source in sources {
                let source_id = source
                    .get("source_id")
                    .and_then(Value::as_str)
                    .map(|value| format!("/{value}"))
                    .unwrap_or_default();
                let code = source
                    .get("code")
                    .and_then(Value::as_str)
                    .map(|value| format!("\tcode={value}"))
                    .unwrap_or_default();
                let last_attempt = source
                    .get("last_attempt_at")
                    .and_then(Value::as_str)
                    .map(|value| format!("\tlast_attempt_at={value}"))
                    .unwrap_or_default();
                let last_success = source
                    .get("last_success_at")
                    .and_then(Value::as_str)
                    .map(|value| format!("\tlast_success_at={value}"))
                    .unwrap_or_default();
                output.stdout(&format!(
                    "  {}{}\t{}{}{}{}\trecovery={}\t{}",
                    field(Some(source), "subject"),
                    source_id,
                    field(Some(source), "status"),
                    code,
                    last_attempt,
                    last_success,
                    field(Some(source), "recovery"),
                    field(Some(source), "message"),
                ));
            }
        }
    }

    output.stdout("Recent:");
    match report.get("recent").and_then(Value::as_array) {
        None => output.stdout("  unavailable"),
        Some(recent) if recent.is_empty() => output.stdout("  none"),
        Some(recent) => {
            for attempt in recent {
                let subject = attempt
                    .get("subject")
                    .and_then(Value::as_str)
                    .map(|value| format!("/{value}"))
                    .unwrap_or_default();
                let duration = attempt
                    .get("duration_ms")
                    .and_then(Value::as_u64)
                    .map(|value| format!("\tduration_ms={value}"))
                    .unwrap_or_default();
                let code = attempt
                    .get("code")
                    .and_then(Value::as_str)
                    .map(|value| format!("\tcode={value}"))
                    .unwrap_or_default();
                output.stdout(&format!(
                    "  {}{}\t{}\tstarted_at={}{}{}",
                    field(Some(attempt), "kind"),
                    subject,
                    field(Some(attempt), "outcome"),
                    field(Some(attempt), "started_at"),
                    duration,
                    code,
                ));
            }
        }
    }
}

fn load_cache(context: &ServiceContext) -> Result<Value, Failure> {
    cache_from_state(&invoke(context, Operation::GetState, json!({}))?)
}

fn cache_from_state(snapshot: &Value) -> Result<Value, Failure> {
    snapshot.get("cache").cloned().ok_or(Failure)
}

fn merge_cache(value: &Value, cache: &Value) -> Value {
    let mut object = match value {
        Value::Object(map) => map.clone(),
        _ => return value.clone(),
    };
    object.insert("cache".to_owned(), cache.clone());
    Value::Object(object)
}

/// A cache that is still filling in is worth one line, and only while it is.  Everything it
/// holds comes back on its own, so there is nothing here for a reader to act on.
fn render_cache_text(cache: &Value, output: &mut dyn CliOutput) {
    if cache.get("rebuilding").and_then(Value::as_bool) != Some(true) {
        return;
    }
    let elapsed = cache
        .get("reset_at")
        .and_then(Value::as_str)
        .and_then(elapsed_label)
        .unwrap_or_else(|| "-".to_owned());
    output.stdout(&format!(
        "Cache: rebuilding\telapsed={elapsed}\tUsage history is catching up."
    ));
}

fn elapsed_label(started_at: &str) -> Option<String> {
    let started = parse_rfc3339_secs(started_at)?;
    let now = parse_rfc3339_secs(&now_rfc3339())?;
    let seconds = now.saturating_sub(started);
    Some(if seconds < 60 {
        format!("{seconds}s")
    } else {
        format!("{}m {}s", seconds / 60, seconds % 60)
    })
}

fn parse_rfc3339_secs(value: &str) -> Option<u64> {
    if value.len() < 20 {
        return None;
    }
    let year = value.get(0..4)?.parse::<i64>().ok()?;
    let month = value.get(5..7)?.parse::<u32>().ok()?;
    let day = value.get(8..10)?.parse::<u32>().ok()?;
    let hour = value.get(11..13)?.parse::<u64>().ok()?;
    let minute = value.get(14..16)?.parse::<u64>().ok()?;
    let second = value.get(17..19)?.parse::<u64>().ok()?;
    if month == 0 || month > 12 || day == 0 || day > 31 {
        return None;
    }
    let days = days_from_civil(year, month, day)?;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

fn days_from_civil(year: i64, month: u32, day: u32) -> Option<u64> {
    let mut year = year;
    let mut month = month as i64;
    if month <= 2 {
        year -= 1;
        month += 9;
    } else {
        month -= 3;
    }
    let era = year.div_euclid(400);
    let yoe = year.rem_euclid(400);
    let doy = (153 * month + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days).ok()
}

/// Zero when the whole product is working, every surface's data is worth showing, and nobody
/// has to do anything. Stale or partial data is a nonzero answer even when the service itself
/// is healthy: something on screen is not what it claims to be.
fn diagnostics_exit_code(report: &Value) -> i32 {
    let summary = report.get("summary");
    let operation = summary
        .and_then(|value| value.get("operation"))
        .and_then(Value::as_str);
    let attention = summary
        .and_then(|value| value.get("attention"))
        .and_then(Value::as_str);
    let surfaces = report.get("surfaces").and_then(Value::as_array);
    let data_is_usable = surfaces.is_some_and(|surfaces| {
        surfaces.iter().all(|surface| {
            matches!(
                surface.get("data").and_then(Value::as_str),
                Some("current" | "empty")
            )
        })
    });
    if operation == Some("healthy") && data_is_usable && attention != Some("required") {
        0
    } else {
        1
    }
}

fn run_login(options: OutputOptions, output: &mut dyn CliOutput, cancel: &AtomicBool) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not complete account login.",
            );
        }
    };
    let manager = AccountManager::new(
        context.relay.clone(),
        context.state.clone(),
        local_device_display_name("QuotaCLI"),
    );
    let outcome = manager.login_device(cancel, |prompt| {
        let uri = prompt
            .verification_uri_complete
            .as_deref()
            .unwrap_or(&prompt.verification_uri);
        output.stderr(&format!("Open {uri} and enter code {}.", prompt.user_code));
    });
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(error) => return report_login_failure(error, output),
    };
    if manager.persist_login(&outcome).is_err() {
        return report_failure(
            Failure,
            output,
            "QuotaCLI could not save account login state.",
        );
    }
    if context
        .state
        .set_component(
            ComponentName::Account,
            ComponentStatus::Ready,
            serde_json::to_value(&outcome.account).ok(),
            Some(now_rfc3339()),
            None,
            false,
        )
        .is_err()
    {
        return report_failure(
            Failure,
            output,
            "QuotaCLI could not save account login state.",
        );
    }
    emit_auth_result(&auth_result_from_session(&outcome.session), options, output);
    0
}

fn run_logout(options: OutputOptions, output: &mut dyn CliOutput) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not complete account logout.",
            );
        }
    };
    let initial = match invoke(&context, Operation::Logout, json!({})) {
        Ok(result) => result,
        Err(_) => {
            return report_failure(
                Failure,
                output,
                "QuotaCLI could not complete account logout.",
            );
        }
    };
    let status = if initial.get("status").and_then(Value::as_str) == Some("logout_pending") {
        wait_for_logout(&context)
    } else {
        Ok("signed_out")
    };
    let (status, exit_code) = match status {
        Ok(status) => (status, 0),
        Err(_) => ("logout_pending", 1),
    };
    if options.format == OutputFormat::Json {
        write_json(
            output,
            &json!({ "schema_version": 1, "status": status }),
            options.pretty,
        );
    } else {
        output.stdout(match status {
            "logout_pending" => "Signed out locally; server revocation is pending.",
            _ => "Signed out of Quota.",
        });
    }
    exit_code
}

fn run_auth_status(options: OutputOptions, output: &mut dyn CliOutput) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not read local account state.",
            );
        }
    };
    let result = match context.state.session_json() {
        Ok(Some(session)) if session.get("status").and_then(Value::as_str) == Some("active") => {
            auth_result_from_session(&session)
        }
        Ok(Some(session))
            if session.get("status").and_then(Value::as_str) == Some("logout_pending") =>
        {
            json!({ "schema_version": 1, "status": "logout_pending" })
        }
        Ok(_) => json!({ "schema_version": 1, "status": "signed_out" }),
        Err(_) => {
            return report_failure(
                Failure,
                output,
                "QuotaCLI could not read local account state.",
            );
        }
    };
    emit_auth_result(&result, options, output);
    if result.get("status").and_then(Value::as_str) == Some("logout_pending") {
        1
    } else {
        0
    }
}

fn run_sync(options: OutputOptions, output: &mut dyn CliOutput) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not collect local quota and Usage.",
            );
        }
    };
    if invoke(&context, Operation::Refresh, json!({})).is_err() {
        return report_failure(
            Failure,
            output,
            "QuotaCLI could not collect local quota and Usage.",
        );
    }
    let snapshot = match wait_for_refresh(&context) {
        Ok(snapshot) => snapshot,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not collect local quota and Usage.",
            );
        }
    };
    let status = if snapshot
        .account
        .value
        .as_ref()
        .and_then(|value| value.get("auth_status"))
        .and_then(Value::as_str)
        == Some("signed_in")
    {
        "synced"
    } else {
        "signed_out"
    };
    let result = json!({
        "schema_version": 2,
        "status": status,
        "local_state": serde_json::to_value(snapshot).unwrap_or(Value::Null),
    });
    write_json(output, &result, options.pretty);
    if status == "synced" { 0 } else { 1 }
}

fn run_account_summary(options: SummaryOptions, output: &mut dyn CliOutput) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not read the account summary.",
            );
        }
    };
    let manager = AccountManager::new(
        context.relay.clone(),
        context.state.clone(),
        local_device_display_name("QuotaCLI"),
    );
    let timezone = quota_service::providers::common::resolve_timezone(&std::env::vars().collect())
        .name()
        .to_owned();
    let component = match manager.refresh_account_state(&timezone, &AtomicBool::new(false)) {
        Ok(component) => component,
        Err(_) => {
            return report_failure(
                Failure,
                output,
                "QuotaCLI could not read the account summary. Sign in with `quotacli login` and retry.",
            );
        }
    };
    let Some(summary) = component
        .get("account_summary")
        .filter(|value| !value.is_null())
    else {
        return report_failure(
            Failure,
            output,
            "QuotaCLI could not read the account summary. Sign in with `quotacli login` and retry.",
        );
    };
    write_json(output, summary, options.pretty);
    0
}

fn run_config(command: ConfigCommand, output: &mut dyn CliOutput) -> i32 {
    let context = match open_context() {
        Ok(context) => context,
        Err(failure) => {
            return report_failure(
                failure,
                output,
                "QuotaCLI could not access provider configuration.",
            );
        }
    };
    match command {
        ConfigCommand::Set { provider, base_url } => {
            if validate_provider_config(provider.as_str(), base_url.as_deref()).is_err() {
                output.stderr("Provider configuration is invalid or unsupported.");
                return 2;
            }
            let mut key = String::new();
            if io::stdin().lock().read_line(&mut key).is_err() {
                output.stderr("Could not read the API key from stdin.");
                return 1;
            }
            let key = key.trim();
            if key.is_empty() {
                output.stderr("API key must not be empty.");
                return 2;
            }
            if context
                .state
                .set_provider_config(provider.as_str(), key, base_url.as_deref())
                .is_err()
            {
                output.stderr("QuotaCLI could not save provider configuration.");
                return 1;
            }
            output.stdout(&format!(
                "Configured {} ({}).",
                provider.as_str(),
                mask_label(provider)
            ));
            0
        }
        ConfigCommand::Get { provider } => match provider_view(&context, provider) {
            Ok(Some(view)) => {
                output.stdout(&format!(
                    "{}: {}",
                    provider.as_str(),
                    view.masked_api_key.as_deref().unwrap_or("configured")
                ));
                0
            }
            Ok(None) => {
                output.stdout(&format!("{}: not configured", provider.as_str()));
                0
            }
            Err(_) => report_failure(
                Failure,
                output,
                "QuotaCLI could not read provider configuration.",
            ),
        },
        ConfigCommand::Unset { provider } => {
            let configured = match context.state.provider_config(provider.as_str()) {
                Ok(value) => value.is_some(),
                Err(_) => {
                    return report_failure(
                        Failure,
                        output,
                        "QuotaCLI could not update provider configuration.",
                    );
                }
            };
            match context.state.remove_provider_config(provider.as_str()) {
                Ok(_) if configured => {
                    output.stdout(&format!("Removed {} config.", provider.as_str()));
                    0
                }
                Ok(_) => {
                    output.stdout(&format!("{}: not configured", provider.as_str()));
                    0
                }
                Err(_) => report_failure(
                    Failure,
                    output,
                    "QuotaCLI could not update provider configuration.",
                ),
            }
        }
        ConfigCommand::List => {
            let mut found = false;
            let snapshot = match context.state.snapshot() {
                Ok(snapshot) => snapshot,
                Err(_) => {
                    return report_failure(
                        Failure,
                        output,
                        "QuotaCLI could not list provider configuration.",
                    );
                }
            };
            for view in snapshot
                .providers
                .into_iter()
                .filter(|view| view.configured)
            {
                found = true;
                output.stdout(&format!(
                    "{}\t{}",
                    view.provider,
                    view.masked_api_key.as_deref().unwrap_or("configured")
                ));
            }
            if !found {
                output.stdout("No provider secrets configured.");
            }
            0
        }
    }
}

fn provider_view(
    context: &ServiceContext,
    provider: ProviderId,
) -> Result<Option<quota_service::protocol::ProviderConfigView>, Failure> {
    context
        .state
        .snapshot()
        .map(|snapshot| {
            snapshot
                .providers
                .into_iter()
                .find(|view| view.provider == provider.as_str())
        })
        .map_err(|_| Failure)
}

fn wait_for_logout(context: &ServiceContext) -> Result<&'static str, Failure> {
    let deadline = Instant::now() + REFRESH_TIMEOUT;
    loop {
        match context.state.session_json() {
            Ok(None) => return Ok("signed_out"),
            Ok(Some(session))
                if session.get("status").and_then(Value::as_str) == Some("logout_pending") =>
            {
                let account = context
                    .state
                    .component(quota_service::protocol::ComponentName::Account)
                    .map_err(|_| Failure)?;
                if account.is_some_and(|account| !account.refreshing) {
                    return Err(Failure);
                }
            }
            Ok(Some(_)) => return Err(Failure),
            Err(_) => return Err(Failure),
        }
        if Instant::now() >= deadline {
            return Err(Failure);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn wait_for_refresh(
    context: &ServiceContext,
) -> Result<quota_service::protocol::StateSnapshot, Failure> {
    let deadline = Instant::now() + REFRESH_TIMEOUT;
    loop {
        let snapshot = context.state.snapshot().map_err(|_| Failure)?;
        if ![
            &snapshot.quota,
            &snapshot.usage,
            &snapshot.account,
            &snapshot.pricing,
        ]
        .iter()
        .any(|component| component.refreshing)
        {
            return Ok(snapshot);
        }
        if Instant::now() >= deadline {
            return Err(Failure);
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn auth_result_from_session(session: &Value) -> Value {
    json!({
        "schema_version": 1,
        "status": "signed_in",
        "account_id": session.get("account_id").cloned().unwrap_or(Value::Null),
        "device_id": session.get("device_id").cloned().unwrap_or(Value::Null),
        "device_generation": session.get("device_generation").cloned().unwrap_or(Value::Null),
    })
}

fn emit_auth_result(value: &Value, options: OutputOptions, output: &mut dyn CliOutput) {
    if options.format == OutputFormat::Json {
        write_json(output, value, options.pretty);
    } else {
        match value.get("status").and_then(Value::as_str) {
            Some("signed_in") => output.stdout(&format!(
                "Signed in to Quota. Device: {}",
                value
                    .get("device_id")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
            )),
            Some("logout_pending") => {
                output.stdout("Signed out locally; server revocation is pending.")
            }
            _ => output.stdout("Signed out of Quota."),
        }
    }
}

fn write_json(output: &mut dyn CliOutput, value: &Value, pretty: bool) {
    let encoded = if pretty {
        serde_json::to_string_pretty(value)
    } else {
        serde_json::to_string(value)
    };
    output.stdout(&encoded.unwrap_or_else(|_| "{\"error\":\"serialization_failed\"}".to_owned()));
}

fn mask_label(provider: ProviderId) -> &'static str {
    provider
        .metadata()
        .credential_config
        .map(|config| config.mask_label)
        .unwrap_or("configured")
}

fn report_failure(_: Failure, output: &mut dyn CliOutput, fallback: &str) -> i32 {
    output.stderr(fallback);
    1
}

fn report_login_failure(error: BackendError, output: &mut dyn CliOutput) -> i32 {
    let message = match error.error.code {
        quota_service::protocol::ErrorCode::Cancelled => "QuotaCLI account login was cancelled.",
        quota_service::protocol::ErrorCode::AuthenticationRequired => {
            "QuotaCLI account login was denied or expired."
        }
        _ => "QuotaCLI could not complete account login.",
    };
    output.stderr(message);
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_and_help_are_runnable_without_network_or_state() {
        let mut output = BufferOutput::default();
        assert_eq!(run_cli(["version"], &mut output), 0);
        assert_eq!(output.stdout, vec![format!("QuotaCLI {QUOTA_CLI_VERSION}")]);
        output = BufferOutput::default();
        assert_eq!(run_cli(["help"], &mut output), 0);
        assert!(output.stdout[0].contains("quotacli status"));
    }

    #[test]
    fn command_errors_are_fixed_and_do_not_echo_secret_values() {
        let mut output = BufferOutput::default();
        assert_eq!(
            run_cli(
                ["config", "set", "openrouter", "--api-key", "secret"],
                &mut output
            ),
            2
        );
        assert!(!output.stderr.join("\n").contains("secret"));
    }

    /// A failed provider that names no source and no recovery leaves the reader guessing
    /// which of its readings broke and where to fix it.
    #[test]
    fn text_status_names_the_source_that_failed_and_what_to_do() {
        let mut output = BufferOutput::default();
        render_status_text(
            &json!({
                "results": [{
                    "provider": "claude",
                    "outcome": "auth_required",
                    "snapshots": [],
                    "message": "The saved sign-in expired or was rejected. \
                                Open Claude Code to refresh the sign-in.",
                    "sources": [
                        {"source_id": "anthropic_oauth_usage_api",
                         "outcome": "auth_required", "category": "auth_required"}
                    ]
                }, {
                    "provider": "grok",
                    "outcome": "unavailable",
                    "snapshots": [],
                    "sources": []
                }]
            }),
            &mut output,
        );
        assert_eq!(
            output.stdout,
            vec![
                "claude\tauth_required\tOAuth\tThe saved sign-in expired or was rejected. \
                 Open Claude Code to refresh the sign-in.",
                "grok\tunavailable",
            ]
        );
    }

    #[test]
    fn text_status_shows_remaining_quota() {
        let mut output = BufferOutput::default();
        render_status_text(
            &json!({
                "results": [{
                    "provider": "codex",
                    "outcome": "success",
                    "snapshots": [{
                        "account": {"label": "Work"},
                        "status": "available",
                        "windows": [{"title": "Weekly", "used_percent": 25.0}]
                    }]
                }]
            }),
            &mut output,
        );
        assert_eq!(
            output.stdout,
            vec!["codex\tWork\tavailable", "  Weekly\t75%"]
        );
    }

    #[test]
    fn diagnostics_render_surfaces_sources_and_recent_work() {
        let report = json!({
            "schema_version": 3,
            "generated_at": "2026-08-11T00:00:00Z",
            "client": {"name": "QuotaCLI", "version": "0.0.7"},
            "summary": {"operation":"healthy","attention":"required"},
            "surfaces": [{
                "id":"usage_this_device","status":"ok","data":"partial",
                "last_success_at":"2026-08-11T00:00:00Z",
                "message":"55 records read from 1 agent.","recovery":"none"
            }],
            "sources": [{
                "subject":"agent:cursor",
                "source_id": null,
                "status":"degraded",
                "last_attempt_at":"2026-08-11T00:00:00Z",
                "last_success_at": null,
                "code":"malformed_json",
                "message":"Invalid Usage records were skipped and the valid ones were kept.",
                "recovery":"update_source"
            }],
            "recent": [{
                "kind":"usage_scan","subject":"agent:cursor",
                "started_at":"2026-08-11T00:00:00Z","duration_ms":12,
                "outcome":"partial","code":"malformed_data"
            }]
        });
        let mut output = BufferOutput::default();
        render_diagnostics_text(&report, &mut output);
        // Partial data on any surface is a nonzero answer even when nothing is broken.
        assert_eq!(diagnostics_exit_code(&report), 1);
        let text = output.stdout.join("\n");
        assert!(text.contains("usage_this_device\tok\tdata=partial"));
        assert!(text.contains("55 records read from 1 agent."));
        assert!(text.contains("agent:cursor\tdegraded\tcode=malformed_json"));
        assert!(text.contains("recovery=update_source"));
        assert!(text.contains("usage_scan/agent:cursor\tpartial"));
        assert!(text.contains("duration_ms=12"));
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("token"));
    }

    #[test]
    fn missing_cache_object_is_an_error() {
        assert!(cache_from_state(&json!({"ipc_version": 1})).is_err());
        assert!(cache_from_state(&json!({"cache": {"rebuilding": false}})).is_ok());
    }

    #[test]
    fn a_rebuilding_cache_is_the_only_one_worth_a_line() {
        let mut settled = BufferOutput::default();
        render_cache_text(
            &json!({"rebuilding": false, "reset_at": null}),
            &mut settled,
        );
        assert!(settled.stdout.is_empty());

        let mut rebuilding = BufferOutput::default();
        render_cache_text(
            &json!({"rebuilding": true, "reset_at": "2026-08-17T01:00:00Z"}),
            &mut rebuilding,
        );
        assert!(rebuilding.stdout[0].contains("Cache: rebuilding"));
        assert!(rebuilding.stdout[0].contains("Usage history is catching up."));
    }

    #[test]
    fn healthy_diagnostics_are_successful_and_json_is_pretty_when_requested() {
        let report = json!({
            "schema_version": 3,
            "summary": {"operation":"healthy","attention":"none"},
            "surfaces": [
                {"id":"quota_overview","status":"ok","data":"empty","last_success_at":null,
                 "message":"No quota has been read yet.","recovery":"none"}
            ],
            "sources": [],
            "recent": []
        });
        let mut output = BufferOutput::default();
        assert_eq!(diagnostics_exit_code(&report), 0);
        write_json(&mut output, &report, true);
        assert!(output.stdout[0].contains("\n  \"schema_version\""));
    }
}
