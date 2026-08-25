# @gotry-io/quota-protocol

Runtime schemas for QuotaBar's Rust local service, managed QuotaRelay, Swift `Codable` models, and
the registered `quota-ios` account client. OAuth and Device control remain released v2; quota,
Usage, and Account summary use managed-data v5. `quota-ios` adds client-specific authorization-code
and account-session payloads on the v2 OAuth contract; the released `quotacli` request and response
shapes are unchanged.

Managed-data v3's default Account summary Device shape shipped and remains unchanged. Device Health
uses `PUT /api/v5/device/health` for authenticated self-owned writes and the explicit
`GET /api/v5/account/summary` read shape, where `health` is required but nullable.
Runtime schemas and exported JSON Schema keep those default/opt-in shapes distinct.

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
