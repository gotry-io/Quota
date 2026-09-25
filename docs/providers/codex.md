# Codex

Catalog id `codex`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

1. Discover `$CODEX_HOME/auth.json` or `~/.codex/auth.json`.
2. Prefer a top-level `personal_access_token` / `personalAccessToken` when present:
   `GET https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami` with
   `Authorization: Bearer <PAT>`, then the same WHAM usage URL with
   `ChatGPT-Account-Id` from whoami (`chatgpt_account_id`). PAT identity comes from whoami, not a
   stale managed-workspace account id. Only HTTP 401/403 falls through to OAuth; a successful but
   malformed WHAM body is reported as an error.
3. An OAuth access token that is expired or within one minute of expiry is the first case where
   this build starts Codex. That token lives about ten days and only the Codex CLI can renew it,
   so a Mac that has not opened Codex in a fortnight would otherwise report an expired sign-in
   until someone does. The expiry is the `exp` in the access token's own JWT payload, decoded
   without checking the signature — the only claim wanted is a timestamp, and a forged one would
   buy a spawn rather than a reading. A token whose payload cannot be read counts as expiring:
   the CLI is the thing that can tell. The `id_token`'s one-hour expiry is not staleness; it is
   only read for identity. A personal-access-token-only `auth.json` is not renewable by anything
   and earns nothing.

   The second case is a WHAM reading that answers `auth_required` while the JWT still looks in
   date: ChatGPT can retire a token this build would still spend. Collection runs first; if
   that official rung is `auth_required` and this Mac holds an OAuth grant, the same bounded
   `codex app-server` runs once and collection runs again in the same refresh. A PAT-only file,
   or a Mac that never signed in, still starts nothing. The CLI's own gate remains that JWT
   `exp` — a spawn against a token the CLI still considers live may leave `auth.json`
   untouched, and an unchanged file is still the failure signal. The hour between attempts
   still applies, so a grant the CLI will not renew is not asked every five minutes.

   On the refresh worker, before collection, `codex -s read-only -a never app-server` is run once
   — the CLI's own words for a sandbox that cannot write and an approval policy that never asks.
   Which app-server request renews was settled by experiment against codex-cli 0.149.0, running
   against a copy of `auth.json` in a throwaway `CODEX_HOME`: **none of them does**. The refresh
   is on the program's startup path, and a run that sent no request at all still made the token
   round trip about 2.2 s in. Its gate is that same access-token `exp`, within about five minutes
   — a fixture whose `last_refresh` was thirty days old but whose token was still live was left
   untouched, with no refresh attempted, which is why this build does not spawn on that stamp the
   way CodexBar's eight-day rule does; it would be a spawn the CLI declines to act on for up to
   two days. `initialize` is sent anyway and its reply read, because that is how this build knows
   the program came up and is speaking the protocol; stdin then closes, and the CLI finishes the
   refresh it has already started before it leaves — 1.3–1.4 s to the reply, 2.6–2.9 s to exit.
   The handshake's `clientInfo` names this build, because the app-server puts that name in the
   `User-Agent` of the requests it makes on its own account.

   Bounded to eight seconds, about three times the observed run and the same figure CodexBar
   allows its own `initialize`, with 64 KiB of stdout read only to bound it, stderr discarded, and
   an empty private working directory. At most one attempt per hour, recorded in `cache.sqlite`
   metadata with the time and the outcome. Afterwards `auth.json` is read again: a
   token with days left continues to step 4 in the same refresh; a file the CLI emptied or removed
   is a Codex that signed itself out; anything else is `auth_required` with "Open Codex to refresh
   the sign-in". A rejected refresh leaves `auth.json` exactly as it was — observed with a bogus
   refresh token, which the endpoint answered `401 token_expired` and the CLI logged rather than
   wrote — so an unchanged file is the failure signal. `last_refresh` keeps one job: saying a
   renewal landed when the token that landed carries no readable expiry of its own. No Codex CLI on
   this Mac means no attempt and no record.
4. Prefer `GET https://chatgpt.com/backend-api/wham/usage` using the local OAuth access token and,
   when present, `ChatGPT-Account-Id`.
5. Map primary, secondary, additional, and dedicated `code_review_rate_limit` windows without
   changing their used/remaining meaning. Classify primary and secondary by reported duration
   (5-hour, weekly, or 30-day monthly) rather than by payload slot, so a Free-tier monthly
   window is not labeled **5 Hours**. Those headline windows carry `primary_cadence`
   (`five_hour` / `weekly` / `monthly`); Spark, Code Review, and other additional limits do
   not, even when they share a duration. Additional `limit_name` values are Title Case
   (`gpt-reserve` → **GPT Reserve**). Spark is **Codex Spark 5 Hours** / **Codex Spark Weekly**;
   Code Review is **Code Review 5 Hours** / **Code Review Weekly**. A null code-review object is
   absent, not malformed. When WHAM includes `credits` with `has_credits` and a finite
   `balance` (string or number), emit a balance-only **Balance (USD)** window
   (`remaining_value` / `value_unit: usd`). Unlimited or `has_credits: false` is omitted.
   `rate_limit_reset_credits.available_count` is a count of earned rate-limit resets, mapped as
   **Reset Credits** (`remaining_value` / `value_unit: count`); it is not a dollar wallet and is
   not redeemed here. When that count is above zero, one more request with the same credential
   and headers as the usage request it followed — `GET
   https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` — answers `{ credits: [{ id,
   reset_type, status, granted_at, expires_at?, title?, description? }], available_count,
   total_earned_count? }` (openai/codex `codex-rs/backend-client/src/types.rs`). Credits whose
   `status` is `available` and whose RFC 3339 `expires_at` is still ahead are grouped by that
   instant into the window's `expiries`, nearest first and at most sixteen instants. A null
   `expires_at` never expires. The count stays `available_count`: the list may be truncated,
   and a credit it does not describe is one the reader is told does not expire. A list request
   that fails, a body without `credits`, or a list describing more credits than were counted
   keeps the count-only window — a documented provider-owned fallback, not a failed reading.
   The `/consume` endpoint beside it redeems a credit and is never called.
6. Do not fall back after a successful but malformed response; report the parser failure instead.
7. If neither credential exists or both answer `auth_required`, and a stored ChatGPT
   [browser session](../provider-collection.md#browser-session) exists, read `GET https://chatgpt.com/api/auth/session`
   (then `/backend-api/me`) with the catalog session cookies. That document has to name an
   account — `account.id`, an email, or an `accessToken` — or the session is refused. A session
   `accessToken` is spent as Bearer on the same WHAM URL; otherwise the Cookie header goes to it
   directly, and to the reset-credit list after it (step 5). QuotaBar acquires those cookies from `chatgpt.com` / `www.chatgpt.com`: the
   `__Secure-`/`__Host-` NextAuth and Auth.js session tokens, their numbered chunks, and the
   optional `_account` context cookie. The fingerprint is the same `account_id` namespace the
   OAuth rung uses.

The local service never submits the Codex refresh token or writes `auth.json`, and never starts the
Codex CLI to read quota: step 3 asks Codex to renew a credential, never to report one, and a grant
still out of time afterwards is reported as the sign-in it is. Redeeming the refresh token here is
not an option even when the CLI cannot be reached — Codex rotates single-use refresh tokens, so a
second program spending one strands the CLI with a token the server has already retired. The PAT
requests present `originator: codex_cli_rs` and the Codex
CLI's own `User-Agent`, because the endpoint only honors personal access tokens from requests that
identify as that CLI. That agent is `codex_cli_rs/<version> (<platform> <os version>; <arch>)` with
the installed Codex version read as [Official CLI identity](../provider-collection.md#official-cli-identity) describes, and
`codex_cli_rs (<platform> <os version>; <arch>)` — no version field at all — when none could be
read. The OAuth rung sends no `User-Agent` of its own. Hidden WebView dashboard scraping and
reset-credit redemption are not used.
