# QuotaRelay

QuotaRelay is the managed Cloudflare Worker + D1 account and usage service for
`https://quota.gotry.io`. It serves the v2 GitHub account, native-client OAuth, device quota/Usage, account
read, and public pricing-catalog APIs, and it renders Quota Web documents through SvelteKit
`Server.respond` as described in [ADR 0011](../../docs/decisions/0011-sveltekit-document-worker.md).
There is no self-hosted or SQLite runtime.

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
native grants and their separate account/device token families. The checked-in Worker enables
Cloudflare `nodejs_compat`, which Better Auth's runtime requires.

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
