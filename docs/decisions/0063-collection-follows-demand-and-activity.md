# ADR 0063: Collection follows demand and activity

- Status: Accepted
- Date: 2026-09-26

## Context

QuotaBar collected on one fixed timer (default five minutes) and read the Account summary every
minute. Quota iOS read the summary only at launch, on return to the foreground, on pull to
refresh, and under background refresh no sooner than thirty minutes apart; the website read it on
load. Someone who opened the phone to check a limit therefore saw a reading up to five minutes
old, and nothing they did could make it newer. Meanwhile a provider nobody was using was read as
often as the one in active use.

Provider limits bound how far that can be pushed. Claude's `/api/oauth/usage` refills about one
request per five minutes with a small burst; `retry-after: 0` is not to be trusted, and an hour
has been seen. Claude Code itself reads on demand and shares a 60-second snapshot. The Codex TUI
reads `wham/usage` every 60 seconds on its own. No public report ties reading usage to a ban, but
consumer terms restrict automated access, so the total request volume must not grow. Measured on
this project's own Mac at the five-minute interval: 170 Claude reads in 18 hours, 169 answered,
no 429.

## Decision

**Collection follows demand and activity: a viewer can ask the Macs to collect now, and each
provider is read as often as it is in use — never below its floor, never above today's total.**

### The demand signal (Relay and protocol)

`POST /api/v6/account/collection-request` with body `{"protocol_version": 6}` — the managed-data version, as
every `/api/v6` body carries — strict, so a body naming a provider, device, or reason is refused. Any signed-in session may call it: the
Mac's Device session, the phone's read-only session, and the browser cookie, which also presents
the same-origin `Origin` (and same-origin Fetch Metadata when sent) that every cookie write does.
The scope is `account:read`, the same one the summary read takes.

It answers `{"protocol_version": 6, "requested_at": RFC3339, "accepted": bool}`. Relay stores one
instant per Account, `accounts.collection_requested_at` (migration `0035`). A request within 60
seconds of the stored one is not stored; it answers the stored `requested_at` with
`accepted: false`, which is not an error. The limit is 30 requests per 10 minutes **per session**
(`429 rate_limited` with `Retry-After`), so one runaway client cannot spend another's. No session
is `401`. Relay never calls a provider: the request is a timestamp and nothing else.

`GET /api/v6/account/summary` carries top-level `collection_requested_at: RFC3339 | null`,
account-wide. It is part of the representation and of the summary's version stamp, so a new
request moves the ETag and every Mac's next minute read receives one full body. A reader treats
the field as optional (ADR 0023): a Relay that predates it does not send it. A client that posts
to a Relay without the route receives 404 and treats it as "not supported", silently.

The signal rides the summary rather than `GET /api/v2/device/sync`, because every Mac already
reads the summary once a minute; putting it on `device/sync` would cost each Mac a second request
every minute.

### Who asks (Quota iOS and the website)

- Quota iOS asks on cold launch, on return to the foreground, and on pull to refresh, when a
  reading in the summary from another device is more than two minutes old. It then re-reads the
  summary conditionally every 20 seconds while in the foreground, for at most three minutes, and
  stops when a Mac reading is newer than `requested_at` or the app leaves the foreground. While it
  waits the subtitle says **Asking your Mac…**; on timeout it returns to **Updated Xm ago**. No
  error is shown.
- The website dashboard asks on load and when the tab becomes visible again, on the same
  two-minute condition, and re-reads the summary every 30 seconds for three minutes.

### Who answers (QuotaBar)

When the minute Account read carries a `collection_requested_at` later than this Mac's last
completed collection and no more than ten minutes old, the Mac schedules one collection now on
the same Quota lane as the timed one (it uploads as usual) and restarts the timer from now. One
requested instant is answered once. A request older than ten minutes — a Mac that slept through
it — is ignored. The diagnostics journal names the trigger `demand`, beside `scheduled` and
`reset`. Every rule below still applies to a demand collection.

### Automatic cadence (QuotaBar)

Refresh Interval gains **Automatic**, the new default. The fixed 1/2/5/10/15-minute values stay;
a fixed value does not adapt, but demand still applies. An identity whose stored interval is 300
seconds (the old default) migrates to Automatic; any other value stays fixed
(`quota_refresh_mode = automatic | fixed` in `identity.sqlite`).

Automatic is computed per provider:

| State | Condition | Interval |
| --- | --- | --- |
| Active | that provider's local agent log was written in the last 5 minutes, or a window has < 20 % remaining | 1 minute |
| Normal | otherwise | 5 minutes |
| Idle | no local activity and no demand for that provider in 60 minutes | 10 minutes |

Activity is a once-a-minute modification-time check of the known log directories
([usage-sources](../usage-sources.md)); files are not parsed. Claude Code → `claude`, Codex →
`codex`, Gemini CLI → `gemini`, Cursor → `cursor`, and OpenCode / Pi by their configured provider;
an agent with no provider mapping does not count. A provider with no local log source (Copilot,
OpenRouter, …) is always Normal. Only providers that are due are collected. Settings shows the
current state under Automatic, for example **Automatic · every 1 min while Claude Code is
active**.

### Floors, backoff, and fairness (R1)

1. **Per-provider floor.** `collection.min_interval_seconds` in `packages/provider/catalog.json`:
   Claude OAuth 300 (Active does not go below five minutes), Codex 60, providers that only read an
   official API-key balance (OpenRouter, DeepSeek) 60, every other provider 120. Active is clamped
   to the floor. Demand, reset catch-up, and Automatic share it; two collections of one provider
   are never closer than its floor and never closer than 60 seconds. CLI credential renewal
   (Codex / Claude / Grok, at most hourly) is unaffected.
2. **Backoff on 429 and rate limiting** (QuotaBar and Quota iOS). A `Retry-After` greater than
   zero is obeyed, capped at 60 minutes; otherwise backoff starts at five minutes and doubles to
   at most 30. It is kept per provider and provider account in `cache.sqlite`, so a restart does
   not reset it. While backing off the last reading is shown with its time, not an error. A manual
   refresh may pass the backoff, at most once a minute per provider.
3. **Jitter.** A timed collection is moved by ±10 % at random, so Macs do not all read on the
   minute.
4. **Cross-device dedupe.** Before collecting a subscription, a Mac looks at the newest reading
   of it in the summary; if another device read that provider within the provider's floor, this
   Mac skips it. Several Macs answering one demand therefore do not all read Claude.
5. **Claude profile cache.** The plan and email (profile) request is cached for 24 hours and
   repeated only when the account changes or the cache expires, so a collection costs Claude one
   request instead of two.
6. **Claude Code's own snapshot (D6).** While Claude is Active, the Mac may read the usage
   snapshot Claude Code writes locally (`cachedUsageUtilization`) and use it when it is fresh
   enough, with no request at all. The format is undocumented, so this is best effort and falls
   back to the normal read.

### Privacy

The request carries nothing but the Account it is made under; the stored value is one instant
that names no provider, device, or requester, and it is deleted with the Account. Activity
detection reads modification times on this Mac and never leaves it.

## Consequences

- Opening the phone or the dashboard brings a reading one to two minutes old at worst, while a
  Mac is awake and signed in.
- Request volume per provider follows use. Using Claude Code four hours a day is about 48 Claude
  reads while active (the five-minute floor) plus the Normal and Idle hours — fewer than the 288 a
  day of the fixed five-minute timer — and an unused provider drops from 288 to about 144.
- Each accepted demand costs every Mac of the Account one extra full summary download. Relay
  stores one column; the SQLite write is negligible.
- A new client against an old Relay sees 404 and behaves as before; an old client ignores the
  field.
- Release order is Relay, then QuotaBar, then Quota iOS.

## Alternatives considered

- **Signal on `GET /api/v2/device/sync`.** Refused: a second request per Mac per minute.
- **Push (APNs or a held connection) to the Mac.** Refused for now: the minute read already
  exists, and a minute of latency is inside the one-to-two-minute goal.
- **Faster fixed intervals.** Refused: request volume grows for every provider, including the
  unused ones, and Claude's limit does not allow it.
