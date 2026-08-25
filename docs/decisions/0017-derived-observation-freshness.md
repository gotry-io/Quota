# ADR 0017: Derive observation freshness from the reading

- Status: accepted
- Date: 2026-08-24

## Decision

How long a quota observation describes current quota is derived from the observation by whoever
reads it. The boundary is the first window reset the reading reports after `observed_at`, its
shortest window cadence when no window reports a reset, and at the latest a fixed maximum age of
24 hours. Every input — `observed_at`, `windows[].resets_at`, `windows[].duration_seconds` — is
already part of the reading.

Collectors no longer stamp `valid_until` onto the snapshots they upload, and the field is not part of
a snapshot: a payload carrying it is refused by the wire schema in every runtime. Stored observations
that carried it are stripped by D1 migration 0013.

The rule is owned once per runtime — `packages/quota-model` for TypeScript, `packages/apple-shared`
for Swift, `packages/service`'s `observation` module for Rust — and all three answer the shared
cases in `packages/protocol/fixtures/quota-observation-conformance.json`.

## Rationale

A stamp is a fact about the reading that only its collector could state, which makes every reader
depend on a producer having stated it. Readings uploaded before the field existed carry no stamp, so
readers that treated an absent stamp as "no expiry" presented two-day-old counters as current
indefinitely, and no client update could repair readings a device had already uploaded. Deriving the
boundary makes the age of a reading a property of the reading: it holds for observations uploaded by
any device, of any age, running any client version.

Derivation cannot disagree with the stamp it replaces, because it is the same computation over the
same frozen inputs. It also removes a way for a collector to be wrong, since a collector that forgets
to stamp is no longer expressible.

The maximum age stays a consumer-side constant rather than wire data for the same reason: a reader
that receives a longer claimed lifetime from a device cannot verify it.

## Consequences

- Observations uploaded before this decision expire on the same terms as new ones, without rewriting
  stored rows.
- A device that stops collecting stops speaking for an account within the maximum age everywhere,
  without depending on that device updating to a client version that republishes its failures.
- Republishing a failed source is bounded by the same rule: only a reading that is still current is
  restated, and a restatement is not `available` and so is not current.
- A device released before this decision cannot upload quota until it updates, because its envelope
  carries a field the snapshot schema does not define. Each runtime covers that refusal with a test.
