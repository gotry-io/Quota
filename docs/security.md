# Security baseline

This document is the source of truth for Quota's trust, credential, transport, logging, and retained
data requirements. Architecture and product behavior are defined in
[`architecture.md`](architecture.md) and [ADR 0006](decisions/0006-managed-account-device-usage.md).

## Trust boundary

- Provider credentials and raw agent logs remain inside the Rust local-collection boundary owned by
  `packages/service` and used by QuotaBar's bundled service and Linux `quotacli`.
  Never upload,
  persist in Relay, print, or log provider access/refresh tokens, cookies, credential files, raw
  credential payloads, prompts, completions, tool payloads, local paths, session/conversation IDs, or
  authorization headers.
- QuotaRelay accepts only protocol-validated account/device authentication material, normalized
  quota observations, and sparse hourly Usage rows with the version of the scan behind each hour. It
  never runs a provider collector or exposes command execution. The daily rollup and the account
  summaries regroup those retained rows and add no prompt, completion, path, session, credential, or
  new identifier.
- Rust local clients' Relay traffic is outbound HTTPS to the fixed origin `https://quota.gotry.io`.
  Only loopback HTTP overrides used by tests are allowed. Redirects are refused.
- QuotaBar launches only the signed `Contents/Helpers/quota-service` child built from the private
  `apps/menubar/helper` entry point and exchanges bounded stdin/stdout NDJSON. It does not resolve
  from `PATH`, run a shell, read service files, or implement provider/account networking.
- If the private helper cannot initialize its owner-only state, it keeps the IPC stream available and
  returns only a fixed, allowlisted error/recovery pair to every request. The startup path never sends
  raw paths, filesystem errors, or diagnostic stderr to Swift. Requests are not on a clock. The helper
  announces `ready` when its state is open, and answers `ping` on the thread that reads stdin without
  taking a lock. A helper that leaves two consecutive pings unanswered is terminated, killed if it
  does not exit, and reaped before its pending continuations fail, so a later request starts a fresh
  helper and never a second live one.
- The deliberate macOS browser-session exception is acquisition only, it applies to Cursor alone,
  and it never starts without consent. Cursor is the only provider whose catalog row declares a
  browser session, because it is the only one with no CLI sign-in and no API key; every other
  provider's grant is renewed by the program that owns it, so no cookie store is opened for them.
  Before the first read QuotaBar shows a confirmation popup naming the browser, the permission
  macOS will ask for — Full Disk Access for Safari, the "Chrome Safe Storage" Keychain item for a
  Chrome-family browser — the exact hosts and Cookie names, the local database the accepted session
  is kept in until disconnected, and that none of it is uploaded. Declining opens nothing.
  SweetCookieKit then briefly reads catalog-allowlisted Cookie names from catalog-declared exact
  hosts in that one browser. Its logger is disabled; profile paths/store IDs and unrelated Cookies
  never cross private stdin or enter logs, diagnostics, UserDefaults, or Relay. A store macOS
  refuses is reported as `access_denied` with the browser name and a closed reason code, not as an
  absent session, and the underlying error — which names a store path — never leaves Swift. Swift
  retains candidates only in memory. Rust validates Cookie syntax and the provider account over
  fixed HTTPS, revalidates on commit, and persists only the accepted header plus an irreversible
  fingerprint and bounded masked label in owner-only SQLite. Failed validation/commit preserves the
  old session; disconnect removes it transactionally.
- Quota Web and the Quota iOS `quota-ios` account client receive normalized account data only. They
  do not discover local credentials or logs. Relay publishes no account projection without an
  authenticated principal.

## Local credentials and identity

- Do not modify provider-owned credential files or Keychain entries. Provider refresh and rotation
  remain owned by the official provider CLI or application through the bounded strategies in
  [`provider-collection.md`](provider-collection.md). Cursor.app `state.vscdb` is opened read-only
  for the `cursorAuth/accessToken` item; the service never writes Cursor files, never refreshes
  that JWT, and never persists the derived cookie unless the user later commits a browser session.
- Optional API-key providers store secrets only in
  `$XDG_CONFIG_HOME/quotacli/providers.json` or `~/.config/quotacli/providers.json`: directory mode
  `0700`, file mode `0600`, no symlinks, shared owner-only lock, and same-directory atomic replace.
  QuotaBar Settings sends a new key only through the private child stdin; Swift never reads the file,
  persists the secret, places it on argv, or receives more than a masked tip. The Rust service
  validates and atomically rewrites the file.
- Operational local state is two owner-only SQLite files under the same released user configuration
  root, both at schema v1 ([ADR 0021](decisions/0021-identity-store-and-disposable-cache.md)). They
  live outside the app bundle and survive ordinary reinstall.
  - `identity.sqlite` holds what this device cannot regenerate: installation id, session, upload
    identity, the hours this device still owes its Account with the scan revision each carries,
    the monotonic counter that revision comes from, stored provider browser sessions, and
    preferences. A newer
    identity schema fails closed and requires an app upgrade. An identity the service cannot open, or
    one missing its installation row, is deleted and recreated: the device becomes a new installation
    and is signed out. It is never partially recovered.
  - `cache.sqlite` holds everything derived from local log files, from Relay, or from the last
    refresh. Any SQLite error on it other than busy, disk-full, or I/O deletes the file and recreates
    it empty; the next refresh rebuilds it. Disk-full and I/O report `unavailable` and delete nothing.
  - A released `state.sqlite` hands over its installation, session, upload identity, browser
    sessions, and Usage upload preference once at startup, and is then removed with every sidecar
    beside it. Its staged uploads do not come across: they were requests in a contract this build
    no longer speaks, and the first scan recomputes the hours behind them. The service never writes a recovered SQL dump, never copies rows out of an
    image it could not read whole, never uploads either file, and never includes their paths in
    diagnostics.
  - The shared `providers.json`/`ProviderConfigLock` path and OAuth `client_id=quotacli` remain
    current collection interfaces. The registered `quota-ios` public client is a separate read-only
    Account interface.
- The cache holds only the typed diagnostic attempt fields defined by
  [ADR 0022](decisions/0022-minimal-diagnostics.md): kind, trigger, catalog-owned subject, start and
  completion instants, duration, outcome, and one allowlisted code. Completed rows are retained for
  seven days and capped at 5,000, pruned at open and hourly; running rows are finalized at the next
  open rather than pruned. A journal write that fails is counted on stderr and never blocks the
  collection, scan, upload, or sync it was recording.
- QuotaBar's private service and Linux `quotacli` use the same owner-only configuration and state
  boundary. The Linux command is a foreground native binary; it is built and tested only and has no
  separate published credential or storage format.
- The installation ID is a random UUID. Relay stores only an account-scoped HMAC derived with
  `QUOTA_INSTALLATION_KEY`; the raw installation ID must not be logged or used as a global account
  identifier. Switching to a different Account sets a new upload lower bound so earlier local
  history is not copied into that Account.
- Account reads answer a conditional request from a version stamp over the rows they project, never
  from a cached body. A 304 asserts only that those rows and the pricing and model catalog revisions
  are unchanged; it is issued to the authenticated principal that asked, and the responses are
  `private, no-cache` so no shared cache may hold them.
- Account and device sessions are separate credential families. Persist each token with its
  audience, authoritative Account/Device IDs, Device generation, and absolute expiry. A response
  whose principal does not match local state fails closed.
- SQLite has one process owner for account/logout state, upload identity, normalized cache,
  and outbox transactions. Logout first cancels the active refresh and atomically advances the
  session to `logout_pending`; subsequent account operations fail their session-epoch check even if
  token revocation must be retried offline.
- QuotaBar does not maintain a second report cache. The service's component state may contain masked
  provider labels, normalized quota, Usage totals, account/device display metadata, and cost
  coverage, but no provider secret or raw local source metadata. Account tokens never cross IPC.

## Account authentication

- GitHub is the only external identity provider. QuotaRelay is the confidential OAuth client; Rust
  local clients never embed the GitHub client secret and never receive a GitHub access token.
- Relay owns the browser sign-in end to end. `GET /api/auth/github/start` mints a 256-bit `state`
  and a PKCE verifier and puts both, with the same-origin path to return to, in one HMAC-signed
  `__Host-quota_oauth` cookie that expires in ten minutes. Both browser cookies carry the `__Host-`
  prefix, which a browser accepts only when the cookie is `Secure`, `Path=/`, and carries no
  `Domain`, so nothing able to write a cookie for a sibling `gotry.io` host can plant one on this
  origin. The registered callback is
  `https://quota.gotry.io/api/auth/github/callback`; it checks `state` against that cookie before
  spending the code, clears the cookie, and answers a callback with a missing, altered, expired, or
  mismatched cookie with 400 and no session. A code GitHub refuses to spend twice is the same 400.
- GitHub login requests no scope at all. Relay fetches only the bounded public profile from GitHub's
  fixed HTTPS API with a 20-second timeout and reads a numeric id and login name from it. The
  numeric subject is HMACed with `GITHUB_SUBJECT_KEY` and becomes the Account id; the GitHub access
  token is used for that one request and is never written anywhere.
- Native browser login uses Authorization Code with PKCE S256, a random state, and a temporary
  `127.0.0.1` callback on a random port. The callback accepts the exact path/state and an
  authorization code only; it rejects tokens in query data and stops after success, cancellation, or
  timeout. Its static no-store success page removes the query from browser history and requests that
  the browser close the callback tab, with text fallback when browser policy blocks self-close.
- QuotaBar uses that native browser path; the Linux `quotacli` uses the OAuth Device Authorization
  Grant and never opens a browser or loopback listener. Device/user codes are high entropy or
  human-readable as appropriate, single-use, short-lived, hashed at rest, and rate-limited. Polling
  implements `authorization_pending`, `slow_down`, denial, and expiry without printing device codes
  or session credentials.
- The registered `quota-ios` public client uses the same Authorization Code with PKCE S256 authorize
  route and the exact custom-scheme redirect `io.gotry.quota:/oauth/callback`. The token exchange
  rejects `installation_id`, `device_display_name`, and `platform`. Relay issues only an account
  token family with `account:read` and `session:revoke:self`. It never creates a Device, Device
  session, or installation record. Refresh is account-audience only and rotates
  with the same compare-and-swap rule. Those credentials use the `qia_`/`qiar_` prefixes and cannot
  be presented as `quotacli` `qa_`/`qar_` or `qd_`/`qdr_` tokens. These sessions cannot call Web-only
  management or destructive routes and cannot write snapshots or Usage. Quota iOS generates a
  cryptographically random verifier and state, verifies the exact callback and state, exchanges the
  code once, never sends a client secret, and never logs codes or tokens. `ASWebAuthenticationSession`
  stays in the app target. The access and refresh session is one Keychain item with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. UserDefaults may hold UI preferences only. The
  HTTPS client is fixed to `https://quota.gotry.io`, attaches Bearer only to that origin, refuses
  redirects, uses a 20-second timeout and a 1 MiB response limit, and performs one single-flight
  account refresh after 401. Last-good cache stores only the decoded Account summary, its fetched
  time, and the ETag that read is current at, in protected app storage. That validator is offered
  back only for the Account the current session belongs to. Its Account id must match the current Keychain session before the
  cache is displayed or used as a fallback; orphaned or mismatched cache is cleared. Logout clears
  the session and the cache.
- Quota iOS widgets use App Group `group.io.gotry.quota` only. The app target alone performs OAuth,
  holds the Keychain session, calls Relay — on screen and under the `io.gotry.quota.refresh`
  background app refresh, which asks for no window sooner than thirty minutes out and reuses that
  same session and cache rather than holding credentials of its own — and publishes a non-secret
  `WidgetSnapshot` through `ProtectedFileWidgetSnapshotStore` (atomic write,
  `completeFileProtectionUntilFirstUserAuthentication`, excluded from backup). The snapshot may
  contain display remaining-quota and Today token/cost fields; it must not contain account ids,
  device ids, fingerprints, tokens, or raw sources. The WidgetKit extension reads that
  file and reloads on app publish/clear only. It has no network, no Keychain, no Security framework
  usage, and no account wire/session modules. Missing, corrupt, or oversize files are treated as
  no-data. Logout, expired session, and absence of a trusted summary clear the snapshot. Both the
  app and `io.gotry.quota.widgets` signing identities need the App Group entitlement; provisioning
  profiles must include `group.io.gotry.quota`. See
  [ADR 0014](decisions/0014-nonsecret-ios-widget-snapshot.md).
- Successful collection-client login issues an account-read token family and a current-device-write
  token family. Access tokens are short-lived; refresh tokens rotate with compare-and-swap so replay
  revokes or rejects the token family. Store only HMACs of server session and grant secrets.
- A browser session is one `account_sessions` row with `client_kind = 'web'` — the same table the
  native clients use, so there is one place a session expires, is revoked, or is swept. It has no
  refresh token: `__Host-quota_session` is the whole credential, is `HttpOnly; Secure; SameSite=Lax;
  Path=/`, and is stored only as an HMAC under its own label, so it cannot be presented as a Bearer
  token and a native token cannot be presented as a cookie. JavaScript never reads it, and it
  appears in no log or response body other than its own `Set-Cookie`.
- On document navigations the Worker reads that cookie through `WebDocumentPort` so SvelteKit can
  paint the header username in the first HTML byte. A request carrying no cookie of that shape is
  answered without reaching D1. SvelteKit never receives `env.DB` or Relay secrets, and every
  document and SvelteKit load response is `Cache-Control: private, no-store`.
- `POST /api/auth/logout` revokes that row and clears the cookie, and requires an exact same-origin
  `Origin` (with same-origin Fetch Metadata when present). Delete Account, Delete Device, and device
  authorization decisions require the same origin check and a session authenticated within ten
  minutes; nothing advances that timestamp except signing in again. Cross-account or unknown user
  codes return a generic not-found response.

## Upload, Usage, and deletion safety

- Quota and Usage uploads require the device token to match the envelope Device ID and current
  generation. Account tokens are read/manage only and cannot write device data; device tokens cannot
  read another Device or the Account aggregate.
- The device profile endpoint accepts only the current Device's authenticated token and generation.
  It can update only that Device's bounded display name and platform; it cannot select a Device ID,
  read Account data, or change authorization state.
- An upload carries no sequence. A quota reading is placed by `(provider, fingerprint)` and ordered
  by the instant it was observed; an hour of Usage is replaced only by a scan whose `scan_version`
  is strictly newer than the stored one. A retry is therefore a comparison, and the response names
  every hour or provider it accepted and every one it ignored.
- Relay keeps one quota observation per `(device_id, provider, fingerprint)` and deletes an
  observation once it is seven days older than the moment it describes. Readers stop presenting a
  reading as current a day after it was observed, so retention only bounds what an account keeps
  from a device that stopped reporting a provider; Device or Account deletion remains the explicit
  removal boundary for everything else.
- The owner-only SQLite `usage_upload_enabled` preference defaults on. When disabled, local indexing,
  aggregation, and display continue, but the service neither stages nor drains Usage uploads. Pending
  outbox work remains local and resumes after re-enabling. Cached Account Usage is omitted from the
  private state response so the native Usage surface remains local-only. The preference does not delete facts that Relay
  already retained; Device or Account deletion remains the explicit removal boundary.
- No device uploads an assertion about its own health. An Account device list is derived from
  lifecycle timestamps Relay already witnessed — when the device last called, and when the newest
  reading it sent was taken — so no local diagnostic detail leaves this device at all.
- An uploaded hour states whether the scan behind it was complete. Permission errors,
  unreadable/changed sources, record limits, malformed or unknown usage records, truncated tails,
  cancellation, or parser uncertainty make that hour `partial`, and a managed read reports a period
  as partial when any hour behind it was. A partial hour still replaces the hour it names, because
  it is the newest reading of it; nothing beside it is touched. The SQLite file index is the sole
  file-level invalidation mechanism and keeps changed files dirty after a partial parse; no watcher
  or byte-checkpoint dependency is used.
- Outbox payloads contain allowlisted aggregate fields only. Source file IDs, byte offsets, record
  hashes, paths, raw events, and parser diagnostics remain local. Token/count invariants and payload,
  row, range, model, and dimension resource bounds are enforced by the current managed-data runtime
  schema before upload and by Relay again before persistence. Model identifiers are opaque provider text: preserve
  any non-empty bounded identifier, including punctuation and `unknown`; do not apply a naming
  whitelist or discard an otherwise valid fact because pricing is missing. Empty internal records
  with no tokens, billable tools, or nonzero source cost do not become Usage facts. Invalid records
  are isolated and counted in the local diagnostic report rather than rolling back a complete agent.
- Model catalog cleanup is report-only. The raw model value is never rewritten, lowercased, trimmed,
  deleted, or replaced in SQLite, upload payloads, or D1. Catalog aliases are explicit exact matches
  scoped by inference provider and optionally agent `client` and UTC date; ambiguous, invalid, or
  unknown values remain unresolved. A catalog revision can regroup historical rows on the next report, but it does
  not trigger source-file reparsing or fact rewrites. Pricing resolves the raw value independently,
  before grouping, so a normalized model may remain unpriced.
- Delete Device is distinct from logout. It transactionally revokes sessions, advances Device
  generation, records a precise watermark, deletes quota and Usage rows including the daily rollup,
  and retains a minimal hidden tombstone. Old tokens and old-generation outbox entries are
  terminally rejected.
  The new generation may rebuild the watermark's UTC hour only after the local service filters raw event
  instants before the precise watermark. The account-scoped browser session remains signed in.
- Delete Account is one Relay D1 batch: sessions, Devices, Device sessions, quota observations,
  hourly Usage, the daily rollup, login grants, and the Account row. Nothing survives as a
  tombstone, and the cookie is cleared in the same response. Local provider data remains owned by
  provider tools.
- Logout disables upload and revokes account/device sessions but intentionally retains the Device and
  remote facts. Re-login to the same Account may backfill locally readable history, including history
  created while signed out. Re-login revokes every prior session family for that installation before
  issuing new credentials; it never reactivates an old access or refresh token.

## Network, subprocesses, and diagnostics

- Provider credentials go only to the fixed official endpoints and documented provider-owned
  variants in [`provider-collection.md`](provider-collection.md). Except for the explicit
  catalog-allowlisted browser-session acquisition above, do not import browser Cookies. Hidden
  WebView state is never an authentication source.
- Collection starts exactly one process: `/usr/bin/security` to read Claude Code's Keychain grant,
  once per refresh and shared by discovery and collection. No collector runs a provider's CLI, and a
  provider grant that has expired is reported as `auth_required` rather than renewed by driving the
  program that owns it. Spawn explicit executables with argument arrays. Never interpolate provider
  or user data into a shell command. Respect cancellation and terminate subprocesses on success,
  failure, timeout, and cancellation.
- Provider HTTP requests use a 20-second timeout and 1 MiB response-body limit; browser-session
  account validation tightens that timeout to ten seconds so it completes inside private IPC. The
  Keychain lookup is bounded to ten seconds and 1 MiB, and its secret is held in a type whose
  `Debug` is redacted so the collection context that carries it cannot print it. Private IPC limits
  every line to 1 MiB, rejects malformed envelopes, exposes only stable error/recovery codes, and
  closes a corrupt connection. stdin EOF cancels service work and ends the child.
- Error output and logs use allowlisted codes and fixed recovery text. Never include raw HTTP bodies,
  subprocess stderr, JWTs, authorization codes, user/device secrets, installation IDs, raw GitHub
  subjects, full email addresses, or local source paths.
- The service owns one bounded diagnostic report for the four Quota/Usage surfaces and the sources
  behind them. QuotaBar's Support page and Linux `quotacli doctor` consume that same report; they
  never inspect local state or source logs, and they never map a code to copy of their own. The
  report may contain fixed statuses, timestamps, recovery codes, catalog-owned `provider:<id>` or
  `agent:<id>` subjects with an optional catalog-owned `source_id`, the service's own fixed names for
  its non-provider paths, and the fixed safe sentences the service writes. Account or device display
  names and IDs never become diagnostic identity. Paths, filenames, model names or lists, prompts,
  completions, session/conversation/installation/device IDs, credentials, tokens, raw provider
  responses, and parser excerpts are forbidden. JSON and copied text are equally redacted. A single
  replaceable SQLite snapshot retains only the last completed report; intermediate component values
  must never be serialized. The recent work a copied report lists is assembled from the typed local
  journal, not logs, and is capped at 100 entries. The complete-data and partial-merge rules are
  canonical in [ADR 0008](decisions/0008-data-integrity-and-diagnostics.md); the report contract,
  attempt retention, and redaction are canonical in
  [ADR 0022](decisions/0022-minimal-diagnostics.md).
- Account/device display values and provider labels are untrusted presentation data: bound, mask
  where required, render as text rather than HTML, and exclude from security logs.
- Model diagnostics may expose only bounded resolved/unresolved/ambiguous counts and catalog-revision
  availability; they must never expose model names or aliases.
- Tests and fixtures use synthetic credentials and identities only. Tests that exercise local files
  use isolated temporary roots and clean them after completion.

## Relay storage and operations

- D1 is the only Relay store. Keep migrations explicit; never rewrite an applied migration. Review
  lifecycle, retention, and new retained fields as security-sensitive changes.
- Treat protocol routing as a trust boundary. V2 writes must pass the closed v2 provider/agent
  schemas. Relay serves one managed data contract, so a read never has to exclude what a retired
  contract could not carry.
- Persist GitHub subjects, installation identities, token/grant secrets, session-store keys, and
  rate-limit subjects only as keyed hashes where equality is required. Persist plaintext native
  tokens only in the one successful issuance response, never in D1, and browser session tokens only
  in their `Set-Cookie`.
- Retained business data is limited to Account/Device lifecycle metadata, normalized quota
  observations, sparse hourly Usage rows, the daily rollup derived from them, and bounded rate
  limits. Nothing is kept to recognize a retry: an hour's `scan_version` is the check, and a
  re-sent hour is ignored rather than written twice. Calculated cost is derived from the canonical
  catalog; it is not persisted as an invoice.
- Rate limits use fixed-window counters keyed by hashes of action and subject. Managed anonymous
  network subjects may use only Cloudflare's trusted connecting-IP metadata. Readiness probes and
  the hourly Worker schedule delete at most 100 expired rows from each credential and observation
  table per run; consuming a limit collects at most 100 expired counters inline. Every
  such delete addresses whole rows, so expiring one fixed window never resets a subject's live one.
  Expired login grants and rate-limit counters are eligible immediately. Expired or revoked account
  and device sessions remain for seven days so logout retries stay diagnosable without allowing
  those credentials to authenticate.
- Production keys (`GITHUB_CLIENT_SECRET` and the subject/installation/session HMAC keys) are
  Cloudflare secrets and must not be tracked. Each key has a distinct purpose and must contain
  sufficient entropy; do not reuse one secret across purposes. `QUOTA_SESSION_HASH_KEY` covers every
  credential Relay stores by equality, including the browser session token and the signature on the
  `__Host-quota_oauth` handoff cookie, each under its own domain label.
- Local builds, Linux `quotacli` build/tests, local D1 migrations, and Wrangler dry runs are
  verification. Do not deploy, apply remote migrations, publish packages, or change production
  secrets without explicit authorization.

## Failure behavior

- A provider failure never fabricates a quota or Usage value.
- Authentication, unavailable, unsupported, stale generation, an ignored hour, an incompletely
  scanned hour, malformed data, and unpriced cost remain distinct outcomes.
- Preserve last-known-good local display data on transient collection/network failures and mark its
  age or coverage; do not silently replace it with empty data.
- Unknown price, channel, model, tier, region, speed, or context is unpriced/partial, never `$0` and
  never resolved by fuzzy or cross-channel fallback.
