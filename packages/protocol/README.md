# @gotry-io/quota-protocol

Runtime schemas for QuotaBar's Rust local service, managed QuotaRelay, Swift `Codable` models, and
the registered `quota-ios` account client. OAuth and Device control remain v2; quota, Usage, and
Account summary use managed-data v6. Each client exchanges its authorization code for one session
on the same v2 OAuth contract, and `quota-ios` names its own request and response payloads because
it registers no Device. Both token responses carry the Account's `display_label` alongside the
session, so a client names the account it signed in to before it has read one.

Strict writes, tolerant reads
([ADR 0023](../../docs/decisions/0023-strict-writes-tolerant-reads.md)). A request body is checked against exactly the contract and refused when it names a key the contract
does not. A response is stated by the same schema — Relay is its producer and answers to it — and
read through the `*ReadSchema` derived from it, which accepts fields and enum members this build
cannot name at any depth. Adding either to a read is therefore not a breaking change; changing the
shape of a released contract still moves its version.

- TypeScript runtime validation lives in `src`.
- Managed-network `ProviderId` and local-report `LocalProviderId` are generated from
  `packages/provider/catalog.json` into `src/provider-ids.generated.ts` via
  `pnpm generate:provider-catalog`. Do not hand-edit that file.
- Language-neutral JSON Schemas live in `schema` and are served by Quota Web under `/schema/`.
  Run `pnpm --filter @gotry-io/quota-protocol generate:schema` from the repository root after
  changing a runtime schema; the generator formats what it writes with the repository's Biome.
- Canonical schema identifiers use `https://quota.gotry.io/schema/`.
- Wire fields use `snake_case`. A request object rejects unknown keys; a read accepts them. V2
  directly relates accounts and devices and contains no owner, pairing, Relay discovery, or
  self-hosted payloads.
- Quota windows may include optional absolute fields (`remaining_value`, `limit_value`,
  `value_unit`) for credits-class meters; consumers that only understand `used_percent` remain valid.
- Pricing schemas and pure calculation code do not contain a canonical price catalog. The managed
  Relay supplies the validated catalog used by clients.
- `fixtures/pricing-conformance.json` is the language-neutral pricing validation, resolution, and
  cost contract read directly by the Rust service and TypeScript quota-model tests.
- `fixtures/wire-conformance.json` states each wire contract as accepted and refused payloads, and
  all three runtimes answer it: writes through the schema that guards them, reads through the schema
  a client reads with.
- `fixtures/freshness-copy-conformance.json` states the thresholds and the words every Quota
  surface uses to say how old a reading is, so the website and the Apple clients say the same
  thing about the same instant.
- `fixtures/quota-observation-conformance.json` states how long a reading describes current quota
  and how observations resolve into subscriptions. Relay resolves them once for every reader
  ([ADR 0024](../../docs/decisions/0024-hour-versioned-usage-and-daily-rollups.md)), so the merge
  cases are answered by `packages/quota-model` and by the Rust two-way merge.
- A Usage upload names whole UTC hours. `UsageRow` carries what it measures and no instant: the hour
  that carries it says when, and its `scan_version` says whether this reading of that hour is newer
  than the stored one. `DatedUsageRow` is the same row projected out of the daily rollup for
  pricing, which needs a date to resolve an effective-dated entry.
