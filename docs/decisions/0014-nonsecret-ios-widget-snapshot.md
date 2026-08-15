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
