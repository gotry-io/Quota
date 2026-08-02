# @gotry/quota-protocol

Versioned wire contracts shared by QuotaCLI and QuotaRelay. QuotaBar mirrors these contracts with
Swift `Codable` models.

- TypeScript runtime validation lives in `src`.
- Language-neutral JSON Schemas live in `schema`.
- Published schema identifiers use `https://quota.gotry.io/schema/`.
- Wire fields use `snake_case` and remain backward compatible within a schema version.
