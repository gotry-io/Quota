# Quota Repository Instructions

This file applies to the entire monorepo. It defines how agents work in the repository; product and
architecture facts live in the referenced source documents rather than being repeated here.

## Sources of truth

Read the relevant source before changing that area. Historical decision discovery is the
[ADR index](docs/decisions/README.md).

| Concern | Canonical source |
| --- | --- |
| Architecture | `docs/architecture.md` |
| Security | `docs/security.md` |
| Protocol | `packages/protocol`; [ADR 0023](docs/decisions/0023-strict-writes-tolerant-reads.md) |
| Provider catalog and strategy | `packages/provider/catalog.json`, `docs/provider-collection.md`, `docs/providers/README.md`, `docs/providers/<id>.md`, `docs/usage-sources.md` |
| Design | `docs/design.md`, `packages/design-tokens/tokens.json` |
| Local state | [ADR 0021](docs/decisions/0021-identity-store-and-disposable-cache.md) |
| Account and sync | [ADR index](docs/decisions/README.md) (0006, 0025, 0027, 0048, 0055) |
| App work | `apps/*/README.md`; platform UI deltas in `apps/*/DESIGN.md` |
| Deployment and release | `docs/relay-self-host.md`, [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| CI | `.github/workflows/ci.yml`, [`CONTRIBUTING.md`](CONTRIBUTING.md) |

Do not create a second description of a canonical rule. Update its source and link to it.

## Repository boundaries

- Put runnable and deployable products under `apps/` and shared code under `packages/`.
- Apple shared types live in `packages/apple-client` and `packages/apple-shared` as
  `docs/architecture.md` states. Do not restate a type one of those packages already owns; do not
  move a QuotaBar-only type into them to make it look shared.
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
- Provider changes must update `packages/provider/catalog.json` — including the row's `capabilities`
  block — the Rust collector, and `docs/providers/<id>.md` (common ladder in
  `docs/provider-collection.md`; local Usage parsers in `docs/usage-sources.md`), then run
  `pnpm generate:provider-catalog`, `pnpm generate:capability-matrix`, and `pnpm generate:reference`
  so protocol ids, Swift `ProviderID`, the capability matrix, and the generated reference stay
  aligned. New providers are frozen and the tiers are fixed by
  `docs/decisions/0060-provider-freeze-and-two-tiers.md`. Follow `docs/security.md` for credentials
  and redaction.
- Persistence changes require a new explicit migration, in the right store: Relay SQLite
  (`apps/relay/migrations`, `d1_migrations` ledger), and locally either `identity.sqlite` or the
  disposable `cache.sqlite`, whose migration ladders are separate. Do not rewrite an applied
  migration.
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
  `docs/provider-collection.md`, `docs/providers/<id>.md`, and observed supported provider behavior.

## Code conventions

- TypeScript is strict ESM. Keep explicit `.ts` extensions for local imports and use `import type`
  for type-only imports. Do not weaken the shared TypeScript checks to bypass errors.
- Format TypeScript/JSON/Markdown with Biome and Rust with rustfmt using the repository configuration.
- Use `@gotry-io/*` for TypeScript workspace packages and `workspace:*` for internal dependencies.
  Keep dependencies pinned consistently. Commit `pnpm-lock.yaml` and the root workspace
  `Cargo.lock`; do not add npm, Yarn, or Bun lockfiles.
- Rust targets the stable toolchain. `apps/menubar/helper` is the only entry that may *write* over
  `packages/service`; keep it private. The `quota` binary is a reader
  (`docs/decisions/0046-a-read-only-quota-command.md`). Only macOS is built, tested, and released.
- Swift code targets macOS 14+ or iOS 26+ and Swift 6.2. Keep wire decoding and Relay access separate
  from views.
- Web UI follows `docs/design.md` and `apps/web/DESIGN.md`. QuotaBar UI follows `docs/design.md` and
  `apps/menubar/DESIGN.md`, not the website design file.
- Wire JSON uses `snake_case`. Primary quota values and meters always represent remaining quota.
- Product names are Quota, QuotaBar, and QuotaRelay. The iOS app's product name is Quota. The
  bundled Rust *service* executable is a private QuotaBar implementation detail, never a public
  command; `quota` is the one public command, and it only reads.
- Prefer direct implementations over redundant wrappers, retries, fallbacks, and defensive branches.
  Add them only for a concrete boundary, failure mode, or security requirement.

Development commands, hooks, the merge queue, and review expectations live in
[`CONTRIBUTING.md`](CONTRIBUTING.md). Do not commit generated state such as `node_modules/`,
`dist/`, `target/`, `.build/`, `.swiftpm/`, `.wrangler/`, SQLite files, logs, or local credentials.

## Verification

- The `.githooks` pre-commit and pre-push hooks are the floor, not the plan. They catch formatting,
  a stale generated catalog, capability matrix, design tokens, ADR index, or reference, and the
  tiers a push touches; the entries below still apply.
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
- Relay change: run Vitest (`test` and `test:node:integration` after a website build). Node
  applies `apps/relay/migrations` on start; cover that ladder in `test/platform`.
- QuotaBar account-path change: on macOS, run affected Swift and Relay tests plus the signed-service
  integration tests available in the app package.
- Local-state change: cover both stores. A damaged `cache.sqlite` must be rebuilt without touching
  identity; a damaged identity must make the device a new signed-out installation.
- Quota iOS, `packages/apple-client`, or a QuotaBar change that crosses either: run
  `pnpm generate:ios`, `pnpm generate:menubar`, `swift test --package-path packages/apple-client`,
  `swift test --package-path apps/menubar`, and the iOS Simulator build/tests from
  `apps/ios/README.md`. A change to either app's `project.yml` re-generates and commits its
  checked-in Xcode project in the same change.
- Web change: run its type check, existing and component tests, e2e smoke, and production build;
  inspect desktop and mobile rendering when browser tooling is available.
- Deployment change: validate `.github/workflows/release-relay-image.yml` and read the
  Dockerfile; a Docker image build is an owner action, not local verification.
- Cross-cutting change: run the full root format, check, test, and build sequence.

If platform-specific verification cannot run, report exactly what was skipped and why.

## Deployment safety

- Local builds are verification. Do not publish packages, push images, create releases, or change
  DNS without explicit user authorization. Relay/website production is the Node/SQLite image on
  dmit; deploying it is the owner action in `docs/relay-self-host.md` (tag `relay-v*`, pull,
  redeploy the Portainer stack).
- Keep production identifiers and secrets out of tracked files.
- Treat migration and retained-data changes as security-sensitive and review them against
  `docs/security.md`.

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
