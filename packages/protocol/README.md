# @gotry-io/quota-protocol

Runtime schemas for QuotaBar's Rust local service, managed QuotaRelay, Swift `Codable` models, and
the registered `quota-ios` account client. OAuth and Device control remain released v2; quota,
Usage, and Account summary use managed-data v5. `quota-ios` adds client-specific authorization-code
and account-session payloads on the v2 OAuth contract; the released `quotacli` request and response
shapes are unchanged.

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
  Run `pnpm --filter @gotry-io/quota-protocol generate:schema` after changing a runtime schema.
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
