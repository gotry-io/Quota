# QuotaRelay

QuotaRelay is the managed Cloudflare Worker + D1 account and usage service for
`https://quota.gotry.io`. It serves v2 GitHub account, native-client OAuth, Device control, and
public catalog APIs alongside the managed-data v4 quota/Usage data APIs. It renders Quota Web documents through SvelteKit
`Server.respond` as described in [ADR 0011](../../docs/decisions/0011-sveltekit-document-worker.md).
There is no self-hosted or SQLite runtime.

QuotaBar and Quota Web speak managed-data v4, the only data contract this Worker serves. A client
that speaks an older shape is refused rather than translated; see
[ADR 0018](../../docs/decisions/0018-single-managed-data-contract.md).

Authenticated collection Devices publish only their own latest sanitized Device Health at
`PUT /api/v5/device/health`. D1 uses the monotonic diagnostics refresh revision to reject delayed
older reports and server receipt time for freshness; Device/Account deletion cascades the row.
Every Device on `GET /api/v5/account/summary` carries a required nullable `health` field; a Device
that has never reported says so rather than being absent. Relay stores no health history. See
[ADR 0015](../../docs/decisions/0015-diagnostic-attempts-and-device-health.md).

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
- `BETTER_AUTH_SECRET`

Register the GitHub OAuth App callback as
`https://quota.gotry.io/api/auth/v2/callback/github`. Better Auth owns GitHub OAuth state, PKCE,
browser cookies, session expiry, and standard auth-route origin checks. QuotaRelay retains the
native grants and their separate account/device token families. The registered `quota-ios` public
client is a read-only Account login: Authorization Code with PKCE and the exact redirect
`io.gotry.quota:/oauth/callback`. It never receives a Device session or upload authority. The
checked-in Worker enables Cloudflare `nodejs_compat`, which Better Auth's runtime requires.

Each keyed secret is independent and must contain at least 32 random characters. OAuth and session
routes return `Cache-Control: no-store`; only the versioned pricing catalog is publicly cacheable.
Production migration and deployment remain workflow-owned and must not be run manually without
explicit authorization.

The checked-in catalog in [`src/pricing-catalog.ts`](./src/pricing-catalog.ts) is a versioned
snapshot with no runtime pricing network dependency. Model metadata and current rates are traced to
models.dev snapshots and the official OpenAI/Anthropic pricing pages listed in that file; effective
date intervals preserve known historical changes. Unknown models and missing component rates stay
unpriced; wildcard dimension matches and the inferred-cache approximation remain explicit in the
calculation assumptions.

Readiness probes and the hourly Worker schedule run the bounded credential cleanup defined in
[`docs/security.md`](../../docs/security.md).
