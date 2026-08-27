# ADR 0026: Isolate invalid input at the smallest scope

- Status: Accepted
- Date: 2026-08-26
- Re-homes the data-integrity half of ADR 0008, which ADR 0022 superseded for diagnostics only.

## Decision

Provider responses and agent logs are untrusted input, and a fault in one of them never costs the
data around it:

- A malformed record is dropped alone; the file it sits in keeps indexing.
- An unreadable or malformed file is skipped alone; the agent's other files keep indexing and
  uploading. The hour it touched is marked `partial`, and stays so until a complete scan of that
  file succeeds.
- A provider that fails does not discard another provider's reading.
- A model identifier is opaque provider text. It is kept as received, punctuation included, and a
  missing price never discards a fact — the fact is reported unpriced.
- A record with no tokens, billable tools, or source cost is not a fact; it is counted, not stored.

An hour is the unit that travels: a device replaces an hour by scan version (ADR 0024), so a
correction to one record reaches Relay as one hour, not as a stream that must be replayed.

## Rationale

One bad Codex model marker used to suppress an entire history. Scoping every fault to the smallest
thing that carries it keeps the display honest — `partial` names exactly what was missed — without
making a whole agent, provider, or upload wait on one line.

## What was given up

Nothing is retried on the user's behalf. A stably malformed file stays `partial` and is named in
the Support page; only a fixed file or a parser change clears it.
