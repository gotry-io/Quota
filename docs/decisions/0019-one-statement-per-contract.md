# ADR 0019: State each contract once

- Status: accepted
- Date: 2026-08-24

## Decision

A wire contract is defined once in `packages/protocol` and restated only where a trust
boundary requires its own check. Four rules keep those restatements from drifting apart, and
keep the contract free of weight nothing reads.

**A field on the wire has a reader.** These carried no product behavior and were validated by
three runtimes each, so they are gone: `AccountQuotaObservation.sequence`, `.captured_at`, and
`.updated_at`; `QuotaSnapshot.source`; and `AccountSummary.generated_at`. Relay keeps the
sequence, capture, and write instants as D1 columns, because that is how it keeps the row, and
projects the observation a reader sees. D1 migration 0013 strips the retired collector name and validity stamp together.

**One concept has one name.** A `BillingAgent` is called `agent` everywhere. The per-agent
groupings that called it `client` — `AccountUsageSummary.agents[]`, the local period summary,
the local Usage report coverage, and the model-catalog alias — now name the enum they carry. The
model catalog is separately versioned, so its rename advances it to `schema_version: 2` rather than
changing a shape a released service still reads: [ADR 0009](0009-versioned-model-catalog.md) keeps
last-known-good on a payload a build cannot read, so an older service degrades to raw model keys
instead of failing.

**One shape has one definition.** Managed and local Usage coverage were the same four fields
under two names with two refinements; they are one schema built with or without the submission
span bound.

**Each contract carries its own version.** `PROTOCOL_VERSION` (control), 
`MANAGED_DATA_PROTOCOL_VERSION` (quota, Usage, Account summary), `LOCAL_USAGE_PROTOCOL_VERSION`
(private local Usage report), `LOCAL_COLLECTION_PROTOCOL_VERSION` (private local collection
report), and `PUBLIC_PROFILE_PROTOCOL_VERSION` (the unauthenticated projection) are named
separately and named once per runtime. The local collection report and the public profile had
been pinned to the control-plane constant, which would have forced them to move whenever it did.

**The restatements answer one judge.** `packages/protocol/fixtures/wire-conformance.json`
states each contract as accepted and refused payloads. The zod schema, the Rust validators in
`packages/service`, and the Swift decoders in `packages/apple-client` and QuotaBar each answer
it.

## Rationale

The wire contract is stated three times by hand: zod defines it, the Rust service checks every
response it receives from Relay, and Swift checks everything that crosses IPC. That redundancy
is deliberate — both products must fail closed on the same input — but until now each could
satisfy its own tests while disagreeing with the others. That is the same shape as the defect
that started this work: one merge rule, five implementations, no shared judge.

A conformance fixture costs one file and makes disagreement a test failure instead of a
production surprise. Removing fields nothing reads removes three hand-written checks each.

## Consequences

- Managed data v4 carries a smaller observation and summary. The contract had not shipped, so
  the removals are part of v4 rather than a further version.
- Adding a field to a contract now means adding cases to the fixture, which is the point: a
  reader that cannot accept the new shape fails in its own test run.
- The fixture covers the three contracts every runtime states. A contract only one runtime
  states — the private local reports — stays covered by that runtime's own tests.
