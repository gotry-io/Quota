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
  quota observations, sparse hourly Usage facts, and coverage/control metadata. It never runs a
  provider collector or exposes command execution.
- Rust local clients' Relay traffic is outbound HTTPS to the fixed origin `https://quota.gotry.io`.
  Only loopback HTTP overrides used by tests are allowed. Redirects are refused.
- QuotaBar launches only the signed `Contents/Helpers/quota-service` child built from the private
  `apps/menubar/helper` entry point and exchanges bounded stdin/stdout NDJSON. It does not resolve
  from `PATH`, run a shell, read service files, or implement provider/account networking.
- If the private helper cannot initialize its owner-only state, it keeps the IPC stream available and
  returns only a fixed, allowlisted error/recovery pair. The startup path never sends
  raw paths, filesystem errors, or diagnostic stderr to Swift. Each Swift request has a fixed
  fifteen-second deadline; timeout closes the child and all pending continuations so a later request can
  start a fresh helper.
- Quota Web receives normalized account data only. It does not discover local credentials or logs.

## Local credentials and identity

- Do not modify provider-owned credential files or Keychain entries. Provider refresh and rotation
  remain owned by the official provider CLI or application through the bounded strategies in
  [`provider-collection.md`](provider-collection.md).
- Optional API-key providers store secrets only in
  `$XDG_CONFIG_HOME/quotacli/providers.json` or `~/.config/quotacli/providers.json`: directory mode
  `0700`, file mode `0600`, no symlinks, shared owner-only lock, and same-directory atomic replace.
  QuotaBar Settings sends a new key only through the private child stdin; Swift never reads the file,
  persists the secret, places it on argv, or receives more than a masked tip. The Rust service
  validates and atomically rewrites the file.
- Operational local state is owner-only `state.sqlite` under the same released user configuration
  root. It lives outside the app bundle and survives ordinary reinstall. SQLite schema migrations are
  explicit; a newer schema fails closed and requires an app upgrade. The first Rust launch imports
  the released installation/session/cache/outbox/pricing JSON transactionally and removes source
  files only after the imported state is readable. The bounded migration lifecycle is defined in
  [ADR 0007](decisions/0007-rust-native-local-service.md). The shared
  `providers.json`/`ProviderConfigLock` path and OAuth `client_id=quotacli` remain current interfaces.
- QuotaBar's private service and Linux `quotacli` use the same owner-only configuration and state
  boundary. The Linux command is a foreground native binary; it is built and tested only and has no
  separate published credential or storage format.
- The installation ID is a random UUID. Relay stores only an account-scoped HMAC derived with
  `QUOTA_INSTALLATION_KEY`; the raw installation ID must not be logged or used as a global account
  identifier. Switching to a different Account sets a new upload lower bound so earlier local
  history is not copied into that Account.
- Account and device sessions are separate credential families. Persist each token with its
  audience, authoritative Account/Device IDs, Device generation, and absolute expiry. A response
  whose principal does not match local state fails closed.
- SQLite has one process owner for account/logout state, quota and Usage sequences, normalized cache,
  and outbox transactions. Logout first cancels the active refresh and atomically advances the
  session to `logout_pending`; subsequent account operations fail their session-epoch check even if
  token revocation must be retried offline.
- QuotaBar does not maintain a second report cache. The service's component state may contain masked
  provider labels, normalized quota, Usage totals, account/device display metadata, and cost
  coverage, but no provider secret or raw local source metadata. Account tokens never cross IPC.

## Account authentication

- GitHub is the only external identity provider. QuotaRelay is the confidential OAuth client; Rust
  local clients never embed the GitHub client secret and never receive a GitHub access token.
- Better Auth owns GitHub OAuth state, PKCE, callback validation, secure browser cookies, session
  expiry, and standard auth-route origin checks. The registered callback is
  `https://quota.gotry.io/api/auth/v2/callback/github`.
- GitHub login requests no email or repository scopes. Relay fetches only the bounded public profile
  from GitHub's fixed HTTPS API with a 20-second timeout. The numeric provider subject is HMACed
  before Better Auth stores it; provider access, refresh, and ID tokens are removed by database hooks
  and are never retained.
- Native browser login uses Authorization Code with PKCE S256, a random state, and a temporary
  `127.0.0.1` callback on a random port. The callback accepts the exact path/state and an
  authorization code only; it rejects tokens in query data and stops after success, cancellation, or
  timeout.
- QuotaBar uses that native browser path; the Linux `quotacli` uses the OAuth Device Authorization
  Grant and never opens a browser or loopback listener. Device/user codes are high entropy or
  human-readable as appropriate, single-use, short-lived, hashed at rest, and rate-limited. Polling
  implements `authorization_pending`, `slow_down`, denial, and expiry without printing device codes
  or session credentials.
- Successful native login issues an account-read token family and a current-device-write token
  family. Access tokens are short-lived; refresh tokens rotate with compare-and-swap so replay
  revokes or rejects the token family. Store only HMACs of server session and grant secrets.
- Better Auth browser sessions use secure, HttpOnly cookies. Raw secondary-storage keys are HMACed;
  values are AES-GCM encrypted with the key hash as associated data. Its database session table
  remains empty because Web session material uses that encrypted store.
- Better Auth validates trusted origins and session freshness for standard sign-in, sign-out, and
  Account deletion routes. Its user-deletion hook removes the Quota domain Account and cascading
  business data. Device authorization decisions and Delete Device additionally require a session
  created within ten minutes and an exact same-origin `Origin` (with same-origin Fetch Metadata when
  present); session refresh does not advance this authentication timestamp. Cross-account or unknown
  user codes return a generic not-found response.

## Upload, Usage, and deletion safety

- Quota and Usage uploads require the device token to match the envelope Device ID and current
  generation. Account tokens are read/manage only and cannot write device data; device tokens cannot
  read another Device or the Account aggregate.
- The service returns authoritative independent `next_snapshot_sequence` and
  `next_usage_sequence`. Clients never guess or reset a lost sequence to zero. A conflict fails
  closed because it can indicate a cloned local configuration.
- A snapshot retry reuses its sequence. A Usage retry reuses the immutable submission ID, sequence,
  generation, coverage, and rows. D1 receipts make accepted and duplicate outcomes explicit.
- Only a complete collector scan may create authoritative replacement coverage. Permission errors,
  unreadable/changed sources, record limits, malformed or unknown usage records, truncated tails,
  cancellation, or parser uncertainty make coverage partial. Partial coverage never deletes or
  replaces remote facts. On reads, `complete` describes only that returned half-open coverage
  interval; absent intervals remain visible gaps and no item claims that the entire query range is
  complete. The SQLite file index is the sole file-level invalidation mechanism and keeps changed
  files dirty after a partial parse so later hours cannot be silently accepted across an unresolved
  gap; no watcher or byte-checkpoint dependency is used.
- Outbox payloads contain allowlisted aggregate fields only. Source file IDs, byte offsets, record
  hashes, paths, raw events, and parser diagnostics remain local. Token/count invariants and payload,
  row, range, model, and dimension resource bounds are enforced by the v2 runtime schema before
  upload and by Relay again before persistence. Model identifiers are opaque provider text: preserve
  any non-empty bounded identifier, including punctuation and `unknown`; do not apply a naming
  whitelist or discard an otherwise valid fact because pricing is missing. Empty internal records
  with no tokens, billable tools, or nonzero source cost do not become Usage facts. Invalid records
  are isolated and counted in the local diagnostic report rather than rolling back a complete agent.
- Delete Device is distinct from logout. It transactionally revokes sessions, advances Device
  generation, records a precise watermark, deletes quota/Usage/coverage/receipt rows, and retains a
  minimal hidden tombstone. Old tokens and old-generation outbox entries are terminally rejected.
  The new generation may rebuild the watermark's UTC hour only after the local service filters raw event
  instants before the precise watermark. The account-scoped browser session remains signed in.
- Delete Account deletes its Devices and business data transactionally. Better Auth removes every
  indexed browser session for the deleted user, and Relay additionally rejects any cached Web
  principal whose business Account no longer exists. Local provider data remains owned by provider
  tools.
- Logout disables upload and revokes account/device sessions but intentionally retains the Device and
  remote facts. Re-login to the same Account may backfill locally readable history, including history
  created while signed out. Re-login revokes every prior session family for that installation before
  issuing new credentials; it never reactivates an old access or refresh token.

## Network, subprocesses, and diagnostics

- Provider credentials go only to the fixed official endpoints and documented provider-owned
  variants in [`provider-collection.md`](provider-collection.md). Do not import browser cookies or
  hidden WebView state.
- Spawn explicit executables with argument arrays. Never interpolate provider or user data into a
  shell command. Respect cancellation and terminate subprocesses on success, failure, timeout, and
  cancellation.
- Provider HTTP requests use a 20-second timeout and 1 MiB response-body limit. Provider JSON-RPC
  uses a 1 MiB stdout-line limit and 64 KiB stderr-capture limit. Private IPC limits every line to
  1 MiB, rejects malformed envelopes, exposes only stable error/recovery codes, and closes a corrupt
  connection. stdin EOF cancels service work and ends the child.
- Error output and logs use allowlisted codes and fixed recovery text. Never include raw HTTP bodies,
  subprocess stderr, JWTs, authorization codes, user/device secrets, installation IDs, raw GitHub
  subjects, full email addresses, or local source paths.
- The service owns one bounded diagnostic report for providers/quota, Usage, pricing, account, and
  synchronization. QuotaBar's Settings action and Linux `quotacli doctor` consume that same report;
  they never inspect local state or source logs themselves. The report may contain stable component
  statuses, bounded counters, safe recovery codes, and age/range summaries, but never paths,
  filenames, model lists, prompts, completions, session/conversation IDs, device IDs, credentials,
  tokens, raw provider responses, or parser excerpts. JSON and copied text are equally redacted.
  The complete-data and partial-merge rules are canonical in
  [ADR 0008](decisions/0008-data-integrity-and-diagnostics.md).
- Account/device display values and provider labels are untrusted presentation data: bound, mask
  where required, render as text rather than HTML, and exclude from security logs.
- Tests and fixtures use synthetic credentials and identities only. Tests that exercise local files
  use isolated temporary roots and clean them after completion.

## Relay storage and operations

- D1 is the only Relay store. Keep migrations explicit; never rewrite an applied migration. Review
  lifecycle, retention, and new retained fields as security-sensitive changes.
- Persist GitHub subjects, installation identities, token/grant secrets, session-store keys, and
  rate-limit subjects only as keyed hashes where equality is required. Better Auth session values
  are encrypted at rest. Persist plaintext native tokens only in the one successful issuance
  response, never in D1.
- Retained business data is limited to Account/Device lifecycle metadata, normalized quota
  observations, sparse hourly Usage facts, complete coverage, idempotency receipts, and bounded rate
  limits. Calculated cost is derived from the canonical catalog; it is not persisted as an invoice.
- Rate limits use fixed-window counters keyed by hashes of action and subject. Managed anonymous
  network subjects may use only Cloudflare's trusted connecting-IP metadata. Readiness probes and
  the hourly Worker schedule delete at most 100 expired rows from each credential table per run.
  Expired login grants, Better Auth encrypted sessions, and rate-limit counters are eligible
  immediately. Expired or revoked native account/device sessions remain for seven days so logout
  retries stay diagnosable without allowing those credentials to authenticate.
- Production keys (`GITHUB_CLIENT_SECRET`, `BETTER_AUTH_SECRET`, and
  subject/installation/session HMAC keys) are Cloudflare secrets and must not be tracked. Each key has
  a distinct purpose and must contain sufficient entropy; do not reuse one secret across purposes.
- Local builds, Linux `quotacli` build/tests, local D1 migrations, and Wrangler dry runs are
  verification. Do not deploy, apply remote migrations, publish packages, or change production
  secrets without explicit authorization.

## Failure behavior

- A provider failure never fabricates a quota or Usage value.
- Authentication, unavailable, unsupported, stale generation, deleted range, sequence conflict,
  partial coverage, malformed data, and unpriced cost remain distinct outcomes.
- Preserve last-known-good local display data on transient collection/network failures and mark its
  age or coverage; do not silently replace it with empty data.
- Unknown price, channel, model, tier, region, speed, or context is unpriced/partial, never `$0` and
  never resolved by fuzzy or cross-channel fallback.
