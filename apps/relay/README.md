# QuotaRelay

QuotaRelay is the managed Cloudflare Worker + D1 account and usage service for
`https://quota.gotry.io`. It serves v2 GitHub account, native-client OAuth, Device control, and
public catalog APIs alongside the managed-data v6 quota/Usage data APIs. It renders Quota Web documents through SvelteKit
`Server.respond` as described in [ADR 0011](../../docs/decisions/0011-sveltekit-document-worker.md).
There is no self-hosted or SQLite runtime.

QuotaBar and Quota Web speak managed-data v6, the only data contract this Worker serves. A client
that speaks an older version is refused rather than translated; see
[ADR 0018](../../docs/decisions/0018-single-managed-data-contract.md). Within a version the two
directions differ: Relay checks a request body against exactly the contract and refuses one that
names a key the contract does not, while a client reads a response through a schema that accepts
fields and enum members its build cannot name, at any depth. Adding either to a response is
therefore not a breaking change. See
[ADR 0023](../../docs/decisions/0023-strict-writes-tolerant-reads.md).

The v6 data contract is four routes
([ADR 0024](../../docs/decisions/0024-hour-versioned-usage-and-daily-rollups.md)):

- `PUT /api/v6/device/snapshots` stores this device's readings by `(provider, fingerprint)`, keeps
  the newer of the stored and uploaded `observed_at` (a same-instant restatement is taken only when
  it changes status from `available` to a failure), and drops the fingerprints the envelope no
  longer names for a provider it does name. It answers `{accepted, ignored}` by provider.
- `PUT /api/v6/device/usage` replaces whole UTC hours. An hour whose `scan_version` is strictly
  newer than the stored one replaces every row of that hour; anything else is `ignored`, including
  an hour before this device's deletion watermark. At most 256 hours, 512 rows in an hour, 1 MiB of
  body. The same D1 batch rewrites `usage_daily` for the UTC dates it touched.
- `GET /api/v6/account/summary?tz=` answers the account, its devices, `subscriptions[]` resolved
  once here rather than by every client, `usage` as Today / last 7 days / last 30 days / all time,
  the pricing and model-catalog revisions, and the paid-sync `entitlement` object. The summary ETag
  includes `entitlements.updated_at`. A local day begins at local midnight, so `tz` decides
  where the three trailing periods start and end. `all` is the last 730 UTC days, not every day
  ever stored: an answer that grows with an account's whole history eventually cannot be given.
  The rollup is read newest day first, so an account with more retained rows than one response can
  carry gets a shorter `all` rather than no summary at all.
- `GET /api/v6/account/usage/activity?from&to` answers up to 400 daily totals, on UTC dates. A
  day's `totals` carries `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
  `cache_write_input_tokens`, `reasoning_tokens`, and `messages` beside `total_tokens`, and its
  `cost` is priced the same way a period's is — so a per-day table needs no second read. A
  single-day read may take `detail=agents` and then carries that day's agent tree.

Each period of `usage` also carries `cache_saved`: what its cache reads saved against paying the
uncached input price for the same tokens, folded from the rows it already priced and therefore
costing no extra query ([ADR 0036](../../docs/decisions/0036-usage-derived-metrics.md)). The cache
hit rate is not on the wire; every client derives it from the totals beside it.

`all` and the activity read are `usage_daily` alone. A trailing period folds its whole UTC days
from `usage_daily` too, and reaches into `usage_hourly` only for the day its edge cuts — four such
days at most, because the three periods end together. A caller keeping UTC opens no hour at all.

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
- `APPLE_SIGNIN_TEAM_ID`, `APPLE_SIGNIN_SERVICES_ID`, `APPLE_SIGNIN_KEY_ID`, and
  `APPLE_SIGNIN_PRIVATE_KEY` (the Sign in with Apple signing key, as the PKCS#8 PEM Apple hands
  out once)
- `IDENTITY_SUBJECT_KEY`
- `QUOTA_INSTALLATION_KEY`
- `QUOTA_SESSION_HASH_KEY`
- `RESEND_API_KEY`
- `REVENUECAT_WEBHOOK_SECRET` — the Authorization header value configured on the RevenueCat
  webhook
- `REVENUECAT_SECRET_KEY` — RevenueCat REST API v1 secret key
- `REVENUECAT_WEB_PURCHASE_URL` — Web Purchase Link base (`https://pay.rev.cat/<token>`), also
  acceptable as a Cloudflare var

`POST /api/billing/revenuecat/webhook` is the RevenueCat webhook. It compares the `Authorization`
header to `REVENUECAT_WEBHOOK_SECRET`, records the event, and folds the `sync` entitlement.
`GET /api/v2/account` carries `entitlement` and `purchase.web_url` (the base with the Account id
appended). `PUT /api/v6/device/snapshots`, `PUT /api/v6/device/usage`, `GET /api/v2/device/sync`,
and `PUT /api/v2/device/profile` answer 402 `subscription_required` unless that entitlement is
`active` or `grace`. See [ADR 0033](../../docs/decisions/0033-entitlement-is-read-from-revenuecat.md).

The extra signing secret the retired browser-auth framework required is
not read by anything now and can be deleted from a local `.env` and from the deployed Worker; it is
named in [ADR 0025](../../docs/decisions/0025-one-session-system.md).

Register the GitHub OAuth App callback as
`https://quota.gotry.io/api/auth/github/callback`, and the Apple Services ID's one Return URL as
`https://quota.gotry.io/api/auth/apple/callback`. QuotaRelay owns the browser sign-in itself, and
an Account owns the channels it is reached through
([ADR 0032](../../docs/decisions/0032-an-account-owns-its-identities.md)):

| Route | What it does |
| --- | --- |
| `GET /api/auth/:provider/start?return_to=&intent=sign_in\|link` | Seals a 256-bit `state`, a PKCE verifier, the provider, the intent, and where to return to in a signed ten-minute `__Host-quota_oauth` cookie, then redirects to that provider. `intent=link` requires a web session; a provider Relay does not sign in through is 404. |
| `GET /api/auth/:provider/callback` | The callback of a provider that redirects. Checks the cookie, spends the code once, and either opens one `sessions` row with `client_kind = 'web'` behind a `__Host-quota_session` cookie, or binds the channel to the signed-in Account. |
| `POST /api/auth/:provider/callback` | The same completion for a provider that answers with a cross-site form POST, which today is Apple alone. Each provider accepts one delivery; the other is 404. |
| `GET /api/auth/:provider/start?return_to=&intent=sign_in\|link` | Seals a 256-bit `state`, a PKCE verifier, the provider, the intent, and where to return to in a signed ten-minute `__Host-quota_oauth` cookie, then redirects to that provider. `intent=link` requires a web session; a provider Relay does not sign in through is 404. Email is not this route. |
| `GET /api/auth/:provider/callback` | Checks the cookie, spends the code once, and either opens one `sessions` row with `client_kind = 'web'` behind a `__Host-quota_session` cookie, or binds the channel to the signed-in Account. |
| `POST /api/auth/email/start` | JSON `{ email, return_to?, intent? }`. Writes a fifteen-minute one-time challenge, mails a link through Resend, and always answers 202. One send per address per minute and five per hour; the IP shares the `web-signin` bucket. `intent=link` requires a web session. |
| `GET /api/auth/email/verify?token=` | Spends the token once and finishes the sealed `sign_in` or `link`. No handoff cookie: a `sign_in` may be opened on another device. Failure is the same browser error page (`expired` / `invalid_request` / `identity_taken`). |
| `POST /api/auth/logout` | Revokes the browser session and clears its cookie. |
| `GET /api/v2/account` | The Account and `identities[]`: provider, label, and when each was bound. |
| `DELETE /api/v2/account/identities/:provider` | Unbinds one channel. `409 conflict` when it is the last one. |
| `DELETE /api/v2/account` | Removes the Account and everything stored for it in one D1 batch. |
| `GET /oauth/v2/authorize` | Redirects to `/sign-in?return_to=/oauth/v2/complete?login_token=…` rather than to a provider, so a native login confirms which Account it is. |
| `GET /oauth/v2/complete` | Turns the web session into an authorization code. |
| `POST /oauth/v2/apple` | Sign in with Apple from inside the iOS app. Takes `{client_id: 'quota-ios', identity_token, nonce, intent?}`, checks the token against Apple's published keys, and answers with the `quota-ios` session — or, with `intent: 'link'` and a Bearer iOS session, binds Apple to that Account. |

`github` and `apple` are the providers registered today; `email` is the remaining channel an Account
can hold. Apple is asked for `name email`, which requires `response_mode=form_post`, so its handoff
cookie alone is sealed `SameSite=None` — still `__Host-`, still signed, still ten minutes. Its
`client_secret` is an ES256 JWT signed per exchange rather than a stored string. A browser whose `Accept` includes `text/html` and that fails on
`/api/auth/:provider/callback` or `/oauth/v2/complete` (no session, expired grant, rate limited,
invalid request, or a channel that already reaches another Account) gets a 200 HTML page titled
**Sign-in didn't finish**, one sentence for that reason, and **Return to Quota and try again.** —
never a token. Callers that do not ask for HTML still receive the original JSON status and body. See
GitHub is the OAuth provider registered today; email is a mailed one-time link on its own routes.
`github`, `apple`, and `email` are the channels an Account can hold. A browser whose `Accept`
includes `text/html` and that fails on `/api/auth/:provider/callback`, `/api/auth/email/verify`, or
`/oauth/v2/complete` (no session, expired grant, rate limited, invalid request, or a channel that
already reaches another Account) gets a 200 HTML page titled **Sign-in didn't finish**, one
sentence for that reason, and **Return to Quota and try again.** — never a token. Callers that do
not ask for HTML still receive the original JSON status and body. See
[ADR 0025](../../docs/decisions/0025-one-session-system.md).

Every client's session is a row in that same table, and one login issues one access/refresh family
([ADR 0027](../../docs/decisions/0027-one-token-per-client.md)). The `quotabar` client exchanges an
authorization code over a loopback redirect for a session scoped `[account:read, device:write]`,
which is the only way a Device is registered; Authorization Code with PKCE is the only grant Relay
offers. The registered `quota-ios` public client is a read-only Account login over the exact
redirect `io.gotry.quota:/oauth/callback`, scoped `[account:read]`, and it registers no Device. Both
exchanges answer with the Account's `display_label` beside the session, read in the same batch that
issued it, so a client can name the account before its first Account read. The checked-in Worker
enables Cloudflare `nodejs_compat`, which the SvelteKit server runtime requires.

Each keyed secret is independent and must contain at least 32 random characters. OAuth and session
routes return `Cache-Control: no-store`; only the versioned pricing and model catalogs are publicly
cacheable. `GET /api/v6/account/summary` and `GET /api/v6/account/usage/activity` are
`private, no-cache` with a strong `ETag`, and answer a matching `If-None-Match` with 304 before
running any Usage query.

Every document response carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`,
`X-Frame-Options: DENY`, and a Content Security Policy that allows scripts, styles, images, fonts,
and connections from this origin only, frames nowhere, and no `<base>` or plugin content. A
rendered page states the policy itself: `apps/web/svelte.config.js` declares the directives and
SvelteKit stamps each response with the nonce its bootstrap script and the theme script in
`app.html` claim, so nothing is hashed ahead of time. Responses SvelteKit does not render carry the
same policy without a nonce.

Production migration and deployment remain workflow-owned and must not be run manually without
explicit authorization.

The checked-in catalog in [`src/pricing-catalog.ts`](./src/pricing-catalog.ts) is a versioned
snapshot with no runtime pricing network dependency. Model metadata and current rates are traced to
models.dev snapshots and the official OpenAI/Anthropic pricing pages listed in that file; effective
date intervals preserve known historical changes. Unknown models and missing component rates stay
unpriced; wildcard dimension matches and the inferred-cache approximation remain explicit in the
calculation assumptions.

Readiness probes and the hourly Worker schedule run the bounded credential and quota-observation
cleanup defined in [`docs/security.md`](../../docs/security.md), and the same batch retires Usage:
`usage_hourly` and the hour versions beside it after 400 days, `usage_daily` after 800, and stored
Account Usage folds after two days. Each is at most a hundred rows per run, so a sweep never
competes with the uploads it runs alongside. An
unhandled request failure writes one `relay_request_failed` line carrying only the path, the status,
and the error's class name.
