# ADR 0014: Non-secret iOS widget snapshot via App Group

- Status: Accepted
- Date: 2026-08-14
- Related: [ADR 0013](./0013-readonly-ios-account-client.md), [`docs/architecture.md`](../architecture.md), [`docs/security.md`](../security.md)

## Context

Quota iOS is a read-only Account viewer ([ADR 0013](./0013-readonly-ios-account-client.md)). Home Screen
and Lock Screen widgets need remaining quota and compact Today Usage without turning the WidgetKit
extension into a second OAuth or Relay client.

Widget extensions run in a constrained process. Giving them Keychain access, Bearer tokens,
`URLSession`, or account wire models would expand the credential and network surface for a surface
that only needs to render the last published remaining-quota projection.

## Decision

Publish a non-secret, versioned `WidgetSnapshot` from the app process into the App Group
`group.io.gotry.quota`. The WidgetKit extension reads only that protected file and never talks to
Relay.

- The app is the only process that performs OAuth, holds the Keychain account session, calls Relay,
  and projects Account summary data into `WidgetSnapshot`.
- The snapshot is written with
  `ProtectedFileWidgetSnapshotStore` (`completeFileProtectionUntilFirstUserAuthentication`, atomic
  replace, excluded from backup). It contains display-oriented remaining quota and Today token/cost
  fields only. It never includes account ids, device ids, fingerprints, tokens, sequences, or raw
  sources.
- The extension target `QuotaWidgets` (`io.gotry.quota.widgets`) embeds in Quota, uses the same App
  Group, and depends only on `QuotaWidgetData` and `QuotaPresentation`. It must not import or link
  `QuotaWire`, `QuotaRelay`, `QuotaAccount`, Security, or use `URLSession`/Keychain.
- Timeline policy is local only: placeholder plus a modest fifteen-minute refresh so reset and
  updated ages can advance. There is no background network task and no extension-initiated fetch.
- Each item carries the freshness facts the collecting device reported — whether the reading was
  available and when it stops describing current quota — not a stale verdict. The extension re-draws
  on its own timeline, so it applies the shared rule at the instant it renders, exactly as the app
  does. A published verdict would freeze at publish time and keep claiming a sleeping device's
  counters are current. The state it carries is the one its source reported, so the widget can name
  why a reading is not current rather than only that it is not. That shape is snapshot version 2; a
  file written by version 1 is rejected by the version gate and the app republishes.
- Missing, corrupt, or oversize snapshot files degrade to a safe no-data presentation. Logout,
  expired session, and absence of a trusted summary clear the published file and reload timelines.
- `widgetURL` opens `io.gotry.quota:/overview` so taps return to the app Overview.

## Consequences

- Widget content can lag the in-app Overview until the app publishes again; that is preferred to
  giving the extension credentials or network.
- App Group membership and matching entitlements are required for both the app and the extension
  signing identities.
- Presentation text reuses `packages/apple-shared` formatters; snapshot encode/decode and the
  protected file store live in `QuotaWidgetData`.
- Future secret-bearing widget features would need a new decision. This ADR does not authorize
  tokens, account identifiers, or network inside the extension.
