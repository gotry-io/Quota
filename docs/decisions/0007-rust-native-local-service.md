# ADR 0007: Rust-native QuotaBar local service

- Status: Accepted
- Date: 2026-08-10
- Updated by [ADR 0027](0027-one-token-per-client.md)

## Context

The released local implementation combined a Node/Bun CLI, repeated process startup, JSON state
files, and Swift-side caching and observation merging, so QuotaBar could show nothing durable until a
full helper run had finished runtime startup, credential discovery, provider requests, a complete
Usage scan, pricing, and account sync. A public macOS CLI, daemon, LaunchAgent, Unix socket, or
independently versioned local frontend would add lifecycle surface the product does not need.

## Decision

QuotaBar bundles one private Apple Silicon Rust executable at `Contents/Helpers/quota-service`,
launches it once, and keeps a bounded stdin/stdout NDJSON connection for the app lifetime. stdin EOF
is the ownership signal: when QuotaBar exits, the service cancels its work and exits. It never
daemonizes and has no public command or socket surface.

The shared implementation lives in `packages/service`. `apps/menubar/helper` is the macOS private
stdio entry point around that crate, and since [ADR 0027](0027-one-token-per-client.md) it is the
only entry point there is.

The private protocol is `snake_case` IPC v1 with request ids, typed operations, stable error and
recovery codes, independent component state, and revisioned state-change events, with lines limited
to 1 MiB. The helper emits `ready` when its local state is open and answers `ping` without taking a
lock; those two facts, not a request deadline, tell QuotaBar whether the child is starting, working,
or gone. `get_state` is read-only and returns last-known-good state immediately, while startup and
five-minute refreshes run in the background. QuotaBar and the service ship atomically, so a private
IPC change replaces both sides directly rather than adding a shim.

The shared crate is the sole local owner of every provider quota collector and its optional
configuration; every Usage parser, its incremental indexing, normalization, aggregation, and local
pricing; native account OAuth, Relay requests, session refresh, the durable outbox, and the account
summary; and the local SQLite stores, component last-known-good state, refresh scheduling, and the
merge of local and account observations for Overview. Swift owns presentation, strict IPC and
managed-wire decoding, UI preferences, accessibility, navigation, and Launch at Login: it does not
read service state or credential files, schedule sync, cache reports, merge subscriptions, or speak
to Relay or a provider.

The provider catalog is language-neutral JSON validated by JSON Schema, and generation keeps the
TypeScript network ids, the Rust metadata, and the Swift ids aligned. Optional provider secrets stay
in the owner-only `providers.json` path. Operational state is SQLite; there is no JSON/SQLite dual
write.

Usage invalidation is file-level: bounded discovery compares identity, size, mtime, and parser
revision against the file index, and unchanged files are skipped. A changed file that has only
grown, and whose whole parsed prefix still hashes to what it hashed before, is read from where the
last parse stopped; anything else is reparsed with its normalized rows replaced transactionally.
The index is the only invalidation mechanism — no watcher.

## Consequences

- QuotaBar renders persisted quota, Usage, and account state before background collection completes,
  and Rust removes a Node/Bun startup from the launch path.
- One process owns scheduling, SQLite, provider refresh, account mutation, and the outbox, so there
  is no duplicate Swift/TypeScript policy.
- The release workflow must build, sign, verify, and notarize a Swift and a Rust executable together.
- Rust duplicates only the local half of the model and pricing behaviour Relay and Web still need in
  TypeScript; cross-language fixtures and generated provider ids guard that seam.
- Quitting QuotaBar stops synchronization. An always-on headless agent is out of scope.
