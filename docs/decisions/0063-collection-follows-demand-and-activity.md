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

A viewer asks only for what a Mac could make newer. A subscription is worth asking for when its
newest reading **from a Mac** (never the asking device's own, never another iPhone's) is older than
two minutes or its provider's catalog floor, whichever is longer — a Mac does not ask a provider
again inside its floor, so a younger reading is as fresh as a request could make it. The floor
reaches both clients from the catalog generator (`ProviderID.minCollectionInterval` in QuotaWire,
`providerMinCollectionIntervalSeconds` in `@gotry-io/quota-protocol`). The follow-up waits only on
the subscriptions it asked about, and ends as soon as each has a Mac reading at or after the
`requested_at` Relay answered.

- **Quota iOS** asks on a cold launch, on a return to the foreground (after its conditional
  summary read), and on pull to refresh or the refresh button. It then re-reads the summary
  conditionally every 20 seconds while in the foreground, at most nine times (three minutes), and
  stops when it is answered, when the app leaves the foreground, or on sign-out. One wait at a
  time. While it waits the subtitle says **Asking your Mac…** (**Asking your Macs…** when the old
  readings came from more than one Mac); on timeout it returns to **Updated Xm ago**. A 404, a
  429, and a timeout end silently, with no banner.
- **The website** Overview asks on load and when its tab becomes visible again (after re-reading
  the summary), on the same rule, and re-reads the summary every 30 seconds for three minutes,
  stopping when it is answered, when the tab is hidden, or when Overview is left. Its status line
  says the same **Asking your Mac…** while it waits; a refusal or a timeout says nothing.

### Who answers (QuotaBar)

When the minute Account read carries a `collection_requested_at` later than this Mac's last
complete collection and no more than ten minutes old, the scheduler runs one pass of every
provider now on the Quota lane (it uploads as usual) and restarts every provider's clock from now.
One requested instant is answered once. A request older than ten minutes — a Mac that slept through
it — is ignored. The diagnostics journal names the trigger `demand`, beside `scheduled` and
`reset`. The pass goes through the same gate as a timed one, so the floors, backoff, and
cross-device skip below decide which providers it actually asks; a demand never makes a provider
faster than its floor.

### Automatic cadence (QuotaBar)

Refresh Interval gains **Automatic**, the new default. The fixed 1/2/5/10/15-minute values stay; a
fixed value applies to every provider and does not adapt, but demand still applies. An identity
whose stored interval is 300 seconds (the old default) migrates to Automatic; any other value stays
fixed (`quota_refresh_mode = automatic | fixed`, identity migration v6).

Automatic gives each provider a tier once a minute, and each provider runs on its own clock:

| Tier | Condition | Interval |
| --- | --- | --- |
| Active | that provider's local agent wrote its logs in the last 5 minutes, or a window of this Mac's last reading has < 20 % remaining while the provider was in use (a write or a collection request) in the last 60 minutes | 1 minute |
| Normal | otherwise | 5 minutes |
| Idle | no local write and no collection request in 60 minutes | 10 minutes |

Every interval is then raised to the provider's floor. Activity is the newest modification time
under the agent's Usage log roots ([usage-sources](../usage-sources.md)): a walk of at most 5,000
entries and six levels, newest directories first, that opens no file. The agents that map to one
provider are Claude Code → `claude`, Codex → `codex`, Gemini CLI → `gemini`, Cursor → `cursor`, Grok
CLI → `grok`, Copilot CLI → `copilot`, and Antigravity → `antigravity`. OpenCode, Pi, and Kilo can
speak for any provider, and saying which would mean parsing their logs, so they do not count. A
provider with no mapped agent (OpenRouter, DeepSeek, …) is always Normal. A pass takes every
provider due within 30 seconds, so providers on one interval share it; when one of those is
still held by its floor for a few seconds, the pass waits for it rather than leave it to a pass
(and an Account read and upload) of its own. Usage is scanned every five
minutes under Automatic, whatever the tiers are, and at the fixed interval otherwise. Settings shows
the fastest tier among the providers in use, for example **Automatic · every 1 min while Codex is
active** or **Automatic · every 3 min while Claude Code is active**.

### Floors, backoff, and fairness

1. **Per-provider floor.** `collection.min_interval_seconds` in `packages/provider/catalog.json`
   is the shortest time between two asks of one provider on one Mac: Claude 180, Codex 60,
   providers that only read an official API-key balance (OpenRouter, DeepSeek) 60, every other
   provider 120. It caps every tier and every fixed interval, and a timed tick, a demand, a window
   reset catch-up, startup, and a settings or account change all respect it. The scheduler waits
   for it rather than spending a tick the gate would refuse. A manual refresh or Diagnostics
   Recheck waits only 60 seconds per provider. CLI credential renewal (Codex / Claude / Grok, at
   most hourly) is unaffected.
2. **Backoff on 429** (QuotaBar and Quota iOS). A `Retry-After` greater than zero is obeyed, capped
   at 60 minutes; otherwise — Anthropic's `retry-after: 0` means nothing — the wait starts at five
   minutes and doubles to at most 30. While backing off the last reading is shown with its age, not
   an error. A manual refresh may pass the backoff, at most once a minute per provider. A reading
   ends the backoff. QuotaBar keeps it per provider and the account it last read for it in
   `cache.sqlite` metadata; Quota iOS keeps it per provider session in its `UserDefaults`; neither
   is cleared by a restart. QuotaBar maps a 429 to `rate_limited` in the journal, and to the wire's
   existing `unavailable` status.
3. **A raised floor after a 429.** A 429 also holds that provider account to max(catalog floor,
   300 seconds) for 24 hours from the latest 429, kept beside the backoff. A success in between does
   not lower it; only the 24 hours running out do. A manual refresh is not held by it.
4. **Jitter.** Each provider's timed tick moves by up to ±10 %, never below its floor, so Macs do not
   all read on the minute.
5. **Cross-device dedupe.** Before asking, a Mac skips a provider when every account it last read
   for it was observed by another device of the Account within the provider's floor, as the latest
   summary states it. Several Macs answering one demand therefore do not all read Claude.
6. **Claude profile cache.** The plan and email (`/api/oauth/profile`) answer for the access token
   they were read with for 24 hours, held in the service's memory against a SHA-256 digest of that
   token and never persisted; a renewal or a new sign-in reads them again. A collection costs
   Claude one request instead of two.
7. **Claude Code's own snapshot.** Before asking the network, the Claude collector decodes the one
   key `cachedUsageUtilization` of Claude Code's global config (`$CLAUDE_CONFIG_DIR/.claude.json` or
   `~/.claude.json`), `{fetchedAtMs, accountUuid?, utilization}`. It stands in for a request only
   when it is under 60 seconds old, its `accountUuid` is the account of the credential in use, and
   this Mac read the network for that credential within the hour. The snapshot lacks the
   limit-reset block (`cedar_ember`), so the **Reset Credits** window is carried from that network
   read. The format is undocumented; anything else leaves the network to answer
   ([claude.md](../providers/claude.md)).

With the profile cached, Claude falls from 24 requests an hour (usage and profile every five
minutes, 170 rounds measured on 2026-09-25/26 with no 429) to at most 20 an hour while Active, and
fewer when Claude Code's snapshot answers.

### Privacy

The request carries nothing but the Account it is made under; the stored value is one instant
that names no provider, device, or requester, and it is deleted with the Account. Activity
detection reads modification times on this Mac and never leaves it. The cadence records in
`cache.sqlite` hold instants and the irreversible account fingerprint a backoff was earned on; the
Claude snapshot is used for one reading and never stored.

## Consequences

- Opening the phone or the dashboard brings a reading one to two minutes old at worst — three for
  Claude — while a Mac is awake and signed in.
- Request volume per provider follows use. Using Claude Code four hours a day is about 80 Claude
  requests while active (the three-minute floor), 12 in the Normal hour after, and about 114 in
  the Idle rest — about 206 a day against 576 (288 collections of two requests) before — and an
  unused provider drops from 288 to about 144.
- Each accepted demand costs every Mac of the Account one extra full summary download. Relay
  stores one column; the SQLite write is negligible.
- A new client against an old Relay sees 404 and behaves as before; an old client ignores the
  field.
- The private IPC changed with QuotaBar in one build (`set_quota_refresh_interval` takes
  `{"mode": "automatic"}` or `{"mode": "fixed", "interval_seconds": N}`; `get_state` adds
  `quota_refresh_mode` and `quota_refresh_tier`), so `ipc_version` does not move.
- Release order is Relay, then QuotaBar, then Quota iOS.

## Alternatives considered

- **Signal on `GET /api/v2/device/sync`.** Refused: a second request per Mac per minute.
- **Push (APNs or a held connection) to the Mac.** Refused for now: the minute read already
  exists, and a minute of latency is inside the one-to-two-minute goal.
- **Faster fixed intervals.** Refused: request volume grows for every provider, including the
  unused ones, and Claude's limit does not allow it.
