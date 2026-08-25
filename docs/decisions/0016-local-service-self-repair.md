# ADR 0016: Local service self-repair

> Status: Superseded by [ADR 0021](./0021-identity-store-and-disposable-cache.md) on 2026-08-25.

- Status: Accepted
- Date: 2026-08-17

## Context

The local service already recovers leftover `refreshing` flags, isolated Usage records, last-good
component values, logout-pending retry, outbox drain, and provider-owned credential refresh. Those
paths were added as separate reactions. A damaged owner-only `state.sqlite` can remain readable for
the last completed diagnostic snapshot while later writes fail. After QuotaBar's fifteen-second
helper recycle, process-local flags are gone, so `diagnose` can again report that last healthy
snapshot. Open-time walks of a hundreds-of-megabyte Usage index or a live `PRAGMA quick_check` can
exceed that same deadline and restart the helper before repair finishes.

[ADR 0008](0008-data-integrity-and-diagnostics.md) remains the diagnostic v2 contract: surfaces,
checks, findings, and isolate-smallest-scope. [ADR 0015](0015-diagnostic-attempts-and-device-health.md)
remains the attempt journal, Support Report projection, and Device Health upload contract. This ADR
owns repair classification, when the loop runs, persist-probe honesty, snapshot trust, salvage copy
policy, required-copy verification, the Open-time fifteen-second bound, fail-closed behavior, the
repair session wire, QuotaBar presentation, and liveness detection.

## Decision

The local service owns one control plane: detect, classify, repair, record, then re-evaluate
diagnostics. QuotaBar and QuotaCLI present the session; they do not inspect SQLite or choose salvage.
There is no user-started repair command, Settings **Repair** button, or `quotacli doctor --repair`.

`get_state` stays a cheap snapshot read. Long work never runs on the helper main thread or inside
`get_state` / `diagnose`. The fifteen-second Swift deadline recycles the helper process; it is not a
classification input.

### Classes and dispositions

`run_repair` executes only four classes. The other four names are catalog exclusions so a later
change does not salvage a 401 or an unreadable `providers.json`.

- **DurableImage** — durable-table or persist-probe `sqlite_durable_corruption`, or
  `quick_check ≠ ok` on a **new** salvage image. Automatic once per site invocation. FailClosed if
  this replacement cannot keep identity. A later corruption of a previously good salvaged image may
  salvage again.
- **ProcessResidue** — running attempt rows, or `refreshing = 1` with no active refresh. Automatic
  on Open via the existing interrupted-attempt recovery, plus clearing leftover `refreshing` flags.
- **StaleHealthEvidence** — persist probe failed, `snapshot_untrusted=1`, snapshot
  `completed_at < state_salvaged_at`, or `usage_reindex_pending`. Automatic: refuse
  `TrustedSnapshot`.
- **DerivedState** — persist probe **passes** and the error is isolated to rebuildable Usage index
  tables. Automatic only on RefreshWorker and WriteFailure. One-transaction drop and recreate of
  the current index schema; do not park the live image.
- **ScheduledProgress** — logout-pending, outbox rows, dirty hours excluding the open UTC hour. Not
  repair; existing single-flight and epoch rules stay in place.
- **UserAction** — `AuthenticationRequired`, `ConfigureProvider`, `Upgrade`, `Reinstall`, or
  unreadable `providers.json`. Existing `recovery_action` only.
- **TransientExternal** — network errors, provider 5xx, Relay unavailable. Existing retry schedule.
- **UntrustedInput** — malformed Usage records/files or provider JSON. Isolate at smallest scope
  ([ADR 0008](0008-data-integrity-and-diagnostics.md)); never treat a corrupt SQLite page as a bad
  Usage record.

One policy per class. Do not salvage on a 401. Do not ask the user to reinstall because a provider
token expired. Do not park the live image because Usage index tables are unreadable while metadata
still writes.

`sqlite_durable_corruption` is `DatabaseCorrupt`, `NotADatabase`, and allowlisted message substrings
(`corrupt`, `malformed`, `database disk image`, `file is not a database`). It is not
`SystemIoFailure`, `CannotOpen`, or `SQLITE_FULL`. Those are `sqlite_io_or_full`:
`Unavailable`+`Retry` without copying a second image onto a disk that may already be full, and
without Reinstall (reinstall does not free a disk).

When several executable signals coexist, `run_repair` runs that site's ordered actions and skips
actions whose precondition is false. It does not pick one class and return.

### Sites

| Site | Trigger | Bound |
| --- | --- | --- |
| **Open** | Helper start, QuotaCLI command, Swift fifteen-second recycle | Persist probe and small-table reads. No live `quick_check`. No Usage `COUNT(*)` or copy. Crash-safe resume or durable-only salvage only. |
| **RefreshStart** | `request_refresh` before spawn, including Startup | Persist probe; at most one durable-only salvage. No Usage walk. No `DROP`. Do not write a diagnostic snapshot. |
| **RefreshWorker** | Start of `run_refresh` after spawn | DerivedState drop/recreate if a pending isolated-index flag is set. |
| **WriteFailure** | After `note_persistence_failure` on the refresh thread | Classify the noted error. Isolated Usage plus a passing persist probe drops the index; durable corruption salvages once; IO/full is Retry with no copy. Set pending and return from `run_refresh`. |
| **DiagnoseRead** | `diagnose` / complete-report read | Persist probe and metadata flags. No salvage. No Usage walk. |
| **PostRefresh** | After a **completed** (not aborted) refresh | Usage reads allowed. Persist the new snapshot; retry that write once after `run_repair(WriteFailure)`. `wal_checkpoint(RESTART)` and refresh `state.sqlite.good`. |

Never salvage or `quick_check` from `get_state`. After recycle, the next `get_state` is a new helper
whose Open sits on that request's fifteen-second timer.

#### Open-time fifteen-second bound

Helper Open runs before `run_stdio`. If it is still copying or checking a large image, the helper is
killed and the next launch repeats.

1. Do not run `PRAGMA quick_check` on the existing live image.
2. Do not `COUNT(*)` or copy `usage_file_index` / `usage_file_records`.
3. Detect "cannot persist" with a metadata heartbeat write (one `INSERT ... ON CONFLICT`).
4. Salvage copies only the durable-small table list. Expected well under one second and must stay
   well under fifteen.
5. After a successful promote, `PRAGMA quick_check` on the **new small** image is allowed.
6. If bounded Open work cannot finish, return `Unavailable`+`Retry` rather than walking Usage or
   `quick_check`ing the large live file.
7. Opening or `ATTACH`ing `state.sqlite.broken` must not set `journal_mode=WAL` on the parked file.
   Use a read-only / `query_only` open. Resume and required-copy verification `SELECT` only
   `installation`, `session`, and the other small required tables. If that cannot finish in budget,
   return `Unavailable`+`Retry`.

#### Per-site ordered actions

- **Open:** delete incomplete `state.sqlite.salvage`; resume interrupted salvage when live is
  missing, 0-byte, not a SQLite header, or a freshly initialized schema with no copied
  `installation` **and** `.broken` exists — decided **before** creating an empty live file; persist
  probe; incomplete replacement (live has `state_salvaged_at` but is missing `installation`/`session`
  that `.broken` still has) → FailClosed **without parking**; else durable corruption with required
  identity rows present → one `SalvageDurableImage`; IO/full → `Unavailable`+`Retry`, no copy;
  finalize interrupted attempts and clear leftover `refreshing` flags; if salvage or resume ran,
  invalidate the diagnostic snapshot and mark Usage reindex pending; persist probe plus small-table
  probe on the promoted image (`sqlite_durable_corruption` → `InvalidState`; IO/full →
  `Unavailable`).
- **RefreshStart:** persist probe; one durable-only salvage if needed; if Usage-isolated corruption
  is already flagged, set `derived_drop_pending=1` only — do not `DROP`; IO/full rejects the refresh
  with `Unavailable`+`Retry`.
- **RefreshWorker:** if `derived_drop_pending` or a Usage-isolated error was noted, discard the
  unreadable derived index and mark reindex pending in one transaction, then clear the pending flag.
- **WriteFailure:** classify; Usage-isolated plus passing persist probe → discard index and mark
  reindex, do not park; DurableImage → one salvage with the same incomplete-replacement split as
  Open; IO/full → Retry, no copy; set refresh pending and return.
- **DiagnoseRead:** persist probe via try-lock (contention with `DROP` → PersistRetry, no snapshot);
  durable corruption → FailClosed, no snapshot, no salvage; IO/full or any other probe error →
  PersistRetry, no snapshot, no salvage; probe ok → TrustedSnapshot or EvaluateLive from flags.
  Force Usage `partial` only when reindex, untrusted, or salvage flags are set. Never read Usage
  index tables.
- **PostRefresh:** only if the refresh was not aborted. Evaluate (Usage reads allowed on this worker
  path) and write the snapshot; on failure, note the persistence failure, run WriteFailure once, and
  retry the snapshot write once.

### Persist-probe honesty

DiagnoseRead always runs a metadata persist probe:

`INSERT INTO metadata(key,value) VALUES ('diagnostics_persist_probe', now) ON CONFLICT(key) DO UPDATE SET value = excluded.value`

A last-completed snapshot is not proof that the image can still be written. Process-local
`image_unwritable` does not survive helper recycle. DiagnoseRead and Open therefore prove the write
path with this heartbeat. They do not walk Usage trees and do not rely on a process-local flag.

`health_evidence_trust` classifies the probe. It does not map every error to FailClosed.

| Probe result | Trust | Diagnose result | Salvage? | Last snapshot? |
| --- | --- | --- | --- | --- |
| `Ok` | TrustedSnapshot or EvaluateLive from flags | Snapshot or EvaluateLive | No | Only if TrustedSnapshot |
| `sqlite_durable_corruption` | FailClosed | Complete FailClosed v2 (`invalid_state` / `reinstall`) | No | No |
| `sqlite_io_or_full` | PersistRetry | `Unavailable`+`Retry` | No | No |
| Any other store error (busy, poisoned mutex, JSON) | PersistRetry | `Unavailable`+`Retry` | No | No |

On persist-probe failure, set process-local `image_unwritable`. If a metadata write can still land,
persist `snapshot_untrusted=1`. Do not salvage on DiagnoseRead. Do not return the last healthy
snapshot unless `persist_probe` returned `Ok`.

A TrustedSnapshot still follows [ADR 0008](0008-data-integrity-and-diagnostics.md): overlay
`generated_at`, `client`, and `recent_activity`, and mark `running` while a refresh is in flight.
EvaluateLive is the honesty path when the snapshot is untrusted. It does not persist a new snapshot.
A snapshot is written only on PostRefresh after a completed refresh, never because DiagnoseRead
found the row missing after a repair.

**DiagnoseRead never walks Usage trees.** Missing snapshot plus clear flags is first-run **empty**,
not salvage **partial**. Forcing `partial` on first install would contradict ADR 0008 (empty is
valid), `quotacli doctor` (nonzero on `partial`), and Device Health (fresh `partial` is **Needs
attention**).

Usage surface on DiagnoseRead EvaluateLive:

- `usage_reindex_pending=1`, `snapshot_untrusted=1`, or `state_salvaged_at` with no completed
  post-salvage `usage_scan` → `usage_this_device.data = partial`, `attention ≥ automatic`. No walk.
- Snapshot row absent and those flags clear → `empty` if there is no last-good Usage component or
  period cache; otherwise last-good with its existing current/stale age. Infer empty from absent
  last-good, never from `COUNT(*)=0`.
- When the walk is skipped, check metrics `files` and `records` are `0`.

`usage_reindex_pending` clears when a `usage_scan` attempt completes with `success` or `partial` (a
real scan). `cancelled` / `interrupted` leave the flag set.

The FailClosed payload is a complete diagnostic v2 report: `schema_version == 2`, the four required
surfaces, finding code **`invalid_state`** (not `local_state_invalid`), recovery `reinstall`, and no
paths. Device Health upload of that report, only if a later write becomes possible, uses existing
`top_code = local_state_invalid`. If the journal is readable, `recent_activity` may be the real
projection; otherwise it is empty. Never return the last healthy snapshot in this state.

Keep the 24-hour `local_state` check and `state_repaired` Info finding for Support Report and
Settings copy. **Exclude `state_repaired` from summary.attention aggregation** so a rebuilt device
is **Healthy** rather than **Check device** for 24 hours.

`complete_diagnostics` writes the live evaluation only on successful PostRefresh when trust is not
FailClosed or PersistRetry. If that write fails: note the persistence failure, run WriteFailure
once, retry the write once, and on second failure leave `snapshot_untrusted=1` while still returning
the live report to the in-process caller. Device Health upload uses **this** report, not a discarded
healthy snapshot. Do not publish Device Health for an aborted refresh.

### Durable-image salvage

The DurableImage executor parks the live image as owner-only `state.sqlite.broken`, builds
`state.sqlite.salvage`, promotes, and restores on failure. The coordinator decides when and what
must be true afterwards.

#### Crash-safe open

First install is only: no live (or empty live) **and** no `.broken`. Only then may migration mint
an installation id.

1. Acquire the owner lock.
2. Delete incomplete `state.sqlite.salvage` and its `-wal`/`-shm`.
3. Stat the live path **before** SQLite init. Do not create an empty live file first.
4. Classify:
   - Missing, 0 bytes, or not a SQLite header, **and** `.broken` exists → resume interrupted
     salvage. Do not create an empty live file first.
   - Openable live whose `installation_id` is missing or differs from `.broken`, and live has no
     `state_salvaged_at` → also resume (create+migrate raced; this is not a first install).
   - Live has `state_salvaged_at` **and** is missing `installation` and/or `session` that `.broken`
     still has → **FailClosed without parking**. The next process must not park an empty salvage
     over the only good `.broken`.
   - Live has `state_salvaged_at`, required identity rows are present, persist/small-table is
     durable corruption → salvage again. Automatic salvage is not a one-shot.
   - Openable live, no marker, durable corruption → park and replace.
   - Persist probe succeeds and identity matches → normal open; no live `quick_check`.
5. IO/full on Open → `Unavailable`+`Retry` only. No copy. Not Reinstall.
6. Then ProcessResidue, then persist plus small-table probe on the resulting live image.

`state_salvaged_at` means a salvage happened. It does not forbid a later salvage. One
`SalvageDurableImage` per Open / WriteFailure / RefreshStart **call**. A second durable-corruption
error in that same call is FailClosed. Failed promote always restores the parked live image before
returning. Automatic DurableImage salvage is capped at **one per UTC day**; a second Automatic
detect becomes stuck/`retry` instead of looping overnight.

Salvage requires free space ≥ `2 × live_size + 64 MiB`. IO/FULL never copies a second image.

#### Required-copy verification

Before promote, open `.broken` read-only. Never set WAL on the parked file. Never checkpoint it.
`SELECT` only `installation.installation_id` and, if that table has a row, `session` existence. Do
not read Usage index tables.

- If `.broken` has `installation.installation_id`, the salvage image must have the **same** id. If
  the copy failed or migration minted a different UUID, restore and return `InvalidState`.
- If `.broken` had a `session` row, the salvage image must have a `session` row. Copy or fail
  closed; never mint.
- Required if present on `.broken`, copy-all-or-fail: `installation`, `session`,
  `usage_upload_context`, `usage_outbox` (a partial outbox can double-count or drop), `components`,
  `metadata` (minus keys below), and `provider_browser_sessions`. An absent table on a garbage
  `.broken` is not an error.

#### Copy policy

The Usage file index is rebuildable from local logs. Copying it is both the latency risk and the
wrong dependency.

**Required:** `installation`; `session` if `.broken` has a row; `metadata` with the exceptions
below; `components`, `provider_browser_sessions`, `usage_upload_context`, and `usage_outbox` if
present.

**Best-effort:** `model_catalog_cache`, `diagnostic_attempts`, `usage_period_cache` (at most eight
rows).

**Never copy:** `usage_file_index`, `usage_file_records`, `usage_dirty_ranges`,
`usage_partial_sources`, `usage_scan_diagnostics`, `sync_diagnostics`, `diagnostic_snapshot`,
`legacy_artifacts`.

Metadata keys not copied, or overwritten after copy: `state_salvaged_at` (written fresh),
`snapshot_untrusted` (set to `1` until a successful snapshot write), `usage_reindex_pending` (set to
`1` until a completed real `usage_scan`), `diagnostics_persist_probe` (rewritten by the next probe),
`overview_json` (rebuilt on the next completed refresh).

After a successful promote: persist probe plus small-table reads on `installation`, `session`,
`metadata`, and `components` only; clear leftover `refreshing` flags; set `state_salvaged_at`,
`usage_reindex_pending=1`, and `snapshot_untrusted=1`; clear `image_unwritable`. Do not clear
last-good component values. Last-good is not proof that the image can still be written.

#### Last-known-good image and WAL checkpoint

After a **successful** completed refresh, persist probe, and `wal_checkpoint(RESTART)` on the live
file, write one owner-only `state.sqlite.good` via SQLite Backup / `VACUUM INTO` of the same
durable-small tables as salvage (never the Usage index). Mode `0600`. Replace atomically. One
generation; no dated stack.

Writing `.good` is best-effort and must not fail the refresh. If `free < 2 × live_size + 64 MiB`,
skip it. `.good` is never uploaded. Diagnostics never include its path.

FailClosed tries `RestoreLastGoodSnapshot` from `.good` **before** Reinstall, then marks reindex. If
`.good` is missing or also corrupt → Reinstall. Salvage still prefers the just-parked `.broken` for
identity copy. `.good` is the second parachute when that copy cannot promote.

Bounds: at most one `state.sqlite.broken` and one `state.sqlite.good`. No recovered SQL dump, no
`.recover` file, no extra `state.sqlite.bak`. Never a path in IPC or diagnostics. Never uploaded.

### DerivedState

When the persist probe succeeds and the failing statement is isolated to rebuildable Usage tables,
and the caller is RefreshWorker or WriteFailure (never RefreshStart, Startup's synchronous path,
DiagnoseRead, or Open):

Drop and recreate the current Usage index tables in one transaction (`usage_file_index`,
`usage_file_records`, `usage_dirty_ranges`, `usage_partial_sources`, matching the current schema
including `record_key` and time indexes). Delete leftover `usage_scan_diagnostics` and
`sync_diagnostics`. Do not re-run migrations v1–v8. Set `usage_reindex_pending=1` and
`snapshot_untrusted=1`. Do not park live. Do not touch `session`, `installation`, or the outbox.

**Keep last-good Usage display during reindex and mark it partial.** `get_state` continues to show
last-good Usage component values and any copied period cache. Diagnose and Device Health report
`usage_this_device.data = partial` until a completed real scan. Do not clear last-good to invent
emptiness, and do not walk the index to prove emptiness.

`DROP` of a large `usage_file_records` tree runs only on the refresh worker after the accepting IPC
has returned. Helper request-thread methods that can run during that work (`get_state`, persist
probe, diagnostic snapshot read) use try-lock or a short wait. On contention they return
`Unavailable`+`Retry`. DiagnoseRead maps that to PersistRetry. They do not fall through to the last
healthy snapshot and do not block across the `DROP`.

If the persist probe itself is `sqlite_durable_corruption`, the image is DurableImage, not
DerivedState.

### Repair session, presentation, and liveness

The user-visible flow is cheap first paint, async detect, a presented repair session if Automatic
work starts, live phase/progress, self-stuck detection, then completed or fail-closed. The service
starts repair. Swift only renders it.

`get_state` gains a required `repair` object (bundled IPC v1; QuotaBar and the helper ship
together). State-change events may list `repair` in `changed_components`. Swift decodes the object
strictly. There is no new event type: emit `state_changed` with `repair` on session create, phase
change, every heartbeat (2 s), stuck, failed, and completed.

```json
{
  "status": "repairing",
  "severity": "derived",
  "phase": "reindexing_usage",
  "title": "Rebuilding Usage history",
  "guidance": "Quota and Account stay available. Usage history is catching up.",
  "activity": "Scanning local logs",
  "started_at": "2026-08-17T01:00:00Z",
  "heartbeat_at": "2026-08-17T01:00:14Z",
  "progress_current": 12,
  "progress_total": 40,
  "stuck": false,
  "blocks_quit": false,
  "recovery_action": null
}
```

- `status`: `idle` | `checking` | `repairing` | `stuck` | `failed` | `completed`.
- `severity`: `none` | `derived` | `durable`. Service-owned and required. Swift does not infer it
  from `phase`. A session that starts as `derived` and later needs DurableImage upgrades to the
  full page; it never downgrades mid-flight.
- `phase`: `preserving_account` | `rebuilding_storage` | `reindexing_usage` | `verifying` |
  `restoring_last_good`, or null when idle.
- `title` ≤ 64 and `guidance` ≤ 160 are service-owned and control-free. Durable guidance: **Keep
  QuotaBar open. You can close this menu.** Derived guidance: **Quota and Account stay available.
  Usage history is catching up.** Never paths, table names, SQL, or ids.
- `activity` ≤ 64 or null is the last honest step. It updates even when a bar cannot.
- `started_at` / `heartbeat_at` are RFC3339 and required while not idle.
- `progress_current` / `progress_total` are both null, or `0 ≤ current ≤ total` and
  `1 ≤ total ≤ 1_000_000`. Set only when the denominator is known and stable. **Never invent a
  percent.**
- `stuck` is the service watchdog decision.
- `blocks_quit` is `true` only while `severity = durable` and `status = repairing`.
- `recovery_action` is `retry` | `reinstall` | null, and only when `stuck` or `failed`.

Persist the session in `metadata` as `repair_session_json` (bounded ≤ 4 KiB) so a quit mid-repair
resumes the same page. Heartbeats update `heartbeat_at` and a monotone `seq` in that blob and bump
`revision` so Swift reloads. `checking` lasts at most two seconds and does not open the Repair
page. The page appears when `status ∈ {repairing, stuck, failed}` or for a 1.5 s success flash when
`completed`.

**`severity = durable`** takes a full Repair page and intercepts ordinary Quit.
**`severity = derived`** keeps Overview and Usage, shows one inline notice, and does not intercept
Quit. Visual tokens stay in [`apps/menubar/DESIGN.md`](../../apps/menubar/DESIGN.md). Closing the
menu extra never cancels repair. Sparkle is suppressed only while `blocks_quit`. Logout and
provider writes return `Busy` only for `severity = durable`. Force Quit cannot be blocked; the next
Open resumes from `.broken` / `repair_session_json`. Launch at Login stays on so a reboot resumes a
durable session. Do not daemonize. The fifteen-second request watchdog must not fire on the repair
worker.

Progress honesty: `preserving_account` is determinate (N of required tables copied).
`rebuilding_storage` and `restoring_last_good` are not. `reindexing_usage` is determinate after
discovery (files completed / files discovered, display capped at 1_000_000). `verifying` is the
persist probe 0/1 then 1/1. Always show `activity` and elapsed.

QuotaCLI has no page. `quotacli doctor` / `status` print `repair.status`, `phase`, `title`, elapsed,
and stuck. Exit nonzero while `repairing` / `stuck` / `failed`. No `--repair` flag.

#### Watchdog

Two independent watchers. The service is authoritative. The 2 s `seq` tick must not need the
SQLite mutex.

- Helper watchdog: `seq` unchanged while `status = repairing` for 45 s → `status = stuck`,
  `blocks_quit = false`, `recovery_action = retry`. Do not immediately kill the worker.
- Swift: no `repair` event and no successful `get_state` for 20 s, then one `get_state`; if the
  heartbeat is older than 45 s or `get_state` fails, render stuck from the last session or the new
  state. Do not terminate the helper.
- Helper second stage: still stuck 30 s after first stuck, or worker panic → abort the worker and
  `run_repair(Open)`. At most **one** automatic helper recycle per session (Swift starts a new
  helper only if stdin/stdout dies).
- User **Retry** only when `stuck` or `failed` with `retry`: Swift `refresh` (fifteen-second
  accept). The service starts a new worker if the image is still repairable.

After one recycle plus one user Retry, further failure is `failed` + `reinstall`. Diagnose and
`get_state` try-lock during a long `DROP` and return `Unavailable`+`Retry` so the fifteen-second RPC
does not kill the helper.

### Mutator wrapper

Every mutating store method goes through one private wrapper that calls `note_persistence_failure`
on error. Do not maintain a selected list of writers. That note sets process-local
`image_unwritable` on durable corruption or IO/full, attempts `snapshot_untrusted=1` when that write
can still land, and does not salvage.

A mid-life write failure inside a refresh aborts only by setting pending and returning from
`run_refresh`. The existing epilogue owns the rerun. Do not `complete_diagnostics` or publish
Device Health when the refresh was aborted or FailClosed. Do not continue the same refresh against
a new image. Retry-once snapshot write stays on the successful PostRefresh path only.

RefreshStart that returns FailClosed or IO/full rejects the refresh. After spawn, RefreshWorker
runs DerivedState `DROP` if flagged.

### Journaling

The journal remains typed work, not an application log ([ADR 0015](0015-diagnostic-attempts-and-device-health.md)).
Insert-before-work cannot run against a broken image.

Do not add a `state_repair` attempt kind in this decision. Record repair with metadata that already
exists or is a key insert (no `CHECK` change): `state_salvaged_at`, `usage_reindex_pending`,
`snapshot_untrusted`, and `diagnostics_persist_probe`. Existing kinds remain: `process_interrupted`
on open; the next `usage_scan` is `partial` or `success`.

A later Support Report row for salvage would need migration v9 (SQLite cannot `ALTER` a `CHECK`)
and is **deferred**. Do not add `state_repaired` to the shipped Device Health `top_code` enum.
After salvage, summary axes already carry the meaning (`partial` + `automatic`). Fail-closed Device
Health continues to map to existing `local_state_invalid`. Never insert an unrecoverable journal
row if the image cannot be written.

### Device Health

Shipped client labels are unchanged ([ADR 0015](0015-diagnostic-attempts-and-device-health.md)):

- Fresh, operation healthy, data current or empty, attention none or automatic → **Healthy**
- Same healthy/current-or-empty with attention `optional` → **Check device**
- Data partial/stale/unknown, operation degraded/blocked, or attention `required` → **Needs
  attention**

| Phase | operation | data | attention | top_code | Label |
| --- | --- | --- | --- | --- | --- |
| Lying snapshot | must not happen | — | — | — | — |
| Fail-closed unreadable image | `blocked` | `unknown` | `required` | `local_state_invalid` if a report can be uploaded later | Needs attention |
| Salvage or index discard succeeded, reindex pending | from other surfaces | `partial` | `automatic` | `null` until a completed problem attempt exists | Needs attention (`data = partial`) |
| Reindex and refresh succeeded; 24 h `state_repaired` excluded from attention | `healthy` | `current` or `empty` | `none` | `null` | Healthy |
| User must reinstall | `blocked` | `unknown` | `required` | `local_state_invalid` | Needs attention |

A repaired device must not look healthy on other devices while Usage is still a last-good stub
(`data = partial`). After a successful rebuild, excluding `state_repaired` from attention makes the
device **Healthy**, not **Check device** for a day. That exclusion is a product choice.
`quotacli doctor` already exits 0 when operation is healthy, data is current or empty, and attention
is not `required`; optional attention does not force a nonzero CLI exit.

Health upload remains best-effort and cannot fail collection.

### What is never auto-repaired

- `providers.json` contents (UserAction / `configure_provider`).
- Provider-owned files and Keychain.
- Session token bytes (copy or lose; never mint).
- Installation id (copy from `.broken` or fail closed; generate only on a true first install with
  no `.broken`).
- Provider payloads and Usage log lines (isolate).
- Relay D1 / remote Device Health history.
- A second process's in-memory refresh (no multi-process protocol).
- Provider HTTP/RPC/PTY collection fallbacks ([`docs/provider-collection.md`](../provider-collection.md)).

Helper startup failures remain the allowlisted set: `Unavailable`+`Retry`,
`InvalidState`+`Reinstall`, or `ClientUpgradeRequired`+`Upgrade`. Open `sqlite_io_or_full` must use
Retry, not Reinstall.

### Decided defaults

- **Keep last-good Usage during reindex and mark it partial.** Do not clear last-good component
  values or period cache to invent emptiness. Diagnose and Device Health report `partial` until a
  completed real scan.
- **Defer Support Report v9.** No `state_repair` journal kind and no Device Health `top_code`
  change in this decision.

## Consequences

- Diagnostics cannot report `operation = healthy` with `data ∈ {current, empty}` when a persist
  probe fails, when a repair is needed, or when Usage is still waiting to be reindexed.
- Open and DiagnoseRead stay inside the fifteen-second helper budget because they never walk Usage
  or `quick_check` a large live image.
- Salvage cannot promote a fabricated installation id or a signed-out session while `.broken` still
  holds the real ones.
- Device Health stays honest: other devices see **Needs attention** while reindex is pending, and a
  rebuilt device is **Healthy** rather than **Check device** for 24 hours.
- QuotaBar can show a live repair session without inspecting SQLite. Force Quit and helper recycle
  resume from durable markers instead of minting a new identity.
- Support Report does not yet show salvage as a journal row; metadata and the next `usage_scan`
  carry that evidence until a later v9 decision.

[ADR 0008](0008-data-integrity-and-diagnostics.md) remains the evaluator contract.
[ADR 0015](0015-diagnostic-attempts-and-device-health.md) remains the journal and Device Health
upload contract. Runtime boundaries are in [`docs/architecture.md`](../architecture.md). Artifact
and redaction rules are in [`docs/security.md`](../security.md).
