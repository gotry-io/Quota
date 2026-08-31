# ADR 0023: Strict writes, tolerant reads

- Status: Accepted
- Date: 2026-08-25
- Partially supersedes [ADR 0018](0018-single-managed-data-contract.md)
- Partially superseded by [ADR 0028](0028-the-boundary-answers-the-write.md) on 2026-08-31: the
  sending-side restatement of write contracts

## Context

[ADR 0019](0019-one-statement-per-contract.md) had each runtime restate the wire contract for its
own trust boundary, and every restatement rejected a key it could not name. That is right for a
payload arriving at Relay and wrong for a payload leaving it: a client is not upgraded at the same
instant as the Worker it reads, so one added field would have failed every Account read on every
device already installed. [ADR 0018](0018-single-managed-data-contract.md) answered that with a
version bump and an in-app updater, which is a large hammer for a new field nobody has to read.
A closed enum did the same thing more quietly — a `moonshot` inference provider once failed every
account read — and each time the whole response was discarded over one value.

## Decision

**A write is checked against exactly the contract.** Relay parses every request body with a schema
that rejects an unnamed key, and answers 400. The Rust service checked its own snapshot and Usage
envelopes the same way before uploading, until that restatement went stale and refused this
device's own payload; [ADR 0028](0028-the-boundary-answers-the-write.md) withdrew it, keeping only
the bounds a type cannot state. IPC request payloads stay `deny_unknown_fields`.

**A read takes what it names and ignores the rest.** Every schema, validator, and decoder that
reads a Relay response accepts fields it cannot name, at any depth. `packages/protocol` states each
read contract once as the strict producer schema Relay answers with, and derives the reader from it;
the Rust validators check required fields and invariants only; `QuotaWire` no longer rejects unknown
keys, and its strict-decoding helper moved to QuotaBar, which needs it for IPC.

**An enum member a build has not heard of is text, not a failure.** A provider, agent, channel, or
status outside a reader's set reads as `unknown` and keeps the raw text where a person sees it —
`ProviderID` carries it, the rest read as `unknown`. A verdict the payload derives from its own
numbers — the cost basis and status — stays closed, because a value outside that set contradicts the
payload rather than extending it.

**IPC is not a version boundary.** The local service and QuotaBar ship in one build and speak one
`ipc_version`, so a key neither side stated is a defect in one of them. IPC stays strict both ways.

`packages/protocol/fixtures/wire-conformance.json` answers writes with the schema that guards them
and reads with the schema a client reads with, so the three runtimes cannot drift apart on either.

## What was given up

Relay can now add a field to a read without any client noticing, which means nothing forces a client
to catch up. A shape change still needs a version bump; only additions travel for free.

A reader no longer proves that a retired field is gone. `valid_until`, `sequence`, and `health` are
ignored rather than refused, and only the producer schema still says they are not in the contract.
