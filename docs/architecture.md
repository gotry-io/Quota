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
QuotaCLI process boundary. QuotaBar retains one last normalized local report so it can render
immediately after launch, then replaces that cache after a successful background collection.

### Remote edge

```text
Remote QuotaCLI ── outbound HTTPS ── QuotaRelay ── QuotaBar
```

QuotaCLI explicitly pairs with a selected Relay, receives a Relay-bound device credential, and sends
normalized snapshots only after edge reporting is enabled. Relay persists accepted snapshots and
serves authenticated QuotaBar clients. It never receives provider credentials or runs provider
collectors. Pairing ownership and token generation are defined in
[`decisions/0002-relay-device-code-pairing.md`](decisions/0002-relay-device-code-pairing.md).
Relay observation retention and QuotaBar subscription presentation are defined in
[`decisions/0003-observation-preserving-subscription-merge.md`](decisions/0003-observation-preserving-subscription-merge.md).

Provider-specific collection order is defined only in
[`provider-collection.md`](provider-collection.md). Credential handling, logging, transport, and
storage requirements are defined only in [`security.md`](security.md).

## Runtime boundaries

### QuotaBar

- Swift 6.2 and SwiftUI, targeting macOS 14 or newer.
- Owns local presentation, Relay profiles, and merging local and remote snapshots.
- Ships its exact compatible QuotaCLI helper inside the signed app bundle and never resolves it from
  the user's `PATH`.
- Stores Relay credentials in Keychain and profile metadata separately.
- Discovers and binds a Relay profile before using its versioned owner endpoints. Its owner client
  covers pairing decisions, snapshot reads, device listing, and device revocation.

### QuotaCLI

- TypeScript bundled as a Node ESM npm package and as a standalone Bun executable from the same
  entry point.
- Owns all provider credential discovery and quota collection.
- Uses the same normalized schemas for local output and edge uploads.
- Owns Relay discovery, Device Code pairing, and the single Relay-bound local edge credential.
  Pairing never enables recurring reporting by itself.
- Provides an explicit one-shot report path that validates the bound Relay instance, collects all
  providers, uploads one normalized envelope, and commits its local sequence after acceptance.
- On macOS, manages one user LaunchAgent that invokes that same `edge report` path at load and every
  300 seconds. Pairing does not load it, stopping retains pairing, and no background-service runtime
  is provided on other platforms.
- Avoids native Node addons so standalone cross-platform builds remain possible.

### QuotaRelay

- Hono application shared across Cloudflare and self-hosted entry points.
- Owns device lifecycle, Relay authentication, and snapshot persistence.
- Accepts normalized protocol payloads only.

### Quota Web

- Static Vite application built independently into `apps/web/dist`.
- Shares the managed `quota.gotry.io` hostname and `quota` Worker deployment with Relay APIs.
- Is not included in the self-hosted Relay executable or container image.

## Package dependency rules

```text
@gotry-io/quota-protocol
    ▲             ▲             ▲
    │             │             │
quota-model  quota-provider  relay-core
                  ▲             ▲
                  │             │
              QuotaCLI       relay app
                             ┌──┴──────────┐
                             │             │
                          D1 state    SQLite state
```

- `quota-protocol`, `quota-model`, and `relay-core` are runtime-neutral.
- `quota-provider` owns both provider contracts and their local implementations. It may use Node/Bun
  system APIs and is imported only by QuotaCLI.
- Cloudflare code must not import filesystem, process execution, TCP, or `bun:sqlite` APIs.
- Self-hosted Relay code may use Bun and `bun:sqlite`.

## Relay runtimes

The managed runtime uses Cloudflare Workers and D1. The self-hosted runtime uses Bun and an embedded
SQLite file. Both implement the `@gotry-io/relay-core` state contract and expose the same protocol
behavior. Versioned Relay operations live under `/api/v1`; the server core covers device-code
pairing, device-owned snapshot writes, owner snapshot reads, and owner device management through
scoped Bearer credentials. Pairing ownership is defined in
[`decisions/0002-relay-device-code-pairing.md`](decisions/0002-relay-device-code-pairing.md), while
credential and scope rules are defined in [`security.md`](security.md).

The self-hosted runtime requires `QUOTA_RELAY_OWNER_TOKEN` at startup. It binds that bearer to the
fixed self-hosted owner and atomically replaces the fixed bootstrap session when the deployment
token changes. The managed runtime has no equivalent environment-token bootstrap and does not
advertise owner authentication before its managed identity path exists.

QuotaBar reads snapshots over authenticated HTTP polling in v1. If later product measurements
justify realtime push, the managed runtime may add one Durable Object per owner for WebSocket
coordination while D1 remains the source of truth; the self-hosted runtime would provide an
equivalent in-process connection hub.

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
credentials are bound to the advertised issuer and instance ID. The bootstrapped self-hosted runtime
advertises bearer authentication, persistent snapshots, and instant device revocation. The managed
runtime continues to advertise those capabilities as disabled until managed owner authentication is
operational.
