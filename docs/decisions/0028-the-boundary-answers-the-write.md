# ADR 0028: The boundary answers the write, and a refusal leaves evidence

- Status: Accepted
- Date: 2026-08-31
- Partially supersedes [ADR 0023](0023-strict-writes-tolerant-reads.md): the sending-side
  restatement of write contracts
- Extends [ADR 0026](0026-isolate-invalid-input-at-the-smallest-scope.md) to the uploads a
  device sends

## Context

[ADR 0023](0023-strict-writes-tolerant-reads.md) had the Rust service check its own snapshot and
Usage envelopes against a restatement of the write contract before uploading. That restatement sits
downstream of the types that produce the payload: every upload is serialized from `QuotaWindow`,
`QuotaAccount`, `QuotaSnapshot`, and `UsageRow` (`packages/service/src/providers/common/types.rs`,
`packages/service/src/usage`), so the restatement can only ever disagree with what this build sends
by being stale.

On 2026-08-31 it was. PR #72 added `primary_cadence` to the protocol schema, the producer types,
and the deployed Relay, but not to the sent-side key allowlist — and every quota upload from every
0.0.33+ device was refused by the device itself. The refusal happened before the request existed,
so it left nothing: no journal row, no failed attempt, no moved `last_seen_at`, for four hours
across two releases, while the diagnose report said everything was healthy. Three guards watched
and none spoke: the conformance fixture carried no case with the new field, the exported-schema
test fed itself a hand-typed payload, and the upload error was discarded as `(false, false, None)`.

The pre-check also cannot do the job it was kept for. It existed so that a payload Relay refuses
would not block the Usage outbox — but the pre-check is a prediction, and the authoritative answer
is Relay's response. Wrong in the lenient direction, a deterministic 400 still blocked the outbox
forever; wrong in the strict direction, the device silently stopped reporting. Both failure modes
existed. The second one fired first.

## Decision

**Shape is stated by the types, once.** The sending side keeps no key allowlist, no key-count
equality, and no enum restatement for payloads its own types produced. What remains before a send
is what a type cannot say: byte and item bounds, `protocol_version`, and value bounds on
provider-fed data — a percentage inside its meter, an instant that parses, a string inside its
length, an hour on its boundary, a bucket named once. Received payloads are unchanged: a reader
tolerates what it cannot name (ADR 0023), and input this device does not control keeps its full
validation.

**A bad reading costs itself, not the report.** A snapshot that fails the remaining value bounds is
dropped alone and counted; the rest of the envelope uploads. A staged Usage batch that Relay
deterministically refuses as invalid is forgotten the way an unrepresentable hour already is, and
the drain carries on; transient failures — network, 5xx, auth, rate limiting, a retired protocol —
keep the queue.

**Every refusal is evidence.** The quota upload earns a journal row (`quota_upload`) exactly as the
Usage drain does: `success` when Relay answered, `partial` with `malformed_data` when something was
dropped or quarantined, `failed` with the mapped code when the send did not land, `no_work` when
there was nothing to send. The diagnose report carries a quota-upload source beside the Usage one.
Nothing on the write path discards an error into `(false, false, None)` again.

**Drift dies in the pull request, not in production.** The exported-schema test uploads what the
producer types maximally state — every optional field set, serialized by the same path production
uses — against the generated `schema/quota-snapshot.json` and `schema/usage.json`, which
`check:schema` keeps derived from the zod definition. A field the types state that the schema does
not fails in CI; a field the schema states that the types do not yet produce is an addition and
travels when the types catch up. The wire-conformance fixture keeps judging what still has two
statements: read contracts across the three runtimes, and Relay's own write schema in TypeScript.
The Rust runtime answers write cases only with "an accepted payload passes its bounds" — it no
longer claims to know what the boundary will refuse.

## What was given up

The device no longer predicts a refusal, so the skew window between a newer client and a
not-yet-deployed Relay shows as recorded 400s until the deployment lands, instead of showing
nothing at all. A quarantined Usage batch is not retried on the user's behalf: only a rescan that
changes the hour re-stages it, and the journal row is what names the loss. And "exactly these keys"
is no longer written anywhere in Rust, so the producer types and the exported schema are the only
two statements left — held together by a test that sends the maximal typed payload, not by
discipline.
