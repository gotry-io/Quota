# Quota Web

Public website for [quota.gotry.io](https://quota.gotry.io).

The site is a static Vite build kept separate from the Relay runtime. The managed `quota` Worker
publishes its `dist/` output through Cloudflare Workers Static Assets alongside the Relay API;
self-hosted Relay builds do not include it. Production builds also publish the canonical protocol files from
`packages/protocol/schema` under `/schema/`; the website does not keep a duplicate source copy.

Managed production publishes through the Relay deploy path (`pnpm deploy:cloudflare` / CI workflow
`deploy-cloudflare.yml`). There is no separate website-only Cloudflare project: website and Relay
API ship together on `quota.gotry.io`.

```bash
pnpm dev:web
pnpm --filter @gotry-io/quota-web check
pnpm --filter @gotry-io/quota-web build
```

The site follows [`DESIGN.md`](./DESIGN.md) in this package. QuotaBar has a separate design system at
[`apps/menubar/DESIGN.md`](../menubar/DESIGN.md). The site links to GitHub while product downloads and
documentation are not yet published.
