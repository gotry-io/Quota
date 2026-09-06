<!-- Draft — pending owner review -->

# App Privacy labels (Quota iOS)

Fill App Store Connect › App Privacy from this table. It is the account data Relay holds
for a signed-in `quota-ios` client, per `docs/security.md`. It matches
`PrivacyInfo.xcprivacy` (WP-3.10b): **User ID** and **Other Usage Data** only; linked; not
used for tracking; purpose App Functionality. The widget extension collects nothing.

Tracking: **No**. `NSPrivacyTracking` is false. No tracking domains. No data is used to
track the user across apps or websites owned by other companies.

Third-party sharing for tracking or advertising: **None**.

## Collected

| Data type | Collected | Linked to identity | Tracking | Purposes | Retention | Processor | Deletion path |
| --- | --- | --- | --- | --- | --- | --- | --- |
| User ID | Yes. GitHub numeric subject, HMAC’d with `GITHUB_SUBJECT_KEY` into the Account id; GitHub login stored as `display_label`. | Yes | No | App Functionality (sign-in, Account summary, session) | Until Delete Account. Native session in Keychain (`WhenUnlockedThisDeviceOnly`) until Log Out, expiry, or revoke. Expired/revoked Relay sessions remain 7 days so logout retries stay diagnosable, then sweep. | QuotaRelay (`quota.gotry.io`, Cloudflare Workers + D1). GitHub is IdP only: public id + login at sign-in; access token never stored. | Settings › Delete Account → website (re-auth within 10 minutes). Log Out on this device clears Keychain, last-good cache, and the widget snapshot. |
| Other Usage Data | Yes. Normalized remaining-quota observations (provider, plan/label, windows, reset, observed-at) and sparse hourly Usage (token totals, derived API-equivalent cost, completeness). No prompts, completions, paths, credentials, or conversation ids. | Yes | No | App Functionality (Overview, Today Usage, widgets) | Quota observations: 7 days after the instant they describe (readers stop treating them as current after 1 day). Usage hours: 400 days. Daily rollup: 800 days (`all` answers at most 730 days). Usage folds: 2 days. | QuotaRelay. Written by QuotaBar, read by this app. | Delete Account (all rows). Delete Device (that Device’s rows, watermark). iOS last-good cache and widget snapshot clear on Log Out. |

The iOS app transmits the OAuth grant and then reads the Account summary. It does not
collect those Usage rows from the iPhone; they are the Account data the viewer displays.
Declare them here because Relay holds them for this App Store product’s signed-in user.

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
| Identifiers | Device ID (QuotaBar’s installation id is an account-scoped HMAC on Relay; this iPhone is not a Device and does not send one) |
| Purchases | Purchase History |
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
