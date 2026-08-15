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
    if options.output.format == OutputFormat::Json {
        write_json(output, &value, options.output.pretty);
    } else {
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
        let Some(snapshots) = result.get("snapshots").and_then(Value::as_array) else {
            output.stdout(&format!("{provider}\t{outcome}"));
            continue;
        };
        if snapshots.is_empty() {
            output.stdout(&format!("{provider}\t{outcome}"));
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
    if options.format == OutputFormat::Json {
        write_json(output, &report, options.pretty);
    } else {
        render_diagnostics_text(&report, output);
    }
    diagnostics_exit_code(&report)
}

fn render_diagnostics_text(report: &Value, output: &mut dyn CliOutput) {
    let summary = report.get("summary").and_then(Value::as_object);
    output.stdout(&format!(
        "Diagnostics: {}",
        summary
            .and_then(|value| value.get("operation"))
            .and_then(Value::as_str)
            .unwrap_or("unknown")
    ));
    output.stdout(&format!(
        "Data: {}",
        summary
            .and_then(|value| value.get("data"))
            .and_then(Value::as_str)
            .unwrap_or("unknown")
    ));
    output.stdout(&format!(
        "Attention: {}",
        summary
            .and_then(|value| value.get("attention"))
            .and_then(Value::as_str)
            .unwrap_or("unknown")
    ));
    if let Some(schema_version) = report.get("schema_version").and_then(Value::as_u64) {
        output.stdout(&format!("Schema version: {schema_version}"));
    }
    if let Some(generated_at) = report.get("generated_at").and_then(Value::as_str) {
        output.stdout(&format!("Generated at: {generated_at}"));
    }
    if let Some(refresh) = report.get("refresh").and_then(Value::as_object) {
        let phase = refresh
            .get("phase")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let as_of = refresh
            .get("as_of")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        output.stdout(&format!("Refresh: {phase} (as of {as_of})"));
    }
    if let Some(client) = report.get("client").and_then(Value::as_object) {
        let name = client
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let version = client
            .get("version")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        output.stdout(&format!("Client: {name} {version}"));
    }
    output.stdout("Surfaces:");
    render_diagnostic_surfaces(report.get("surfaces"), output);
    output.stdout("Checks:");
    render_diagnostic_checks(report.get("checks"), output);
    if let Some(findings) = report.get("findings").and_then(Value::as_array) {
        if findings.is_empty() {
            output.stdout("Findings: none");
        } else {
            output.stdout("Findings:");
            for finding in findings {
                let component = finding
                    .get("component")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let subject = finding
                    .get("subject")
                    .and_then(Value::as_str)
                    .map(|value| format!("/{value}"))
                    .unwrap_or_default();
                let code = finding
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let severity = finding
                    .get("severity")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let count = finding.get("count").and_then(Value::as_u64);
                let message = finding.get("message").and_then(Value::as_str).unwrap_or("");
                let recovery = finding
                    .get("recovery")
                    .and_then(Value::as_str)
                    .unwrap_or("none");
                let source = finding
                    .get("source")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let impact = finding
                    .get("impact")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let observed_at = finding
                    .get("observed_at")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let suffix = count.map(|count| format!(" ({count})")).unwrap_or_default();
                output.stdout(&format!(
                    "  [{severity}] {component}{subject}/{code}{suffix}\t{message}\tsource={source}\timpact={impact}\tobserved_at={observed_at}\trecovery={recovery}"
                ));
            }
        }
    }
    render_diagnostic_activity(report.get("recent_activity"), output);
}

fn render_diagnostic_activity(value: Option<&Value>, output: &mut dyn CliOutput) {
    let Some(activity) = value.and_then(Value::as_object) else {
        output.stdout("Recent activity: unavailable");
        return;
    };
    let Some(attempts) = activity.get("attempts").and_then(Value::as_array) else {
        output.stdout("Recent activity: unavailable");
        return;
    };
    if attempts.is_empty() {
        output.stdout("Recent activity: none");
    } else {
        output.stdout("Recent activity:");
        for attempt in attempts {
            let kind = attempt
                .get("kind")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let subject = attempt
                .get("subject")
                .and_then(Value::as_str)
                .map(|value| format!("/{value}"))
                .unwrap_or_default();
            let outcome = attempt
                .get("outcome")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let trigger = attempt
                .get("trigger")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let source = attempt
                .get("source")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let started_at = attempt
                .get("started_at")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let code = attempt
                .get("code")
                .and_then(Value::as_str)
                .map(|value| format!("\tcode={value}"))
                .unwrap_or_default();
            output.stdout(&format!(
                "  {kind}{subject}\t{outcome}\ttrigger={trigger}\tsource={source}\tstarted_at={started_at}{code}"
            ));
        }
    }
    if activity.get("history_truncated").and_then(Value::as_bool) == Some(true) {
        output.stdout("  Older activity was removed by bounded retention.");
    }
}

fn render_diagnostic_surfaces(value: Option<&Value>, output: &mut dyn CliOutput) {
    let Some(Value::Array(surfaces)) = value else {
        output.stdout("  unavailable");
        return;
    };
    for surface in surfaces {
        let name = surface
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let operation = surface
            .get("operation")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let data = surface
            .get("data")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let source = surface
            .get("source")
            .and_then(Value::as_str)
            .map(|value| format!("\tsource={value}"))
            .unwrap_or_default();
        output.stdout(&format!(
            "  {name}\t{operation}\tdata={data}{source}{}",
            diagnostic_metrics_suffix(surface)
        ));
    }
}

fn render_diagnostic_checks(value: Option<&Value>, output: &mut dyn CliOutput) {
    let Some(Value::Array(checks)) = value else {
        output.stdout("  unavailable");
        return;
    };
    if checks.is_empty() {
        output.stdout("  none");
    }
    for check in checks {
        let name = check
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let subject = check
            .get("subject")
            .and_then(Value::as_str)
            .map(|value| format!("/{value}"))
            .unwrap_or_default();
        let source = check
            .get("source")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let mode = check
            .get("mode")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let operation = check
            .get("operation")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let data = check
            .get("data")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        output.stdout(&format!(
            "  {name}{subject}\t{source}\t{mode}\t{operation}\tdata={data}{}",
            diagnostic_metrics_suffix(check)
        ));
    }
}

fn diagnostic_metrics_suffix(value: &Value) -> String {
    let metrics = value
        .get("metrics")
        .and_then(Value::as_object)
        .map(|metrics| {
            let mut values = metrics
                .iter()
                .filter_map(|(key, value)| value.as_i64().map(|value| (key, value)))
                .collect::<Vec<_>>();
            values.sort_by(|left, right| left.0.cmp(right.0));
            values
                .into_iter()
                .map(|(key, value)| format!("{key}={value}"))
                .collect::<Vec<_>>()
                .join(",")
        })
        .unwrap_or_default();
    if metrics.is_empty() {
        String::new()
    } else {
        format!("\t{metrics}")
    }
}

fn diagnostics_exit_code(report: &Value) -> i32 {
    let summary = report.get("summary");
    let operation = summary
        .and_then(|value| value.get("operation"))
        .and_then(Value::as_str);
    let data = summary
        .and_then(|value| value.get("data"))
        .and_then(Value::as_str);
    let attention = summary
        .and_then(|value| value.get("attention"))
        .and_then(Value::as_str);
    if operation == Some("healthy")
        && !matches!(data, Some("partial" | "stale" | "unknown"))
        && attention != Some("required")
    {
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
    let component = match manager.refresh_account_state(&AtomicBool::new(false)) {
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
    fn diagnostics_render_v2_surfaces_checks_and_findings() {
        let report = json!({
            "schema_version": 2,
            "summary": {"operation":"healthy","data":"partial","attention":"required"},
            "refresh": {"phase":"idle","revision":7,"as_of":"2026-08-11T00:00:00Z"},
            "generated_at": "2026-08-11T00:00:00Z",
            "client": {"name": "QuotaCLI", "version": "0.0.7"},
            "surfaces": [{"name":"usage_this_device","operation":"healthy","data":"partial","source":"this_device","metrics":{"records":55}}],
            "checks": [{"name":"usage_scan","subject":"agent:cursor","source":"this_device","mode":"required","operation":"healthy","data":"partial","metrics":{"valid_records":55}}],
            "findings": [{
                "component": "usage_scan",
                "subject": "agent:cursor",
                "source": "this_device",
                "code": "malformed_json",
                "severity": "warning",
                "impact": "surface",
                "recovery": "update_source",
                "count": 55,
                "observed_at": "2026-08-11T00:00:00Z",
                "message": "Invalid records were isolated."
            }],
            "recent_activity": {
                "attempts": [{
                    "kind": "usage_scan",
                    "subject": "agent:cursor",
                    "outcome": "partial",
                    "trigger": "scheduled",
                    "source": "this_device",
                    "started_at": "2026-08-11T00:00:00Z",
                    "code": "malformed_data"
                }],
                "history_truncated": true
            }
        });
        let mut output = BufferOutput::default();
        render_diagnostics_text(&report, &mut output);
        assert_eq!(diagnostics_exit_code(&report), 1);
        let text = output.stdout.join("\n");
        assert!(text.contains("usage_this_device\thealthy\tdata=partial"));
        assert!(text.contains("records=55"));
        assert!(text.contains("usage_scan/agent:cursor/malformed_json (55)"));
        assert!(text.contains("source=this_device"));
        assert!(text.contains("impact=surface"));
        assert!(text.contains("observed_at=2026-08-11T00:00:00Z"));
        assert!(text.contains("usage_scan/agent:cursor\tpartial\ttrigger=scheduled"));
        assert!(text.contains("Older activity was removed"));
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("token"));
    }

    #[test]
    fn healthy_diagnostics_are_successful_and_json_is_pretty_when_requested() {
        let report = json!({
            "schema_version": 2,
            "summary": {"operation":"healthy","data":"empty","attention":"none"},
            "surfaces": [],
            "checks": [],
            "findings": []
        });
        let mut output = BufferOutput::default();
        assert_eq!(diagnostics_exit_code(&report), 0);
        write_json(&mut output, &report, true);
        assert!(output.stdout[0].contains("\n  \"schema_version\""));
    }
}
