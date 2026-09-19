# Antigravity

Catalog id `antigravity`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

CodexBar Automatic is app language-server → `agy` CLI HTTPS → IDE language-server → Google OAuth.
This build does **not** attach to a local `language_server`, does not spawn `agy`, and does not
read CodexBar's `~/.codexbar/antigravity/oauth_creds.json`. Those rungs need a process this
refresh is not allowed to start. The official remote path that remains is Cloud Code Assist with
the CLI's own OAuth file.

1. Discover `~/.gemini/antigravity-cli/antigravity-oauth-token` (or `$GEMINI_CLI_HOME/antigravity-cli/antigravity-oauth-token`).
   The official CLI writes `{ "auth_method", "token": { "access_token", "refresh_token", "expiry" } }`.
   macOS Keychain "Antigravity Safe Storage" is not read: the service name is not an official
   file contract, and this collector does not invent a second grant store.
2. A token more than 60 seconds from expiry is spent as-is. An expired access token is refreshed
   in memory against `POST https://oauth2.googleapis.com/token` only when the same file also
   carries `client_id` and `client_secret`. This build does not extract an OAuth client from
   Antigravity.app binaries. Without a client an expired token answers `auth_required`. The file
   is never written.
3. `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` with
   `{ metadata: { ideType: "ANTIGRAVITY", platform: "PLATFORM_UNSPECIFIED", pluginType: "GEMINI" } }`
   and, when set, `GOOGLE_CLOUD_PROJECT` as `cloudaicompanionProject`. `currentTier.id` (else
   `planInfo.planType`) becomes the plan slug. Requests identify as `User-Agent: antigravity`
   because that is the client the Antigravity OAuth grant was issued for.
4. Prefer `POST …:retrieveUserQuotaSummary`. When that is refused or has no windows,
   `POST …:retrieveUserQuota` with `{ project }` when a project id is known. Summary `groups[]`
   buckets become named windows (Gemini / Claude + GPT × 5 Hours / Weekly). Legacy `buckets[]`
   REQUESTS rows pool by reset horizon the way Gemini CLI does, except a reset within six hours
   is **5 Hours** rather than per-minute.
5. Absent file or unusable grant → `auth_required` with "Run `agy` and sign in with Google".
   HTTP 401/403 → `auth_required`. Identity is the access token JWT `email` (else stored `email`,
   else `sub`).
