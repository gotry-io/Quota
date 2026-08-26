//! Provider quota collectors.
//!
//! Collectors deliberately return normalized, redacted snapshots. Credentials and provider-owned
//! response bodies never cross this module's result boundary.

pub mod claude;
pub mod codex;
pub mod common;
pub mod cursor;
pub mod deepseek;
pub mod grok;
pub mod kimi;
pub mod litellm;
pub mod openrouter;

pub use common::{
    BROWSER_SESSION_SOURCE, CollectionContext, ProviderError, ProviderSession, QuotaSnapshot,
    ValidatedBrowserSession,
};

use crate::catalog::ProviderId;

pub fn discover(provider: ProviderId, context: &CollectionContext) -> Vec<ProviderSession> {
    match provider {
        ProviderId::Codex => codex::discover(context),
        ProviderId::Claude => claude::discover(context),
        ProviderId::Grok => grok::discover(context),
        ProviderId::OpenRouter => openrouter::discover(context),
        ProviderId::DeepSeek => deepseek::discover(context),
        ProviderId::Kimi => kimi::discover(context),
        ProviderId::LiteLlm => litellm::discover(context),
        ProviderId::Cursor => cursor::discover(context),
    }
}

pub fn collect(
    provider: ProviderId,
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    match provider {
        ProviderId::Codex => codex::collect(session, context),
        ProviderId::Claude => claude::collect(session, context),
        ProviderId::Grok => grok::collect(session, context),
        ProviderId::OpenRouter => openrouter::collect(session, context),
        ProviderId::DeepSeek => deepseek::collect(session, context),
        ProviderId::Kimi => kimi::collect(session, context),
        ProviderId::LiteLlm => litellm::collect(session, context),
        ProviderId::Cursor => cursor::collect(session, context),
    }
}

/// The source a discovered session reads from.
///
/// A failed read names the exact rung that produced its verdict, in
/// [`ProviderError::source_id`].  A successful one has no error to name it, so the report
/// records where the session came from: a stored browser session, or the provider's own
/// credential path.
pub fn session_source_id(provider: ProviderId, session: &ProviderSession) -> &'static str {
    if session.credential_source == BROWSER_SESSION_SOURCE {
        return BROWSER_SESSION_SOURCE;
    }
    match provider {
        ProviderId::Codex => codex::SOURCE_API,
        ProviderId::Claude => claude::SOURCE,
        ProviderId::Grok => grok::SOURCE,
        ProviderId::OpenRouter => openrouter::SOURCE,
        ProviderId::DeepSeek => deepseek::SOURCE,
        ProviderId::Kimi => kimi::SOURCE,
        ProviderId::LiteLlm => litellm::SOURCE,
        ProviderId::Cursor => cursor::APP_SOURCE,
    }
}

/// What a person calls a collection source.
///
/// Source ids are written for code and travel through the report as ids; this is the one
/// place that turns them into words for a reader.  QuotaBar keeps the same table in Swift,
/// because the report crosses the IPC boundary as ids and nothing else.
pub fn source_display_name(source_id: &str) -> &'static str {
    match source_id {
        claude::SOURCE
        | claude::SIGNED_OUT_SOURCE
        | codex::SOURCE_API
        | grok::SOURCE
        | grok::BILLING_RPC_SOURCE => "OAuth",
        codex::SOURCE_PAT => "Access token",
        BROWSER_SESSION_SOURCE | cursor::SOURCE => "Browser session",
        cursor::APP_SOURCE => "Cursor app session",
        kimi::CLI_SOURCE => "Kimi Code token",
        kimi::SOURCE | openrouter::SOURCE | deepseek::SOURCE | litellm::SOURCE => "API key",
        _ => "Provider",
    }
}

/// Whether a source is a browser session this app stores, which is re-added here rather
/// than renewed in the program that owns the provider.
pub fn is_browser_session_source(source_id: &str) -> bool {
    source_display_name(source_id) == "Browser session"
}

pub fn validate_browser_session(
    provider: ProviderId,
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    let cookie_header = common::normalize_browser_cookie_header(provider, cookie_header)?;
    match provider {
        ProviderId::Cursor => cursor::validate_browser_session(&cookie_header, context),
        _ => Err(ProviderError::new(
            common::ErrorCategory::Unsupported,
            BROWSER_SESSION_SOURCE,
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::path::Path;

    /// Split so that scanning this file does not find the scanner.
    const SPAWN: &str = concat!("Command", "::new(");

    /// The only functions allowed to start a program a variable names, each with the rule
    /// that keeps it off the five-minute timer. All three run on the refresh worker before
    /// collection; no collector starts anything.
    const NAMED_SPAWNS: &[(&str, &str)] = &[
        // `claude mcp list`, to have Claude Code renew the sign-in it owns. Runs only when the
        // credential on disk is already expired or within a minute of it and holds a refresh
        // token to renew from, and at most once an hour whatever the last attempt produced.
        ("claude/refresh.rs", "renew"),
        // `<binary> --version`, to fill in the header this build sends as the provider's own
        // CLI. Runs when the installed binary's fingerprint is absent or has changed, at most
        // once per installed binary and never more than once an hour.
        ("common/cli_version.rs", "probe"),
        // `grok agent stdio`, to have the CLI that owns Grok's token renew it. Runs only when
        // the token on disk is already expired or within a minute of it, and at most once an
        // hour whatever the last attempt produced.
        ("grok/refresh.rs", "renew"),
    ];

    fn visit(directory: &Path, found: &mut BTreeSet<String>, spawns: &mut Vec<(String, String)>) {
        for entry in std::fs::read_dir(directory).expect("provider sources") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                visit(&path, found, spawns);
                continue;
            }
            if path.extension().and_then(std::ffi::OsStr::to_str) != Some("rs") {
                continue;
            }
            let text = std::fs::read_to_string(&path).expect("source");
            for (index, _) in text.match_indices(SPAWN) {
                let argument = text[index + SPAWN.len()..]
                    .split(')')
                    .next()
                    .unwrap_or_default()
                    .trim();
                if argument.starts_with('"') {
                    found.insert(argument.trim_matches('"').to_owned());
                    continue;
                }
                let module = NAMED_SPAWNS
                    .iter()
                    .find(|(module, _)| path.ends_with(module))
                    .map(|(module, _)| *module);
                let Some(module) = module else {
                    panic!(
                        "{}: {SPAWN}{argument}) starts a program a variable names, which is how \
                         a provider CLI ends up spawned on a five-minute timer",
                        path.display()
                    );
                };
                spawns.push((module.to_owned(), enclosing_function(&text[..index])));
            }
        }
    }

    /// The name of the function a byte offset sits in, so the allowance above can be spent on
    /// one function rather than on a file.
    fn enclosing_function(before: &str) -> String {
        before
            .rfind("fn ")
            .map(|index| {
                before[index + 3..]
                    .split(['(', '<'])
                    .next()
                    .unwrap_or_default()
                    .trim()
                    .to_owned()
            })
            .unwrap_or_default()
    }

    /// Collection reads files and speaks HTTP.  The processes a refresh starts are the macOS
    /// Keychain lookup that finds Claude's grant, the one `--version` a newly installed
    /// provider CLI earns, and the two renewals an already-expired Claude Code or Grok
    /// credential earns; everything else was a provider CLI driven on a five-minute timer,
    /// and this counts the call sites so a new one cannot arrive quietly.
    #[test]
    fn collection_starts_no_process_it_did_not_name() {
        let mut found = BTreeSet::new();
        let mut spawns = Vec::new();
        visit(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("src/providers"),
            &mut found,
            &mut spawns,
        );
        assert_eq!(
            found,
            // `/bin/sh` is the bounded runner proving its own bounds, in its own test.
            BTreeSet::from(["/bin/sh".to_owned(), "/usr/bin/security".to_owned()])
        );
        spawns.sort();
        let named = NAMED_SPAWNS
            .iter()
            .map(|(module, function)| ((*module).to_owned(), (*function).to_owned()))
            .collect::<Vec<_>>();
        assert_eq!(
            spawns, named,
            "each named spawn is allowed exactly one call site, in the function named with it"
        );
    }
}
