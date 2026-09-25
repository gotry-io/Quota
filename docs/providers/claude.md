# Claude Code

Catalog id `claude`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

1. Discover `$CLAUDE_CONFIG_DIR/.credentials.json`, `~/.claude/.credentials.json`, or the macOS
   Keychain generic password service `Claude Code-credentials` when collection home is the
   process `HOME`. Isolated or remapped homes do not read the live Keychain.
2. Parse only `claudeAiOauth`; a document without it is not a Claude sign-in, which is what a
   Keychain item holding only `mcpOAuth` is. An entry with the object but no `accessToken` is a
   Claude Code that signed itself out — it empties the tokens in place and sets `expiresAt` to 0.
   Recovery depends on the Keychain: an emptied file with no Keychain item is `auth_required`
   under its own source, "Claude Code is signed out. Run `claude` and sign in again." A Keychain
   item this process was refused is `access_denied`, "QuotaBar could not read Claude Code's
   Keychain item. Open Claude Code to refresh the sign-in" — Claude Code can read a grant this
   process cannot, and opening it has been seen to rewrite the file from that item. A grant needs
   `accessToken` with a usable `user:profile` scope. The Keychain entry wins unless it is the
   only expiring one of the two, an emptied entry counting as expiring; a Keychain that withheld
   its entry outranks an emptied file beside it, because that file is what an older Claude Code
   left behind and says nothing about the grant this device was refused. The snapshot plan
   prefers `rateLimitTier` over `subscriptionType`, written `max_5x` / `max_20x` / `max` /
   `pro`.
3. This build starts Claude Code when a grant is expired or within one minute of expiry and
   carries a non-empty `refreshToken`, **or** when the file holds no usable grant and the
   Keychain item exists but this process was refused it. Its access token lives about eight hours
   and only Claude Code renews it, so a Mac that has not opened it since breakfast would
   otherwise report an expired sign-in all day; a withheld Keychain item next to an emptied file
   is the same hole, because Claude Code writes the live grant where this process cannot read it.
   If the official OAuth reading then answers `auth_required` while this Mac still holds a
   grant, the same `mcp list` is asked once more in that refresh — the local clock is not the
   account — and collection runs again. A Mac with nothing to renew from still starts nothing.
   On the refresh worker, before collection, `claude mcp list` is run once. That command is
   chosen by experiment against 2.1.246: `claude auth status --json` reports the expired token
   without renewing, `claude doctor` reaches the CLI's refresh path only when the environment
   already carries a running Claude Code session's variables, and `mcp list` reaches it
   deterministically under an `env -i`-style environment of `HOME`, `PATH`, `TERM=dumb`, and
   `CLAUDE_CONFIG_DIR` where this device sets one — leaving an unexpired credential untouched.
   Its one side effect is that it health-checks approved MCP servers; started in an empty private
   directory created for the run, that reaches the user-scoped servers in `~/.claude.json` and no
   project's `.mcp.json`, and the deadline is what keeps a slow server from holding the refresh.
   Bounded to ten seconds — measured here at 2.97–3.46 s renewing and 2.05–2.44 s not — with
   64 KiB of stdout read only to bound it and discarded, stderr discarded, and no stdin. A
   scheduled refresh records the attempt in `cache.sqlite` metadata and will not ask again for an
   hour, whatever the outcome; a Recheck or a manual refresh skips that hour so it can ask
   immediately. Afterwards the credential is read again. A Keychain secret this refresh actually
   held is forgotten first, because Claude Code rewrites that entry in place; a refusal is kept,
   so the collector is not sent through a second prompt for a grant the CLI may have rewritten
   into the file. A grant with time left continues to step 4 in the same refresh; an emptied
   entry with no Keychain item is the signed-out outcome above; a withheld Keychain item is
   `access_denied` as above; anything else is `auth_required` with "Open Claude Code to refresh
   the sign-in". No Claude Code on this Mac, no refresh token in a readable entry, no
   `claudeAiOauth` at all, and no withheld Keychain item each mean no attempt and no record.
4. Call `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1` with
   `anthropic-beta: oauth-2025-04-20`. Every usage request, on both rungs, carries
   `cedar_ember=1`: without it the limit-reset block (step 5) answers `null`.
5. Map the five-hour, seven-day, model-scoped, and extra-usage windows that are present. Titles are
   **5 Hours**, **Weekly**, **Sonnet Weekly**, **Opus Weekly**, **OAuth Apps Weekly**,
   **{Model} Only**, **Daily Routines**, and **Extra Usage**. The five-hour and seven-day
   windows are the headline meters (`primary_cadence` `five_hour` and `weekly`); model-scoped
   weeklies, Daily Routines, and Extra Usage are not. Every weekly limit meters one
   seven-day cycle, so a weekly window that reports no reset of its own — model-scoped or not —
   takes the seven-day window's reset. Extra Usage is a monthly USD spend cap: when
   `is_enabled` is not false and `used_credits` / `monthly_limit` are present, they are cents,
   mapped to `remaining_value` / `limit_value` / `value_unit: usd`. Utilization may be null when
   the cap is on; used/limit then supplies `used_percent`. A utilization-only extra_usage object
   still maps as a percent window. Extra usage that is off is omitted.

   The `cedar_ember` block is Claude's limit resets: `{ eligible, ineligible_reason, at_limit,
   weekly_resets_at, cooldown_until, next_grant_id, grants: [{ id, label, resets_total,
   resets_left, starts_at, ends_at, clears[], paused, usable_now, use_requires_limit,
   percent_used }] }` (support.claude.com article 17007452; the shape comes from third-party
   reverse engineering and is read tolerantly). It maps to **Reset Credits** (id
   `reset_credits`, `value_unit: count`, `used_percent: 0`, no `primary_cadence`):
   `remaining_value` is the sum of `resets_left` over every grant that is not `paused` and whose
   RFC 3339 `ends_at` has not passed, and `expiries` groups those grants' `resets_left` by
   `ends_at`, nearest first. A grant with no `ends_at` is counted and lists no expiry. The window
   is omitted when the block is `null` or absent, when `eligible` is `false` (a caller Anthropic
   does not count as a surface that can use them is answered `ineligible_reason: "surface"`), or
   when there are no grants; a block this build
   cannot read — a `resets_left` that is not a non-negative whole number, `grants` that is not a
   list — is omitted too, and never fails the reading beside it. Unknown fields are ignored.
   Nothing here redeems a reset (`reset_rate_limits` is not called).
6. Enrich identity best-effort through `/api/oauth/profile`; usage remains valid if enrichment fails.
7. Usage accepts `utilization` / `resets_at` and the aliases `utilization_pct` / `reset_at`.
8. If no credential exists or the OAuth rung answers `auth_required`, and a stored Claude
   [browser session](../provider-collection.md#browser-session) exists, send the stored allowlisted Cookie header
   (`sessionKey` plus optional `lastActiveOrg`) to `https://claude.ai/api/organizations` and
   `/api/account` best-effort for the masked label and plan (QuotaBar asks in turn; the iPhone
   asks for both at once, since neither depends on the other), then
   `/organizations/{id}/usage?cedar_ember=1`, mapped as step 5 maps the OAuth body. Prefer the listed org matching `lastActiveOrg`, then the org on
   `/api/account`, unless that org is `api_disabled`; otherwise the first chat-capable org. The
   org list alone is not proof: the same usage document has to map before the session is stored.
   The `sessionKey` value must start with `sk-ant-`. QuotaBar acquires `sessionKey` and optional
   `lastActiveOrg` from `claude.ai` / `www.claude.ai`. The fingerprint is the same
   `organization_id` namespace the OAuth rung uses. A Keychain this Mac was refused is
   `access_denied`, not `auth_required`, so it never reaches this rung.

An absent, stale, or unreadable session is `auth_required`. A Claude Code installation configured
only for a third-party API gateway does not provide Anthropic subscription OAuth quota unless a
valid `claude.ai` browser session is stored.
Collection never drives the Claude CLI to read quota, in any form: step 3 asks Claude Code to renew
a credential, never to report one, and a grant still out of time afterwards is reported as the
sign-in it is. The local service never submits the Claude refresh token or writes its credential
file or Keychain entry — Claude Code alone rotates that token and writes what it gets back. The
Keychain read is performed once per refresh and shared, plus once more when a renewal ran. Both
OAuth requests — usage and profile — present one identity, `User-Agent: claude-cli/<version>
(external, cli)`, the official CLI's rather than this build's, carrying the installed Claude Code
version read as [Official CLI identity](../provider-collection.md#official-cli-identity) describes
and falling back to `claude-cli/2.1.0 (external, cli)` when none could be read. That is the
identity the usage endpoint answers the limit-reset block for: measured 2026-09-25, the same
account asked as `claude-code/<version>` was answered `eligible: false`, `ineligible_reason:
"surface"`. The web rung keeps this build's own `User-Agent`.
