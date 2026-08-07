# @gotry-io/quota-protocol

Versioned wire contracts shared by QuotaCLI and QuotaRelay. QuotaBar mirrors these contracts with
Swift `Codable` models.

- TypeScript runtime validation lives in `src`.
- `ProviderId` / `ProviderIdSchema` are generated from `packages/provider/src/catalog.ts` into
  `src/provider-ids.generated.ts` via `pnpm generate:provider-catalog`. Do not hand-edit that file.
- Language-neutral, versioned JSON Schemas live in `schema` and are served by Quota Web under
  `/schema/`. Keep JSON Schema provider enums aligned when catalog ids change.
- Canonical schema identifiers use `https://quota.gotry.io/schema/`.
- Wire fields use `snake_case`. Once a schema version is released, it remains backward compatible.
- Quota windows may include optional absolute fields (`remaining_value`, `limit_value`,
  `value_unit`) for credits-class meters; consumers that only understand `used_percent` remain valid.
