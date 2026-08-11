use quota_service::catalog::ProviderId;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputFormat {
    Text,
    Json,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutputOptions {
    pub format: OutputFormat,
    pub pretty: bool,
}

impl Default for OutputOptions {
    fn default() -> Self {
        Self {
            format: OutputFormat::Text,
            pretty: false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StatusOptions {
    pub providers: ProviderSelection,
    pub output: OutputOptions,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProviderSelection {
    Configured,
    All,
    Explicit(Vec<ProviderId>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SummaryOptions {
    pub pretty: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ConfigCommand {
    Set {
        provider: ProviderId,
        base_url: Option<String>,
    },
    Get {
        provider: ProviderId,
    },
    Unset {
        provider: ProviderId,
    },
    List,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    Help,
    Version,
    Status(StatusOptions),
    Doctor,
    Login { output: OutputOptions },
    Logout(OutputOptions),
    AuthStatus(OutputOptions),
    Sync(OutputOptions),
    AccountSummary(SummaryOptions),
    Config(ConfigCommand),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ParseError(pub String);

impl ParseError {
    fn unknown_command() -> Self {
        // Do not echo arguments after a command: config arguments can contain secrets supplied by
        // a shell wrapper, and fixed diagnostics make accidental disclosure less likely.
        Self("Unknown command. Run `quotacli help` for usage.".to_owned())
    }

    fn unknown_option() -> Self {
        Self("Unknown option. Run `quotacli help` for usage.".to_owned())
    }

    fn missing_option_value() -> Self {
        Self("Option value is missing.".to_owned())
    }
}

pub fn parse<I>(args: I) -> Result<Command, ParseError>
where
    I: IntoIterator,
    I::Item: Into<String>,
{
    let args = args.into_iter().map(Into::into).collect::<Vec<_>>();
    let Some(command) = args.first().map(String::as_str) else {
        return Ok(Command::Help);
    };
    match command {
        "help" | "--help" | "-h" => Ok(Command::Help),
        "version" | "--version" | "-v" => Ok(Command::Version),
        "status" => parse_status(&args[1..]),
        "doctor"
            if args[1..]
                .iter()
                .any(|arg| matches!(arg.as_str(), "--help" | "-h")) =>
        {
            Ok(Command::Help)
        }
        "doctor" => parse_no_options(&args[1..], Command::Doctor),
        "login" => parse_login(&args[1..]),
        "logout"
            if args[1..]
                .iter()
                .any(|arg| matches!(arg.as_str(), "--help" | "-h")) =>
        {
            Ok(Command::Help)
        }
        "logout" => parse_output_only(&args[1..]).map(Command::Logout),
        "auth" => parse_auth(&args[1..]),
        "sync" => parse_sync(&args[1..]),
        "account" => parse_account(&args[1..]),
        "config" => parse_config(&args[1..]),
        _ => Err(ParseError::unknown_command()),
    }
}

fn parse_no_options<T>(args: &[String], value: T) -> Result<T, ParseError> {
    if args.is_empty() || (args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h")) {
        return Ok(value);
    }
    Err(ParseError::unknown_option())
}

fn parse_status(args: &[String]) -> Result<Command, ParseError> {
    let mut output = OutputOptions::default();
    let mut providers = ProviderSelection::Configured;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--help" | "-h" => return Ok(Command::Help),
            "--pretty" => output.pretty = true,
            "--format" => {
                output.format = parse_format(next_value(args, &mut index)?)?;
            }
            value if value.starts_with("--format=") => {
                output.format = parse_format(value.trim_start_matches("--format=").to_owned())?;
            }
            "--provider" => {
                let value = next_value(args, &mut index)?;
                providers = parse_provider_selection(&value)?;
            }
            value if value.starts_with("--provider=") => {
                providers = parse_provider_selection(value.trim_start_matches("--provider="))?;
            }
            _ => return Err(ParseError::unknown_option()),
        }
        index += 1;
    }
    Ok(Command::Status(StatusOptions { providers, output }))
}

fn parse_login(args: &[String]) -> Result<Command, ParseError> {
    if args
        .iter()
        .any(|arg| matches!(arg.as_str(), "--help" | "-h"))
    {
        return Ok(Command::Help);
    }
    parse_output_only(args).map(|output| Command::Login { output })
}

fn parse_auth(args: &[String]) -> Result<Command, ParseError> {
    if args.first().map(String::as_str) != Some("status") {
        return Err(ParseError("Unknown auth command.".to_owned()));
    }
    if args[1..]
        .iter()
        .any(|arg| matches!(arg.as_str(), "--help" | "-h"))
    {
        return Ok(Command::Help);
    }
    parse_output_only(&args[1..]).map(Command::AuthStatus)
}

fn parse_sync(args: &[String]) -> Result<Command, ParseError> {
    let mut output = OutputOptions {
        format: OutputFormat::Json,
        pretty: false,
    };
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--help" | "-h" => return Ok(Command::Help),
            "--pretty" => output.pretty = true,
            "--format" => {
                if parse_format(next_value(args, &mut index)?)? != OutputFormat::Json {
                    return Err(ParseError("sync supports --format json.".to_owned()));
                }
            }
            value if value.starts_with("--format=") => {
                if parse_format(value.trim_start_matches("--format=").to_owned())?
                    != OutputFormat::Json
                {
                    return Err(ParseError("sync supports --format json.".to_owned()));
                }
            }
            _ => return Err(ParseError::unknown_option()),
        }
        index += 1;
    }
    Ok(Command::Sync(output))
}

fn parse_output_only(args: &[String]) -> Result<OutputOptions, ParseError> {
    let mut output = OutputOptions::default();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--pretty" => output.pretty = true,
            "--format" => output.format = parse_format(next_value(args, &mut index)?)?,
            value if value.starts_with("--format=") => {
                output.format = parse_format(value.trim_start_matches("--format=").to_owned())?;
            }
            _ => return Err(ParseError::unknown_option()),
        }
        index += 1;
    }
    Ok(output)
}

fn parse_account(args: &[String]) -> Result<Command, ParseError> {
    if args.first().map(String::as_str) != Some("summary") {
        return Err(ParseError("Unknown account command.".to_owned()));
    }
    let mut summary = SummaryOptions { pretty: false };
    let mut index = 1;
    while index < args.len() {
        let key = args[index].as_str();
        match key {
            "--help" | "-h" => return Ok(Command::Help),
            "--pretty" => summary.pretty = true,
            "--format" => {
                let value = next_value(args, &mut index)?;
                if value != "json" {
                    return Err(ParseError(
                        "account summary supports --format json.".to_owned(),
                    ));
                }
            }
            value if value.starts_with("--format=") => {
                if value.trim_start_matches("--format=") != "json" {
                    return Err(ParseError(
                        "account summary supports --format json.".to_owned(),
                    ));
                }
            }
            _ => return Err(ParseError::unknown_option()),
        }
        index += 1;
    }
    Ok(Command::AccountSummary(summary))
}

fn parse_config(args: &[String]) -> Result<Command, ParseError> {
    let Some(verb) = args.first().map(String::as_str) else {
        return Err(ParseError("Missing config command.".to_owned()));
    };
    match verb {
        "list" if args.len() == 1 => Ok(Command::Config(ConfigCommand::List)),
        "get" => parse_provider_verb(&args[1..], |provider| ConfigCommand::Get { provider }),
        "unset" => parse_provider_verb(&args[1..], |provider| ConfigCommand::Unset { provider }),
        "set" => parse_config_set(&args[1..]),
        "--help" | "-h" => Ok(Command::Help),
        _ => Err(ParseError("Unknown config command.".to_owned())),
    }
}

fn parse_provider_verb<F>(args: &[String], make: F) -> Result<Command, ParseError>
where
    F: FnOnce(ProviderId) -> ConfigCommand,
{
    if args.len() != 1 {
        return Err(ParseError("Expected exactly one provider.".to_owned()));
    }
    Ok(Command::Config(make(parse_provider(&args[0])?)))
}

fn parse_config_set(args: &[String]) -> Result<Command, ParseError> {
    let mut provider = None;
    let mut base_url = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--api-key" | "--api-key-stdin" => {
                // Deliberately do not include the value in the diagnostic.
                return Err(ParseError(
                    "Do not pass API keys on the command line; config set reads the key from stdin.".to_owned(),
                ));
            }
            "--base-url" => base_url = Some(next_value(args, &mut index)?),
            value if value.starts_with("--base-url=") => {
                base_url = Some(value.trim_start_matches("--base-url=").to_owned());
            }
            value if value.starts_with('-') => return Err(ParseError::unknown_option()),
            value => {
                if provider.is_some() {
                    return Err(ParseError("Expected exactly one provider.".to_owned()));
                }
                provider = Some(parse_provider(value)?);
            }
        }
        index += 1;
    }
    let Some(provider) = provider else {
        return Err(ParseError("Missing provider.".to_owned()));
    };
    Ok(Command::Config(ConfigCommand::Set { provider, base_url }))
}

fn parse_provider_selection(value: &str) -> Result<ProviderSelection, ParseError> {
    if value == "all" {
        return Ok(ProviderSelection::All);
    }
    let mut providers = Vec::new();
    for part in value
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
    {
        let provider = parse_provider(part)?;
        if !providers.contains(&provider) {
            providers.push(provider);
        }
    }
    if providers.is_empty() {
        return Err(ParseError("Missing value for --provider.".to_owned()));
    }
    Ok(ProviderSelection::Explicit(providers))
}

fn parse_provider(value: &str) -> Result<ProviderId, ParseError> {
    ProviderId::parse(value).ok_or_else(|| ParseError("Invalid provider.".to_owned()))
}

fn next_value(args: &[String], index: &mut usize) -> Result<String, ParseError> {
    *index += 1;
    args.get(*index)
        .cloned()
        .ok_or_else(ParseError::missing_option_value)
}

fn parse_format(value: String) -> Result<OutputFormat, ParseError> {
    match value.as_str() {
        "text" => Ok(OutputFormat::Text),
        "json" => Ok(OutputFormat::Json),
        _ => Err(ParseError("Invalid --format value.".to_owned())),
    }
}

pub fn usage() -> &'static str {
    "QuotaCLI\n\nUsage:\n  quotacli version\n  quotacli status [--provider <id>|all] [--format text|json] [--pretty]\n  quotacli doctor\n  quotacli login [--format text|json] [--pretty]\n  quotacli logout [--format text|json] [--pretty]\n  quotacli auth status [--format text|json] [--pretty]\n  quotacli sync [--format json] [--pretty]\n  quotacli account summary [--format json] [--pretty]\n  quotacli config set <provider> [--base-url <url>]\n  quotacli config get <provider>\n  quotacli config unset <provider>\n  quotacli config list\n  quotacli help"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_words(value: &str) -> Result<Command, ParseError> {
        parse(value.split_whitespace().map(str::to_owned))
    }

    #[test]
    fn parses_native_command_shapes_without_a_parser_dependency() {
        assert!(matches!(parse_words("version"), Ok(Command::Version)));
        assert!(matches!(parse_words("doctor"), Ok(Command::Doctor)));
        assert!(matches!(
            parse_words("login --format json"),
            Ok(Command::Login {
                output: OutputOptions {
                    format: OutputFormat::Json,
                    ..
                }
            })
        ));
        assert!(matches!(
            parse_words("auth status --format json"),
            Ok(Command::AuthStatus(_))
        ));
        assert!(matches!(
            parse_words("sync --format=json --pretty"),
            Ok(Command::Sync(_))
        ));
        assert!(matches!(
            parse_words("account summary --format json --pretty"),
            Ok(Command::AccountSummary(_))
        ));
    }

    #[test]
    fn rejects_secret_argv_and_invalid_options_without_echoing_values() {
        let error = parse_words("config set openrouter --api-key super-secret").unwrap_err();
        assert_eq!(
            error.0,
            "Do not pass API keys on the command line; config set reads the key from stdin."
        );
        assert!(!error.0.contains("super-secret"));
        assert!(parse_words("status --provider no-such-provider").is_err());
        assert!(parse_words("status --format yaml").is_err());
        assert!(parse_words("login --device-auth").is_err());
    }

    #[test]
    fn deduplicates_explicit_providers_and_rejects_unimplemented_summary_filters() {
        let command = parse_words("status --provider codex,codex,claude").expect("status");
        let Command::Status(options) = command else {
            panic!("status")
        };
        assert_eq!(
            options.providers,
            ProviderSelection::Explicit(vec![ProviderId::Codex, ProviderId::Claude])
        );
        assert!(parse_words("account summary --from 2026-01-03").is_err());
    }
}
