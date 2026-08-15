# ADR 0008: Complete local data and unified diagnostics

- Status: Accepted
- Date: 2026-08-11
- Scope: native local service, QuotaBar private IPC, QuotaCLI diagnostics, and managed Usage writes

## Decision

Quota treats provider and agent output as untrusted input, but it must not lose valid data because a
different record, file, provider, or upload boundary is invalid. Every collection path parses and
retains all valid bounded facts, isolates invalid input at the smallest possible scope, and exposes
the resulting state through one bounded diagnostic report.

The service is the only diagnostic authority. It evaluates whether the user-visible Quota and Usage
surfaces can fulfill their current promises, then reports the source checks that explain those
surfaces. QuotaBar and QuotaCLI render or copy the result; they do not inspect SQLite, source logs,
credentials, or reimplement health, data-state, or recovery policy.

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
- A multipart batch is drained within one refresh and remains invisible until complete. The native
  builder validates fact identity uniqueness across the whole batch before staging, so an invalid
  hour stays dirty and visible in diagnostics without blocking later hours. Relay also atomically
  rejects and removes a duplicate-identity batch from an invalid sender after consuming its
  sequence, so one unsupported request cannot block the device stream.
- Partial coverage is explicitly marked and cannot delete remote facts. Its rows are the current
  retained snapshot, not deltas: a present fact identity replaces the older value while identities
  absent from the partial snapshot remain untouched. Complete partitions are authoritative only
  for their exact coverage range. A later complete scan closes the gap and may replace the
  corresponding range.
- Bounded read responses may mark `coverage_truncated`, `breakdowns_truncated`, or
  `unpriced_truncated` when detail lists reach their resource limit. Exact totals remain valid;
  clients preserve them and surface the missing detail as degraded rather than rejecting the whole
  response.

## Diagnostic report contract

The private `diagnose` operation returns a bounded `schema_version: 2` report. Diagnostic v1 shipped,
but its component/setup model could not express source intent or distinguish usable remote data from
missing local credentials. V2 is the replacement contract; the bundled service and Swift client move
together, and QuotaCLI has no separate consumer that requires a v1 compatibility path.

The top-level fields are `schema_version`, `summary`, `refresh`, `generated_at`, `client`, `surfaces`,
`checks`, and `findings`. `client` contains only `name` and `version`. `summary` keeps three independent
axes instead of collapsing them into one severity:

- `operation` is `healthy`, `degraded`, or `blocked`. `blocked` is reserved for a required path that
  cannot operate safely or make progress, such as invalid durable state or a required client upgrade.
  Missing optional setup, login, or local credentials is not blocked.
- `data` is `current`, `stale`, `partial`, `empty`, or `unknown`. Empty is a valid first-run or inactive
  state. Stale and partial describe retained data independently of whether the service can operate.
- `attention` is `none`, `automatic`, `optional`, or `required`. It states who, if anyone, must act;
  authentication or a recovery verb does not by itself make a finding an error.

The four fixed surfaces are `quota_overview`, `usage_this_device`, `usage_account`, and `account`.
Checks explain the collection path behind them and carry `source` (`this_device`, `account`, or
`system`), an optional safe `provider:<id>` or `agent:<id>` subject, `mode` (`inactive`,
`opportunistic`, or `required`), operation/data state, last-attempt and last-success timestamps, and
bounded metrics. Findings carry the same source and safe subject plus one root-cause code, severity,
impact (`none`, `source`, `surface`, or `system`), occurrence count, observation time, recovery code,
and fixed safe message. The report contains at most four surfaces, 128 checks, and 256 findings;
metric values and finding counts are bounded to `0..1,000,000` and `1..1,000,000` respectively.

Diagnostic intent follows product behavior:

- **Show in Overview** is a Swift presentation preference only. It never opts this device into local
  collection and never changes diagnostic mode.
- Account-sourced provider observations can fully satisfy Quota Overview. A local collector without
  explicit configuration is opportunistic, so a local authentication failure may be useful info but
  does not degrade a current Account-backed surface. Explicit saved local configuration makes that
  source required and its failure actionable. No local providers or credentials is healthy/empty.
- Signed-out Account state and disabled Usage upload are inactive/healthy. A closed dirty range or
  outbox entry that is waiting for the next scheduler opportunity is normal automatic work, not a
  failed upload. Only a recorded completed attempt that failed, was rejected, or found an
  unrepresentable partition degrades the required upload check. While uploadable work remains, a
  later `no_work` attempt does not erase that failure; a successful attempt does. With no uploadable
  work left, `no_work` is sufficient evidence that the path is healthy. The still-changing open UTC
  hour is not uploadable pending work.
- Usage findings are emitted once per agent and root parser/access reason. Aggregate
  `scan_partial`/`partial_sources` duplicates are not emitted. A truncated active tail, source change,
  or cancelled scan is transient automatic work; stable malformed input or access failure is an
  actionable partial-data finding while valid records remain available.

The report is evaluated only at a completed refresh boundary. `refresh.as_of` and
`refresh.revision` identify that coherent snapshot, while `refresh.phase`, `started_at`, and
`next_due_at` describe current scheduler state. During a refresh, `diagnose` returns the previous
completed snapshot marked `running`. QuotaBar Recheck requests a real single-flight refresh and waits
for a newer idle revision, or clearly keeps the last completed snapshot marked as still running if it
exceeds the UI wait. The structured attempt journal, Support Report projection, snapshot persistence,
retention, and cross-device Device Health derived from this boundary are defined by
[ADR 0015](0015-diagnostic-attempts-and-device-health.md).

Names, codes, messages, and identities are control-free and bounded. Provider and Usage-agent IDs are
the only retained subject identities. Raw paths, filenames, model names/lists, prompts, completions,
session or conversation IDs, installation or device IDs, credentials, tokens, raw provider responses,
and parser excerpts never cross IPC or appear in text/JSON copies.

QuotaCLI exits zero when operation is healthy, data is current or empty, and attention is not
required. It exits nonzero for blocked/degraded operation, stale/partial/unknown data, or required
attention. Waiting automatic work and healthy empty/inactive installations exit zero.

## Consequences

This keeps recovery local and observable: one bad Codex model marker cannot suppress an entire
history, and one oversized report cannot permanently block the Usage outbox. The service owns
bounded evaluation and redaction, so the CLI and Swift UI remain thin presentation clients. New
capabilities extend the fixed surfaces/checks/findings contract rather than creating a second
diagnostic command or client-side policy. Operational evidence remains the typed bounded journal in
[ADR 0015](0015-diagnostic-attempts-and-device-health.md), not a generic event log.

See [`docs/architecture.md`](../architecture.md) for runtime boundaries and
[`docs/security.md`](../security.md) for retained-data and redaction rules.
