# QuotaCLI

QuotaCLI is the local provider collector and remote edge agent. It is written in TypeScript and
packaged as a standalone Bun executable.

Provider credentials are read locally and never sent to QuotaRelay. Edge mode sends only validated,
normalized quota snapshots from `@gotry/quota-protocol`.

```bash
pnpm --filter @gotry/quota-cli dev -- providers
pnpm --filter @gotry/quota-cli dev -- doctor
pnpm --filter @gotry/quota-cli dev -- quota --format json --pretty
pnpm --filter @gotry/quota-cli build
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

Pairing and daemon commands will be added on top of the versioned device-certificate protocol.
