# QuotaRelay

QuotaRelay is the managed Cloudflare Worker + D1 account and usage service for
`https://quota.gotry.io`. It serves v2 GitHub account, native-client OAuth, Device control, and
public catalog APIs alongside the managed-data v6 quota/Usage data APIs. It renders Quota Web documents through SvelteKit
`Server.respond` as described in [ADR 0011](../../docs/decisions/0011-sveltekit-document-worker.md).
There is no self-hosted or SQLite runtime.

QuotaBar and Quota Web speak managed-data v6, the only data contract this Worker serves. A client
that speaks an older shape is refused rather than translated; see
[ADR 0018](../../docs/decisions/0018-single-managed-data-contract.md).

The v6 data contract is four routes
([ADR 0024](../../docs/decisions/0024-hour-versioned-usage-and-daily-rollups.md)):

- `PUT /api/v6/device/snapshots` stores this device's readings by `(provider, fingerprint)`, keeps
  the newer of the stored and uploaded `observed_at`, and drops the fingerprints the envelope no
  longer names for a provider it does name. It answers `{accepted, ignored}` by provider.
- `PUT /api/v6/device/usage` replaces whole UTC hours. An hour whose `scan_version` is strictly
  newer than the stored one replaces every row of that hour; anything else is `ignored`, including
  an hour before this device's deletion watermark. At most 256 hours, 512 rows in an hour, 1 MiB of
  body. The same D1 batch rewrites `usage_daily` for the UTC dates it touched.
- `GET /api/v6/account/summary?tz=` answers the account, its devices, `subscriptions[]` resolved
  once here rather than by every client, `usage` as Today / last 7 days / last 30 days / all time,
  and the pricing and model-catalog revisions. A day is a UTC day; `tz` decides which calendar days
  the trailing windows name.
- `GET /api/v6/account/usage/activity?from&to` answers up to 400 daily totals.

Both reads fold days from `usage_daily` and never open `usage_hourly`.

A Device on `GET /api/v6/account/summary` carries `last_seen_at` and `last_observed_at` and nothing
it asserted about itself. How recently it spoke is derived by the reader from the newer of the two.
Relay stores no device-reported health. See
[ADR 0022](../../docs/decisions/0022-minimal-diagnostics.md).

Apply local D1 migrations before starting Wrangler:

```bash
pnpm d1:migrate:local
pnpm dev
```

The Worker requires these secrets:

- `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`
- `GITHUB_SUBJECT_KEY`
- `QUOTA_INSTALLATION_KEY`
- `QUOTA_SESSION_HASH_KEY`

That is the whole list. The extra signing secret the retired browser-auth framework required is
not read by anything now and can be deleted from a local `.env` and from the deployed Worker; it is
named in [ADR 0025](../../docs/decisions/0025-one-session-system.md).

Register the GitHub OAuth App callback as
`https://quota.gotry.io/api/auth/github/callback`. QuotaRelay owns the browser sign-in itself:
`GET /api/auth/github/start` seals a 256-bit `state` and a PKCE verifier in a signed ten-minute
`__Host-quota_oauth` cookie and redirects to GitHub with no scope; the callback checks that cookie, spends
the code once, and opens one `sessions` row with `client_kind = 'web'` behind a
`__Host-quota_session` cookie. `POST /api/auth/logout` revokes it, and `DELETE /api/v2/account` removes
the Account and everything stored for it in one D1 batch. See
[ADR 0025](../../docs/decisions/0025-one-session-system.md).

Every client's session is a row in that same table, and one login issues one access/refresh family
([ADR 0027](../../docs/decisions/0027-one-token-per-client.md)). The `quotabar` client exchanges an
authorization code over a loopback redirect for a session scoped `[account:read, device:write]`,
which is the only way a Device is registered; Authorization Code with PKCE is the only grant Relay
offers. The registered `quota-ios` public client is a read-only Account login over the exact
redirect `io.gotry.quota:/oauth/callback`, scoped `[account:read]`, and it registers no Device. The
checked-in Worker enables Cloudflare `nodejs_compat`, which the SvelteKit server runtime requires.

Each keyed secret is independent and must contain at least 32 random characters. OAuth and session
routes return `Cache-Control: no-store`; only the versioned pricing and model catalogs are publicly
cacheable. `GET /api/v6/account/summary` and `GET /api/v6/account/usage/activity` are
`private, no-cache` with a strong `ETag`, and answer a matching `If-None-Match` with 304 before
running any Usage query.
Production migration and deployment remain workflow-owned and must not be run manually without
explicit authorization.

The checked-in catalog in [`src/pricing-catalog.ts`](./src/pricing-catalog.ts) is a versioned
snapshot with no runtime pricing network dependency. Model metadata and current rates are traced to
models.dev snapshots and the official OpenAI/Anthropic pricing pages listed in that file; effective
date intervals preserve known historical changes. Unknown models and missing component rates stay
unpriced; wildcard dimension matches and the inferred-cache approximation remain explicit in the
calculation assumptions.

Readiness probes and the hourly Worker schedule run the bounded credential and quota-observation
cleanup defined in [`docs/security.md`](../../docs/security.md). An unhandled request failure writes
one `relay_request_failed` line carrying only the path, the status, and the error's class name.
