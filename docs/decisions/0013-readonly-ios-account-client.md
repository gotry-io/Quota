# ADR 0013: Read-only Quota iOS account client

- Status: Accepted
- Date: 2026-08-14
- Related: [ADR 0006](./0006-managed-account-device-usage.md)
- Updated 2026-08-26 by [ADR 0027](./0027-one-token-per-client.md)

> Updated 2026-08-26: every client now holds one session; `quotacli` and the Device Authorization Grant are gone ([ADR 0027](./0027-one-token-per-client.md)).
>
> Updated 2026-09-05: the phone reads a provider's own web session for itself, signed in inside the
> app and kept in that device's Keychain ([ADR 0034](./0034-ios-collects-for-itself.md)). What this
> record decides is unchanged: `quota-ios` is still a read-only Account client, adds no Device, and
> uploads nothing.

## Context

Quota's collection clients — QuotaBar with loopback PKCE, Linux QuotaCLI with the Device
Authorization Grant — both log in as Devices: a session creates or restores a Device from an
installation identity and issues account-read plus current-device-write token families. A phone
needs to read the same Account without inventing an iOS platform, an installation identity, a Device
row, and upload authority the product does not have.

## Decision

Register a second public OAuth client, `quota-ios`, as a read-only Account client. It is not a
collection Device and never receives upload authority.

- Authorization uses the existing `/oauth/v2/authorize` route with Authorization Code, PKCE S256, a
  random opaque `state`, and the exact redirect URI `io.gotry.quota:/oauth/callback`. Loopback
  redirects stay valid only for `quotacli`.
- The code exchange is client-specific and must not accept `installation_id`,
  `device_display_name`, or `platform`. Relay consumes the grant into an account session only —
  scopes `account:read` and `session:revoke:self` — and answers with `account_id` and
  `account_session` and nothing else: no Device session, id, generation, or record.
- That session persists in the existing `account_sessions` table with `device_id` null. No new
  migration, no new grant kind, and no `ios` member in `PlatformSchema`.
- Refresh is account audience only and keeps rotating compare-and-swap. Access and refresh tokens
  take the distinct prefixes `qia_` and `qiar_` where `quotacli` keeps `qa_`/`qar_` and `qd_`/`qdr_`,
  and a refresh request accepts only the prefix registered for that client. Logout and
  `/oauth/v2/revoke` stay the revocation path and recognize `qiar_`.
- These native account sessions cannot call the Web-only management or destructive routes and cannot
  write snapshots or Usage. Account data reads use whatever the single managed data contract is; the
  `quotacli` loopback and device-code behaviour is untouched, because this change is additive rather
  than a shim, and nothing dual-writes a Device row.

Quota iOS consumes the session through `packages/apple-client`.

## Consequences

- Account summaries list only collection Devices; a `quota-ios` login never adds one.
- A `quota-ios` credential can read Account quota and Usage and revoke its own session, and can write
  nothing.
- Shipping the viewer gives Quota iOS and `packages/apple-client` no *upload* capability. Reading a
  provider on the phone, added by [ADR 0034](./0034-ios-collects-for-itself.md), stays local to that
  device.
