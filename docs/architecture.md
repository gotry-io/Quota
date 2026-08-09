# Architecture

This document defines the target v1 system boundaries. It does not claim that every path is already
implemented; the repository's current milestone is maintained in the root
[`README.md`](../README.md#status).

## Products

The product list and user-facing descriptions are maintained in the root
[`README.md`](../README.md). QuotaBar, QuotaCLI, QuotaRelay, and Quota Web remain separate runtime
boundaries, but macOS distributes QuotaCLI only inside QuotaBar. Local collection must continue to
work without the managed service. Relay has anonymous capability-based owners rather than user
accounts, and the website does not participate in credential discovery or quota collection.

## Data paths

### Local provider

```text
QuotaBar ── user-only local IPC ── QuotaCLI ── local provider sessions
```

QuotaBar starts its bundled QuotaCLI helper. QuotaCLI discovers logged-in provider sessions,
collects quota, and returns a validated normalized report. Provider credentials remain inside the
QuotaCLI process boundary. QuotaBar retains one last normalized local report so it can render
immediately after launch, then replaces that cache after a successful app-lifecycle collection at
launch and every five minutes while running.

### Remote Relay agent

```text
Linux/Windows QuotaCLI ─────────────── outbound HTTPS ── QuotaRelay ── QuotaBar
macOS QuotaBar ── bundled QuotaCLI ─── outbound HTTPS ───────┘
```

QuotaCLI explicitly pairs with a selected Relay, receives a Relay-bound device credential, and on
`relay pair` uploads one normalized snapshot immediately after the device credential is saved. On
macOS, the signed QuotaBar login item refreshes its local report at app launch and every five minutes
while QuotaBar is running. Each cycle also checks for the device credential and invokes `relay push`
only while paired. Other platforms use an operator-owned external scheduler for recurring
`relay push` calls.
Relay persists accepted snapshots and serves QuotaBar instances authenticated by anonymous owner
capabilities. It never receives provider credentials or runs provider collectors. Pairing and token
generation are defined in
[`decisions/0002-relay-device-code-pairing.md`](decisions/0002-relay-device-code-pairing.md).
The account-free control boundary is defined in
[`decisions/0004-anonymous-relay-owners.md`](decisions/0004-anonymous-relay-owners.md).
Relay observation retention and QuotaBar subscription presentation are defined in
[`decisions/0003-observation-preserving-subscription-merge.md`](decisions/0003-observation-preserving-subscription-merge.md).
Relay retains observations by reporting device rather than globally deduplicating subscriptions.
QuotaBar attaches caller-owned source identity and combines local and remote observations only in
its presentation resolver; Relay storage and protocol payloads remain unchanged.

Provider-specific collection order is defined only in
[`provider-collection.md`](provider-collection.md). Credential handling, logging, transport, and
storage requirements are defined only in [`security.md`](security.md).

## Runtime boundaries

### Provider catalog

- `packages/provider/src/catalog.ts` is the single registration table: display name, product order,
  menubar default visibility, login recovery command, auth message, brand icon asset, credential
  sources, collection strategies, and optional API-key config metadata.
- Adding a provider:
  1. Catalog row (+ strategy section in [`provider-collection.md`](provider-collection.md)).
  2. Ambient OAuth: collector under `packages/provider/src/providers/<id>/` + ambient factory in
     `registry.ts`. API-key HTTPS: map + `ApiKeyHttpCollectorSpec` under `providers/<id>/`, register
     in `packages/provider/src/api-key/specs.ts` (shared resolve/fetch shell).
  3. `pnpm generate:provider-catalog` (writes protocol `ProviderId`, Swift `ProviderID`, and JSON
     Schema provider enums).
  4. Optional monochrome brand SVG under `apps/menubar/.../BrandIcons/`.
- Do not hand-edit generated id files; re-run the generator after catalog changes.
- `quotacli config set <provider>` and QuotaBar Settings API-key sections are table-driven from
  catalog entries with `config.kind === "api_key"`. Ambient OAuth/session providers use `config: null`.
- Agent visibility defaults and wipe keys follow the catalog via QuotaBar `ProviderVisibility`.
- Windows may carry optional absolute `remaining_value` / `limit_value` / `value_unit` for credits
  budgets; primary UI meters still use `used_percent` / remaining percent.

### QuotaBar

- Swift 6.2 and SwiftUI, targeting macOS 14 or newer.
- Owns local presentation, internal Relay endpoint records, and presentation-time resolution of
  local and remote observations as defined by
  [`decisions/0003-observation-preserving-subscription-merge.md`](decisions/0003-observation-preserving-subscription-merge.md).
- Ships its exact compatible QuotaCLI helper inside the signed app bundle and never resolves it from
  the user's `PATH`; the Homebrew Cask exposes this same signed helper as `quotacli` for pairing and
  one-shot commands.
- Owns the macOS recurring refresh and upload lifecycle: it collects the local Overview immediately
  after app launch and every 300 seconds while running, then invokes `relay push` only while paired.
  Quitting QuotaBar stops recurring work, and Launch at Login is the only automatic-start mechanism.
- Stores hidden owner capabilities in a user-only Application Support file and keeps endpoint
  records as internal state only.
  Pairing through any Relay URL automatically registers an isolated anonymous owner capability;
  users never enter tokens, profile names, or admin credentials.
- Discovers and binds each endpoint before using its versioned owner endpoints. The owner client
  covers pairing decisions, snapshot reads, device listing, and device revocation for that
  QuotaBar's private group only.
- Shares one `RelayStateModel` between five-minute app-lifecycle polling, the Overview, and the
  panel's single typed Settings stack for Remote Devices and Pair Device.
- Settings **General** Launch at Login mirrors `SMAppService.mainApp` system status (one-shot
  first-run default-on seed when still unregistered).
- Settings is multi-level: home destinations for **Agents** and **Remote Devices**; Agents lists
  catalog providers and opens a per-provider page. Its visibility switch applies to local and Relay
  sources, while a read-only reporting section derives This Mac and active owned-device provenance
  from existing snapshots. Provider credentials remain explicitly scoped to This Mac; API keys for
  `ProviderID.configurableCases` write the same owner-only
  `~/.config/quotacli/providers.json` file as QuotaCLI. Remote Devices remains the device-management
  boundary.
- Provider metadata (names, defaults, login commands, brand icons) comes from the generated catalog
  bindings; do not hardcode parallel provider switch tables in views.
- Its macOS owner-path acceptance flow launches the real app boundary and composes the same
  `RelayStateModel`, stores, owner client, resolver, and Settings actions against isolated
  managed and self-hosted Relay runtimes; no second test implementation of the Relay protocol is
  used.

### QuotaCLI

- TypeScript bundled as a Node ESM npm package for non-macOS headless machines and as QuotaBar's
  private Bun helper from the same entry point. There is no standalone macOS CLI artifact.
- Owns all provider credential discovery and quota collection via `@gotry-io/quota-provider`.
- Uses the same normalized schemas for local output and Relay uploads.
- `quotacli config` stores API-key provider secrets in owner-only
  `$XDG_CONFIG_HOME/quotacli/providers.json` or `~/.config/quotacli/providers.json` (directory
  `0700`, file `0600`). Collection prefers that file over env fallbacks. Keys are accepted only via
  the interactive hidden prompt; get/list never print full secrets. QuotaCLI and QuotaBar take the
  same owner-only lock directory while read-modify-writing this shared file, then replace it
  atomically.
- Owns Relay discovery, Device Code pairing, and the single Relay-bound local device credential.
- Provides an explicit one-shot `relay push` path that validates the bound Relay instance, collects
  all providers, uploads one normalized envelope, and commits its local sequence after acceptance.
- Does not own a background-service runtime. Before a macOS pair, push, or unpair, it removes the
  legacy `io.gotry.quotacli.relay` LaunchAgent shipped by earlier releases; this compatibility
  cleanup is retained only for that released artifact.
- Unpairing uses the device capability to revoke the remote device and removes the local credential
  only after the Relay reaches a terminal revoked state.
- Exposes `doctor` as a read-only summary of local provider readiness and Relay pairing state
  without performing collection or upload. `status` defaults to locally discovered providers,
  supports explicit provider/all selection, and keeps terminal progress on stderr so stdout remains
  machine-readable.
- Avoids native Node addons so the npm package and QuotaBar helper remain portable to their build
  environments.

### QuotaRelay

- Hono application shared across Cloudflare and self-hosted entry points.
- Owns device lifecycle, Relay authentication, and snapshot persistence.
- Accepts normalized protocol payloads only.

### Quota Web

- Static Vite application built independently into `apps/web/dist`.
- Shares the managed `quota.gotry.io` hostname and `quota` Worker deployment with Relay APIs.
- Managed production deploys ship website assets with the Relay Worker (`deploy-cloudflare.yml` /
  `pnpm deploy:cloudflare`); there is no separate website-only Cloudflare project.
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
pairing, device-owned snapshot writes and self-revocation, owner snapshot reads, and owner
device management through scoped Bearer credentials. Pairing is defined in
[`decisions/0002-relay-device-code-pairing.md`](decisions/0002-relay-device-code-pairing.md), while
credential and scope rules are defined in [`security.md`](security.md).

Both managed and self-hosted runtimes allow anonymous owner registration. Neither requires a
bootstrap token or user account. Each registration creates an isolated expiring owner group scoped
to the devices that QuotaBar pairs through that endpoint. See
[`decisions/0005-url-only-relay-enrollment.md`](decisions/0005-url-only-relay-enrollment.md).

Every successful device report advances `last_seen_at`. A device that has not reported for 30 days
is revoked on the authorization path, while the Worker scheduled handler and self-hosted maintenance
timer persist the same transition without waiting for a client request. The hourly maintenance also
deletes ephemeral owner groups that are at least 30 days old with no device activity in that window
and removes pairing sessions 24 hours after their expiry. Snapshot envelopes are bounded to 32
observations before persistence.

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
credentials are bound to the advertised issuer and instance ID. Both runtimes advertise bearer
authentication, persistent snapshots, instant device revocation, and `multi_tenant` for isolated
anonymous owner groups. `multi_tenant` does not imply user accounts.
