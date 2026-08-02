# Architecture

This document defines the target v1 system boundaries. It does not claim that every path is already
implemented; the repository's current milestone is maintained in the root
[`README.md`](../README.md#status).

## Products

The product list and user-facing descriptions are maintained in the root
[`README.md`](../README.md). Architecturally, QuotaBar, QuotaCLI, QuotaRelay, and Quota Web are four
independently runnable or deployable boundaries. Local collection must continue to work without the
managed service or a Relay account, and the website does not participate in credential discovery or
quota collection.

## Data paths

### Local provider

```text
QuotaBar ── user-only local IPC ── QuotaCLI ── local provider sessions
```

QuotaBar starts its bundled QuotaCLI helper. QuotaCLI discovers logged-in provider sessions,
collects quota, and returns a validated normalized report. Provider credentials remain inside the
QuotaCLI process boundary.

### Remote edge

```text
Remote QuotaCLI ── outbound HTTPS / WebSocket ── QuotaRelay ── QuotaBar
```

QuotaCLI pairs with an explicitly selected Relay, receives a Relay-bound device credential, and
sends normalized snapshots. Relay persists accepted snapshots and serves authenticated QuotaBar
clients. It never receives provider credentials or runs provider collectors.

Provider-specific collection order is defined only in
[`provider-collection.md`](provider-collection.md). Credential handling, logging, transport, and
storage requirements are defined only in [`security.md`](security.md).

## Runtime boundaries

### QuotaBar

- Swift 6.2 and SwiftUI, targeting macOS 14 or newer.
- Owns local presentation, Relay profiles, and merging local and remote snapshots.
- Stores Relay credentials in Keychain and profile metadata separately.
- Discovers Relay capabilities before using versioned endpoints.

### QuotaCLI

- TypeScript packaged as a standalone Bun executable.
- Owns all provider credential discovery and quota collection.
- Uses the same normalized schemas for local output and edge uploads.
- Avoids native Node addons so standalone cross-platform builds remain possible.

### QuotaRelay

- Hono application shared across Cloudflare and self-hosted entry points.
- Owns device lifecycle, Relay authentication, snapshot persistence, and realtime coordination.
- Accepts normalized protocol payloads only.

### Quota Web

- Static Vite application built independently into `apps/web/dist`.
- May share the managed Cloudflare hostname and Worker deployment with Relay APIs.
- Is not included in the self-hosted Relay executable or container image.

## Package dependency rules

```text
@gotry/quota-protocol
    ▲          ▲             ▲
    │          │             │
quota-model  provider-core  relay-core
                 ▲             ▲
                 │             │
            provider-node    relay app
                 ▲          ┌──┴──────────┐
                 │          │             │
             QuotaCLI     D1 state    SQLite state
```

- `quota-protocol`, `quota-model`, `provider-core`, and `relay-core` are runtime-neutral.
- `provider-node` may use Node/Bun system APIs and is imported only by QuotaCLI.
- Cloudflare code must not import filesystem, process execution, TCP, or `bun:sqlite` APIs.
- Self-hosted Relay code may use Bun and `bun:sqlite`.

## Relay runtimes

The managed runtime uses Cloudflare Workers, D1, and Durable Objects. The self-hosted runtime uses
Bun and an embedded SQLite file. Both implement the `@gotry/relay-core` state contract and expose the
same protocol behavior.

The persistence requirement, D1/SQLite choice, and R2 boundary are recorded in
[`decisions/0001-persistent-relay-storage.md`](decisions/0001-persistent-relay-storage.md). That ADR is
the source of truth for storage rationale.

## Relay discovery

Every Relay exposes:

```text
GET /.well-known/quotabar-relay
```

The managed discovery URL is
`https://quota.gotry.io/.well-known/quotabar-relay`. The document identifies the Relay instance,
supported API versions, authentication methods, deployment mode, and capabilities. Device
credentials are bound to the advertised issuer and instance ID.
