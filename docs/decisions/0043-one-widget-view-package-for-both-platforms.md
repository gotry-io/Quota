# ADR 0043: One widget view package for both platforms

- Status: Accepted
- Date: 2026-09-07
- Related: [ADR 0014](./0014-nonsecret-ios-widget-snapshot.md),
  [ADR 0007](./0007-rust-native-local-service.md)

## Context

[ADR 0014](./0014-nonsecret-ios-widget-snapshot.md) already says the App Group `WidgetSnapshot` is
the widget file for every Apple WidgetKit surface, and that macOS widgets read the same one. Until
now no Mac could: QuotaBar was packaged by hand from `swift build` output, and SwiftPM has no
app-extension product, so there was no `.appex` to embed.

Making QuotaBar produce one raises the question the snapshot decision left open. Two extensions on
two platforms draw the same thing from the same file. The Overview widget's rows, its selection
rules for each family, and its configuration Intent are one product surface described twice if each
app owns a copy, and the two copies drift the first time only one of them is corrected.

The publishing side is not symmetric with the reading side. Quota projects Relay's resolved
`QuotaSubscription` list; QuotaBar projects the Overview rows the private Rust service resolved.
Both hold `QuotaSnapshot`, which is `QuotaWire`'s — and ADR 0014 forbids the extensions from
linking `QuotaWire` at all.

## Decision

QuotaBar is generated from `apps/menubar/project.yml` by `pnpm generate:menubar`, the way Quota iOS
is, and the generated `QuotaBar.xcodeproj` is committed. `xcodebuild` produces `QuotaBar.app` with
`PlugIns/QuotaBarWidgets.appex`; `scripts/package-menubar.sh` archives, exports, and adds
`Contents/Helpers/quota-service`. `apps/menubar/Package.swift` stays: it is the library and
`swift test` view of the same sources, so `pnpm test:swift` keeps running every QuotaBar test
without an Xcode scheme.

The widget is one description in `packages/apple-client`, split by what the extensions are allowed
to link:

- `QuotaWidgetViews` owns the Overview entry, its six family views, the per-family selection and
  formatting rules, and the configuration Intent. It depends on `QuotaWidgetData` and
  `QuotaPresentation` and nothing else, so both extensions can link it under ADR 0014. Only the
  extensions and the test bundles do: linking it into Quota changed how the app itself rendered,
  which its accessibility audits caught, and an app has no reason to draw a widget anyway.
- `QuotaWidgetData` keeps the snapshot types and protected file store, and gains the App Group
  identifier, the widget kind, and the publisher both apps write through.
- `QuotaWidgetProjection` owns the one rule that turns resolved readings into a `WidgetSnapshot`:
  which windows become items, how they rank, and how Today is worded. It speaks `QuotaWire`, so it
  is the publishing side only — both apps depend on it, neither extension does.

Each extension declares only its `WidgetBundle`, its `Widget`, its timeline, and which families it
supports. macOS supports `systemSmall`, `systemMedium`, and `systemLarge`; the Lock Screen accessory
families stay iPhone's.

The links are one rule with two spellings. Each app registers its own scheme — Quota's
`io.gotry.quota:`, QuotaBar's `quotabar:` — and both answer `/overview` and
`/subscriptions/<selection_id>`. QuotaBar opens its panel from the first status item and scrolls
Overview to the provider whose row published that id; an id from an older salt resolves to nothing
and lands on Overview. Each extension also carries its own `AccentColor` asset catalog, because an
extension has no app to borrow a tint from, and the meter is filled from that tint.

Two macOS-only rendering rules, both because AppKit-backed controls cannot be drawn from an
archived SwiftUI view tree: the meter is SwiftUI shapes rather than `Gauge`, and a static
`ImageRenderer` capture turns row `Link`s off through `overviewWidgetRowLinksEnabled` so the
screenshot tests can draw the row content the widget shows inside them.

QuotaBar publishes after every state update, from the Overview rows already on screen, and clears
the snapshot when there is nothing to show. Its App Group is `86Y537ZF24.group.io.gotry.quota`: a
Mac app distributed outside the Mac App Store may only join a group whose identifier begins with its
Team ID, and that prefix is what makes the entitlement self-certifying without a provisioning
profile. Publishing never fails a state update — an unentitled build (every ad-hoc signed local
package, whose signature carries no entitlements) or an unwritable container leaves one sentence on
the Diagnostics page's Data section and nothing else.

`selection_id` stays what ADR 0014 says it is on both platforms: `SHA-256(selector ‖ "|" ‖ salt)`
truncated to twelve hex characters, over `SubscriptionSelector`'s preimage. That derivation is
`QuotaPresentation`'s, beside the selector it hashes. QuotaBar's 32-byte salt is its own Keychain
item, never in the App Group, and is only ever asked for by a build that has a container to publish
to.

## Consequences

- QuotaBar has two build descriptions of the same sources. `project.yml` is what ships;
  `Package.swift` is what `swift test` runs. A source file added to one is added to the other, and
  `pnpm generate:menubar` must stay idempotent so the committed project is reviewable.
- The one place they differ is resources: the packaged app finds brand icons in
  `Contents/Resources/BrandIcons`, and the package build finds them in `Bundle.module`. The lookup
  says so with `#if SWIFT_PACKAGE` rather than carrying a second copy of the assets.
- A widget change is now one change. An iOS-only or macOS-only rendering rule has to say which
  platform it is for, in the shared view, where the other platform's behaviour is visible next to
  it.
- Desktop widgets show nothing until QuotaBar is signed with a real Developer ID identity: an
  ad-hoc local package is not entitled to the App Group. Diagnostics says so rather than looking
  broken.
- QuotaBar now has a public URL scheme. It answers exactly the two widget paths and nothing else;
  a third path is a new decision, not an addition to this one.
- A future secret-bearing or network-touching widget feature is still refused by ADR 0014; nothing
  here widens what an extension may link.
