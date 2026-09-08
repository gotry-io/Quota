<!-- Draft — pending owner review -->

# App Privacy labels (Quota iOS)

Fill App Store Connect › App Privacy from this table. It is the account data Relay holds
for a signed-in iPhone, per `docs/security.md`. It matches
`PrivacyInfo.xcprivacy` (WP-3.10b): **User ID** and **Other Usage Data** only; linked; not
used for tracking; purpose App Functionality. The widget extension collects nothing.

Tracking: **No**. `NSPrivacyTracking` is false. No tracking domains. No data is used to
track the user across apps or websites owned by other companies.

Third-party sharing for tracking or advertising: **None**.

## Collected

| Data type | Collected | Linked to identity | Tracking | Purposes | Retention | Processor | Deletion path |
| --- | --- | --- | --- | --- | --- | --- | --- |
| User ID | Yes. A GitHub numeric subject or an Apple `sub`, HMAC’d with `IDENTITY_SUBJECT_KEY` into the identity’s subject; the Account id is opaque and derived from none of it; the channel’s label (a GitHub login, or the address Apple states) is stored as `display_label`. | Yes | No | App Functionality (sign-in, Account summary, session) | Until Delete Account. Native session in Keychain (`WhenUnlockedThisDeviceOnly`) until Log Out, expiry, or revoke. Expired/revoked Relay sessions remain 7 days so logout retries stay diagnosable, then sweep. | QuotaRelay (`quota.gotry.io`, Cloudflare Workers + D1). GitHub and Apple are IdPs only: the public id and label at sign-in; no provider access token is stored, and Apple’s identity token is verified and discarded. | Settings › Delete Account → website (re-auth within 10 minutes). Log Out on this device clears Keychain, last-good cache, and the widget snapshot. |
| Email Address | Yes, when Sign in with Apple states one — which may be Apple’s private relay address. It is the label of the Apple channel on the Account and is shown as the Account’s name; the app asks for it and never asks any other way. | Yes | No | App Functionality (naming the Account) | Until Delete Account, or until the Apple channel is unbound. | QuotaRelay. | Settings › Delete Account → website. |
| Other Usage Data | Yes. Normalized remaining-quota observations (provider, plan/label, windows, reset, observed-at) — the ones this iPhone reads from providers it is signed in to, and the ones Macs running QuotaBar report — and sparse hourly Usage from Macs (token totals, derived API-equivalent cost, completeness). No prompts, completions, paths, credentials, or conversation ids. | Yes | No | App Functionality (Overview, Today Usage, widgets, multi-device sync) | Quota observations: 7 days after the instant they describe (readers stop treating them as current after 1 day). Usage hours: 400 days. Daily rollup: 800 days (`all` answers at most 730 days). Usage folds: 2 days. | QuotaRelay. Written by this iPhone (quota only) and by QuotaBar (quota and Usage), read by both and by the website. | Delete Account (all rows). Delete Device (that Device’s rows, watermark). iOS last-good cache and widget snapshot clear on Log Out. |

The iOS app signs in, registers as a Device, uploads the remaining-quota readings it takes,
and reads the Account summary. It never uploads Usage: it runs no coding agent. Declare the
rows here because Relay holds them for this App Store product’s signed-in user.

## Not collected

Declare **Not Collected** for every other App Privacy type. Do not add undeclared
categories to `PrivacyInfo.xcprivacy`.

| Group | Types |
| --- | --- |
| Contact Info | Name, Email Address, Phone Number, Physical Address, Other User Contact Info |
| Health & Fitness | Health, Fitness |
| Financial Info | Payment Info, Credit Info, Other Financial Info (API-equivalent cost is derived Usage, not payment info) |
| Location | Precise Location, Coarse Location |
| Sensitive Info | Sensitive Info |
| Contacts | Contacts |
| User Content | Emails or Text Messages, Photos or Videos, Audio Data, Gameplay Content, Customer Support, Other User Content |
| Browsing History | Browsing History |
| Search History | Search History |
| Identifiers | Device ID (this iPhone presents an installation id it generated itself at random — not IDFV, IDFA, or any hardware identifier — and Relay stores only an account-scoped HMAC of it) |
| Purchases | Purchase History (there is no purchase in the app) |
| Usage Data | Product Interaction, Advertising Data |
| Diagnostics | Crash Data, Performance Data, Other Diagnostic Data (local `diagnose` stays on the Mac; this app has no analytics or crash reporter) |
| Surroundings | Environment Scanning |
| Body | Hands, Head |
| Other Data | Other Data Types |

## Local material that never leaves the device as a collection

| Store | Contents | Leaves the device? |
| --- | --- | --- |
| Keychain session | Access/refresh family for `quota-ios`, `WhenUnlockedThisDeviceOnly` | Presented only to `https://quota.gotry.io` as Bearer. |
| Keychain provider sessions | One item per provider and account fingerprint the user signed in to in Settings › Providers: the sign-in cookie header, masked account label, and two dates. `AfterFirstUnlockThisDeviceOnly`, not synchronized to iCloud | Presented only to that provider's own API as a `Cookie` header. Never uploaded to Quota, never in the App Group snapshot, deleted by Remove. |
| Last-good Account cache | Decoded summary, fetch time, ETag | No upload; offered only for the Account the current session owns; cleared on mismatch, orphan, or Log Out. |
| App Group widget snapshot | Non-secret remaining quota and compact Today fields | Extension reads the file only. No network, Keychain, or account modules. Cleared on Log Out. |
| UI preferences | Appearance and similar, when present | Not account data. |

## Required Reason APIs

WP-3.10b found no Required Reason API use in the app, extension, `apple-client`, or
`apple-shared` (no UserDefaults, file timestamps, disk space, boot time, or active
keyboard APIs). `NSPrivacyAccessedAPITypes` is empty. Re-check if those call sites appear.

The in-app provider sign-in ([ADR 0034](../../../docs/decisions/0034-ios-collects-for-itself.md))
adds no entry to either list: Keychain and `WKWebView` are not Required Reason APIs, and a cookie
that never leaves the device for Quota is not collected data. Declare **Not Collected** for
Browsing History — Quota reads no browsing history; it reads the cookies its own sheet's
non-persistent store holds for the one host the user signed in to.
