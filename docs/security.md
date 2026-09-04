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
- The macOS browser-session exception is acquisition only, covers the five providers whose catalog
  entry declares `browser_session` — Codex, Claude, Grok, Kimi, and Cursor — and never starts without
  the consent popup in [ADR 0010](decisions/0010-provider-browser-session-auth.md). Full Disk Access
  is probed only after that consent, and only as a directory-readable check, never by parsing
  cookies. Cursor is the
  only one marked `exclusive`, because a stored session is the only credential it has.
  SweetCookieKit's logger is disabled; profile paths, store IDs, the error behind a refused store,
  and unrelated Cookies never cross private stdin or enter logs, diagnostics, UserDefaults, or
  Relay, and Swift holds candidates only in memory. Rust revalidates each account and persists
  the accepted headers plus irreversible fingerprints and masked labels. Turning Browser Sign-in
  off deletes those rows transactionally.
- Quota Web and Quota iOS receive normalized account data only, never local credentials or logs.

- The local service's HTTP client follows no redirects and caps bodies at 1 MiB. On macOS it
  speaks TLS through Secure Transport (`reqwest` `native-tls`) rather than rustls: cursor.com's
  edge (Vercel) fingerprints the handshake and answers rustls with a 403 HTML page whatever the
  cookie says, which this service would otherwise report as `auth_required`. Linux builds keep
  rustls. Certificate validation is the platform's in both cases.

## Local credentials and identity

- Do not modify provider-owned credential files or Keychain entries; refresh stays owned by the
  provider's own program ([`provider-collection.md`](provider-collection.md)). Cursor.app
  `state.vscdb` is opened read-only for `cursorAuth/accessToken`: the service never writes Cursor
  files, refreshes that JWT, or persists the derived cookie unless a browser session is committed.
- Optional API-key providers store secrets only in `$XDG_CONFIG_HOME/quota/providers.json` or
  `~/.config/quota/providers.json`: mode `0700` directory, `0600` file, no symlinks, shared
  owner-only lock, same-directory atomic replace. QuotaBar sends a new key only through the private
  child stdin; Swift never reads the file, persists the secret, puts it on argv, or receives more
  than a masked tip.
- On first run the service adopts the root it was released under beside its own — the released
  image's identity, session, upload context, and browser sessions, and its `providers.json` under
  the same `0700`/`0600` rules — then removes what it read. It looks only beside the root it was
  given, so an isolated run reads nothing else.
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
- The installation ID is a random UUID; Relay stores only an account-scoped HMAC of it derived with
  `QUOTA_INSTALLATION_KEY`, and the raw ID is never logged or used as a global identifier. Every
  account signed in on this Mac is owed every hour it still holds; the only upload lower bound is
  the deletion watermark Relay states for a deleted Device.
- Account reads answer a conditional request from a version stamp over the rows they project, never
  from a cached body. A 304 asserts only that those rows and the catalog revisions are unchanged, is
  issued to the principal that asked, and is `private, no-cache` so no shared cache may hold it.
- A client holds one session, and the scopes on its row are what it may do
  ([ADR 0027](decisions/0027-one-token-per-client.md)). Persist its token with the authoritative
  IDs, the Device generation it opened at, and an absolute expiry; a response whose principal does
  not match local state fails closed.
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
  answers with a static no-store page that drops the query from history. The service owns PKCE, the
  listener, and the exchange; QuotaBar opens the URL
  ([ADR 0025](decisions/0025-one-session-system.md)). It is the only grant a collection client has:
  there is no headless or second-screen flow to authorize.
- The `quota-ios` client's authority is scoped by
  [ADR 0013](decisions/0013-readonly-ios-account-client.md) and its widget snapshot by
  [ADR 0014](decisions/0014-nonsecret-ios-widget-snapshot.md). `ASWebAuthenticationSession` stays in
  the app target, the session is one Keychain item with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, UserDefaults holds UI preferences only, and the
  client makes one single-flight refresh after 401. Its last-good cache holds only the decoded
  summary, its fetch time, and its ETag in protected storage, is offered back only for the Account
  the current Keychain session owns, and is cleared when orphaned, mismatched, or signed out. The
  app target alone performs OAuth, holds the session, and calls Relay; the extension has no network,
  Keychain, Security, or account modules. The widget snapshot may carry a locally salted
  `selection_id`; the 32-byte salt lives in the app-private Keychain with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never in the App Group, so the App Group
  file sees only the irreversible id. Logout deletes the salt so prior deep links and widget Intent
  configuration fall back to Overview.
- A collection or viewer login issues one access/refresh family, and what it may do is the scopes
  on its own session row ([ADR 0027](decisions/0027-one-token-per-client.md)). Access tokens are
  short-lived, a replayed refresh revokes its whole token family, and only HMACs of server session
  and grant secrets are stored. Each client's tokens are hashed under a domain its prefix names, so
  a token issued to one cannot be presented as another's.
- A browser session has no refresh token: `__Host-quota_session` is the whole credential, is
  `HttpOnly; Secure; SameSite=Lax; Path=/`, and is stored only as an HMAC under its own label, so it
  cannot be presented as a Bearer token nor a native token as a cookie. JavaScript never reads it,
  and it appears in no log or response body but its own `Set-Cookie`.
- A document navigation carrying no cookie of that shape is answered without reaching D1, SvelteKit
  never receives `env.DB` or Relay secrets, and every document and load response is `Cache-Control:
  private, no-store`.
- `POST /api/auth/logout` revokes that row and clears the cookie, and requires an exact same-origin
  `Origin` with same-origin Fetch Metadata when present. Delete Account and Delete Device require
  that same check, `account:manage`, and a session authenticated within ten minutes, which nothing
  advances except signing in again — so only a browser can make either. `POST /oauth/v2/revoke`
  needs no scope: presenting the refresh token is the proof, and it ends the whole family and signs
  out the Device the session spoke for.

## Upload, Usage, and deletion safety

- Quota and Usage uploads require `device:write` and a session whose Device ID and generation match
  the envelope. That scope is only ever granted to a session that names a Device, and such a session
  stops authorizing the moment its Device moves past the generation it was opened at, so Delete
  Device ends every token issued before it. A session that names no Device — the browser's, the iOS
  viewer's — cannot write device data at all. The device profile endpoint writes only the Device its
  own session names, and only that Device's bounded display name and platform: it cannot select a
  Device ID, read Account data, or change authorization.
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
- A refresh starts three kinds of process and no others, and no collector starts any of them: the
  two that drive a provider CLI run on the refresh worker before collection, so nothing on the
  five-minute timer can spawn on its own account.
  - `/usr/bin/security` reads Claude Code's Keychain grant once per refresh, for both discovery and
    collection, plus once more when a renewal actually ran — a renewal replaces a credential this
    refresh may already have read, so the memo taken before it ran describes the grant it replaced.
    A read that fails costs a second call which asks only whether the entry is there: that is what
    separates a Mac that was never signed in from one that is not allowed to read the secret, and
    the answer decides whether the reader is offered "sign in" or "grant access". Neither call is
    made again once the refresh has its answer.
  - `<binary> --version` reads the installed Claude Code or Codex version the request headers claim,
    only for a provider this device holds a sign-in for, and only when the binary's real path, size,
    and mtime differ from the fingerprint stored in the disposable cache — so a given installed
    binary is run at most once, and never more than once an hour. Bounded to five seconds and 4 KiB
    of stdout, no stdin, stderr discarded, only `HOME` and `PATH` in its environment, and the same
    empty owner-only working directory a renewal gets. A failed or
    absent read leaves the header on its fallback constant, and collection neither waits on it nor
    fails because of it.
  - **The renewal** asks the CLI that owns a sign-in to renew it, and only when the credential on
    disk is already expired or within a minute of expiry. It is one mechanism serving three
    providers rather than three rungs: a provider states the program, its arguments, which of this
    device's variables the child inherits, whether the sign-in is expiring, whether it is usable,
    and how to talk to the child; the binary lookup, the working directory, the environment, the
    spawn, the floor, and the verdict are shared, and there is exactly one place in the provider
    sources where any of these programs is started.
    - `claude mcp list`, additionally requiring a `claudeAiOauth` `refreshToken` in the entry — one
      with no refresh token cannot be renewed by anything, and a Keychain item holding only
      `mcpOAuth` is not a Claude sign-in, so neither is worth a spawn. It is the invocation that
      reaches Claude Code's own refresh path without asking for anything else; its one side effect
      is that it health-checks the MCP servers this device approved, which the empty working
      directory narrows to the user-scoped ones in `~/.claude.json` and the deadline bounds.
    - `codex -s read-only -a never app-server`, additionally requiring an OAuth grant rather than a
      personal access token, whose expiry is the `exp` in the access token's own JWT payload —
      read as a timestamp, with no signature check, because a forged one would buy a spawn rather
      than a reading, and an unreadable one counts as expiring. The Codex CLI renews on its own
      startup path rather than in answer to any request; `initialize` is sent to know the program
      came up, its reply read, and stdin then closed so the CLI can finish and leave.
    - `grok agent stdio`, which asks for the `cached_token` method and no other: the CLI's
      interactive sign-in prints a device code and waits for a person, and nothing on a timer may
      start that.
    - At most one attempt an hour per provider whatever the outcome, recorded in the disposable
      cache — on time alone, so a binary that rewrites itself cannot buy an earlier spawn. Bounded
      to the CLI's own deadline (10 s for Claude Code, 8 s for Codex, 5 s for Grok) and 64 KiB of
      stdout, stderr discarded, an empty owner-only directory created for the run as its working
      directory, and an environment of `HOME`, `PATH`, the one variable naming that provider's
      credential home, and whatever fixed pair that provider's plan names — Claude Code's is
      `TERM=dumb`, so its CLI does not try to draw a terminal into a pipe. The outcome is judged by re-reading the credential, never by an exit
      status; a credential the CLI emptied or removed is a program that signed itself out, which is
      a different answer from one that could not renew. The service never submits a refresh token
      itself and never writes a provider's credential file or Keychain item — Codex's refresh
      tokens are single-use, so a second program spending one would strand the CLI with a token the
      server has already retired.
  - Everywhere else an expired grant is reported as `auth_required` rather than renewed by driving
    its owner, and no collector runs a provider's CLI to read quota. Spawn explicit executables with
    argument arrays, never interpolate provider or user data into a shell, and terminate subprocesses
    on success, failure, timeout, and cancellation.
- Provider HTTP uses the same twenty-second, 1 MiB bounds; browser-session validation tightens the
  timeout to ten seconds so it finishes inside private IPC, and the Keychain lookup is bounded the
  same way with its secret in a type whose `Debug` is redacted. Private IPC limits each line to 1
  MiB, rejects malformed envelopes, exposes only stable codes, and closes a corrupt connection.
- Error output and logs use allowlisted codes and fixed recovery text, never raw HTTP bodies,
  subprocess stderr, JWTs, authorization codes, secrets, installation IDs, raw GitHub subjects, full
  email addresses, or local source paths.
- The service owns one bounded diagnostic report, which QuotaBar's Support page consumes without
  inspecting local state or source logs. It may carry fixed statuses,
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
  new retained fields as security-sensitive. Protocol routing is a trust boundary: v6 writes pass
  the closed v6 provider and agent schemas, and one managed contract is served, so a read excludes
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
