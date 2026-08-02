# QuotaCLI

QuotaCLI is the local provider collector and remote edge agent. One TypeScript entry point produces
a Node ESM npm package and a standalone Bun executable.

Provider credentials are read locally and never sent to QuotaRelay. Edge mode sends only validated,
normalized quota snapshots from `@gotry-io/quota-protocol`.

```bash
pnpm --filter @gotry-io/quotacli dev -- providers
pnpm --filter @gotry-io/quotacli dev -- doctor
pnpm --filter @gotry-io/quotacli dev -- quota --format json --pretty
pnpm --filter @gotry-io/quotacli build
```

## Commands

```text
quotacli version
quotacli providers
quotacli doctor
quotacli quota [--provider codex|claude|grok|all] [--format text|json] [--pretty]
quotacli help
```

`quota` defaults:

- `--provider all`
- `--format text` when attached to a terminal
- `--format json` otherwise

Exit codes for `quota`:

- `0`: every requested provider returned at least one fresh snapshot
- `1`: collection completed with one or more provider failures
- `2`: invalid CLI arguments

JSON output is one versioned `QuotaCollectionReport`. Provider failures stay inside the report.
QuotaCLI never prints credentials, authorization headers, cookies, raw JWTs, or unredacted response
bodies.

## Distribution artifacts

`build:npm` creates the Node-based `dist/npm/quotacli.js` published as
`@gotry-io/quotacli`. `build:standalone` creates `dist/standalone/quotacli` for the QuotaBar app
bundle and direct release downloads. The npm package installs the same `quotacli` command and does
not require Bun at runtime.

## Planned edge pairing

Edge reporting is not implemented yet. Its accepted command shape is:

```text
quotacli edge pair                         # defaults to https://quota.gotry.io
quotacli edge pair --relay https://relay.example.com
quotacli edge start
quotacli edge status
quotacli edge stop
quotacli edge unpair
```

`pair` uses a Relay-generated Device Code approved in QuotaBar. It does not accept a manually
created long-lived token and does not start reporting by itself. See
[`ADR 0002`](../../docs/decisions/0002-relay-device-code-pairing.md).
