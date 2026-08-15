# ADR 0015: Diagnostic attempts, support reports, and Device Health

- Status: Accepted
- Date: 2026-08-15

## Context

The diagnostics evaluator in [ADR 0008](0008-data-integrity-and-diagnostics.md) needs durable evidence
about completed work. Component timestamps and a short support projection cannot reliably answer
whether the last attempt failed or when a path last succeeded. A free-form log would be difficult to
bound, redact, and use as a stable product contract.

Account device lists also need enough information to distinguish a recently healthy collector from
a device that reported a problem or simply has not run recently. Device lifecycle `last_seen_at`
does not carry that meaning, and client-observed clocks are not authoritative for freshness.

Diagnostic v1 shipped with QuotaBar 0.0.15. Its v2 replacement is an unreleased bundled
service/QuotaBar contract and is extended directly. Managed-data v3 shipped with QuotaBar 0.0.12, so
its default strict Account summary shape cannot gain a field in place.

## Decision

### Local attempt journal and Support Report

SQLite migration v8 adds an owner-only structured attempt journal. It is not an application log.
Each refresh and its `quota_collection`, `usage_scan`, `usage_upload`, `account_sync`, and
`pricing_refresh` work records a typed trigger, source, optional safe subject, mode, start and
completion time, bounded duration, outcome, code, recovery, bounded numeric metrics, state revision,
and parent refresh. Device Health uploads use the same structure but are excluded from the health
signal they publish.

The same migration clears only a cached, derived Account summary produced before clients requested
the strict `device_health=1` shape. This prevents the first post-upgrade `get_state` from sending an
old Device object without the required nullable `health` field. Account session, Device/upload
identity, local facts, outbox work, and Account Usage period caches remain intact; the next refresh
rebuilds the summary from Relay.

An attempt is inserted before work begins and the same row is finalized after success, partial work,
no work, failure, cancellation, or a caught worker failure. Opening the database converts any
remaining running rows to `interrupted/process_interrupted`. `partial` is distinct from `success`:
stable malformed Usage or incomplete coverage cannot become a successful scan. Authentication may
remain the cause of an opportunistic `no_work` attempt without making optional local collection
unhealthy.

Subjects are either null or catalog-owned `provider:<id>` / `agent:<id>` values. Metrics contain at
most 16 allowlisted labels and bounded nonnegative integers. The journal must never contain paths,
filenames, models, raw responses, parser excerpts, stderr, prompts, session/conversation IDs,
installation/device IDs, credentials, or tokens.

Retention is seven days with a hard cap of 50,000 completed rows. At a five-minute cadence, roughly
2,016 weekly refreshes times fewer than 20 meaningful steps fit below that cap while leaving room for
manual activity. This preserves useful recent support context without retaining a month of
owner-only operational history. Pruning runs in attempt write transactions, never removes running
rows, detaches children if an old parent is removed, and permanently marks that history was
truncated.

The evaluator queries the full retained journal by kind/source/subject for the latest completed
attempt and latest success. Health policy and Device Health timestamps never read the bounded Support
Report projection. Diagnostics v2 adds `recent_activity`, assembled by the service from running work,
the latest 20 refreshes and their children, and failed/interrupted attempts from the last 24 hours,
with a total maximum of 512 attempts and `history_truncated`. QuotaBar and QuotaCLI strictly decode
and render the same service-owned JSON/text facts; neither recreates policy.

SQLite migration v7 remains the single replaceable last-completed diagnostics snapshot. A refresh
publishes that snapshot only after its component state is applied. Current running phase is overlaid
at read time, so Support Report never combines intermediate component states. Recheck starts or
joins the real single-flight refresh and either returns a newer completed revision or clearly reports
that the refresh is still running.

### Cross-device Device Health

After an authenticated device completes a refresh, the local service derives a sanitized Device
Health schema from the completed diagnostics boundary and uploads it on change or as a 15-minute
heartbeat. Upload is best effort and cannot fail quota, Usage, or Account synchronization. Its own
failure is a local typed attempt and does not recursively affect the health payload being sent.

The payload contains only schema/client product and version/platform, device-observed time, a
monotonic diagnostics `refresh_revision`, last completed refresh, last successful Account sync,
the three diagnostic summary axes, one allowlisted top-level code, bounded consecutive refresh
failures, and whether Usage upload is enabled. When Usage upload is disabled, no Usage attempt,
agent, metric, or other local collection detail is uploaded; only the setting and generic device
summary remain. Attempts, provider/agent subjects, paths, models, identifiers, and diagnostic history
never upload.

The device access token determines the only Device that can write. The request cannot select a
Device ID, and Relay also requires the authenticated generation and platform to match. D1 migration
0010 stores one replace-in-place health row per Device with `ON DELETE CASCADE`; Relay retains no
remote health history. A greater revision replaces the row, the same revision may refresh a
heartbeat, and a delayed lower revision is a successful no-op that cannot refresh the stored
freshness window. Device and Account deletion therefore remove health with their existing lifecycle
data.

QuotaBar 0.0.15 device sessions were already issued before this endpoint and carry the released
`sync:read:self` self-device scope. The new route accepts that existing scope rather than forcing a
logout solely to mint another token, but still performs a write-only self check from the authenticated
Device principal; account and iOS tokens remain unable to call it. This is the concrete shipped-token
compatibility exception, not general read-scope write authority.

Relay's `received_at` is the freshness authority and currently grants a 20-minute fresh window.
Clients may show **Healthy** only while fresh and only when operation is healthy, data is current or
empty, and attention is none or automatic. A fresh degraded/blocked, partial/stale/unknown, or
required-attention report is **Needs attention**. Expired or absent reports are **Not recently
active** or **Unknown**, never an assertion that a sleeping, powered-off, or closed app is broken.
Recovery copy directs the user to the corresponding Device; one Device never requests credentials
on behalf of another.

Device Health is exposed through an explicit managed-data v3 read opt-in. The default
`GET /api/v3/account/summary` response remains byte-shape compatible and contains no `health` key.
Clients that request `device_health=1` strictly decode a Device shape where `health` is required but
nullable. QuotaBar, Quota Web, and the read-only iOS client use the opt-in; iOS remains unable to
write Device Health.

QuotaBar can be upgraded before the managed Relay deployment. The released Relay rejects the new
query key with `400 invalid_request`, so the native client has one concrete compatibility path: when
and only when it added the opt-in itself and receives that response, it retries once without the new
opt-ins and projects each released Device to `health: null` before applying the same strict local
validator. Network, authentication, malformed-response, and explicit caller errors do not fall back.
This path exists only for the shipped deployment boundary and can be removed after the minimum Relay
deployment supports Device Health.

## Consequences

- Support data describes actual completed work and recovery without becoming a general telemetry or
  logging system.
- A bounded projection remains convenient to copy, while evaluator facts and successful timestamps
  do not disappear after 20 refreshes.
- Remote Device status is useful when recent, honest when stale, and independent of whether the
  viewing Device has matching provider credentials.
- Managed-data v3 keeps its shipped default response compatible; new strict clients deliberately opt
  into the new Device shape.
- Relay stores only the latest minimal health signal and no third-party telemetry is introduced.

Evaluation semantics remain canonical in [ADR 0008](0008-data-integrity-and-diagnostics.md), Device
identity and deletion in [ADR 0006](0006-managed-account-device-usage.md), and the shipped
managed-data boundary in [ADR 0012](0012-managed-data-v3.md).
