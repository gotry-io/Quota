# @gotry-io/quota-protocol

The single v2 wire contract shared by QuotaBar's Rust local service, managed QuotaRelay, and Swift `Codable`
models.

- TypeScript runtime validation lives in `src`.
- Managed-network `ProviderId` and local-report `LocalProviderId` are generated from
  `packages/provider/catalog.json` into `src/provider-ids.generated.ts` via
  `pnpm generate:provider-catalog`. Do not hand-edit that file.
- Language-neutral JSON Schemas live in `schema` and are served by Quota Web under `/schema/`.
  Run `pnpm --filter @gotry-io/quota-protocol generate:schema` after changing a runtime schema.
- Canonical schema identifiers use `https://quota.gotry.io/schema/`.
- Wire fields use `snake_case`; objects reject unknown keys. V2 directly relates accounts and
  devices and contains no owner, pairing, Relay discovery, or self-hosted payloads.
- Quota windows may include optional absolute fields (`remaining_value`, `limit_value`,
  `value_unit`) for credits-class meters; consumers that only understand `used_percent` remain valid.
- Pricing schemas and pure calculation code do not contain a canonical price catalog. The managed
  Relay supplies the validated catalog used by clients.
- `fixtures/pricing-conformance.json` is the language-neutral pricing validation, resolution, and
  cost contract read directly by the Rust service and TypeScript quota-model tests.
