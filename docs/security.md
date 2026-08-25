# Security baseline

This document is the source of truth for Quota's trust, credential, transport, logging, and retained
data requirements. Boundaries and data paths live in [`architecture.md`](architecture.md), and the
managed account boundary in [ADR 0006](decisions/0006-managed-account-device-usage.md).

## Trust boundary

- Provider credentials and raw agent logs stay inside the Rust local-collection boundary owned by
  `packages/service`. Never upload, persist in Relay, print, or log provider tokens, cookies,
  credential files or payloads, prompts, completions, tool payloads, local paths, session or
  conversation IDs, or authorization headers.
- QuotaRelay accepts only protocol-validated authentication material, normalized quota observations,
  and sparse hourly Usage rows carrying the version of the scan behind each hour. It never runs a
  collector or exposes command execution, and its rollups regroup retained rows without adding a
  prompt, completion, path, session, credential, or identifier.
- Every first-party Relay client — Rust and Swift alike — is fixed to the origin
  `https://quota.gotry.io`, attaches Bearer only there, refuses redirects, and bounds each request
  to twenty seconds and 1 MiB. Only loopback HTTP overrides used by tests are allowed.
- QuotaBar launches only the signed `Contents/Helpers/quota-service` child built from the private
  `apps/menubar/helper` entry point and exchanges bounded stdin/stdout NDJSON, never resolving from
  `PATH`, running a shell, reading service files, or doing provider or account networking. A helper
  that cannot initialize its state keeps the IPC stream available and answers every request with a
  fixed allowlisted error/recovery pair; the startup path never sends raw paths, filesystem errors,
  or stderr to Swift. A helper judged gone is terminated, killed if it will not exit, and reaped
  before its pending requests fail.
- The macOS browser-session exception is acquisition only, applies to Cursor alone, and never starts
  without the consent popup in [ADR 0010](decisions/0010-provider-browser-session-auth.md).
  SweetCookieKit's logger is disabled; profile paths, store IDs, the error behind a refused store,
  and unrelated Cookies never cross private stdin or enter logs, diagnostics, UserDefaults, or
  Relay, and Swift holds candidates only in memory. Rust revalidates the account on commit and
  persists only the accepted header plus an irreversible fingerprint and masked label; failed
  validation keeps the old session and disconnect removes it transactionally.
- Quota Web and Quota iOS receive normalized account data only, never local credentials or logs.

## Local credentials and identity

- Do not modify provider-owned credential files or Keychain entries; refresh stays owned by the
  provider's own program ([`provider-collection.md`](provider-collection.md)). Cursor.app
  `state.vscdb` is opened read-only for `cursorAuth/accessToken`: the service never writes Cursor
  files, refreshes that JWT, or persists the derived cookie unless a browser session is committed.
- Optional API-key providers store secrets only in `$XDG_CONFIG_HOME/quotacli/providers.json` or
  `~/.config/quotacli/providers.json`: mode `0700` directory, `0600` file, no symlinks, shared
  owner-only lock, same-directory atomic replace. QuotaBar sends a new key only through the private
  child stdin; Swift never reads the file, persists the secret, puts it on argv, or receives more
  than a masked tip.
- Operational local state is two owner-only SQLite files under the released user configuration root,
  outside the app bundle and surviving a reinstall
  ([ADR 0021](decisions/0021-identity-store-and-disposable-cache.md)). A newer `identity.sqlite`
  schema fails closed and asks for an app upgrade; one the service cannot open, or one missing its
  installation row, is deleted and recreated, so the device becomes a new signed-out installation,
  never partially recovered. The service never writes a recovered SQL dump, copies rows out of an
  image it could not read whole, uploads either file, or names their paths in diagnostics.
- The cache holds only the typed attempt fields of
  [ADR 0022](decisions/0022-minimal-diagnostics.md), seven days and 5,000 rows; a failed journal
  write is counted on stderr and blocks nothing.
- QuotaBar's private service and Linux `quotacli` share one owner-only configuration and state
  boundary; the Linux command is a foreground binary with no separate credential or storage format.
- The installation ID is a random UUID; Relay stores only an account-scoped HMAC of it derived with
  `QUOTA_INSTALLATION_KEY`, the raw ID is never logged or used as a global identifier, and switching
  Account sets a new upload lower bound.
- Account reads answer a conditional request from a version stamp over the rows they project, never
  from a cached body. A 304 asserts only that those rows and the catalog revisions are unchanged, is
  issued to the principal that asked, and is `private, no-cache` so no shared cache may hold it.
- Account and device sessions are separate credential families. Persist each token with its
  audience, authoritative IDs, Device generation, and absolute expiry; a response whose principal
  does not match local state fails closed.
- SQLite has one process owner for account state, upload identity, normalized cache, and outbox
  transactions. Logout cancels the active refresh and atomically advances the session to
  `logout_pending`, so later account operations fail their session-epoch check even if revocation is
  retried offline.
- QuotaBar keeps no second report cache. Component state may carry masked provider labels,
  normalized quota, Usage totals, display metadata, and cost coverage, but no secret or raw source
  metadata, and account tokens never cross IPC.

## Account authentication

- QuotaRelay is the confidential GitHub OAuth client. Local clients never embed its secret and never
  receive a GitHub access token, and login requests no scope at all.
- Relay owns the browser sign-in end to end ([ADR 0025](decisions/0025-one-session-system.md)). Both
  cookies take the `__Host-` prefix, the ten-minute HMAC-signed handoff carries the `state` and PKCE
  verifier, and a missing, altered, expired, or mismatched handoff — or a code GitHub will not spend
  twice — is 400 with no session. Relay reads only the bounded public GitHub profile over fixed
  HTTPS, HMACs the numeric subject with `GITHUB_SUBJECT_KEY` into the Account id, and never writes
  the GitHub access token anywhere.
- Native browser login uses Authorization Code with PKCE S256, a random state, and a temporary
  `127.0.0.1` callback on a random port that accepts the exact path, state, and an authorization
  code only, rejects tokens in query data, stops after success, cancellation, or timeout, and
  answers with a static no-store page that drops the query from history. Linux `quotacli` uses the
  Device Authorization Grant and opens no browser or listener: codes are high entropy or
  human-readable as appropriate, single-use, short-lived, hashed at rest, and rate-limited, and
  polling handles `authorization_pending`, `slow_down`, denial, and expiry without printing codes.
- The `quota-ios` client's authority is scoped by
  [ADR 0013](decisions/0013-readonly-ios-account-client.md) and its widget snapshot by
  [ADR 0014](decisions/0014-nonsecret-ios-widget-snapshot.md). `ASWebAuthenticationSession` stays in
  the app target, the session is one Keychain item with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, UserDefaults holds UI preferences only, and the
  client makes one single-flight refresh after 401. Its last-good cache holds only the decoded
  summary, its fetch time, and its ETag in protected storage, is offered back only for the Account
  the current Keychain session owns, and is cleared when orphaned, mismatched, or signed out. The
  app target alone performs OAuth, holds the session, and calls Relay; the extension has no network,
  Keychain, Security, or account modules.
- Access tokens are short-lived, a replayed refresh revokes its whole token family, and only HMACs
  of server session and grant secrets are stored.
- A browser session has no refresh token: `__Host-quota_session` is the whole credential, is
  `HttpOnly; Secure; SameSite=Lax; Path=/`, and is stored only as an HMAC under its own label, so it
  cannot be presented as a Bearer token nor a native token as a cookie. JavaScript never reads it,
  and it appears in no log or response body but its own `Set-Cookie`.
- A document navigation carrying no cookie of that shape is answered without reaching D1, SvelteKit
  never receives `env.DB` or Relay secrets, and every document and load response is `Cache-Control:
  private, no-store`.
- `POST /api/auth/logout` revokes that row and clears the cookie, and requires an exact same-origin
  `Origin` with same-origin Fetch Metadata when present. Delete Account, Delete Device, and device
  authorization decisions require that same check and a session authenticated within ten minutes,
  which nothing advances except signing in again. Cross-account or unknown user codes return a
  generic not-found.

## Upload, Usage, and deletion safety

- Quota and Usage uploads require the device token to match the envelope Device ID and current
  generation. Account tokens are read or manage only and cannot write device data; device tokens
  cannot read another Device or the Account aggregate. The device profile endpoint takes only the
  current Device's token and generation and updates only that Device's bounded display name and
  platform: it cannot select a Device ID, read Account data, or change authorization.
- An upload carries no sequence: a reading is placed by `(provider, fingerprint)` and ordered by
  when it was observed, an hour is replaced only by a strictly newer `scan_version`, and the
  response names what it accepted and ignored.
- Relay keeps one quota observation per `(device_id, provider, fingerprint)` and deletes it seven
  days after the moment it describes. Readers stop presenting a reading as current a day after it
  was observed, so retention only bounds what an account keeps from a device that stopped reporting;
  deletion is the explicit removal boundary.
- Disabling the owner-only `usage_upload_enabled` preference deletes nothing Relay already retained,
  and no device uploads an assertion about its own health, so no diagnostic detail leaves it.
- An uploaded hour states whether its scan was complete: permission errors, unreadable or changed
  sources, record limits, malformed records, truncated tails, cancellation, or parser uncertainty
  make it `partial`, and it still replaces the hour it names because it is the newest reading of it.
- Outbox payloads carry allowlisted aggregate fields only; file IDs, byte offsets, record hashes,
  paths, raw events, and parser diagnostics stay local, and payload, row, range, model, and
  dimension bounds plus token invariants are checked by the managed-data schema before upload and by
  Relay before persistence. Model identifiers are opaque provider text: preserve any non-empty
  bounded identifier, punctuation and `unknown` included, never rewrite or replace the raw value,
  and never discard a valid fact because pricing is missing. Records with no tokens, billable tools,
  or source cost do not become Usage facts, and an invalid record is isolated and counted in the
  diagnostic report rather than rolling back an agent.
- The three lifecycle verbs are defined by
  [ADR 0006](decisions/0006-managed-account-device-usage.md). This is their enforcement. Delete
  Device runs in one transaction, old tokens and old-generation outbox entries are terminally
  rejected after it, the new generation rebuilds the watermark's UTC hour only once raw instants
  before it are filtered out, and the browser session stays signed in. Delete Account leaves no
  tombstone and clears the cookie in the same response.
- Logout disables upload and revokes sessions but retains the Device and its remote facts. Re-login
  may backfill locally readable history, including history created while signed out; it revokes
  every prior session family for that installation first and never reactivates an old token.

## Network, subprocesses, and diagnostics

- Provider credentials go only to the fixed endpoints in
  [`provider-collection.md`](provider-collection.md); apart from the acquisition above, do not
  import browser Cookies, and hidden WebView state is never an authentication source.
- Collection starts exactly one process: `/usr/bin/security`, reading Claude Code's Keychain grant
  once per refresh for both discovery and collection. No collector runs a provider's CLI, and an
  expired grant is reported as `auth_required` rather than renewed by driving its owner. Spawn
  explicit executables with argument arrays, never interpolate provider or user data into a shell,
  and terminate subprocesses on success, failure, timeout, and cancellation.
- Provider HTTP uses the same twenty-second, 1 MiB bounds; browser-session validation tightens the
  timeout to ten seconds so it finishes inside private IPC, and the Keychain lookup is bounded the
  same way with its secret in a type whose `Debug` is redacted. Private IPC limits each line to 1
  MiB, rejects malformed envelopes, exposes only stable codes, and closes a corrupt connection.
- Error output and logs use allowlisted codes and fixed recovery text, never raw HTTP bodies,
  subprocess stderr, JWTs, authorization codes, secrets, installation IDs, raw GitHub subjects, full
  email addresses, or local source paths.
- The service owns one bounded diagnostic report, which QuotaBar's Support page and Linux `quotacli
  doctor` consume without inspecting local state or source logs. It may carry fixed statuses,
  timestamps, recovery codes, catalog-owned `provider:<id>` or `agent:<id>` subjects with an
  optional `source_id`, the service's fixed names for its non-provider paths, and the safe sentences
  it writes. Display names and IDs never become diagnostic identity; paths, filenames, model names,
  prompts, completions, session, conversation, installation, and device IDs, credentials, tokens,
  raw responses, and parser excerpts are forbidden, and JSON and copied text are equally redacted.
  Intermediate component values are never serialized, and a copied report's recent work comes from
  the typed journal rather than logs ([ADR 0022](decisions/0022-minimal-diagnostics.md)).
- Display values and provider labels are untrusted presentation data: bound them, mask where
  required, render as text rather than HTML, and keep them out of security logs. Model diagnostics
  expose only bounded resolved, unresolved, and ambiguous counts and catalog-revision availability.
- Tests and fixtures use synthetic credentials and isolated temporary roots, cleaned afterwards.

## Relay storage and operations

- Keep D1 migrations explicit, never rewrite an applied one, and review lifecycle, retention, and
  new retained fields as security-sensitive. Protocol routing is a trust boundary: v2 writes pass
  the closed v2 provider and agent schemas, and one managed contract is served, so a read excludes
  nothing a retired one could not carry.
- Persist GitHub subjects, installation identities, token and grant secrets, session-store keys, and
  rate-limit subjects only as keyed hashes where equality is required. Plaintext native tokens
  appear only in the one successful issuance response, never in D1, and browser session tokens only
  in their `Set-Cookie`.
- Retained business data is limited to Account and Device lifecycle metadata, normalized quota
  observations, sparse hourly Usage rows, the daily rollup, and bounded rate limits. Nothing is kept
  to recognize a retry: an hour's `scan_version` is the check. Cost is derived from the canonical
  catalog, never persisted as an invoice.
- Rate limits use fixed-window counters keyed by hashes of action and subject, and an anonymous
  network subject may come only from Cloudflare's trusted connecting-IP metadata. Readiness probes
  and the hourly schedule delete at most 100 expired rows per credential and observation table per
  run, and consuming a limit collects at most 100 expired counters inline; each delete addresses
  whole rows, so expiring one window never resets a live one. Expired grants and counters are
  eligible at once; expired or revoked sessions remain seven days so logout retries stay
  diagnosable.
- Production keys (`GITHUB_CLIENT_SECRET` and the subject, installation, and session HMAC keys) are
  Cloudflare secrets, are never tracked, and are never reused across purposes.
  `QUOTA_SESSION_HASH_KEY` covers every credential Relay stores by equality — browser session token
  and `__Host-quota_oauth` signature included — each under its own domain label.

## Failure behavior

- A provider failure never fabricates a quota or Usage value. Authentication, unavailable,
  unsupported, stale generation, an ignored hour, an incompletely scanned hour, malformed data, and
  unpriced cost remain distinct outcomes.
- Preserve last-known-good display data on a transient collection or network failure and mark its
  age rather than replacing it with empty data.
- Unknown price, channel, model, tier, region, speed, or context is unpriced or partial, never `$0`
  and never resolved by fuzzy or cross-channel fallback.
