# ADR 0025: One session system, and Relay writes the browser's

- Status: Accepted
- Date: 2026-08-26
- Updates: [ADR 0006](0006-managed-account-device-usage.md), [ADR 0011](0011-sveltekit-document-worker.md)
- Updated 2026-08-26 by [ADR 0027](0027-one-token-per-client.md)

> Updated 2026-08-26: the table is now `sessions`, and it holds one row per client rather than a second one for a Device ([ADR 0027](0027-one-token-per-client.md)).

## Decision

Relay owns the GitHub OAuth round trip and the session it opens. Better Auth, its dependency, and its
six D1 tables are deleted; migration 0019 drops them and gives `account_sessions` a `client_kind`
column so one table answers for `web`, `cli`, and `ios`.

**Sign-in is three routes.** `GET /api/auth/github/start` seals a 256-bit `state`, a PKCE verifier,
and the same-origin path to return to in an HMAC-signed `__Host-quota_oauth` cookie good for ten
minutes, then redirects to GitHub with `scope=` empty. `GET /api/auth/github/callback` compares
`state` against that cookie, exchanges the code with the verifier inside a 20-second timeout, reads
`GET /user` for a numeric id and login name, HMACs the id with `GITHUB_SUBJECT_KEY` into the Account
id, writes one session row, sets `__Host-quota_session; HttpOnly; Secure; SameSite=Lax; Path=/`, and
returns the browser where it started. `POST /api/auth/logout` revokes the row and clears the cookie.

Both cookies take the `__Host-` prefix, which a browser honours only for a `Secure`, `Path=/` cookie
with no `Domain`. That last condition is worth a wider path: a signed handoff proves Relay wrote it,
not that this browser asked for it, so anything able to set a cookie for a sibling `gotry.io` host
could otherwise plant a valid handoff and finish the sign-in as itself.

A missing, altered, expired, or mismatched handoff is 400 with no session; so is a code GitHub will
not spend twice. The GitHub access token is used for that one profile read and never stored, and the
session token only as an HMAC under `web-access`, so a cookie cannot be replayed as a Bearer token
or the reverse. Both HMACs use `QUOTA_SESSION_HASH_KEY` under new domain labels;
`BETTER_AUTH_SECRET` is no longer read anywhere.

**The Web principal is read, not synthesized.** `authorizeAccount` and `WebDocumentPort.getViewer`
resolve the session cookie against `account_sessions`, and the ten-minute freshness rule guarding
device-authorization decisions, Delete Device, and Delete Account reads that row's
`authenticated_at`. Delete Account is one D1 batch over sessions, Devices, Device sessions,
observations, Usage, the daily rollup, login grants, and the Account.

## Why

Two systems held a session, and every rule about one was restated across the seam: a database hook
upserted the Account row, the Web principal was synthesized per request from a foreign session,
deletion ran through a foreign user record, and "fresh enough" meant a timestamp neither table
owned. A GitHub sign-in is one state, one verifier, one code, and one row; writing those directly is
less code than adapting a framework to them, and it removed the only encrypted-at-rest store, the
only secondary session store, and 1.6 MiB of Worker bundle.

## What was given up

Another identity provider, e-mail sign-in, or multi-factor stops being a configuration change; each
would be another start and callback route resolving to the same `accounts` row. Quota supports
GitHub only, and said so before this change. A browser session also does not rotate: the cookie is
the whole credential for ninety days, revocable by sign-out, Delete Account, or expiry — the
lifetime Better Auth was configured for, without the refresh machinery it never used.

## When to revisit

If a second sign-in method is scheduled, evaluate a library again at that point — as an identity
front behind `WebSessionPort`, still writing `account_sessions` — rather than carrying one now for a
method that is not planned. Session ownership does not move back either way.
