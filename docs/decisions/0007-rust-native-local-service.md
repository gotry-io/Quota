# ADR 0007: Rust-native QuotaBar local service

- Status: Accepted
- Date: 2026-08-10

## Context

The released local implementation combined a Node/Bun CLI, repeated process startup, JSON state
files, and Swift-side caching and observation merging. QuotaBar could not display durable state until
a full helper run completed, so launch latency included runtime startup, credential discovery,
provider requests, complete Usage scanning, pricing, and account synchronization. Provider and Usage
semantics were also split across TypeScript and Swift boundaries that the macOS product did not need.

QuotaBar is the macOS local product. The repository also provides a Linux-only native Rust
`quotacli` entry point that reuses the local implementation. A public macOS CLI, background daemon,
LaunchAgent, Unix socket, Windows client, or independently versioned local frontend would add
lifecycle and compatibility surfaces without serving the current product.

## Decision

QuotaBar bundles one private Apple Silicon Rust executable at
`Contents/Helpers/quota-service`. QuotaBar launches it once and keeps a persistent bounded
stdin/stdout NDJSON connection for the app lifetime. stdin EOF is the ownership signal: when
QuotaBar exits, the service cancels work and exits. It never daemonizes and has no public command or
socket surface.

The shared implementation lives in `packages/service`. `apps/menubar/helper` is the macOS private
stdio entry point around that crate, while `apps/cli` is the Linux-only native `quotacli` entry point.
The Linux binary is built and tested in Ubuntu CI and released from `cli-v*` tags as a static x86_64
binary with a checksum. It has no npm, Homebrew, or source-package publication.

The private protocol is `snake_case` IPC v1 with request IDs, typed operations, stable error and
recovery codes, independent component state, and revisioned state-change events. Lines are limited to
1 MiB. `get_state` is read-only and returns persisted last-known-good state immediately; startup and
five-minute refreshes run in the service background. QuotaBar and the service ship atomically, so an
unreleased private IPC change replaces both sides directly rather than adding compatibility shims.

The shared Rust crate is the sole local owner of:

- all seven provider quota collectors and optional provider configuration;
- all five Usage parsers, file-level incremental indexing, normalization, aggregation, and local
  pricing;
- native account OAuth, Relay requests, session refresh, quota/Usage sequences, durable outbox, and
  account summary;
- SQLite schema and migrations, component last-known-good state, refresh scheduling, and merging
  local/account observations for Overview.

Swift owns presentation, strict IPC and managed-wire decoding, local UI preferences, accessibility,
navigation, and Launch at Login. It does not read service state/credential files, schedule periodic
sync, cache reports, merge subscriptions, or perform Relay/provider networking.

The provider catalog is language-neutral JSON validated by JSON Schema. Generation keeps TypeScript
network IDs, `packages/service` Rust metadata, and Swift IDs aligned. Optional provider secrets remain
in the released owner-only `providers.json` path so `quotacli` and QuotaBar serialize access to the
same configuration. Operational state is SQLite; there is no JSON/SQLite dual write.

Usage invalidation is the final file-level design: bounded discovery compares identity/size/mtime/
parser-revision against the SQLite file index, unchanged files are skipped, and changed files are
reparsed with their normalized rows replaced transactionally. The file index is the sole
invalidation mechanism; no watcher or byte-checkpoint dependency is used.

## Migration and compatibility

The first SQLite schema transactionally imports the released installation, session, Usage cache,
Usage outbox, and pricing cache once through `migration/legacy_json.rs`, under the released
`state.lock`; import is idempotent and source files are removed only after the new state is readable.
Native cutover starts at QuotaBar 0.0.6. Releases 0.0.6 and 0.0.7 retain the bounded 0.0.5 JSON/
`state.lock` import and explicit 0.0.5 server/wire behavior. QuotaBar 0.0.8 removes the
`compatibility` module, one-time import, old lock/path imports, and their focused tests. The shared
`providers.json`/`ProviderConfigLock` path and OAuth `client_id=quotacli` remain current interfaces.
Retained managed-network protocol v2, Relay data, and already published npm artifacts remain
compatible because they are released boundaries. There is no fallback to the deleted TypeScript/Bun
runtime or compatibility layer for its local command surface.

QuotaBar is distributed as a signed/notarized app and Homebrew Cask. The Cask installs no command.
Linux `quotacli` is distributed as a static x86_64 binary through GitHub Releases; npm, Homebrew,
and source-package publication remain intentionally absent.

## Consequences

- QuotaBar can render persisted quota, Usage, and account state before background collection
  completes; Rust removes Node/Bun startup from the launch path.
- One process owns scheduling, SQLite, provider refresh, account mutation, and outbox sequencing,
  eliminating duplicate Swift/TypeScript policy.
- The app bundle and release workflow must build, sign, verify, and notarize both Swift and Rust
  executables.
- Rust now duplicates only the local portions of network model/pricing behavior still needed in
  TypeScript by Relay/Web. Cross-language fixtures and generated provider IDs guard that boundary.
- Quitting QuotaBar intentionally stops synchronization. Users who need an always-on/headless agent
  are outside the current product scope.
- Ubuntu CI verifies and releases the Linux-native `quotacli`; Windows is not built or released.
