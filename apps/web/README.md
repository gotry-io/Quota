# Quota Web

Public website for [quota.gotry.io](https://quota.gotry.io).

The site is a static Vite build kept separate from the Relay runtime. Its `dist/` output is intended
for Cloudflare Workers Static Assets in the managed deployment; self-hosted Relay builds do not
include it. Production builds also publish the canonical protocol files from
`packages/protocol/schema` under `/schema/`; the website does not keep a duplicate source copy.

```bash
pnpm dev:web
pnpm --filter @gotry-io/quota-web check
pnpm --filter @gotry-io/quota-web build
```

The initial site follows the repository's root [`DESIGN.md`](../../DESIGN.md) tokens and links to
GitHub while product downloads and documentation are not yet published.
