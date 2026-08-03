# Architecture

This document defines the target v1 system boundaries. It does not claim that every path is already
implemented; the repository's current milestone is maintained in the root
[`README.md`](../README.md#status).

## Products

The product list and user-facing descriptions are maintained in the root
[`README.md`](../README.md). Architecturally, QuotaBar, QuotaCLI, QuotaRelay, and Quota Web are four
independently runnable or deployable boundaries. Local collection must continue to work without the
managed service. Relay has anonymous capability-based controllers rather than user accounts, and the
website does not participate in credential discovery or quota collection.

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
serves QuotaBar instances authenticated by anonymous controller capabilities. It never receives
provider credentials or runs provider collectors. Pairing and token generation are defined in
[`decisions/0002-relay-device-code-pairing.md`](decisions/0002-relay-device-code-pairing.md).
The account-free control boundary is defined in
[`decisions/0004-anonymous-relay-controllers.md`](decisions/0004-anonymous-relay-controllers.md).
Relay observation retention and QuotaBar subscription presentation are defined in
[`decisions/0003-observation-preserving-subscription-merge.md`](decisions/0003-observation-preserving-subscription-merge.md).
Relay retains observations by reporting device rather than globally deduplicating subscriptions.
QuotaBar attaches caller-owned source identity and combines local and remote observations only in
its presentation resolver; Relay storage and protocol payloads remain unchanged.

Provider-specific collection order is defined only in
[`provider-collection.md`](provider-collection.md). Credential handling, logging, transport, and
storage requirements are defined only in [`security.md`](security.md).

## Runtime boundaries

### QuotaBar

- Swift 6.2 and SwiftUI, targeting macOS 14 or newer.
- Owns local presentation, Relay profiles, and presentation-time resolution of local and remote
  observations as defined by
  [`decisions/0003-observation-preserving-subscription-merge.md`](decisions/0003-observation-preserving-subscription-merge.md).
- Ships its exact compatible QuotaCLI helper inside the signed app bundle and never resolves it from
  the user's `PATH`.
- Stores Relay controller credentials in Keychain and profile metadata separately. It automatically
  creates an anonymous controller when first connecting to the managed Relay; self-hosted profiles
  accept the deployment-provided controller credential.
- Discovers and binds a Relay profile before using its versioned controller endpoints. Its
  controller client covers pairing decisions, snapshot reads, device listing, and device
  revocation.
- Shares one `RelayStateModel` between five-minute app-lifecycle polling, the Overview, and the
  panel's single typed Settings stack for Relay profiles, pairing decisions, and device management.
- Its macOS controller-path acceptance flow launches the real app boundary and composes the same
  `RelayStateModel`, stores, controller client, resolver, and Settings actions against isolated
  managed and self-hosted Relay runtimes; no second test implementation of the Relay protocol is
  used.

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
- Unpairing stops that service, uses the device capability to revoke the remote device, and removes
  the local credential only after the Relay reaches a terminal revoked state.
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
pairing, device-owned snapshot writes and self-revocation, controller snapshot reads, and controller
device management through scoped Bearer credentials. Pairing is defined in
[`decisions/0002-relay-device-code-pairing.md`](decisions/0002-relay-device-code-pairing.md), while
credential and scope rules are defined in [`security.md`](security.md).

The self-hosted runtime requires `QUOTA_RELAY_CONTROLLER_TOKEN` at startup. It binds that bearer to
the fixed self-hosted controller and atomically replaces the fixed bootstrap credential when the
deployment token changes. The managed runtime instead lets QuotaBar register a random anonymous
controller capability directly; neither runtime has user accounts.

Every successful device report advances `last_seen_at`. A device that has not reported for 30 days
is revoked on the authorization path, while the Worker scheduled handler and self-hosted maintenance
timer persist the same transition without waiting for a client request. The hourly maintenance also
deletes managed controllers that are at least 30 days old with no device activity in that window and
removes pairing sessions 24 hours after their expiry. It never garbage-collects the permanent
self-hosted controller. Snapshot envelopes are bounded to 32 observations before persistence.

QuotaBar reads snapshots over authenticated HTTP polling in v1. If later product measurements
justify realtime push, the managed runtime may add one Durable Object per controller for WebSocket
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
and the managed runtime both advertise bearer authentication, persistent snapshots, and instant
device revocation. Managed `multi_tenant` means multiple isolated anonymous controllers share the
runtime; it does not imply accounts.
