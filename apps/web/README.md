# Quota Web

Public website for [quota.gotry.io](https://quota.gotry.io).

The site is a SvelteKit app kept separate from the Relay source boundary. The managed `quota`
Worker renders documents through SvelteKit `Server.respond` and publishes hashed `/_app` assets
from `dist/` through Cloudflare Workers Static Assets. Production builds also publish canonical
protocol files from `packages/protocol/schema` under `/schema/`; the website does not keep a
duplicate source copy.

SvelteKit owns documents, routes, components, and the document-scoped viewer. Relay owns Better
Auth, OAuth, APIs, D1, Usage aggregation, and domain policy. The only join is `WebDocumentPort`.
See [ADR 0011](../../docs/decisions/0011-sveltekit-document-worker.md).

Managed production publishes through the Relay deploy path (`pnpm deploy:cloudflare` / CI workflow
`deploy-cloudflare.yml`). There is no separate website-only Cloudflare project: website and Relay
API ship together on `quota.gotry.io`.

```bash
pnpm dev:web
QUOTA_DEV_VIEWER=octocat pnpm dev:web   # signed-in header QA only; Usage APIs still 401
pnpm --filter @gotry-io/quota-web check
pnpm --filter @gotry-io/quota-web build
```

`pnpm dev:web` is fast HMR and is not a real GitHub login. `pnpm dev:relay` is the composed
Worker. Browser GitHub login on localhost is not available.

`/my` is the GitHub-backed account dashboard and `/activate` approves or denies a native-client
device authorization grant. Unsigned `/my` visits are a server redirect home. Every page requires a
session; Quota Web publishes no account data anonymously. `/app` shipped in 0.0.4, so it remains a
single bookmark redirect to `/my`; new links and OAuth callbacks use `/my`. Better Auth owns GitHub sign-in, browser sessions,
sign-out, OAuth state/PKCE, account deletion, and standard auth-route origin validation. Quota's
authorization decision and Device deletion routes additionally require a recent session and an
exact same-origin request.

The signed-in dashboard opts into managed-data v3 Device Health and strictly shows each Device's app
version, platform, server-authoritative last report/refresh/sync, and health/staleness presentation.
It is read-only: remediation points to Diagnostics on that Device, and absent or expired reports do
not imply the Device is broken. The default non-opted-in Account summary remains compatible with
released strict clients.

New files under `static/` other than `logo.svg`, `logo-monochrome.svg`, `og.png`, and `schema/`
need a matching `!/filename` negation in `apps/relay/wrangler.jsonc`.

The site follows [`DESIGN.md`](./DESIGN.md) in this package. QuotaBar has a separate design system at
[`apps/menubar/DESIGN.md`](../menubar/DESIGN.md).
