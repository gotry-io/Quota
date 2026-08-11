# ADR 0008: Complete local data and unified diagnostics

- Status: Accepted
- Date: 2026-08-11
- Scope: native local service, QuotaBar private IPC, QuotaCLI diagnostics, and managed Usage writes

## Decision

Quota treats provider and agent output as untrusted input, but it must not lose valid data because a
different record, file, provider, or upload boundary is invalid. Every collection path parses and
retains all valid bounded facts, isolates invalid input at the smallest possible scope, and exposes
the resulting state through one bounded diagnostic report.

The service is the only diagnostic authority. It reports the same capabilities to QuotaBar and
QuotaCLI: providers and quota collection, Usage parsing and coverage, pricing, account state, and
upload/synchronization. Clients render or copy this report; they do not inspect SQLite, source logs,
credentials, or reimplement health rules.

## Data and upload rules

- Model identifiers are opaque provider text. The service preserves non-empty bounded identifiers
  as received, including punctuation such as `[]`, and does not require a catalog price to retain a
  Usage fact. Only unsafe control text and resource bounds are rejected.
- A zero-value internal record with no tokens, billable tool calls, or source cost is ignored and is
  counted in diagnostics; it is not a Usage fact.
- A malformed record is isolated to that record. An unreadable or malformed file is isolated to
  that file, while valid files for the same agent continue to index and upload. A provider failure
  does not discard another provider's successful quota result.
- Upload builders partition complete data on the smallest complete time unit required by the
  replacement contract and by request byte/row bounds. Partitioning is lossless and deterministic;
  it never drops rows or models to fit a limit. A partition that cannot be represented remains
  pending with a diagnostic issue instead of being silently discarded.
- A multipart batch is drained within one refresh and remains invisible until complete. If its
  parts contain duplicate fact identities, Relay atomically rejects and removes only that staged
  batch after consuming its sequence; the client records a degraded diagnostic and continues with
  later uploads instead of retrying the same invalid part forever.
- Partial coverage is explicitly marked and cannot replace or delete remote facts. Complete
  partitions are authoritative only for their exact coverage range. A later complete scan closes
  the gap and may replace the corresponding range.
- Bounded read responses may mark `coverage_truncated`, `breakdowns_truncated`, or
  `unpriced_truncated` when detail lists reach their resource limit. Exact totals remain valid;
  clients preserve them and surface the missing detail as degraded rather than rejecting the whole
  response.

## Diagnostic report contract

The private `diagnose` operation returns a bounded `schema_version: 1` report. Its top-level fields
are `schema_version`, `status` (`healthy`, `degraded`, or `blocked`), `generated_at`, `client`,
`components`, and `issues`; `client` has only `name` and `version`. `components` is an array with one
entry for each fixed capability name: `providers`, `quota`, `usage`, `pricing`, `account`, and `sync`.
Each component has `name`, `status` (`ready`, `degraded`, or `blocked`), an optional safe `message`,
and bounded integer `metrics` whose values are `0..1,000,000`. Issues contain only a fixed component,
stable code, severity, count (`1..1,000,000`), and safe message. Names, statuses, codes, and messages
are control-free and bounded. Raw paths, filenames, model lists, prompts, completions, session IDs,
credentials, tokens, device IDs, and unredacted provider output never cross IPC or appear in a copied
report.

`healthy` means no component is degraded or blocked. `degraded` means valid data remains available
but a bounded subset was skipped, stale, partial, unpriced, or awaiting retry. `blocked` means the
capability cannot make progress without a repair such as login, configuration, upgrade, or retry.
QuotaCLI exits zero only for `healthy`; `degraded` and `blocked` have stable nonzero exits.

## Consequences

This keeps recovery local and observable: one bad Codex model marker cannot suppress an entire
history, and one oversized report cannot permanently block the Usage outbox. The service owns
bounded counters and redaction, so the CLI and Swift UI remain thin presentation clients. New
capabilities must add a fixed component and safe metrics to the shared report rather than creating a
second diagnostic command or report cache.

See [`docs/architecture.md`](../architecture.md) for runtime boundaries and
[`docs/security.md`](../security.md) for retained-data and redaction rules.
