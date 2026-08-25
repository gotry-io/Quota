# QuotaCLI

`quotacli` is the Linux-native Quota command-line client. It is a direct Rust binary and shares
the provider, Usage, Relay, protocol, and owner-only local state implementation with QuotaBar
through [`quota-service`](../../packages/service).

## Commands

```text
quotacli version
quotacli status [--provider <id>|all] [--format text|json] [--pretty]
quotacli doctor [--format text|json] [--pretty]
quotacli login [--format text|json] [--pretty]
quotacli logout [--format text|json] [--pretty]
quotacli auth status [--format text|json] [--pretty]
quotacli sync [--format json] [--pretty]
quotacli account summary [--format json] [--pretty]
quotacli config set <provider> [--base-url <url>]
quotacli config get <provider>
quotacli config unset <provider>
quotacli config list
```

Provider API keys are read from stdin for `config set`; an API key is never accepted on argv.
`config get` and `config list` only print masked configuration status. Local state is stored at
`$XDG_CONFIG_HOME/quotacli` or `~/.config/quotacli`.

This crate targets Linux. A small non-Linux entry-point guard keeps parser tests buildable on
developers' macOS hosts; it does not provide a Windows implementation.

`cli-vX.Y.Z` releases contain a static x86_64 Linux binary archive and its SHA-256 checksum. npm,
Homebrew, source-package, macOS, and Windows distributions are not provided.

`login` is headless on Linux: it requests an OAuth Device Authorization Grant, prints the
verification URL and user code, and polls Relay until the browser account flow approves or expires.
It never opens a browser or creates a loopback listener. Device codes and session tokens are never
printed. Use a browser on another device to open the displayed URL when the CLI host has no GUI.

`account summary` returns one Account read: the account, its devices, the subscriptions Relay
resolved from every device that reported them, and the four periods — Today, 7 Days, 30 Days, and
All — in this host's own calendar. It goes through the shared token-refresh and compare-and-swap
state path.

`sync` runs one refresh and prints the local state it left behind: collected quota, the local Usage
periods folded from this host's hourly facts, and the account read above under `account_summary`.

`doctor` renders the shared service report. It lists the four surfaces — Quota Overview, this
device's Usage, Account Usage, and Account — and the sources behind them: provider discovery and
quota, Usage parsing, the pricing catalog, account state, and the upload path. Every sentence comes
from the service; `doctor` prints it rather than mapping a code to copy of its own. Missing optional
setup is inactive, and waiting for the next scheduler opportunity is normal. Text is intended for a
terminal; JSON is bounded and safe to attach to a bug report. Both include the same service-owned
recent work, capped at 100 attempts. `--pretty` only changes JSON whitespace. The command exits `0`
when operation is healthy, every surface's data is current or empty, and attention is not required.
Anything else exits `1`. Paths, source filenames, model lists, raw logs or responses, parser
excerpts, prompts, completions, session or device identifiers, credentials, and tokens are never
printed.

## Development

```bash
cargo test --manifest-path apps/cli/Cargo.toml
cargo build --release --manifest-path apps/cli/Cargo.toml
```
