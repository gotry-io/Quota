# ADR 0019: State each contract once

- Status: Accepted
- Date: 2026-08-24
- Updated 2026-08-25 by [ADR 0023](./0023-strict-writes-tolerant-reads.md), inline below

## Decision

A wire contract is defined once in `packages/protocol` and restated only where a trust boundary
requires its own check. Four rules keep those restatements from drifting apart, and keep the contract
free of weight nothing reads.

**A field on the wire has a reader.** These carried no product behaviour and were validated by three
runtimes each, so they are gone: `AccountQuotaObservation.sequence`, `.captured_at`, and
`.updated_at`; `QuotaSnapshot.source`; and `AccountSummary.generated_at`. Relay keeps the capture and
write instants as D1 columns, because that is how it keeps the row, and projects the observation a
reader sees.

**One concept has one name.** A `BillingAgent` is called `agent` everywhere. The per-agent groupings
that called it `client` now name the enum they carry. The model catalog is separately versioned, so
its rename advances it to `schema_version: 2` rather than changing a shape a released service still
reads: [ADR 0009](./0009-versioned-model-catalog.md) keeps last-known-good on a payload a build
cannot read, so an older service degrades to raw model keys instead of failing.

**One shape has one definition.** Where managed and local sides described the same four fields under
two names with two refinements, they became one schema built with or without the tighter bound.

**Each contract carries its own version.** `PROTOCOL_VERSION` for the control plane and
`MANAGED_DATA_PROTOCOL_VERSION` for quota, Usage, and Account summary are named separately and named
once per runtime. There is no third: the private local Usage and collection reports travel nested
inside an IPC state that already carries `ipc_version`, and both ends of that pipe ship in one build,
so `LOCAL_USAGE_PROTOCOL_VERSION` and `LOCAL_COLLECTION_PROTOCOL_VERSION` were numbers nobody could
disagree about and are gone.

**The restatements answer one judge.** `packages/protocol/fixtures/wire-conformance.json` states each
contract as accepted and refused payloads, and the zod schema, the Rust validators in
`packages/service`, and the Swift decoders in `packages/apple-client` and QuotaBar each answer it.
[ADR 0023](./0023-strict-writes-tolerant-reads.md) changed what a restatement may refuse — a write is
checked against exactly the contract, a read takes what it names and ignores the rest — so the
fixture answers each contract from the side it is on.

## Rationale

The wire contract is stated three times by hand: zod defines it, the Rust service checks every
response it receives from Relay, and Swift checks everything that crosses IPC. That redundancy is
deliberate — both products must fail closed on the same input — but until now each could satisfy its
own tests while disagreeing with the others. That is the same shape as the defect that started this
work: one merge rule, five implementations, no shared judge. A conformance fixture costs one file and
turns disagreement into a test failure instead of a production surprise, and removing a field nothing
reads removes three hand-written checks.

## Consequences

- Adding a field to a contract means adding cases to the fixture, which is the point: a reader that
  cannot accept the new shape fails in its own test run.
- The fixture covers the three contracts every runtime states. A contract only one runtime states —
  the private local reports — stays covered by that runtime's own tests.
