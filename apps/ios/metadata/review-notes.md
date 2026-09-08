<!-- Draft — pending owner review -->

# App Review notes (Quota iOS)

Paste the sections below into App Store Connect › App Review Information › Notes after the
owner fills the placeholders. Do not submit with angle-bracket tokens still in the text.

## Sign-in (Guideline 4.8)

Quota offers **Sign in with Apple**, GitHub, and an emailed sign-in link. One Account can hold
more than one of them, and Settings › Sign-in methods adds or removes a channel.

- Relay (`https://quota.gotry.io`) is the confidential OAuth client for GitHub and the audience for
  Apple's identity token. It requests no GitHub scopes, reads the public profile once (numeric id
  and login), HMACs the id into an opaque identity subject, and never stores the GitHub access
  token. Apple's identity token is verified and discarded; the email Apple states (possibly a
  private relay address) is kept only as the channel's label.
- Sign in with Apple is offered wherever the other methods are, with equal prominence, and asks
  for no data beyond what Apple provides.
- The app never embeds a web view for Quota sign-in: GitHub and email start an
  `ASWebAuthenticationSession` against `https://quota.gotry.io`; Apple uses the native
  `ASAuthorizationController`.

## What this iPhone does

Quota on iPhone reads quota for itself and, when signed in to a Quota Account, reports it.

- **Without an Account**, Settings › Providers lets the user sign in to their own Codex, Claude
  Code, or Grok account (next section). Overview shows what this phone read. Nothing leaves the
  device.
- **With an Account**, this iPhone registers as a Device — the same way a Mac running QuotaBar does
  — and uploads the readings it takes: provider, plan, remaining quota, reset times, observed-at.
  It uploads no Usage (it runs no coding agent), no cookies, and no credentials. Macs running
  QuotaBar report into the same Account, and Overview merges every device into one row per
  subscription. Multi-device sync is free; there is no purchase anywhere in the app.
- Home Screen and Lock Screen widgets render a non-secret App Group snapshot the app publishes.
  The widget extension has no network, Keychain, or account session.
- Reviewers can exercise the app with any Codex, Claude Code, or Grok account and no Quota Account
  at all, or sign in with the demo Account below to see Macs' readings beside the phone's.

## Signing in to a provider inside the app

Settings › Providers lets a user sign in to their **own** Codex, Claude Code, or Grok account so
this app can show that account's remaining quota. This is not a login for Quota — the Quota identity is Apple, GitHub, or email (above).

- Tapping Connect first shows a confirmation naming the exact cookies and hosts involved, that
  they stay in the iPhone's Keychain, that Quota never uploads them, and that Remove deletes them.
- Continue opens a full-screen sheet showing **the provider's own sign-in page** in a `WKWebView`
  whose data store is non-persistent and created for that sheet. Quota injects no JavaScript, reads
  no page content, and intercepts no form or navigation. It reads only that store's cookies, and
  only to ask the provider whether they identify a signed-in account.
- An accepted session is stored in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronized to iCloud) and is sent only
  to that provider's own API. Remove deletes it.
- The cookie itself is never uploaded to Quota's servers, so no provider credential appears in
  the App Privacy declaration; the remaining-quota numbers read with it are uploaded only when a
  Quota Account is signed in, as Other Usage Data.

Reviewers can exercise this with any provider account, or skip it: the demo Account below shows
Overview without it.

## Demo Account

The demo GitHub Account is signed into QuotaBar on a Mac that has uploaded synthetic quota
and Usage. In the app choose Continue with GitHub, then complete GitHub’s page as this user.

- GitHub username: `<DEMO_GITHUB_LOGIN>`
- GitHub password: `<DEMO_PASSWORD>`

Owner: create this GitHub user, disable 2FA (or provide a Reviewer-usable path), sign it
into QuotaBar on one Mac, and confirm Overview shows remaining quota plus Today Usage
before submitting.

## Demo video

`<DEMO_VIDEO_URL>`

Owner: record Settings › Providers › Connect (a provider sign-in) → Overview → Continue with
GitHub → Overview with the Mac's rows → widget gallery if shown → Settings. Host the file and paste the URL. Leave this heading in place
if the URL is not ready; do not submit with the placeholder.

## Account deletion

Deletion is a website action. The iOS client cannot call Delete Account: that route needs
`account:manage` and a browser session authenticated within the last ten minutes.

Path the reviewer should follow:

1. In the app, open **Settings › Delete Account**.
2. The app opens the website sign-in
   (`https://quota.gotry.io/api/auth/github/start?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount`)
   in a non-ephemeral `ASWebAuthenticationSession` so the browser session can carry cookies.
3. Sign in again with any method on the Account. That resets `authenticated_at`.
4. Confirm Delete Account on the website. Relay deletes the Account, Devices, quota
   observations, Usage, sessions, and deletion controls in one batch and leaves no tombstone.
5. Return to the app and **Log Out** so this device drops its Keychain session and cached
   Overview.

A session older than ten minutes is refused; signing in again is the only way to refresh
that clock. Log Out on the iPhone revokes this client’s session only and does not delete
the Account.
