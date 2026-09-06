# ADR 0038: Sessions are a local view of files

- Status: Accepted
- Date: 2026-09-06
- Extends [ADR 0006](0006-managed-account-device-usage.md),
  [ADR 0021](0021-identity-store-and-disposable-cache.md), and
  [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md)

## Decision

**A session is one Usage source file.** Codex `sessions/*.jsonl`, Claude Code
`projects/*/*.jsonl`, and the OpenCode, Pi, Grok, and Cursor files the collector already
discovers each become one row. The identity stored is the file-index hash, never a session id,
path, or conversation id. The row hangs off `usage_file_index` in `cache.sqlite` as
`usage_sessions` and is folded from the records that index already holds. A log that only grew
is still read from the byte its last parse stopped on; the session fold then re-aggregates that
file's stored records rather than re-reading the prefix. Rows whose last write is older than 90
days are deleted.

**Nothing about a session is uploaded.** [ADR 0006](0006-managed-account-device-usage.md) already
forbids a session id leaving the machine, and this view does not even keep one. An hour on the
wire is still an hour of tokens.

**`project_key` is a basename, not a path.** A generic log (`updates.jsonl`, `opencode.db`,
`state.vscdb`, `store.db`) takes its parent directory. A file sitting in a `projects/` folder
takes that folder's name. Everything else uses the file stem. There is no grouping toggle; that
belongs to project attribution if it lands.

The local Usage report carries `sessions: { active, today, recent }`. `active` is a write in the
last five minutes. `today` uses the same local midnight as the Today period. `recent` is at most
20 rows by `last_activity_at`. QuotaBar's Usage page renders that list for This Mac.

## Why

Hourly facts throw away the file a request came from. A person looking at Usage still thinks in
conversations. Deriving the list from files the device already reads avoids a second parser, a
session id, and any new upload surface.

## What was given up

OpenCode's `opencode.db` and Cursor's `state.vscdb` / `store.db` are one file holding many
conversations, so they appear as one session until a later change splits them. Without project
attribution, `project_key` is a basename rather than a repository name.

## When to revisit

When project attribution lands, reuse its `project_key`. If a collector later exposes a stable
per-conversation file for OpenCode or Cursor, the same table already keys by file.
