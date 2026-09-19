# Gemini CLI

Catalog id `gemini`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

1. Discover `~/.gemini/oauth_creds.json`. There is no browser-session rung: Google's Code Assist
   grant is the OAuth file the Gemini CLI writes, not a cookie.
2. Read `access_token`, `refresh_token`, and `expiry_date` (milliseconds, as the CLI writes it). A
   token more than 60 seconds from expiry is spent as-is. An expired or missing access token is
   refreshed in memory against `POST https://oauth2.googleapis.com/token` with the Gemini CLI's
   installed-application client id and secret, **read at refresh time from the CLI package
   installed on this device** (`gemini` resolved like every CLI here, then
   `@google/gemini-cli-core/dist/src/code_assist/oauth2.js` beside it; Google's own source
   comments that this secret is not treated as a secret, but this repository still carries no
   copy of it). Without an installed CLI an expired token answers `auth_required`, and signing in
   through the CLI restores it. This build does **not** write `oauth_creds.json`; the CLI
   remains the file owner. Google refresh tokens for this client are reusable, unlike Codex's
   single-use rotation, so spending one here does not strand the CLI. There is no Gemini CLI
   command that renews without making a billed request, so this is not a [`renewal.rs`](../../packages/service/src/providers/common/renewal.rs)
   spawn.
3. `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` with
   `{ metadata: { ideType: "GEMINI_CLI", pluginType: "GEMINI" } }` and, when set,
   `GOOGLE_CLOUD_PROJECT` as `cloudaicompanionProject`. The response's
   `cloudaicompanionProject` (else the env project) is required. `currentTier.id` becomes the plan
   slug (`standard-tier` → `standard_tier`).
4. `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` with
   `{ project: <cloudaicompanionProject> }`. Map `buckets[]` whose `tokenType` is `REQUESTS` (or
   omitted). `remainingAmount / remainingFraction` is the limit; a fraction alone is treated as
   remaining percent of 100, matching the CLI. Pool buckets that share a reset horizon:
   - reset within five minutes → **Per Minute** (`duration_seconds: 60`)
   - otherwise within two days, or no reset → **Daily** (`duration_seconds: 86400`)
   - within eight days → **Weekly**
   - else → **Monthly**
   Official daily request limits are aggregated across models, so per-model buckets that share a
   horizon become one window (`value_unit: "count"`). Daily is not a protocol `primary_cadence`
   member.
5. Absent file or unusable grant → `auth_required` with "Run `gemini` and sign in with Google".
   HTTP 401/403 → `auth_required`. Identity is the access token JWT `email` (else `sub`); a token
   that names no one is source-scoped. Newer Gemini CLI builds may migrate this file into the
   macOS Keychain; this collector reads the file the CLI still writes and documents as
   `oauth_creds.json`.

The Code Assist `retrieveUserQuotaSummary` weekly/five-hour meter used by Antigravity is not
called: that method answers `403` for this OAuth client.
