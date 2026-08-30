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
        ProviderId::Codex => codex::SOURCE,
        ProviderId::Claude => claude::SOURCE,
        ProviderId::Grok => grok::SOURCE,
        ProviderId::OpenRouter => openrouter::SOURCE,
        ProviderId::DeepSeek => deepseek::SOURCE,
        // Kimi has two official rungs that answer the same endpoint; the Settings page shows
        // them as two rows, so a success names the one the session was discovered from.
        ProviderId::Kimi if kimi::is_cli_credential_source(&session.credential_source) => {
            kimi::CLI_SOURCE
        }
        ProviderId::Kimi => kimi::SOURCE,
        ProviderId::LiteLlm => litellm::SOURCE,
        ProviderId::Cursor => cursor::APP_SOURCE,
    }
}

/// Whether a source is a browser session this app stores, which is re-added here rather
/// than renewed in the program that owns the provider.
///
/// Source ids are written for code and travel through the report as ids. What a person calls
/// one is QuotaBar's table in Swift, which is where the report is read; the only question
/// asked on this side is this one.
pub fn is_browser_session_source(source_id: &str) -> bool {
    matches!(
        source_id,
        BROWSER_SESSION_SOURCE
            | claude::WEB_SOURCE
            | codex::WEB_SOURCE
            | grok::WEB_SOURCE
            | kimi::WEB_SOURCE
            | cursor::WEB_SOURCE
    )
}

pub fn validate_browser_session(
    provider: ProviderId,
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    let cookie_header = common::normalize_browser_cookie_header(provider, cookie_header)?;
    match provider {
        ProviderId::Codex => codex::validate_browser_session(&cookie_header, context),
        ProviderId::Claude => claude::validate_browser_session(&cookie_header, context),
        ProviderId::Grok => grok::validate_browser_session(&cookie_header, context),
        ProviderId::Kimi => kimi::validate_browser_session(&cookie_header, context),
        ProviderId::Cursor => cursor::validate_browser_session(&cookie_header, context),
        _ => Err(ProviderError::new(
            common::ErrorCategory::Unsupported,
            BROWSER_SESSION_SOURCE,
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kimi_session_names_the_rung_it_was_discovered_from() {
        let session = |credential_source: &str| ProviderSession {
            provider: ProviderId::Kimi,
            credential_source: credential_source.to_owned(),
            cookie_header: None,
        };
        assert_eq!(
            session_source_id(ProviderId::Kimi, &session("providers.json")),
            kimi::SOURCE
        );
        assert_eq!(
            session_source_id(ProviderId::Kimi, &session("KIMI_API_KEY")),
            kimi::SOURCE
        );
        assert_eq!(
            session_source_id(
                ProviderId::Kimi,
                &session("/Users/me/.kimi-code/credentials/kimi-code.json")
            ),
            kimi::CLI_SOURCE
        );
        assert_eq!(
            session_source_id(ProviderId::Kimi, &session(BROWSER_SESSION_SOURCE)),
            BROWSER_SESSION_SOURCE
        );
    }

    use std::collections::BTreeMap;
    use std::path::Path;

    /// Split so that scanning this file does not find the scanner.
    const SPAWN: &str = concat!("Command", "::new(");

    /// Every program named by a literal in `src/providers`, and how many call sites name it.
    ///
    /// The count is the point: a set said "`/usr/bin/security` is expected here" and would
    /// have taken a second, a third, and a fourth call site without a word.
    const NAMED_PROGRAMS: &[(&str, usize)] = &[
        // The bounded runner proving its own bounds, in its own test.
        ("/bin/sh", 6),
        // Claude Code's Keychain grant, plus the call that asks only whether the entry is
        // there — which is what separates a Mac that was never signed in from one that is not
        // allowed to read the secret, and runs only when reading it failed.
        ("/usr/bin/security", 2),
    ];

    /// The only functions allowed to start a program a variable names, each with the rule
    /// that keeps it off the five-minute timer. Both run on the refresh worker before
    /// collection; no collector starts anything.
    const NAMED_SPAWNS: &[(&str, &str)] = &[
        // `<binary> --version`, to fill in the header this build sends as the provider's own
        // CLI. Runs when the installed binary's fingerprint is absent or has changed, at most
        // once per installed binary and never more than once an hour.
        ("common/cli_version.rs", "probe"),
        // The one renewal: `claude mcp list`, `codex app-server`, or `grok agent stdio`, to
        // have the CLI that owns a sign-in renew it. Runs only when the credential on disk is
        // already out of time, and at most once an hour per provider whatever the last attempt
        // produced. Which program and which conversation is the provider's to state; this is
        // the only place any of them is started.
        ("common/renewal.rs", "renew"),
    ];

    fn visit(
        directory: &Path,
        found: &mut BTreeMap<String, usize>,
        spawns: &mut Vec<(String, String)>,
    ) {
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
                    *found
                        .entry(argument.trim_matches('"').to_owned())
                        .or_default() += 1;
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
    /// provider CLI earns, and the one renewal an already-expired Claude Code, Codex, or Grok
    /// credential earns; everything else was a provider CLI driven on a five-minute timer,
    /// and this counts the call sites so a new one cannot arrive quietly.
    #[test]
    fn collection_starts_no_process_it_did_not_name() {
        let mut found = BTreeMap::new();
        let mut spawns = Vec::new();
        visit(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("src/providers"),
            &mut found,
            &mut spawns,
        );
        assert_eq!(
            found,
            NAMED_PROGRAMS
                .iter()
                .map(|(program, count)| ((*program).to_owned(), *count))
                .collect::<BTreeMap<_, _>>(),
            "each named program is allowed exactly the call sites listed with it"
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
