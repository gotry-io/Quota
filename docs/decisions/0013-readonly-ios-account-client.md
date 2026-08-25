# ADR 0013: Read-only Quota iOS account client

- Status: Accepted
- Date: 2026-08-14
- Related: [ADR 0006](./0006-managed-account-device-usage.md), [ADR 0012](./0012-managed-data-v3.md), [`docs/architecture.md`](../architecture.md), [`docs/security.md`](../security.md)

## Context

Quota's released native OAuth public client is `quotacli`. QuotaBar uses Authorization Code with
PKCE and a temporary loopback callback; Linux QuotaCLI uses the OAuth Device Authorization Grant.
Both are collection Devices: a successful login creates or restores a Device from an installation
identity and issues an account-read family plus a current-device-write family with upload sequences.

A Quota iOS app needs to sign in with the same GitHub Account and read that Account's quota and
Usage. Treating the phone as a collection Device would invent an iOS Platform, an installation
identity, a Device row, and upload authority the product does not have. `PlatformSchema` is the
released collection-device enum `macos` | `linux` | `windows`. The `quotacli` authorization-code
and device-code request and response shapes are a released protocol v2 boundary.

Managed quota, Usage, and Account summary already shipped as managed-data v3
([ADR 0012](./0012-managed-data-v3.md)). New account readers use that current data boundary.

## Decision

Register a second public OAuth client, `quota-ios`, as a read-only Account client. It is not a
collection Device and never receives upload authority.

- Authorization uses the existing `/oauth/v2/authorize` route: Authorization Code with PKCE S256,
  a random opaque `state`, and the exact redirect URI `io.gotry.quota:/oauth/callback`. Loopback
  redirects remain valid only for `quotacli`.
- The authorization-code exchange is a client-specific protocol v2 request. It must not accept
  `installation_id`, `device_display_name`, or `platform`. Relay consumes the grant into an account
  session only: scopes `account:read` and `session:revoke:self`. The response is a client-specific
  protocol v2 object with `account_id` and `account_session`. It contains no Device session, Device
  id, Device generation, upload sequence, installation identity, or Device record.
- Persist that session in the existing `account_sessions` table with `device_id` null. Do not add a
  migration, a new grant kind, or `ios` to `PlatformSchema`.
- Refresh for `quota-ios` is account audience only and keeps rotating refresh-token
  compare-and-swap. Access and refresh tokens use the distinct prefixes `qia_` and `qiar_`;
  `quotacli` keeps `qa_`/`qar_` and `qd_`/`qdr_`. Each refresh request accepts only the prefix
  registered for that public client. Logout and `/oauth/v2/revoke` remain the revocation path and
  recognize `qiar_`. These native account sessions cannot call Web-only management or destructive
  routes and cannot write snapshots or Usage.
- Account data reads use the current managed-data v3 routes, including the explicit per-device
  health shape defined by [ADR 0015](0015-diagnostic-attempts-and-device-health.md). OAuth, refresh,
  and revoke remain on released v2. [ADR 0018](0018-single-managed-data-contract.md) has since
  retired the v2 data routes and advanced the managed data contract to v4, and
  [ADR 0022](0022-minimal-diagnostics.md) removed the health shape; the routes named here are the v3
  ones that shipped.
- `quotacli` loopback PKCE and device-code behavior stay the released collection-client contract.
  This change is additive. It is not a compatibility shim and does not dual-write Device rows.

Quota iOS consumes this account session through `packages/apple-client`. Shipping the viewer does
not add collection, upload, or Device capabilities.

## Consequences

- Account summaries list only collection Devices. A `quota-ios` login never adds a Device.
- A `quota-ios` credential can read Account quota and Usage and can revoke its own session. It
  cannot write snapshots, Usage, Device Health, or Device control state.
- Collection clients continue to use `client_id=quotacli` and the existing token response.
- Quota iOS and `packages/apple-client` consume the account session as a read-only client. They do
  not gain collection or upload capabilities by shipping.
