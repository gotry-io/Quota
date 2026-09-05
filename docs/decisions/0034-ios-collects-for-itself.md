# ADR 0034: Quota iOS signs in to providers for itself

- Status: Accepted
- Date: 2026-09-05
- Related: [ADR 0010](./0010-provider-browser-session-auth.md),
  [ADR 0013](./0013-readonly-ios-account-client.md),
  [ADR 0014](./0014-nonsecret-ios-widget-snapshot.md)

## Context

[ADR 0013](./0013-readonly-ios-account-client.md) made the phone a reader of what a Mac had
already reported: no providers, no credentials, no collection. That holds for the managed Account
and is why `quota-ios` can write nothing to Relay. It also means a reader with no Mac opens the app
to an empty Overview, and the only advice it can give is to install QuotaBar.

A phone can read a provider's own web session the same way a Mac can. `QuotaProviderWeb` already
answers `packages/protocol/fixtures/provider-web-conformance.json` beside the Rust collectors, so
a reading taken on a phone resolves to the same account fingerprint as the Mac's. What was missing
was where the session comes from: iOS has no browser cookie jar an app may read, and it must not.

## Decision

Quota iOS acquires provider sessions by signing in inside the app, and reads them on the device.
It remains a read-only *Account* client: nothing acquired here is uploaded, and Relay's contract
with `quota-ios` is unchanged.

- **The reader signs in, this app watches only the cookie jar.** Connect opens a full-screen sheet
  holding a `WKWebView` on the catalog's `browser_session.login_url`, with a
  `WKWebsiteDataStore.nonPersistent()` created for that sheet and discarded when it closes. No user
  script, message handler, or navigation policy of this app's runs inside it; no page content, form
  field, or navigation is read or intercepted. After each navigation finishes, the sheet asks the
  store for its cookies, and nothing else.
- **A session is what the catalog names and the provider confirms.** The cookies are assembled by
  `BrowserSessionSpec.assembleCookieHeaders` — one statement of which names on which hosts are a
  sign-in, which of them travel together, and which only name the account a session acts as; the
  Mac's importer answers the same rule. The assembled header is then spent on
  `ProviderWebCollector.validate`, and only a header the provider answered for is stored. A header
  already refused is never retried.
- **Consent comes first, per provider.** The first Connect for a provider shows one confirmation
  naming that provider's cookies and hosts from the catalog, where they are kept, and that they are
  never uploaded — the iOS wording of the same paragraph in
  [ADR 0010](./0010-provider-browser-session-auth.md). Declining stores nothing and opens no sheet.
- **Cookies live in the Keychain and nowhere else.** One item per provider and account fingerprint,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronizable, holding the cookie
  header, the masked account label, and the two dates Settings shows. `UserDefaults` holds the
  consent answer and never a session. Remove deletes that item. Nothing is written to the App Group
  snapshot, a file, a log, or Relay.
- **Two accounts of one provider are two sessions.** Signing in again as the same account replaces
  the item it already had; signing in as a different one adds a row.
- **The phone's ladder has one rung.** A Mac tries a provider's official credential first and reads
  a browser session only when that is absent or refused. iOS has no official rung: there is no
  Codex CLI, no `~/.claude` grant, and no keychain another program wrote. The browser session is
  the only credential, so there is nothing to order it against.
- **Only providers this app can read appear.** Codex, Claude Code, and Grok — the three
  `QuotaProviderWeb` implements. Kimi and Cursor declare a browser session in the catalog and have
  no collector here, and a Connect row that cannot finish is worse than no row.
- **App Review.** The sheet is the provider's own sign-in page, shown so the reader can see their
  own quota in this app. It is not a sign-in for Quota — [ADR 0013](./0013-readonly-ios-account-client.md)
  keeps GitHub as the only identity — and it collects nothing from the page beyond the session
  cookie the sign-in leaves. `apps/ios/metadata/review-notes.md` states this for reviewers.

## What was given up

The phone can now hold provider credentials, which [ADR 0013](./0013-readonly-ios-account-client.md)
deliberately kept it free of: a lost phone holds a provider session until it is removed or expires,
where before it held only an account reader. That is bounded by the Keychain's device-only
accessibility and by Remove, and it buys the app the ability to answer for an account no Mac
reports.

A hidden web view is a credible way to take a session without asking, so this build spends the
opposite: the web view is always visible, always the provider's own page, and always consented to
first. `docs/security.md` keeps the rule that hidden WebView state is never an authentication
source.

## When to revisit

When a provider offers a device-code or OAuth sign-in a phone can complete, that becomes the
rung above this one and the ladder on iOS starts to look like the Mac's. When these local readings
should reach Overview, the widgets, or another device, that is a separate decision about what a
non-collection client may write — this ADR gives it no upload authority.
