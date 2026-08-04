# Quota Repository Instructions

This file applies to the entire monorepo. It defines how agents work in the repository; product and
architecture facts live in the referenced source documents rather than being repeated here.

## Sources of truth

Read the relevant source before changing that area:

| Concern | Canonical source |
| --- | --- |
| Product overview, repository layout, commands, current status | `README.md` |
| System boundaries, data paths, package dependencies, runtime split | `docs/architecture.md` |
| Credentials, trust, redaction, transport, storage safety | `docs/security.md` |
| Codex, Claude Code, and Grok collection strategies | `docs/provider-collection.md` |
| Persistent Relay storage decision and rationale | `docs/decisions/0001-persistent-relay-storage.md` |
| Relay pairing, code control, and credential issuance | `docs/decisions/0002-relay-device-code-pairing.md` |
| Anonymous Relay owner lifecycle | `docs/decisions/0004-anonymous-relay-owners.md` |
| Website visual tokens and marketing UI | `apps/web/DESIGN.md` |
| QuotaBar menu-panel visual tokens and UI behavior | `apps/menubar/DESIGN.md` |
| App-specific usage | The corresponding `apps/*/README.md` |

Do not create a second description of a canonical rule. Update its source and link to it.

## Repository boundaries

- Put runnable and deployable products under `apps/` and shared code under `packages/`.
- Do not recreate legacy top-level `internal/`, `protocol/`, or `cmd/` trees.
- Follow the dependency graph and runtime restrictions in `docs/architecture.md`.
- Preserve documented protocol and platform interfaces that intentionally reserve future behavior.
  Confirm that scaffolding is stale before removing it.
- Keep the website and self-hosted Relay artifacts separate even when the managed deployment serves
  both from one hostname.

## Change requirements

- Protocol changes start in `packages/protocol`. Keep runtime schemas, exported JSON Schemas, tests,
  and Swift decoding aligned. An already released protocol version remains compatible; breaking
  released behavior requires a new protocol version.
- Provider changes must follow both `docs/provider-collection.md` and `docs/security.md`.
- Persistence changes require a new explicit migration. Do not rewrite an applied migration.
- Architecture, trust boundary, retention, provider strategy, layout, command, and current-status
  changes must update their canonical document in the same change.
- Durable architecture decisions belong in `docs/decisions/`; temporary implementation plans do not
  belong in permanent documentation after completion.

## Compatibility discipline

- Do not add compatibility shims, legacy aliases, dual read/write paths, optional decoding defaults,
  deprecation wrappers, or speculative fallbacks unless the user explicitly requests compatibility
  or the relevant interface, artifact, or persisted schema has shipped in a production release or
  deployment.
- Verify release and deployment status from the canonical README and relevant release configuration
  before preserving old behavior. Compatibility is scoped to the shipped boundary, not the entire
  repository.
- For unreleased code, change the canonical schema, model, callers, tests, and documentation together
  and delete the replaced path. Prefer the final direct design over migration scaffolding.
- When compatibility is required, document the concrete shipped constraint and cover it with a
  focused test. Remove the compatibility path when the supported release or retained data no longer
  requires it.
- Provider API shape variants and documented provider-owned collection fallbacks are product input
  handling, not repository-version compatibility. Keep only the variants required by
  `docs/provider-collection.md` and observed supported provider behavior.

## Code conventions

- TypeScript is strict ESM. Keep explicit `.ts` extensions for local imports and use `import type`
  for type-only imports.
- Do not weaken the shared TypeScript checks to bypass errors.
- Format supported files with Biome using the repository configuration.
- Use `@gotry-io/*` for workspace packages and `workspace:*` for internal dependencies. The public
  CLI package is `@gotry-io/quotacli`; its installed command remains `quotacli`.
- Keep dependencies pinned consistently and commit only `pnpm-lock.yaml`; do not add npm, Yarn, or
  Bun lockfiles.
- Avoid native Node addons in QuotaCLI.
- Swift code targets macOS 14+ and Swift 6.2. Keep wire decoding and Relay access separate from views.
- Web UI follows `apps/web/DESIGN.md` and must remain keyboard-accessible and responsive.
- QuotaBar UI follows `apps/menubar/DESIGN.md` (system material panel), not the website design file.
- Wire JSON uses `snake_case`. Primary quota values and meters always represent remaining quota.
- Product names are Quota, QuotaBar, QuotaCLI, and QuotaRelay.
- Prefer direct implementations over redundant wrappers, retries, fallbacks, and defensive branches.
  Add them only for a concrete boundary, failure mode, or security requirement.

## Development commands

Run commands from the repository root. The required toolchain is listed in `README.md`.

```bash
pnpm install
pnpm format:check
pnpm check
pnpm test
pnpm build
```

Targeted development entry points are defined by the root `package.json` scripts and each app's
README. Do not duplicate their command lists in new documents.

Do not commit generated state such as `node_modules/`, `dist/`, `.build/`, `.swiftpm/`, `.wrangler/`,
SQLite files, logs, or local credentials.

## Verification

- TypeScript-only change: run the affected workspace's type check and tests, plus root formatting.
- Provider change: run quota-provider and QuotaCLI tests, including relevant failure and redaction
  cases.
- Protocol change: run protocol, model, provider, Relay, and Swift decoding tests.
- Relay change: run Vitest, Bun SQLite tests, and the Cloudflare dry-run build.
- QuotaBar Relay owner-path change: on macOS, run `pnpm test:relay:e2e` in addition to the
  affected Swift and Relay tests.
- Web change: run its type check and production build; inspect desktop and mobile rendering when
  browser tooling is available.
- Deployment change: validate Compose and build the complete Relay image.
- Cross-cutting change: run the full root format, check, test, and build sequence.

If platform-specific verification cannot run, report exactly what was skipped and why.

## Deployment safety

- Local builds and Wrangler dry runs are verification. Do not deploy Workers, apply remote D1
  migrations, publish packages, push images, create releases, or change DNS without explicit user
  authorization.
- Keep production identifiers and secrets out of tracked files.
- Treat migration and retained-data changes as security-sensitive and review them against
  `docs/security.md`.

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
