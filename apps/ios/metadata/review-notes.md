<!-- Draft — pending owner review -->

# App Review notes (Quota iOS)

Paste the sections below into App Store Connect › App Review Information › Notes after the
owner fills the placeholders. Do not submit with angle-bracket tokens still in the text.

## Sign-in: GitHub is the only identity provider (Guideline 4.8)

Quota does not offer a second login method. GitHub is not a convenience SSO on top of a
Quota-owned account: **the Quota Account is the GitHub principal.**

- Relay is the confidential GitHub OAuth client. It requests no GitHub scopes. It reads the
  public profile once (numeric id and login name), HMACs the id into the Account id, and
  never stores the GitHub access token.
- QuotaBar on a Mac and Quota on this iPhone must be the same GitHub subject. QuotaBar is
  the collection Device; this app is the registered read-only public client `quota-ios`
  (scope `account:read` only; it can revoke its own session and write nothing). A second identity would split the
  Account the Mac already reports into.
- The app does not create, email, or password-protect an independent account system. Connect
  Account starts `ASWebAuthenticationSession` against `https://quota.gotry.io` and never
  embeds a web view.

This matches the App Review exception for a client of a specific third-party service whose
users must sign in to that existing account to reach their content. Guideline 4.8’s “another
login service” requirement does not apply: there is no primary Quota account apart from
GitHub.

## Companion app

Quota on iPhone is a **companion** to QuotaBar for Mac.

- This iPhone is not a collection Device. It does not configure providers, read local agent
  logs, hold provider credentials, or upload quota or Usage.
- Remaining quota, Today Usage, and the Devices list come from Relay as the Account summary
  a Mac running QuotaBar already uploaded.
- Without a Mac (or other collection Device) signed into the same GitHub Account, Overview
  has nothing to show. Reviewers should use the demo Account below, which a Mac has already
  reported synthetic data for.
- Home Screen and Lock Screen widgets render a non-secret App Group snapshot the app
  publishes. The widget extension has no network, Keychain, or account session.

## Signing in to a provider inside the app

Settings › Providers lets a user sign in to their **own** Codex, Claude Code, or Grok account so
this app can show that account's remaining quota. This is not a login for Quota — GitHub remains
the only Quota identity (above).

- Tapping Connect first shows a confirmation naming the exact cookies and hosts involved, that
  they stay in the iPhone's Keychain, that Quota never uploads them, and that Remove deletes them.
- Continue opens a full-screen sheet showing **the provider's own sign-in page** in a `WKWebView`
  whose data store is non-persistent and created for that sheet. Quota injects no JavaScript, reads
  no page content, and intercepts no form or navigation. It reads only that store's cookies, and
  only to ask the provider whether they identify a signed-in account.
- An accepted session is stored in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronized to iCloud) and is sent only
  to that provider's own API. Remove deletes it.
- Nothing acquired here is uploaded to Quota's servers, and no provider credential appears in the
  App Privacy declaration because none is collected off the device.

Reviewers can exercise this with any provider account, or skip it: the demo Account below shows
Overview without it.

## Demo Account

The demo GitHub Account is signed into QuotaBar on a Mac that has uploaded synthetic quota
and Usage. Sign in on the device with Connect Account, then complete GitHub’s page as this
user.

- GitHub username: `<DEMO_GITHUB_LOGIN>`
- GitHub password: `<DEMO_PASSWORD>`

Owner: create this GitHub user, disable 2FA (or provide a Reviewer-usable path), sign it
into QuotaBar on one Mac, and confirm Overview shows remaining quota plus Today Usage
before submitting.

## Demo video

`<DEMO_VIDEO_URL>`

Owner: record Connect Account → Overview (remaining quota, Devices, Today Usage) → widget
gallery if shown → Settings. Host the file and paste the URL. Leave this heading in place
if the URL is not ready; do not submit with the placeholder.

## Account deletion

Deletion is a website action. The iOS client cannot call Delete Account: that route needs
`account:manage` and a browser session authenticated within the last ten minutes.

Path the reviewer should follow:

1. In the app, open **Settings › Delete Account**.
2. The app opens the website sign-in
   (`https://quota.gotry.io/api/auth/github/start?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount`)
   in a non-ephemeral `ASWebAuthenticationSession` so the browser session can carry cookies.
3. Sign in with GitHub again. That resets `authenticated_at`.
4. Confirm Delete Account on the website. Relay deletes the Account, Devices, quota
   observations, Usage, sessions, and deletion controls in one batch and leaves no tombstone.
5. Return to the app and **Log Out** so this device drops its Keychain session and cached
   Overview.

A session older than ten minutes is refused; signing in again is the only way to refresh
that clock. Log Out on the iPhone revokes this client’s session only and does not delete
the Account.
