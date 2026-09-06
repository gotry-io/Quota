# ADR 0039: Project attribution stays local

- Status: Accepted
- Date: 2026-09-06
- Extends [ADR 0006](0006-managed-account-device-usage.md),
  [ADR 0021](0021-identity-store-and-disposable-cache.md), and
  [ADR 0024](0024-hour-versioned-usage-and-daily-rollups.md)

## Decision

This Mac may group local Usage by project. A project is the basename of the git work tree
when `.git` is reachable from the working directory the agent recorded, otherwise the last
path component of that cwd. The key is stored only on `cache.sqlite` hour facts as
`project_key`. It is never a path, never copied onto an upload `UsageRow`, and never sent
to Relay. Unattributed work, and work past the 50-project bound, is shown as `other`.

Parsers fill `NormalizedUsageEvent.project_key` from allow-listed local evidence: Codex
session metadata `cwd`, Claude Code record `cwd` or the encoded `~/.claude/projects/<dir>/`
name, Cursor `~/.cursor/projects/<dir>/`, OpenCode session `directory` when present. Grok
and Pi yield a key only when a cwd field exists on the record.

**Settings › Agents** has **Group Usage by project**, default on. Turning it off keeps
collection and upload unchanged, clears the project dimension from hour facts, and hides
the Usage page Projects section. It does not reread agent logs: stored events already
carry the basename, and the hour is recomputed from them.

QuotaBar's Usage page, on This Mac, lists Projects as Project / Tokens / Cost / Top model
for the selected period. Account, iOS, and the website do not show this dimension: the
cloud never received it.

## Why

Token Tracker, VibeUsage, and WhereMyTokens all answer "which repository burned this".
Quota's upload contract forbids paths ([ADR 0006](0006-managed-account-device-usage.md)).
A basename on the disposable cache is enough for This Mac and is not an identifier Relay
can join across devices.

## What was given up

A full path, a stable repo id, and any Account-wide project rollup. Two clones that share
a folder name collapse. An encoded Claude/Cursor directory name that contained `-` can
decode lossily when the record has no `cwd`. Those are accepted: the alternative is
shipping a path off the machine.

## When to revisit

If a person needs to distinguish two repositories with the same basename, or if an agent
starts recording a stable, non-path project id that is safe to store locally. Uploading
the dimension remains a separate privacy decision.
