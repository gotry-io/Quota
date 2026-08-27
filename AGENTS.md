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
| Collection strategy for all eight providers, and every subprocess a refresh may start | `docs/provider-collection.md` |
| CodexBar external platform capability baseline (quota/usage/fallback) | `docs/codexbar-platform-capabilities.md` |
| Persistent Relay storage decision and rationale | `docs/decisions/0001-persistent-relay-storage.md` |
| Observation merge that preserves what each device saw | `docs/decisions/0003-observation-preserving-subscription-merge.md` |
| One private Rust service behind one entry point | `docs/decisions/0007-rust-native-local-service.md` |
| Report-time model catalog, and why the raw model text is kept | `docs/decisions/0009-versioned-model-catalog.md` |
| Browser-session acquisition, its consent gate, and its bounds | `docs/decisions/0010-provider-browser-session-auth.md` |
| SvelteKit documents served through the Relay Worker | `docs/decisions/0011-sveltekit-document-worker.md` |
| Freshness derived from the observation, not stamped on it | `docs/decisions/0017-derived-observation-freshness.md` |
| One statement per contract, and where it is written | `docs/decisions/0019-one-statement-per-contract.md` |
| Invalid provider/agent input isolation | `docs/decisions/0026-isolate-invalid-input-at-the-smallest-scope.md` |
| Managed account, device, authentication, and deletion lifecycle | `docs/decisions/0006-managed-account-device-usage.md` |
| Browser sign-in and the one session table behind every client | `docs/decisions/0025-one-session-system.md` |
| One token per client, and why there is no CLI or device grant | `docs/decisions/0027-one-token-per-client.md` |
| Managed-data v6: hour-versioned Usage, daily rollups, resolved subscriptions | `docs/decisions/0024-hour-versioned-usage-and-daily-rollups.md` |
| Strict writes, tolerant reads, and unknown enum members | `docs/decisions/0023-strict-writes-tolerant-reads.md` |
| Local identity store, disposable cache, and what a damaged image costs | `docs/decisions/0021-identity-store-and-disposable-cache.md` |
| Diagnostic report v3, the attempt journal, and Account device status | `docs/decisions/0022-minimal-diagnostics.md` |
| Read-only iOS account client | `docs/decisions/0013-readonly-ios-account-client.md` |
| Non-secret iOS widget snapshot and background refresh | `docs/decisions/0014-nonsecret-ios-widget-snapshot.md` |
| Freshness, provider-name, and Devices copy shared by every client | `apps/menubar/DESIGN.md` (Shared product vocabulary) |
| Website visual tokens and marketing UI | `apps/web/DESIGN.md` |
| QuotaBar menu-panel visual tokens and UI behavior | `apps/menubar/DESIGN.md` |
| Quota iOS visual tokens and UI behavior | `apps/ios/DESIGN.md` |
| App-specific usage | The corresponding `apps/*/README.md` |

Do not create a second description of a canonical rule. Update its source and link to it.

## Repository boundaries

- Put runnable and deployable products under `apps/` and shared code under `packages/`.
- The Apple packages own what more than one Apple product speaks: `packages/apple-client` owns the
  managed wire types — quota, account, and Usage — plus `ProviderID` and Relay access;
  `packages/apple-shared` owns Foundation-only presentation semantics. QuotaBar owns its private IPC
  models, its Usage upload and local-report types, and app-only provider behavior, and extends the
  shared types rather than declaring a second copy. Wire validation lives with the type it protects,
  so both products answer the same input the same way. Do not restate a type one of those packages
  already owns; do not move a QuotaBar-only type into them to make it look shared.
- Do not recreate legacy top-level `internal/`, `protocol/`, or `cmd/` trees.
- Follow the dependency graph and runtime restrictions in `docs/architecture.md`.
- Preserve documented protocol and platform interfaces that intentionally reserve future behavior.
  Confirm that scaffolding is stale before removing it.
- Keep the website source and managed Relay source as separate app boundaries even though production
  serves both from one hostname.

## Change requirements

- Protocol changes start in `packages/protocol`. Keep runtime schemas, exported JSON Schemas, tests,
  Rust production/consumption, and Swift decoding aligned. A payload crossing into a system is
  checked against exactly the contract and refused when it does not match. A payload read back out
  of one takes the fields and enum members it names and ignores the rest, so adding either is not a
  breaking change; changing the shape of a released data contract still requires a new protocol
  version. See `docs/decisions/0023-strict-writes-tolerant-reads.md`.
- Provider changes must update `packages/provider/catalog.json`, the Rust collector, and
  `docs/provider-collection.md`, then run `pnpm generate:provider-catalog` so protocol ids and Swift
  `ProviderID` stay aligned. Follow `docs/security.md` for credentials and redaction.
- Persistence changes require a new explicit migration, in the right store: D1 for Relay, and
  locally either `identity.sqlite` or the disposable `cache.sqlite`, whose migration ladders are
  separate. Do not rewrite an applied migration.
- The private IPC surface — including the `ready` event, `ping`, and the `diagnose` report's
  `schema_version: 3` — ships atomically with QuotaBar. Change both sides together and delete the
  replaced one; the local reports carried inside IPC state name no version of their own.
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
- Rust code targets the stable toolchain. `apps/menubar/helper` is the only entry point over
  `packages/service`; keep it private: no command parser, socket listener, daemonization, or public
  installation surface. The shared crate stays platform-neutral in style, but only macOS is built,
  tested, and released.
- Swift code targets macOS 14+ or iOS 17+ and Swift 6.2. Keep wire decoding and Relay access separate from views.
- Web UI follows `apps/web/DESIGN.md` and must remain keyboard-accessible and responsive.
- QuotaBar UI follows `apps/menubar/DESIGN.md` (system material panel), not the website design file.
- Wire JSON uses `snake_case`. Primary quota values and meters always represent remaining quota.
- Product names are Quota, QuotaBar, and QuotaRelay. The iOS app's product name is Quota. The
  bundled Rust service executable is a private QuotaBar implementation detail, never a public
  command.
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
- Protocol change: run protocol, model, provider, Relay, and Swift decoding tests, including the
  `wire-conformance.json` cases every runtime answers. After catalog id changes, run
  `pnpm generate:provider-catalog` before type check and Swift tests.
- Managed-data change: managed reads and writes are v6 on `/api/v6`. Exercise the hour-replacement
  and daily-rollup paths and the resolved `subscriptions[]` a summary answers with.
- Authentication change: a client holds one session, and its scopes are what it may do
  (`docs/decisions/0027-one-token-per-client.md`). Cover the session that writes a Device, the one
  that only reads, and the browser cookie, and keep the case proving a token from a Device's earlier
  generation is refused.
- Relay change: run Vitest, local D1 migration verification, and the Cloudflare dry-run build.
- QuotaBar account-path change: on macOS, run affected Swift and Relay tests plus the signed-service
  integration tests available in the app package.
- Local-state change: cover both stores. A damaged `cache.sqlite` must be rebuilt without touching
  identity; a damaged identity must make the device a new signed-out installation.
- Quota iOS, `packages/apple-client`, or a QuotaBar change that crosses either: run
  `pnpm generate:ios`, `swift test --package-path packages/apple-client`, `swift test --package-path
  apps/menubar`, and the iOS Simulator build/tests from `apps/ios/README.md`.
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
