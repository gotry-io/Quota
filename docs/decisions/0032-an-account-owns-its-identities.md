# ADR 0032: An Account owns its identities

- Status: Accepted
- Date: 2026-09-05
- Updates: [ADR 0006](0006-managed-account-device-usage.md),
  [ADR 0025](0025-one-session-system.md)

## Decision

**An Account is not an identity. It owns the channels it can be reached through.** Migration 0025
adds `account_identities(account_id, provider, subject, label, created_at)` with `(provider,
subject)` as its primary key and `(account_id, provider)` unique, drops `accounts.identity_subject`,
and gives an Account an opaque id of its own. `provider` is `github`, `apple`, or `email` — one
vocabulary, stated in `packages/protocol` and stored as it is answered. `subject` is always an HMAC
under `IDENTITY_SUBJECT_KEY` (renamed from `GITHUB_SUBJECT_KEY`), so a GitHub numeric id, an Apple
`sub`, and a normalized address are stored the same way and none of them is stored as itself.
`accounts.display_label` is the label of the identity bound first, refreshed whenever that channel
states a new one.

**A provider proves an identity and decides nothing else.** `IdentityProvider` is `begin(intent,
return_to, now)` and `complete(request, now)`, which answers a subject and a label or a category of
refusal. `WebSessions` owns what that means: a sign-in resolves `(provider, subject)` to the Account
already bound to it, or opens one; a link binds the channel to the Account the browser is signed in
as. GitHub and Apple are the implementations this ADR ships; Email registers against the same port.
as. GitHub is the first OAuth implementation; Apple registers against the same port. Email proves
the address with a mailed token and calls the same completion without a handoff cookie.

**The intent travels in the sealed handoff, not in a query.** `__Host-quota_oauth` still carries the
`state`, the PKCE verifier, and where to return to, and now also the provider and whether this round
trip is a `sign_in` or a `link` on a named Account. `sealHandoff` takes the cookie's `SameSite` so a
provider that answers with a cross-site form POST can be given what it needs without changing it for
the providers that redirect.

**A link that would take a channel from another Account is refused.** `identity_taken` changes
nothing. A JSON client sees 409; a browser is sent back to `return_to?linked=taken` so Settings can
say one sentence. A link the Account already holds is the state it asked for and succeeds. Unbinding
is `DELETE /api/v2/account/identities/:provider` under `account:manage` and the ten-minute freshness
rule, and it refuses to remove the last identity (`409 conflict`), because an Account no channel
reaches is an Account nobody can sign in to.

**Apple's Web round trip answers with a cross-site form POST, so its handoff is `SameSite=None`.**
`AppleIdentityProvider` is the second implementation of the same port. Asking Apple for `name email`
requires `response_mode=form_post`, which means Apple answers `POST /api/auth/apple/callback` from
`appleid.apple.com` — and a browser attaches no `SameSite=Lax` cookie to that. Only Apple's handoff
is sealed `None`; it is still `__Host-`, still signed, still ten minutes long, and it is still the
only thing the callback is checked against. The `client_secret` Apple asks for is not a stored
string but an ES256 JWT signed per exchange from `APPLE_SIGNIN_PRIVATE_KEY`, so nothing long-lived
is held in a variable. The identity token is checked against Apple's published keys — RS256, `iss`,
`aud`, `exp`, and the `nonce` this round trip sent — before its `sub` names anyone.

**A stand-in label never overwrites a name a channel stated.** The label a provider states replaces
the one stored for that identity, so a renamed GitHub login or a changed Apple address is not left
frozen at whatever the first sign-in saw. Apple, though, hands over an address only while the person
is sharing one: a later sign-in can arrive with nothing, and naming the channel "Apple ID" then
would rename an Account that already had a real name. So a provider states whether its label is its
own stand-in, and a stand-in fills an empty label and replaces nothing. GitHub's "GitHub account"
fallback says the same thing about itself.

**The iOS app does not go out to a browser to sign in with Apple.** `ASAuthorizationAppleIDProvider`
has already proved the identity on the device, so `POST /oauth/v2/apple` takes that identity token
and the nonce behind it and answers with the viewer's one session — the same row, scopes, and
credential domains `/oauth/v2/token` issues, by the same function. Sending the app out to
`/sign-in` and back through `/oauth/v2/complete` would ask Apple the same question a second time and
carry the answer through a redirect for no gain. The app hands Apple the nonce's SHA-256 and Relay
the value, so a token minted for an earlier request proves nothing about this one. `intent: link`
binds Apple to the Account a held iOS session already names. The `sub` Apple states is stable across
the Web and native flows of one Team, so an Account reached in the app and one reached on the
website are one Account.

**Every sign-in passes through `/sign-in`.** `GET /oauth/v2/authorize` no longer leaves for a
provider: it redirects to `/sign-in?return_to=/oauth/v2/complete?login_token=…`, and that page asks
a signed-in browser to continue as the Account it holds or to use a different one. `GET
/api/v2/account` answers `identities[]` — provider, label, and when it was bound — so a client can
show what reaches this Account.

**Email is a mailed token, not a cookie round trip.** `POST /api/auth/email/start` writes a
fifteen-minute one-time row in `email_challenges` and Resend delivers a link to
`/api/auth/email/verify?token=…`. The address and the token are stored only as hashes. The token
itself is the credential, so a `sign_in` may be opened on another device — the mail client is often
a phone — and that browser receives the session. There is no `__Host-quota_oauth` cookie on this
path, because a cookie the mail client does not have would refuse the usual case. `intent=link`
still names the Account that asked in the challenge, and completing it still requires the opening
browser to hold that Account's session, so a mailed link cannot bind the addressee to whoever sent
the mail. Start always answers 202, whether the address is already an identity, whether a
per-address limit skipped the send, and whether Resend accepted the mail; the IP still shares the
`web-signin` bucket with the other channels.

GitHub is the first OAuth implementation of `IdentityProvider`. Email does not implement that port:
it has no authorize URL and no handoff. Apple registers against the same OAuth port.

## Why

GitHub was the Account: `accounts.id` was the HMAC of a GitHub numeric id, so there was exactly one
way in and losing it lost everything behind it. Sign in with Apple is required for an iOS app that
offers third-party sign-in, and an address is what someone has when they have nothing else, so a
second and a third channel were coming either way. Making the Account its own row with identities
beside it is the change that stops each new channel from being a second kind of Account.

The cookie handoff is kept because it is still true that a sign-in nobody finishes should cost
nothing to forget: state in a table would need writing, sweeping, and a story for the rows a
half-finished sign-in leaves. The `__Host-` prefix is what makes a signed cookie enough. Email
cannot use that cookie: the person who asked is often not the browser that opens the mail, so the
token is stored (as a hash, one-time, fifteen minutes) and swept with the other expired grants.

Silent reuse is what `/sign-in` exists to end. A browser already holding a provider session was
handed straight back to whichever Account that session belonged to, which is the wrong answer as
soon as a person can have two. Confirming the Account is one page and it is the same page QuotaBar
and Quota for iPhone open.

## What was given up

`SameSite=None` on Apple's handoff is a cookie any cross-site request can carry, which `Lax` exists
to prevent. It is accepted for that one provider because the alternative — dropping `name email` so
Apple redirects instead — gives up the address that names the channel on the Account, and because
what the cookie carries is signed, `__Host-`-scoped, ten minutes old at most, and useless without
the `state` and `nonce` Apple states back. `/sign-in` was the alternative for the iOS app too, and
was given up for the reason above: it would prove nothing the device had not already proved.

A link conflict could have merged the two Accounts instead of refusing. Merging Devices, quota
observations, Usage rollups, and stored folds is a destructive operation with no undo, decided from
a browser redirect the person cannot inspect; refusing costs one sentence and keeps both Accounts
intact. Nothing merges by address either: an email an OAuth provider states is not proof of that
address, so treating a matching address as the same person would let anyone who can name it reach
an Account they never proved.

There is no data migration. Quota has no released Relay users, so migration 0025 deletes every
Account and everything hanging off one rather than carrying a GitHub-shaped Account id forward as a
subject. A migration-behaviour test that must see rows preserved therefore runs the ladder up to
this cutover.

## When to revisit

If Accounts ever need to be merged — the same person having opened two before they linked anything —
that is a deliberate, confirmed operation with its own contract, not a side effect of a link.
