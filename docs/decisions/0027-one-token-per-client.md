# ADR 0027: One token per client; QuotaCLI and the device grant retired

- Status: Accepted
- Date: 2026-08-26
- Updates: [ADR 0006](0006-managed-account-device-usage.md),
  [ADR 0013](0013-readonly-ios-account-client.md), [ADR 0025](0025-one-session-system.md)

## Decision

**A client holds one session.** Migration 0021 merges `device_sessions` into `account_sessions` and
renames the result `sessions`. A row either names the Device it speaks for, at the generation that
Device had when the session opened, or names none. QuotaBar's login issues one access/refresh family
scoped `[account:read, device:write]`; the iOS viewer's is `[account:read]`; a browser session is
`[account:read, account:manage]` and carries no refresh token, because the cookie is the whole
credential ([ADR 0025](0025-one-session-system.md)). `token_audience` is gone from the wire, and
`OAuthTokenResponse`, both refresh responses, and the local session envelope each carry one
`session`.

One table means one code path. Authorization is one query whose join insists a Device-bound session
still matches its Device's generation, so Delete Device — which advances that generation — ends every
token issued before it without having to find them. Rotation is one compare-and-swap over that row,
and revocation is one family update. Ending a session is not a scope: holding its refresh token is
the proof, which is what `POST /oauth/v2/revoke` asks for, so `session:revoke:self` and the
`POST /api/v2/device/logout` route that never had a caller are both deleted.

**QuotaCLI is retired, and the OAuth Device Authorization Grant with it.** `apps/cli`, its release
workflow, the Linux CI tier, and the root scripts and hook branch feeding them are deleted. Nothing
else used `POST /oauth/v2/device/code`, `POST /oauth/v2/device/authorize`, the device-code branch of
`/oauth/v2/token`, or the `/activate` page, so the device code, the user code, the polling loop, and
the login-grant columns holding them go too. Authorization Code with PKCE over a loopback callback —
the flow QuotaBar uses — is the only grant left. The registered client id is `quotabar`, and
`PlatformSchema` names `macos` alone, because QuotaBar is now the only client that registers a
Device.

## Why

Two token families meant every rule about a session was written twice — two authorizations, two
rotations, two revocations, two retention sweeps — and kept consistent by hand, for a separation the
scopes on one row already express. A second grant type and a second screen existed for one product
with no update path and no audience, and the shared crate they were meant to justify is untouched by
their removal.

## What was given up

Signing in from a machine with no browser is no longer possible; so is running Quota on Linux at all,
though `packages/service` stays platform-neutral in style. A QuotaBar session issued before this
change no longer resolves — the local envelope changed shape with the wire — so every signed-in Mac
signs in once more. The owner-only configuration and state root moves from `~/.config/quotacli/` to
`~/.config/quota/`, which makes that device a new installation.

Re-adding a command-line client later means restoring `apps/cli` from history and re-adding a
device-code or loopback grant beside the browser one; the shared crate it was built on never moved.

## When to revisit

If headless collection is scheduled — a build server, a container, a Linux workstation — the grant
comes back before the product does, and it comes back as a second way to open the same `sessions`
row rather than as a second session system.
