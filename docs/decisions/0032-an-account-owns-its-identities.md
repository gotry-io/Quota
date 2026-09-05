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
as. GitHub is the first OAuth implementation; Apple registers against the same port. Email proves
the address with a mailed token and calls the same completion without a handoff cookie.

**The intent travels in the sealed handoff, not in a query.** `__Host-quota_oauth` still carries the
`state`, the PKCE verifier, and where to return to, and now also the provider and whether this round
trip is a `sign_in` or a `link` on a named Account. `sealHandoff` takes the cookie's `SameSite` so a
provider that answers with a cross-site form POST can be given what it needs without changing it for
the providers that redirect.

**A link that would take a channel from another Account is refused.** `identity_taken` changes
nothing and shows the browser one sentence naming the provider. A link the Account already holds is
the state it asked for and succeeds. Unbinding is `DELETE /api/v2/account/identities/:provider`
under `account:manage` and the ten-minute freshness rule, and it refuses to remove the last identity
(`409 conflict`), because an Account no channel reaches is an Account nobody can sign in to.

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
