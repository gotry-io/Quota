# @gotry-io/quota-protocol

Versioned wire contracts shared by QuotaCLI and QuotaRelay. QuotaBar mirrors these contracts with
Swift `Codable` models.

- TypeScript runtime validation lives in `src`.
- Language-neutral, versioned JSON Schemas live in `schema` and are served by Quota Web under
  `/schema/`.
- Canonical schema identifiers use `https://quota.gotry.io/schema/`.
- Wire fields use `snake_case`. Once a schema version is released, it remains backward compatible.
