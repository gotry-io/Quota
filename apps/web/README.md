# Quota Web

Public website for [quota.gotry.io](https://quota.gotry.io).

The site is a static Vite build kept separate from the Relay runtime. Its `dist/` output is intended
for Cloudflare Workers Static Assets in the managed deployment; self-hosted Relay builds do not
include it.

```bash
pnpm dev:web
pnpm --filter @gotry/quota-web check
pnpm --filter @gotry/quota-web build
```

The initial site follows the repository's root [`DESIGN.md`](../../DESIGN.md) tokens and links to
GitHub while product downloads and documentation are not yet published.
