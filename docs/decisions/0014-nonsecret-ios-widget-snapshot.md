# ADR 0014: Non-secret iOS widget snapshot via App Group

- Status: Accepted
- Date: 2026-08-14
- Related: [ADR 0013](./0013-readonly-ios-account-client.md)
- Updated 2026-09-04: locally salted `selection_id`; unpublished v2 shape changes in place

## Context

Quota iOS is a read-only Account viewer ([ADR 0013](./0013-readonly-ios-account-client.md)), and its
Home Screen and Lock Screen widgets need remaining quota and compact Today Usage. A widget extension
runs in a constrained process; giving it Keychain access, Bearer tokens, `URLSession`, or account
wire models would expand the credential and network surface for something that only re-draws the
last published projection.

## Decision

Publish a non-secret, versioned `WidgetSnapshot` from the app process into the App Group
`group.io.gotry.quota`. The WidgetKit extension reads only that protected file and never talks to
Relay.

- The app is the only process that performs OAuth, holds the Keychain account session, calls Relay,
  and projects Account summary data into `WidgetSnapshot`.
- The snapshot is written with
  `ProtectedFileWidgetSnapshotStore` (`completeFileProtectionUntilFirstUserAuthentication`, atomic
  replace, excluded from backup). It contains display-oriented remaining quota, Today token/cost
  fields, and a locally salted `selection_id` per item. It never includes account ids, device ids,
  fingerprints, tokens, sequences, raw sources, account display labels, or the unsalted
  subscription selector. Widget Intent configuration is not stored in the snapshot.
- The extension target `QuotaWidgets` (`io.gotry.quota.widgets`) embeds in Quota, uses the same App
  Group, and depends only on `QuotaWidgetData` and `QuotaPresentation`. It must not import or link
  `QuotaWire`, `QuotaRelay`, `QuotaAccount`, Security, or use `URLSession`/Keychain.
- Timeline policy inside the extension is local only: a placeholder plus a modest fifteen-minute
  refresh so reset and updated ages advance. The extension never fetches. What it draws is
  republished by the app process, on a foreground refresh and on a `BGAppRefreshTask`
  (`io.gotry.quota.refresh`) the app asks for no sooner than every thirty minutes.
- Each item carries the freshness facts the collecting device reported — whether the reading was
  available and when it stops describing current quota — rather than a verdict. The extension
  re-draws on its own timeline and applies the shared rule at the instant it renders, exactly as the
  app does; a published verdict would freeze at publish time and keep claiming a sleeping device's
  counters are current. That shape is snapshot version 2, and a version 1 file is rejected by the
  version gate so the app republishes. iOS has not shipped, so `selection_id` joins version 2 in
  place rather than as a new version; a file missing it is rejected and the app republishes.
- Each item's `selection_id` is the first twelve lowercase hex characters of
  SHA-256(`SubscriptionSelector` ‖ "|" ‖ salt). The 32-byte salt is generated on first use, stored
  in the app-private Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not an App
  Group item), and deleted on logout. Regenerating the salt invalidates old deep links and widget
  Intent configuration, which fall back to Overview. The App Group file sees only the irreversible
  `selection_id`.
- Missing, corrupt, or oversize snapshot files degrade to a safe no-data presentation. Logout,
  expired session, and absence of a trusted summary clear the published file and reload timelines.
- Each item opens `io.gotry.quota:/subscriptions/<selection_id>`. A medium or large widget with
  more than one item keeps `io.gotry.quota:/overview` for the widget as a whole.

## Consequences

- Widget content can lag the in-app Overview until the app publishes again; that is preferred to
  giving the extension credentials or network.
- App Group membership and matching entitlements are required for both the app and the extension
  signing identities.
- Presentation text reuses `packages/apple-shared` formatters; snapshot encode/decode and the
  protected file store live in `QuotaWidgetData`.
- Future secret-bearing widget features would need a new decision. This ADR does not authorize
  tokens, account identifiers, the installation salt, or network inside the extension.
