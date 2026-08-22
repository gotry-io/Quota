use crate::catalog::ProviderId;
use serde_json::Value;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use uuid::Uuid;

use super::common::{
    CollectionContext, ErrorCategory, HttpClient, LOCAL_FILE_LIMIT, ProviderError, ProviderSession,
    QuotaAccount, QuotaSnapshot, QuotaWindow, ValidatedBrowserSession, account_identity,
    clamp_percent, collect_official_or_browser, discover_official_or_browser, is_executable_file,
    mask_email, number, obj_get, obj_get_any, parse_date, read_bounded_file, run_bounded_command,
    slug, string,
};

mod web;

pub const SOURCE: &str = "anthropic_oauth_usage_api";
pub const CLI_SOURCE: &str = "claude_cli_usage";
pub const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const PROFILE_URL: &str = "https://api.anthropic.com/api/oauth/profile";
pub const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const AUTH_REFRESH_SKEW: i64 = 60;

#[derive(Clone, Debug)]
struct Credentials {
    access_token: String,
    expires_at: Option<i64>,
    scopes: Vec<String>,
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
    source: String,
}

pub fn discover(context: &CollectionContext) -> Vec<ProviderSession> {
    discover_official_or_browser(
        ProviderId::Claude,
        load_credentials(context).map(|credentials| ProviderSession {
            provider: ProviderId::Claude,
            credential_source: credentials.source,
        }),
        context,
    )
}

pub fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    web::validate_browser_session(cookie_header, context)
}

pub fn collect(
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_official_or_browser(
        session,
        context,
        ProviderId::Claude,
        SOURCE,
        || collect_official(context),
        || web::collect(context),
    )
}

fn collect_official(context: &CollectionContext) -> Result<QuotaSnapshot, ProviderError> {
    let credentials = load_credentials(context)
        .ok_or_else(|| ProviderError::new(ErrorCategory::AuthRequired, SOURCE))?;
    let plan = credentials.subscription_type.clone();
    match collect_oauth(credentials, context) {
        Ok(snapshot) => Ok(snapshot),
        Err(error) if error.category == ErrorCategory::Error => Err(error),
        // The official CLI renders the same account's usage panel. It only runs
        // when local credentials exist, so a missing sign-in never spawns a probe
        // and the OAuth verdict still drives the browser-session fallback.
        Err(oauth_error) => collect_cli_usage(plan, context).map_err(|_| oauth_error),
    }
}

fn collect_oauth(
    mut credentials: Credentials,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if !credentials
        .scopes
        .iter()
        .any(|scope| scope == "user:profile")
    {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    let refresh_attempted = credentials
        .expires_at
        .map(|expiry| expiry <= context.observed_unix() + AUTH_REFRESH_SKEW)
        .unwrap_or(false);
    if refresh_attempted {
        credentials = refresh_and_reload(&credentials, context).unwrap_or(credentials);
    }
    match collect_with_credentials(&credentials, context) {
        Ok(snapshot) => Ok(snapshot),
        Err(error) if error.category == ErrorCategory::AuthRequired && !refresh_attempted => {
            let refreshed =
                refresh_and_reload(&credentials, context).unwrap_or(credentials.clone());
            if refreshed.access_token != credentials.access_token
                || refreshed.expires_at != credentials.expires_at
            {
                collect_with_credentials(&refreshed, context)
            } else {
                Err(error)
            }
        }
        Err(error) => Err(error),
    }
}

fn load_credentials(context: &CollectionContext) -> Option<Credentials> {
    let root = context
        .env("CLAUDE_CONFIG_DIR")
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| context.home_directory.join(".claude"));
    let file = root.join(".credentials.json");
    let file_credentials = read_credentials_file(&file);
    if file_credentials
        .as_ref()
        .map(|credentials| !is_expiring(credentials, context.observed_unix()))
        .unwrap_or(false)
    {
        return file_credentials;
    }
    if cfg!(target_os = "macos")
        && context.allows_host_keychain()
        && let Some(credentials) = read_keychain(context)
    {
        return Some(credentials);
    }
    file_credentials
}

fn read_credentials_file(path: &Path) -> Option<Credentials> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let value: Value = serde_json::from_slice(&read_bounded_file(path, LOCAL_FILE_LIMIT)?).ok()?;
    parse_credentials(&value, &path.to_string_lossy())
}

fn read_keychain(context: &CollectionContext) -> Option<Credentials> {
    let mut command = Command::new("/usr/bin/security");
    command.args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]);
    let output = run_bounded_command(
        command,
        Duration::from_secs(10),
        context.cancel.as_ref(),
        1_048_576,
    )?;
    let value: Value = serde_json::from_slice(&output).ok()?;
    parse_credentials(&value, &format!("macOS Keychain: {KEYCHAIN_SERVICE}"))
}

fn parse_credentials(value: &Value, source: &str) -> Option<Credentials> {
    if value.get("claudeAiOauth").is_none() && value.get("mcpOAuth").is_some() {
        return None;
    }
    let oauth = value.get("claudeAiOauth")?.as_object()?;
    let access_token = obj_get_any(
        &Value::Object(oauth.clone()),
        &["accessToken", "access_token"],
    )
    .and_then(|v| string(Some(v)))?;
    let expires_at = obj_get_any(&Value::Object(oauth.clone()), &["expiresAt", "expires_at"])
        .and_then(|v| parse_date(Some(v)));
    let scopes = oauth
        .get("scopes")
        .and_then(Value::as_array)
        .map(|values| values.iter().filter_map(|v| string(Some(v))).collect())
        .unwrap_or_default();
    Some(Credentials {
        access_token,
        expires_at,
        scopes,
        subscription_type: obj_get_any(
            &Value::Object(oauth.clone()),
            &["subscriptionType", "subscription_type"],
        )
        .and_then(|v| string(Some(v))),
        rate_limit_tier: obj_get_any(
            &Value::Object(oauth.clone()),
            &["rateLimitTier", "rate_limit_tier"],
        )
        .and_then(|v| string(Some(v))),
        source: source.to_owned(),
    })
}

fn is_expiring(credentials: &Credentials, now: i64) -> bool {
    credentials
        .expires_at
        .map(|expiry| expiry <= now + AUTH_REFRESH_SKEW)
        .unwrap_or(false)
}

fn refresh_and_reload(
    credentials: &Credentials,
    context: &CollectionContext,
) -> Option<Credentials> {
    // Claude owns token renewal: its interactive `/status` refreshes an
    // expiring OAuth token on disk, and the probe exits immediately after.
    run_cli_slash_command(context, "/status")?;
    let reloaded = load_credentials(context)?;
    ((reloaded.access_token != credentials.access_token)
        || (reloaded.expires_at != credentials.expires_at))
        .then_some(reloaded)
}

fn stop_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

struct ProbeCleanup {
    probe_dir: PathBuf,
    transcript: PathBuf,
}

impl ProbeCleanup {
    fn new(context: &CollectionContext, probe_dir: &Path, session_id: &str) -> Self {
        let config_root = context
            .env("CLAUDE_CONFIG_DIR")
            .and_then(|value| value.split(',').next())
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| context.home_directory.join(".claude"));
        let project = probe_dir
            .to_string_lossy()
            .chars()
            .map(|value| {
                if value.is_ascii_alphanumeric() {
                    value
                } else {
                    '-'
                }
            })
            .take(200)
            .collect::<String>();
        Self {
            probe_dir: probe_dir.to_owned(),
            transcript: config_root
                .join("projects")
                .join(project)
                .join(format!("{session_id}.jsonl")),
        }
    }
}

impl Drop for ProbeCleanup {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.transcript);
        let _ = fs::remove_dir_all(&self.probe_dir);
    }
}

fn resolve_executable(context: &CollectionContext) -> Option<String> {
    if let Some(path) = context
        .env("CLAUDE_CLI_PATH")
        .filter(|v| !v.trim().is_empty())
    {
        return Some(path.to_owned());
    }
    let paths = [
        context.home_directory.join(".local/bin/claude"),
        context.home_directory.join(".claude/local/claude"),
        context.home_directory.join(".claude/bin/claude"),
        PathBuf::from("/opt/homebrew/bin/claude"),
        PathBuf::from("/usr/local/bin/claude"),
        PathBuf::from("/Applications/cmux.app/Contents/Resources/bin/claude"),
    ];
    paths
        .into_iter()
        .find(|path| is_executable_file(path))
        .map(|path| path.to_string_lossy().into_owned())
        .or_else(|| Some("claude".to_owned()))
}

fn collect_cli_usage(
    plan: Option<String>,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    let output = run_cli_slash_command(context, "/usage")
        .ok_or_else(|| ProviderError::new(ErrorCategory::Unavailable, CLI_SOURCE))?;
    let text = String::from_utf8_lossy(&output);
    let windows = map_cli_usage_text(&text);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, CLI_SOURCE));
    }
    let (fingerprint, scope) = account_identity("claude", "organization_id", None);
    Ok(QuotaSnapshot {
        provider: ProviderId::Claude,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: None,
            plan,
        },
        windows,
        source: CLI_SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

const PROBE_TIMEOUT: Duration = Duration::from_secs(45);
const PROBE_EXIT_GRACE: Duration = Duration::from_secs(10);
const PROBE_STARTUP_FLOOR: Duration = Duration::from_secs(2);
const PROBE_QUIET: Duration = Duration::from_millis(1_500);
const PROBE_PANEL_QUIET: Duration = Duration::from_millis(2_500);
const PROBE_PANEL_LIMIT: Duration = Duration::from_secs(20);
const PROBE_SETTLE: Duration = Duration::from_millis(1_000);
const PROBE_NUDGE: Duration = Duration::from_millis(800);
const PROBE_OUTPUT_LIMIT: usize = 1_048_576;
const PROBE_TAIL: usize = 16_384;
/// Terminal cursor-position query the TUI may issue at startup; answered so it
/// does not wait on a reply.
const CURSOR_POSITION_QUERY: &[u8] = b"\x1b[6n";
const CURSOR_POSITION_REPLY: &[u8] = b"\x1b[1;1R";

/// Interactive prompts the CLI can show before or after a slash command, matched
/// on whitespace-free lowercase output. Each group is one dialog (its needles
/// are alternative wordings) and is answered at most once. The trust dialog
/// covers the empty, owner-only probe directory in which no tool is allowed;
/// the palette groups confirm the command's own autocomplete row so a
/// neighbouring action is never selected.
struct PromptReply {
    needles: &'static [&'static str],
    reply: &'static [u8],
}

const PROMPT_REPLIES: &[PromptReply] = &[
    PromptReply {
        needles: &["yes,itrustthisfolder", "quicksafetycheck"],
        reply: b"\r",
    },
    PromptReply {
        needles: &["doyoutrustthefilesinthisfolder"],
        reply: b"y\r",
    },
    PromptReply {
        needles: &["readytocodehere"],
        reply: b"\r",
    },
    PromptReply {
        needles: &["pressentertocontinue"],
        reply: b"\r",
    },
];
const USAGE_PALETTE_REPLIES: &[PromptReply] = &[PromptReply {
    needles: &["showplanusagelimits", "showplan"],
    reply: b"\r",
}];
const STATUS_PALETTE_REPLIES: &[PromptReply] = &[PromptReply {
    needles: &["showclaudecodestatus", "showclaudecode"],
    reply: b"\r",
}];

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ProbeStage {
    /// Waiting for the CLI to settle: answer its prompts, then submit the slash
    /// command once output goes quiet.
    Starting,
    /// Command submitted; wait for the panel it opens to carry its data (or,
    /// for commands without a recognizable payload, to go quiet).
    Submitted,
    /// Panel dismissed with Escape; `/exit` goes next.
    Dismissed,
    /// `/exit` submitted; wait for the process to leave.
    Exiting,
}

/// Runs the official Claude CLI in a bounded, tool-less, probe-only session,
/// submits one slash command, and returns the captured terminal output.
///
/// macOS `script` allocates the PTY that Claude's interactive slash commands
/// require, while still invoking the executable without a shell. The TUI reads
/// raw keystrokes, so commands are submitted with a carriage return, its
/// Settings panels are closed with Escape, and its interactive prompts are
/// answered from [`PROMPT_REPLIES`]. The probe directory is stable per user so
/// the first-run trust dialog is answered once. `/usage` is considered rendered
/// as soon as the session row carries a percentage; a panel that is still
/// loading is nudged with Enter, and one that reports a load failure is left
/// immediately.
fn run_cli_slash_command(context: &CollectionContext, command: &str) -> Option<Vec<u8>> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let executable = resolve_executable(context)?;
    let script = Path::new("/usr/bin/script");
    if !fs::metadata(script)
        .map(|metadata| metadata.is_file())
        .unwrap_or(false)
    {
        return None;
    }
    let probe_dir = std::env::temp_dir().join("quota-claude-probe");
    fs::create_dir_all(probe_dir.join(".claude")).ok()?;
    let settings = probe_dir.join(".claude/settings.local.json");
    fs::write(
        &settings,
        b"{\"disableDeepLinkRegistration\":\"disable\"}\n",
    )
    .ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&probe_dir, fs::Permissions::from_mode(0o700)).ok()?;
        fs::set_permissions(&settings, fs::Permissions::from_mode(0o600)).ok()?;
    }
    let session_id = Uuid::new_v4().to_string();
    let _cleanup = ProbeCleanup::new(context, &probe_dir, &session_id);
    let mut child = Command::new(script)
        .args([
            "-q",
            "/dev/null",
            &executable,
            "--allowed-tools",
            "",
            "--strict-mcp-config",
            "--session-id",
            &session_id,
        ])
        .current_dir(&probe_dir)
        .envs(
            context
                .environment
                .iter()
                .filter(|(key, _)| *key != "HOME" && !key.starts_with("ANTHROPIC_")),
        )
        .env("HOME", &context.home_directory)
        .env("DISABLE_AUTOUPDATER", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let (Some(mut stdin), Some(mut stdout)) = (child.stdin.take(), child.stdout.take()) else {
        stop_child(&mut child);
        return None;
    };
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut chunk = [0u8; 8_192];
        loop {
            match stdout.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(count) => {
                    if sender.send(chunk[..count].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });

    let is_usage = command == "/usage";
    let palette = if is_usage {
        USAGE_PALETTE_REPLIES
    } else {
        STATUS_PALETTE_REPLIES
    };
    let started = std::time::Instant::now();
    let mut last_output = started;
    let mut stage = ProbeStage::Starting;
    let mut stage_since = started;
    let mut last_nudge = started;
    let mut answered = [false; PROMPT_REPLIES.len() + 1];
    let mut screen = CompactText::default();
    let mut output = Vec::new();
    let mut send = |bytes: &[u8]| stdin.write_all(bytes).and_then(|_| stdin.flush()).is_ok();
    loop {
        if context.cancelled() || started.elapsed() > PROBE_TIMEOUT {
            stop_child(&mut child);
            return None;
        }
        let mut grew = false;
        match receiver.recv_timeout(Duration::from_millis(100)) {
            // Drain what else has already arrived so a burst of small writes
            // costs one rescan rather than one per write.
            Ok(first) => {
                for chunk in std::iter::once(first).chain(receiver.try_iter()) {
                    if chunk
                        .windows(CURSOR_POSITION_QUERY.len())
                        .any(|window| window == CURSOR_POSITION_QUERY)
                    {
                        let _ = send(CURSOR_POSITION_REPLY);
                    }
                    output.extend_from_slice(&chunk);
                }
                grew = true;
                last_output = std::time::Instant::now();
                if output.len() > PROBE_OUTPUT_LIMIT {
                    stop_child(&mut child);
                    return None;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = child.wait();
                return (stage >= ProbeStage::Dismissed).then_some(output);
            }
        }
        if let Ok(Some(_)) = child.try_wait() {
            // Drain what the reader still holds, then hand back the transcript.
            while let Ok(chunk) = receiver.try_recv() {
                output.extend_from_slice(&chunk);
            }
            return (stage >= ProbeStage::Dismissed).then_some(output);
        }
        // Nothing new means the screen is provably unchanged since the last scan.
        if grew || screen.lower.is_empty() {
            let tail = output.len().saturating_sub(PROBE_TAIL);
            screen = compact_terminal_text(&String::from_utf8_lossy(&output[tail..]));
        }
        if stage < ProbeStage::Dismissed {
            // Palette rows only exist once the command has been typed.
            let visible = if stage == ProbeStage::Submitted {
                answered.len()
            } else {
                PROMPT_REPLIES.len()
            };
            let prompts = PROMPT_REPLIES.iter().chain(palette.iter()).take(visible);
            for (index, prompt) in prompts.enumerate() {
                if answered[index]
                    || !prompt
                        .needles
                        .iter()
                        .any(|needle| screen.lower.contains(needle))
                {
                    continue;
                }
                answered[index] = true;
                if !send(prompt.reply) {
                    stop_child(&mut child);
                    return None;
                }
                last_output = std::time::Instant::now();
            }
        }
        let quiet = last_output.elapsed();
        match stage {
            ProbeStage::Starting => {
                if quiet >= PROBE_QUIET && started.elapsed() >= PROBE_STARTUP_FLOOR {
                    if !send(format!("{command}\r").as_bytes()) {
                        stop_child(&mut child);
                        return None;
                    }
                    stage = ProbeStage::Submitted;
                    stage_since = std::time::Instant::now();
                    last_output = stage_since;
                    last_nudge = stage_since;
                }
            }
            ProbeStage::Submitted => {
                let panel = &screen.lower;
                // A panel that stopped drawing, or one that has drawn too long,
                // is as done as it is going to get.
                let settled = quiet >= PROBE_PANEL_QUIET;
                let expired = stage_since.elapsed() >= PROBE_PANEL_LIMIT;
                let rendered = expired
                    || if is_usage {
                        let failed = panel.contains("failedtoloadusagedata");
                        let has_data = panel.contains("currentsession") && has_percent(panel);
                        let loading = panel.contains("loadingusagedata") && !has_data;
                        if loading && last_nudge.elapsed() >= PROBE_NUDGE {
                            // Claude's panel can wait for a keystroke before it draws the rows.
                            let _ = send(b"\r");
                            last_nudge = std::time::Instant::now();
                        }
                        failed || (has_data && quiet >= PROBE_SETTLE) || (!loading && settled)
                    } else {
                        settled
                    };
                if rendered {
                    if !send(b"\x1b") {
                        stop_child(&mut child);
                        return None;
                    }
                    stage = ProbeStage::Dismissed;
                    last_output = std::time::Instant::now();
                }
            }
            ProbeStage::Dismissed => {
                if quiet >= PROBE_QUIET {
                    if !send(b"/exit\r") {
                        stop_child(&mut child);
                        return Some(output);
                    }
                    stage = ProbeStage::Exiting;
                    stage_since = std::time::Instant::now();
                }
            }
            ProbeStage::Exiting => {
                if stage_since.elapsed() > PROBE_EXIT_GRACE {
                    // The panel text is already captured; do not let a stuck TUI
                    // outlive the refresh.
                    stop_child(&mut child);
                    return Some(output);
                }
            }
        }
    }
}

fn has_percent(lower: &str) -> bool {
    let bytes = lower.as_bytes();
    bytes
        .iter()
        .enumerate()
        .any(|(index, byte)| *byte == b'%' && index > 0 && bytes[index - 1].is_ascii_digit())
}

/// Terminal text with escape sequences and whitespace removed. The TUI positions
/// words with cursor moves rather than spaces, so matching must ignore spacing.
/// `lower` is ASCII-lowercased and byte-aligned with `text`.
#[derive(Default)]
struct CompactText {
    text: String,
    lower: String,
}

fn compact_terminal_text(raw: &str) -> CompactText {
    let text: String = strip_ansi(raw)
        .chars()
        .filter(|character| !character.is_whitespace() && !character.is_control())
        .collect();
    let lower = text.to_ascii_lowercase();
    CompactText { text, lower }
}

/// One of Claude's fixed usage windows. Both the OAuth body and the CLI panel
/// describe the same quota, so they share this table rather than each carrying
/// its own ids and titles — that is what keeps either source updating the same row.
struct ClaudeWindow {
    /// Key in the OAuth usage body.
    field: &'static str,
    /// Whitespace-free lowercase scopes the Settings panel renders inside
    /// `Current week (…)`. Empty when the panel has no row for this window.
    labels: &'static [&'static str],
    id: &'static str,
    title: &'static str,
    duration_seconds: u64,
}

const FIVE_HOUR_FIELD: &str = "five_hour";
const CLAUDE_WINDOWS: &[ClaudeWindow] = &[
    ClaudeWindow {
        field: FIVE_HOUR_FIELD,
        // The panel calls this one "Current session" rather than a weekly scope.
        labels: &[],
        id: "five_hour",
        title: "5 hour",
        duration_seconds: 18_000,
    },
    ClaudeWindow {
        field: "seven_day",
        labels: &["allmodels"],
        id: "seven_day",
        title: "Weekly",
        duration_seconds: 604_800,
    },
    ClaudeWindow {
        field: "seven_day_sonnet",
        labels: &["sonnet", "sonnetonly"],
        id: "seven_day_sonnet",
        title: "Sonnet weekly",
        duration_seconds: 604_800,
    },
    ClaudeWindow {
        field: "seven_day_opus",
        labels: &["opus", "opusonly"],
        id: "seven_day_opus",
        title: "Opus weekly",
        duration_seconds: 604_800,
    },
    ClaudeWindow {
        field: "seven_day_oauth_apps",
        labels: &[],
        id: "seven_day_oauth_apps",
        title: "OAuth apps weekly",
        duration_seconds: 604_800,
    },
];

/// The weekly window a model-scoped row belongs to, whether it comes from the
/// OAuth `limits[]` array or the panel's `Current week (<Model>)` heading.
fn scoped_weekly_window(name: &str) -> (String, String) {
    (
        format!("claude-weekly-scoped-{}", slug(name, '-')),
        format!("{name} only"),
    )
}

/// Maps the text of Claude's Settings → Usage panel. Each window is a title such
/// as `Current session` or `Current week (Fable)` followed by a bar and
/// `<n>% used`; Claude reports percent *used*, taken verbatim.
fn map_cli_usage_text(text: &str) -> Vec<QuotaWindow> {
    let compact = compact_terminal_text(text);
    let mut windows: Vec<QuotaWindow> = Vec::new();
    let mut push = |id: String, title: String, used: f64, duration: u64| {
        if windows.iter().any(|window| window.id == id) {
            return;
        }
        windows.push(QuotaWindow {
            id,
            title,
            used_percent: clamp_percent(used),
            resets_at: None,
            duration_seconds: Some(duration),
            remaining_value: None,
            limit_value: None,
            value_unit: None,
        });
    };
    let five_hour = CLAUDE_WINDOWS
        .iter()
        .find(|window| window.field == FIVE_HOUR_FIELD);
    if let Some(window) = five_hour
        && let Some(used) = percent_used_after(&compact.lower, "currentsession", 0)
    {
        push(
            window.id.to_owned(),
            window.title.to_owned(),
            used,
            window.duration_seconds,
        );
    }
    let mut cursor = 0;
    while let Some(offset) = compact.lower[cursor..].find("currentweek(") {
        let open = cursor + offset + "currentweek(".len();
        let Some(close) = compact.lower[open..].find(')').map(|index| open + index) else {
            break;
        };
        cursor = close + 1;
        let Some(used) = percent_used_after(&compact.lower, ")", close) else {
            continue;
        };
        let scope = &compact.lower[open..close];
        let (id, title) = match CLAUDE_WINDOWS
            .iter()
            .find(|window| window.labels.contains(&scope))
        {
            Some(window) => (window.id.to_owned(), window.title.to_owned()),
            None => {
                let name = compact.text[open..close].trim_end_matches("only");
                if name.is_empty() {
                    continue;
                }
                scoped_weekly_window(name)
            }
        };
        push(id, title, used, 604_800);
    }
    windows
}

/// Wording that marks a percentage as consumed versus remaining. Claude's panel
/// currently prints `<n>% used`; a remaining-style phrasing is converted so a copy
/// change cannot invert every reading.
const USED_WORDS: &[&str] = &["used", "spent", "consumed"];
const REMAINING_WORDS: &[&str] = &["left", "remaining", "available"];

/// The first labelled percentage after `label` (searched from `from`), as a
/// used percent, without crossing into the next window's title.
fn percent_used_after(lower: &str, label: &str, from: usize) -> Option<f64> {
    let start = from + lower[from..].find(label)? + label.len();
    let end = lower[start..]
        .find("current")
        .map(|index| start + index)
        .unwrap_or(lower.len())
        .min(start + 600);
    let window = &lower[start..end];
    let bytes = window.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if *byte != b'%' {
            continue;
        }
        let digits = bytes[..index]
            .iter()
            .rev()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if digits == 0 {
            continue;
        }
        let Ok(value) = window[index - digits..index].parse::<f64>() else {
            continue;
        };
        if !(0.0..=100.0).contains(&value) {
            continue;
        }
        let after = &window[index + 1..];
        if USED_WORDS.iter().any(|word| after.starts_with(word)) {
            return Some(value);
        }
        if REMAINING_WORDS.iter().any(|word| after.starts_with(word)) {
            return Some(100.0 - value);
        }
    }
    None
}

/// Drops ANSI escape sequences: CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or
/// `ESC \`), and two-byte `ESC x` forms.
fn strip_ansi(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != 0x1b {
            output.push(bytes[index]);
            index += 1;
            continue;
        }
        index += 1;
        match bytes.get(index) {
            Some(b'[') => {
                index += 1;
                while index < bytes.len() {
                    let byte = bytes[index];
                    index += 1;
                    if (0x40..=0x7e).contains(&byte) {
                        break;
                    }
                }
            }
            Some(b']') => {
                index += 1;
                while index < bytes.len() {
                    let byte = bytes[index];
                    index += 1;
                    if byte == 0x07 {
                        break;
                    }
                    if byte == 0x1b && bytes.get(index) == Some(&b'\\') {
                        index += 1;
                        break;
                    }
                }
            }
            Some(_) => index += 1,
            None => {}
        }
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn collect_with_credentials(
    credentials: &Credentials,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    if !credentials
        .scopes
        .iter()
        .any(|scope| scope == "user:profile")
    {
        return Err(ProviderError::new(ErrorCategory::AuthRequired, SOURCE));
    }
    let client = HttpClient::new()?;
    let bearer = format!("Bearer {}", credentials.access_token);
    let headers = [
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("anthropic-beta", "oauth-2025-04-20"),
        ("User-Agent", "claude-code/2.1.0"),
    ];
    let usage = match client.get_json(USAGE_URL, &headers, SOURCE) {
        Ok((_, value)) => value,
        Err(error) => return Err(error),
    };
    let windows = map_usage(&usage);
    if windows.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, SOURCE));
    }
    let (email, organization_id) = {
        let profile_headers = [
            ("Authorization", bearer.as_str()),
            ("Accept", "application/json"),
        ];
        match client.get_json(PROFILE_URL, &profile_headers, SOURCE) {
            Ok((_, value)) => map_profile(&value),
            Err(_) => (None, None),
        }
    };
    let plan = credentials
        .subscription_type
        .clone()
        .or_else(|| credentials.rate_limit_tier.clone());
    let (fingerprint, scope) =
        account_identity("claude", "organization_id", organization_id.as_deref());
    Ok(QuotaSnapshot {
        provider: ProviderId::Claude,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: mask_email(email.as_deref()),
            plan,
        },
        windows,
        source: SOURCE,
        status: "available",
        observed_at: context.observed_at(),
    })
}

pub(super) fn map_usage(value: &Value) -> Vec<QuotaWindow> {
    let mut windows = Vec::new();
    for entry in CLAUDE_WINDOWS {
        if let Some(window) = usage_window(
            obj_get(value, entry.field),
            entry.id,
            entry.title,
            entry.duration_seconds,
        ) {
            windows.push(window);
        }
    }
    if let Some(limits) = obj_get(value, "limits").and_then(Value::as_array) {
        let mut seen = std::collections::HashSet::new();
        for entry in limits {
            if string(obj_get(entry, "kind")).as_deref() != Some("weekly_scoped")
                || string(obj_get(entry, "group")).as_deref() != Some("weekly")
            {
                continue;
            }
            let Some(percent) = number(obj_get(entry, "percent")) else {
                continue;
            };
            let model = obj_get(entry, "scope").and_then(|v| obj_get(v, "model"));
            let Some(model_name) = obj_get_any(
                model.unwrap_or(&Value::Null),
                &["display_name", "displayName"],
            )
            .and_then(|v| string(Some(v))) else {
                continue;
            };
            let model_id =
                obj_get(model.unwrap_or(&Value::Null), "id").and_then(|v| string(Some(v)));
            if is_all_models(model_id.as_deref(), &model_name) {
                continue;
            }
            let identity = model_id.as_deref().unwrap_or(&model_name);
            let (id, _) = scoped_weekly_window(identity);
            if !seen.insert(id.clone()) {
                continue;
            }
            windows.push(QuotaWindow {
                id,
                title: format!("{model_name} only"),
                used_percent: clamp_percent(percent),
                resets_at: obj_get_any(entry, &["resets_at", "resetsAt"])
                    .and_then(|v| parse_date(Some(v)))
                    .map(super::common::unix_seconds_to_iso),
                duration_seconds: Some(604_800),
                remaining_value: None,
                limit_value: None,
                value_unit: None,
            });
        }
    }
    let routines = [
        "seven_day_routines",
        "seven_day_claude_routines",
        "claude_routines",
        "routines",
        "routine",
        "seven_day_cowork",
        "cowork",
    ]
    .iter()
    .find_map(|key| obj_get(value, key));
    if let Some(window) = usage_window(routines, "claude-routines", "Daily Routines", 604_800) {
        windows.push(window);
    }
    let extra = obj_get(value, "extra_usage").or_else(|| obj_get(value, "extraUsage"));
    if let Some(utilization) = extra.and_then(|v| number(obj_get(v, "utilization"))) {
        windows.push(QuotaWindow {
            id: "extra_usage".to_owned(),
            title: "Extra usage".to_owned(),
            used_percent: clamp_percent(utilization),
            resets_at: None,
            duration_seconds: None,
            remaining_value: None,
            limit_value: None,
            value_unit: None,
        });
    }
    windows
}

fn usage_window(
    value: Option<&Value>,
    id: &str,
    title: &str,
    duration: u64,
) -> Option<QuotaWindow> {
    let value = value?;
    let utilization = number(obj_get_any(
        value,
        &["utilization", "utilization_pct", "percent"],
    ))?;
    Some(QuotaWindow {
        id: id.to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(utilization),
        resets_at: obj_get_any(value, &["resets_at", "resetsAt", "reset_at", "resetAt"])
            .and_then(|v| parse_date(Some(v)))
            .map(super::common::unix_seconds_to_iso),
        duration_seconds: Some(duration),
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    })
}

fn map_profile(value: &Value) -> (Option<String>, Option<String>) {
    let account = obj_get(value, "account");
    let organization = obj_get(value, "organization");
    (
        obj_get_any(
            account.unwrap_or(&Value::Null),
            &["emailAddress", "email_address", "email"],
        )
        .and_then(|v| string(Some(v)))
        .or_else(|| {
            obj_get_any(value, &["emailAddress", "email_address", "email"])
                .and_then(|v| string(Some(v)))
        }),
        obj_get(organization.unwrap_or(&Value::Null), "uuid")
            .and_then(|v| string(Some(v)))
            .or_else(|| {
                obj_get_any(value, &["organizationUuid", "organization_uuid"])
                    .and_then(|v| string(Some(v)))
            }),
    )
}

fn is_all_models(model_id: Option<&str>, model_name: &str) -> bool {
    if slug(model_name, '-') == "all-models" {
        return true;
    }
    model_id
        .map(|id| {
            let id = slug(id, '-');
            id == "all-models" || id.ends_with("-all-models")
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated_context() -> CollectionContext {
        CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-claude-missing-home"),
            environment: std::collections::HashMap::new(),
            config_path: None,
            browser_sessions: std::collections::HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
        }
    }

    #[test]
    fn discovers_browser_session_when_oauth_is_absent() {
        let mut context = isolated_context();
        assert!(!context.allows_host_keychain());
        assert!(discover(&context).is_empty());
        context
            .browser_sessions
            .insert(ProviderId::Claude, "sessionKey=sk-ant-ok".to_owned());
        let sessions = discover(&context);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].credential_source, "browser_session");
    }

    #[test]
    fn maps_optional_usage_windows_and_extra_usage() {
        let windows = map_usage(&serde_json::json!({
            "five_hour": null,
            "seven_day": {"utilization": 41.5, "resets_at": "2026-08-09T12:00:00Z"},
            "extra_usage": {"utilization": 12.5}
        }));
        assert!(windows.iter().any(|window| window.id == "seven_day"));
        assert!(windows.iter().any(|window| window.id == "extra_usage"));
        let aliased = map_usage(&serde_json::json!({
            "five_hour": {"utilization_pct": 10, "reset_at": "2026-08-09T12:00:00Z"}
        }));
        assert_eq!(aliased[0].id, "five_hour");
        assert_eq!(aliased[0].used_percent, 10.0);
    }

    #[test]
    fn maps_cli_usage_panel_used_percent_verbatim() {
        let panel = concat!(
            "\u{1b}[1mSettings\u{1b}[0m  Usage\n",
            "Current session\n",
            "\u{1b}[32m████\u{1b}[0m░░░░░░░░░░░░░░░░ 20% used\n",
            "Resets 4pm (Asia/Shanghai)\n",
            "\n",
            "Current week (all models)\n",
            "█████████░░░░░░░░░░░ 45% used\n",
            "Resets Aug 25 at 9am (Asia/Shanghai)\n",
            "\n",
            "Current week (Sonnet only)\n",
            "██░░░░░░░░░░░░░░░░░░ 10% used\n",
        );
        let windows = map_cli_usage_text(panel);
        assert_eq!(
            windows
                .iter()
                .map(|window| (window.id.as_str(), window.used_percent))
                .collect::<Vec<_>>(),
            [
                ("five_hour", 20.0),
                ("seven_day", 45.0),
                ("seven_day_sonnet", 10.0),
            ]
        );
        assert!(map_cli_usage_text("Not logged in\n").is_empty());
        // A remaining-style phrasing is converted; a bare percentage is ignored.
        let remaining =
            map_cli_usage_text("Current session\n████ 80% left\nCurrent week (all models)\n45%\n");
        assert_eq!(
            remaining
                .iter()
                .map(|window| (window.id.as_str(), window.used_percent))
                .collect::<Vec<_>>(),
            [("five_hour", 20.0)]
        );
    }

    #[test]
    fn maps_cursor_positioned_panel_and_model_scoped_week() {
        // The TUI places words with cursor moves, so spacing is unreliable, and a
        // session's stats block precedes the windows.
        let panel = concat!(
            "\u{1b}]0;claude\u{7}Session Total cost: $0.0000\u{1b}[3;5H",
            "Current\u{1b}[1Csession████████████████▌\u{1b}[12C33%usedResets 10:30pm (Asia/Singapore)",
            "\u{1b}[5;1HCurrent week (all models)   ██▌   5% used  Resets Aug 23 at 12pm",
            "\u{1b}[7;1H+50% weekly limits promo through Aug 31",
            "\u{1b}[9;1HCurrent week (Fable)██▌\u{1b}[40C5% used",
        );
        let windows = map_cli_usage_text(panel);
        assert_eq!(
            windows
                .iter()
                .map(|window| (
                    window.id.as_str(),
                    window.title.as_str(),
                    window.used_percent
                ))
                .collect::<Vec<_>>(),
            [
                ("five_hour", "5 hour", 33.0),
                ("seven_day", "Weekly", 5.0),
                ("claude-weekly-scoped-fable", "Fable only", 5.0),
            ]
        );
    }

    #[test]
    fn parses_oauth_credentials_and_rejects_mcp_only_payloads() {
        let credentials = parse_credentials(
            &serde_json::json!({
                "claudeAiOauth": {
                    "accessToken": "claude-access",
                    "refreshToken": "claude-refresh",
                    "expiresAt": "2026-08-11T00:00:00Z",
                    "scopes": ["user:profile"],
                    "subscriptionType": "pro",
                    "rateLimitTier": "max"
                }
            }),
            "fixture",
        )
        .unwrap();
        assert_eq!(credentials.access_token, "claude-access");
        assert_eq!(credentials.expires_at, Some(1786406400));
        assert_eq!(credentials.scopes, ["user:profile"]);
        assert_eq!(credentials.subscription_type.as_deref(), Some("pro"));
        assert!(
            parse_credentials(
                &serde_json::json!({
                    "mcpOAuth": {"token": "mcp-only"}
                }),
                "fixture"
            )
            .is_none()
        );
        assert!(
            parse_credentials(
                &serde_json::json!({
                    "claudeAiOauth": {"scopes": ["user:profile"]}
                }),
                "fixture"
            )
            .is_none()
        );
    }

    #[test]
    fn keeps_scoped_model_limits_and_drops_all_models_scope() {
        let windows = map_usage(&serde_json::json!({
            "limits": [
                {"kind": "weekly_scoped", "group": "weekly", "percent": 17,
                 "scope": {"model": {"id": "claude-sonnet-4", "display_name": "Claude Sonnet"}},
                 "resets_at": "2026-08-12T00:00:00Z"},
                {"kind": "weekly_scoped", "group": "weekly", "percent": 90,
                 "scope": {"model": {"id": "all-models", "display_name": "All models"}}}
            ]
        }));
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].id, "claude-weekly-scoped-claude-sonnet-4");
        assert_eq!(windows[0].used_percent, 17.0);
    }
}
