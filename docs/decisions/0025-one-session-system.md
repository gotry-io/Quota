# ADR 0025: One session system, and Relay writes the browser's

- Status: Accepted
- Date: 2026-08-26
- Updates: [ADR 0006](0006-managed-account-device-usage.md), [ADR 0011](0011-sveltekit-document-worker.md)

## Decision

Relay owns the GitHub OAuth round trip and the session it opens. Better Auth, its dependency, and
its six D1 tables are deleted; migration 0019 drops them and gives `account_sessions` a
`client_kind` column so one table answers for `web`, `cli`, and `ios`.

**Sign-in is three routes.** `GET /api/auth/github/start` mints a 256-bit `state` and a PKCE
verifier, seals both — with the same-origin path to return to — in an HMAC-signed
`quota_oauth` cookie good for ten minutes, and redirects to GitHub with `scope=` empty.
`GET /api/auth/github/callback` compares `state` against that cookie, exchanges the code with the
verifier inside a 20-second timeout, reads `GET /user` for a numeric id and login name, HMACs the
id with `GITHUB_SUBJECT_KEY` into the Account id, writes one session row, sets
`quota_session; HttpOnly; Secure; SameSite=Lax; Path=/`, clears the handoff, and returns the
browser where it started. `POST /api/auth/logout` revokes the row and clears the cookie.

A missing, altered, expired, or mismatched handoff cookie is 400 with no session; so is a code
GitHub will not spend twice. The GitHub access token is used for that one profile read and never
stored. The session token is stored only as an HMAC under `web-access`, so a cookie cannot be
replayed as a Bearer token and a native token cannot be replayed as a cookie.

**The Web principal is read, not synthesized.** `authorizeAccount` and `WebDocumentPort.getViewer`
resolve `quota_session` against `account_sessions`. The ten-minute freshness rule that guards
device-authorization decisions, Delete Device, and Delete Account reads that row's
`authenticated_at`. Delete Account is one D1 batch over sessions, Devices, Device sessions,
observations, hourly Usage, the daily rollup, login grants, and the Account.

The signing key is `QUOTA_SESSION_HASH_KEY`, already Relay's credential-equality key, under new
domain labels. `BETTER_AUTH_SECRET` is no longer read anywhere.

## Why

Two systems held a session, and every rule about one had to be restated across the seam: the
Account row was upserted by a database hook, the Web principal was synthesized on each request from
a foreign session, deletion ran through a foreign user record, and "is this session fresh enough"
meant a timestamp neither table owned. A GitHub sign-in is one state, one verifier, one code, and
one row. Writing those directly is less code than adapting a framework to them, and it removed the
only encrypted-at-rest store, the only secondary session store, and about 1.6 MiB of Worker bundle.

## What was given up

Additional identity providers, e-mail sign-in, and multi-factor are no longer a configuration
change; each would be another start and callback route resolving to the same `accounts` row. That
is the intended trade: Quota supports GitHub only, and said so before this change.

A browser session does not rotate. The cookie is the whole credential for ninety days, revocable by
sign-out, Delete Account, or expiry — the same lifetime Better Auth was configured for, without the
refresh machinery it never used here.
