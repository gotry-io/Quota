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
| Provider registration catalog (ids, defaults, config) | `packages/provider/catalog.json` |
| Codex, Claude Code, Grok, and OpenRouter collection strategies | `docs/provider-collection.md` |
| CodexBar external platform capability baseline (quota/usage/fallback) | `docs/codexbar-platform-capabilities.md` |
| Persistent Relay storage decision and rationale | `docs/decisions/0001-persistent-relay-storage.md` |
| Managed account, device, authentication, deletion, and Usage boundary | `docs/decisions/0006-managed-account-device-usage.md` |
| Managed-data v3 and Cursor account-sync protocol | `docs/decisions/0012-managed-data-v3.md` |
| Read-only iOS account client | `docs/decisions/0013-readonly-ios-account-client.md` |
| Non-secret iOS widget snapshot | `docs/decisions/0014-nonsecret-ios-widget-snapshot.md` |
| Website visual tokens and marketing UI | `apps/web/DESIGN.md` |
| QuotaBar menu-panel visual tokens and UI behavior | `apps/menubar/DESIGN.md` |
| Quota iOS visual tokens and UI behavior | `apps/ios/DESIGN.md` |
| App-specific usage | The corresponding `apps/*/README.md` |

Do not create a second description of a canonical rule. Update its source and link to it.

## Repository boundaries

- Put runnable and deployable products under `apps/` and shared code under `packages/`.
- Do not recreate legacy top-level `internal/`, `protocol/`, or `cmd/` trees.
- Follow the dependency graph and runtime restrictions in `docs/architecture.md`.
- Preserve documented protocol and platform interfaces that intentionally reserve future behavior.
  Confirm that scaffolding is stale before removing it.
- Keep the website source and managed Relay source as separate app boundaries even though production
  serves both from one hostname.

## Change requirements

- Protocol changes start in `packages/protocol`. Keep runtime schemas, exported JSON Schemas, tests,
  Rust production/consumption, and Swift decoding aligned. An already released protocol version remains compatible; breaking
  released behavior requires a new protocol version.
- Provider changes must update `packages/provider/catalog.json`, the Rust collector, and
  `docs/provider-collection.md`, then run `pnpm generate:provider-catalog` so protocol ids and Swift
  `ProviderID` stay aligned. Follow `docs/security.md` for credentials and redaction.
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
- Format TypeScript/JSON/Markdown with Biome and Rust with rustfmt using the repository configuration.
- Use `@gotry-io/*` for TypeScript workspace packages and `workspace:*` for internal dependencies.
- Keep dependencies pinned consistently. Commit `pnpm-lock.yaml` and the root workspace
  `Cargo.lock`; do not add npm, Yarn, or Bun lockfiles.
- Rust code targets the stable toolchain. Keep `apps/menubar/helper` private: no command parser,
  socket listener, daemonization, or public installation surface. `apps/cli` is the Linux-only
  native `quotacli` command and is built/tested without a Windows target or publication workflow.
- Swift code targets macOS 14+ or iOS 17+ and Swift 6.2. Keep wire decoding and Relay access separate from views.
- Web UI follows `apps/web/DESIGN.md` and must remain keyboard-accessible and responsive.
- QuotaBar UI follows `apps/menubar/DESIGN.md` (system material panel), not the website design file.
- Wire JSON uses `snake_case`. Primary quota values and meters always represent remaining quota.
- Product names are Quota, QuotaBar, QuotaCLI, and QuotaRelay. The iOS app's product name is Quota.
  The bundled Rust service executable is a private QuotaBar implementation detail, not the public
  `quotacli` command.
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
pnpm version:bump:menubar patch   # QuotaBar CFBundleShortVersionString only
# Publish: git tag menubar-vX.Y.Z

# Linux only: native QuotaCLI validation (run on Ubuntu)
pnpm build:linux-cli
pnpm check:linux-cli
pnpm test:linux-cli
```

Targeted development entry points are defined by the root `package.json` scripts and each app's
README. Do not duplicate their command lists in new documents.

Do not commit generated state such as `node_modules/`, `dist/`, `target/`, `.build/`, `.swiftpm/`,
`.wrangler/`, SQLite files, logs, or local credentials.

## Verification

- The `.githooks` pre-commit and pre-push hooks are the floor, not the plan. They catch formatting,
  a stale generated catalog, and the tiers a push touches; the entries below still apply.
- TypeScript-only change: run the affected workspace's type check and tests, plus root formatting.
- Provider change: run shared Rust service and entry-point tests, including relevant failure and
  redaction cases.
- Protocol change: run protocol, model, provider, Relay, and Swift decoding tests. After catalog id
  changes, run `pnpm generate:provider-catalog` before type check and Swift tests.
- Relay change: run Vitest, local D1 migration verification, and the Cloudflare dry-run build.
- QuotaBar account-path change: on macOS, run affected Swift and Relay tests plus the signed-service
  integration tests available in the app package.
- Quota iOS or `packages/apple-client` change: run `pnpm generate:ios`, `swift test --package-path
  packages/apple-client`, and the iOS Simulator build/tests from `apps/ios/README.md`. Do not migrate
  QuotaBar into `packages/apple-client` unless that is the requested change.
- Web change: run its type check and production build; inspect desktop and mobile rendering when
  browser tooling is available.
- Deployment change: validate the Cloudflare workflow and the complete Worker + Static Assets
  dry-run build.
- Cross-cutting change: run the full root format, check, test, and build sequence.

If platform-specific verification cannot run, report exactly what was skipped and why.

## Deployment safety

- Local builds and Wrangler dry runs are verification. Do not manually deploy Workers, apply remote
  D1 migrations, publish packages, push images, create releases, or change DNS without explicit user
  authorization. The checked-in `deploy-cloudflare.yml` workflow is the authorized path for managed
  Relay/website production deploys from `main` once Cloudflare secrets are configured.
- Keep production identifiers and secrets out of tracked files.
- Treat migration and retained-data changes as security-sensitive and review them against
  `docs/security.md`.

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
