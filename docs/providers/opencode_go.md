# OpenCode Go

Catalog id `opencode_go`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

CodexBar Automatic unscoped is **local → API → web**. Scoped web-first order applies when a
CodexBar account, manual cookie, or workspace is selected; this build has no cookie or workspace
rung, so it keeps the unscoped order. The web path is CodexBar scraping `opencode.ai/_server`
HTML/JSON with `auth` / `__Host-auth` cookies — not a documented official quota API — and is not
implemented here.

1. Discover a local OpenCode Go sign-in at `$XDG_DATA_HOME/opencode/auth.json` (default
   `~/.local/share/opencode/auth.json`) when `opencode-go.key` is non-empty; else the API key from
   owner-only `providers.opencode_go.api_key` or `OPENCODE_API_KEY`.
2. Local: read `opencode.db` `message` rows whose `providerID` is `opencode-go` and that carry a
   numeric `cost`. Sum dollars in the rolling 5-hour, UTC-week (Monday), and UTC-month windows.
   Remaining is that sum against the published OpenCode Go limits of **$12 / 5 hours**, **$30 /
   week**, and **$60 / month**. Those limits are product documentation, not a quota endpoint.
   Empty history with a key present is not a reading: fall through to the API key.
3. API: `GET https://opencode.ai/zen/go/v1/usage` with `Authorization: Bearer`. Map `usage.rolling`
   / `weekly` / `monthly` `usagePercent` (or `remainingPercent`) and `resetInSec` / `resetAt` onto
   **5 Hours**, **Weekly**, and **Monthly**. Dollar remaining/limit fields are kept when present.
   Custom base URLs are not supported.
4. Absent key and no local auth → `auth_required` with guidance to configure QuotaBar (or set
   `OPENCODE_API_KEY`). HTTP 401/403 → `auth_required`. Identity is the SHA-256 of the API key
   (or the local `opencode-go` key) under `api_key`. No browser-session rung.
