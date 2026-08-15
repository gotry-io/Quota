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

`account summary` returns the fresh default calculated-cost view through the shared token-refresh
and compare-and-swap state path.

`doctor` consumes the shared service diagnostic report. It covers provider discovery and quota,
Usage parsing and coverage, pricing, account state, and synchronization through the v2
surface/check/finding contract. Source checks distinguish this device, Account, and system work;
missing optional setup and waiting for the next scheduler opportunity are normal. Text is intended
for a terminal; JSON is bounded and safe to attach to a bug report. Both include the same
service-owned recent attempts: running work, the latest 20 refresh trees, recent failures, and a
history-truncated marker, capped at 512 entries. `--pretty` only changes JSON
whitespace. The command exits `0` when operation is healthy, data is current or empty, and attention
is not required. Degraded/blocked operation, stale/partial/unknown data, or required attention exits
with `1`. Paths, source filenames, model lists, raw logs/responses, parser excerpts, prompts,
completions, session or device identifiers, credentials, and tokens are never printed.

## Development

```bash
cargo test --manifest-path apps/cli/Cargo.toml
cargo build --release --manifest-path apps/cli/Cargo.toml
```
