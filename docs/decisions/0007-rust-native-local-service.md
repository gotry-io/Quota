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
1 MiB. The helper emits `ready` when its local state is open and answers `ping` without taking a
lock; those two facts, not a request deadline, tell QuotaBar whether the child is starting, working,
or gone. `get_state` is read-only and returns persisted last-known-good state immediately; startup and
five-minute refreshes run in the service background. QuotaBar and the service ship atomically, so an
unreleased private IPC change replaces both sides directly rather than adding compatibility shims.

The shared Rust crate is the sole local owner of:

- all seven provider quota collectors and optional provider configuration;
- all six Usage parsers, file-level incremental indexing, normalization, aggregation, and local
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

QuotaBar 0.0.6 and 0.0.7 transactionally imported the released installation, session, Usage cache,
Usage outbox, and pricing cache under the released `state.lock`. QuotaBar 0.0.8 completed the planned
cutover by deleting the compatibility module, one-time JSON import, old lock/path handling,
version-specific Relay behavior, and their focused tests. Local schema migration v3 removes the
temporary imported-artifact table and marker without rewriting the already-applied v1 migration.
The shared `providers.json`/`ProviderConfigLock` path and OAuth `client_id=quotacli` remain current
interfaces.
Released managed-network protocol v2, its compatible Relay routes, and already published npm
artifacts remain supported boundaries. Current clients use the managed-data evolution documented in
[ADR 0012](0012-managed-data-v3.md). There is no fallback to the deleted TypeScript/Bun runtime or
compatibility layer for its local command surface.

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
