# Quota Web

Public website for [quota.gotry.io](https://quota.gotry.io).

The site is a static Vite build kept separate from the Relay source boundary. The managed `quota`
Worker publishes its `dist/` output through Cloudflare Workers Static Assets alongside the account,
device, quota, and Usage API. Production builds also publish canonical protocol files from
`packages/protocol/schema` under `/schema/`; the website does not keep a duplicate source copy.

Managed production publishes through the Relay deploy path (`pnpm deploy:cloudflare` / CI workflow
`deploy-cloudflare.yml`). There is no separate website-only Cloudflare project: website and Relay
API ship together on `quota.gotry.io`.

```bash
pnpm dev:web
pnpm --filter @gotry-io/quota-web check
pnpm --filter @gotry-io/quota-web build
```

`/my` is the GitHub-backed account dashboard and `/activate` approves or denies a native-client device
authorization grant. Unsigned `/my` visits redirect home. `/app` shipped in 0.0.4, so it remains a
single bookmark redirect to `/my`; new links and OAuth callbacks use `/my`. Better Auth owns GitHub
sign-in, browser sessions, sign-out,
OAuth state/PKCE, account deletion, and standard auth-route origin validation. Quota's authorization
decision and Device deletion routes additionally require a recent session and an exact same-origin
request.

The site follows [`DESIGN.md`](./DESIGN.md) in this package. QuotaBar has a separate design system at
[`apps/menubar/DESIGN.md`](../menubar/DESIGN.md). The site links to GitHub while product downloads and
documentation are not yet published.
