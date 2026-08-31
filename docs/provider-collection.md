# Provider collection

This document is the source of truth for current provider discovery and collection strategy order.
All implementations must also satisfy the credential, network, process, redaction, and fixture rules
in [`security.md`](security.md). For an external baseline of CodexBar's quota, usage, and fallback
behavior across its full provider set, see
[`codexbar-platform-capabilities.md`](codexbar-platform-capabilities.md).

The shared Rust service owns provider access and emits normalized protocol models for QuotaBar.
QuotaRelay never handles the provider-specific inputs described here. Provider collection does not
initiate account authentication; account login is the browser flow described in
[`security.md`](security.md).

## Registration (monorepo)

Product metadata lives in `packages/provider/catalog.json` (not in this file). Collection
**strategy** for each provider is documented in the sections below.

To add a provider:

1. Catalog row in `packages/provider/catalog.json`, validated by `catalog.schema.json`.
2. Strategy section in this document.
3. Collector implementation under `packages/service/src/providers/`.
4. Registry entry in `packages/service/src/providers/mod.rs`.
5. `pnpm generate:provider-catalog` for protocol, Rust, and Swift provider IDs.
6. Optional QuotaBar brand SVG named by `brand_icon_asset`.

API-key providers declare credential and base-URL capabilities so QuotaBar Settings can render the
correct native fields. Browser-session capability separately declares its HTTPS login URL, exact
Cookie hosts/names, and browser-priority prefix; capabilities may coexist. Every provider with a
signed-in web session declares one — Codex, Claude Code, Grok, Kimi Code, and Cursor — and it is
always the last rung, described once under [Browser session](#browser-session).

Supported order today: Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, Cursor.

API-key HTTPS providers share the bounded request, credential resolution, URL validation, and
snapshot helpers in `packages/service/src/providers/common/`.

Every collection result reports `sources`, one entry per local credential source discovery found,
each carrying the `source_id` of the rung that answered for it, its `outcome`, and the `category`
that separates a refusal from an ordinary failure. An empty list means the provider was never set up
on this device, which is a different state from collection failing here and is what lets a client
stay quiet about the first and speak about the second. `auth_required` additionally carries a result
message naming what restores collection, because a stored sign-in the provider no longer accepts
recovers differently from one that never existed, and a browser session saved here is re-added here
while a provider's own grant is renewed by opening that provider's program.

A scheduled refresh starts at most three kinds of process, none of them a provider CLI reading
quota: the macOS Keychain lookup that finds Claude Code's grant, the `--version` a newly installed
provider CLI earns, and the one renewal an already-expired Claude Code, Codex, or Grok credential
earns — Claude Code also earns one when the file holds no usable grant and the Keychain item was
refused. Each is listed with its trigger and its bounds under
[Bounded subprocesses](#bounded-subprocesses). Requests
otherwise identify as `Quota/<version>`, except where a section below says the provider only answers
its own client.

How long a collected snapshot describes current quota is derived from the reading itself, as
described in [`architecture.md`](architecture.md). Collectors do not report it, providers do not
report it, and nothing stamps it onto the upload.

## Official CLI identity

Two endpoints answer the provider's own command-line client and nothing else, so the Codex and
Claude Code requests below present that client's `User-Agent`. Sending another program's client
identity is a provider-terms risk this build takes knowingly, and it is stated once here rather
than repeated.

The version in those headers is the version of the CLI installed on this device, not a constant.
Only those two are read: Grok's CLI is started for a renewal but never asked its version, because
no request identifies as it.

- The binary is resolved by name — `claude`, `codex`, and `grok` alike — on the service's `PATH`,
  then in `~/.local/bin`, `~/.npm-global/bin`, `~/.volta/bin`, `/opt/homebrew/bin`, and
  `/usr/local/bin`. Symlinks are followed to the real file.
- That file's real path, size, and mtime are its fingerprint, stored with the version and the time
  it was read in `cache.sqlite` metadata. The store is rebuildable: a cache reset costs one read
  per installed CLI.
- A refresh only `stat`s. `<binary> --version` runs when the fingerprint is absent or has changed,
  and never more often than once an hour per CLI, so a binary that rewrites itself cannot turn a
  five-minute timer into a spawn. It runs bounded: five seconds, 4 KiB of stdout, stderr discarded,
  no stdin, and an `env -i`-style environment holding only `HOME` and `PATH`.
- The first semver-looking token of the output is the version, which reads `2.1.0 (Claude Code)`,
  a bare `2.1.0`, and `codex-cli 0.42.1`. Anything else is no version rather than a guess.
- The probe runs on the refresh worker before collection, and only for a provider this device
  actually holds a sign-in for, so a Mac without Codex never runs `codex --version`. Collection
  never waits on it and never fails because of it: an absent or failed read leaves the header on
  the fallback stated in that provider's section.

The renewals under [Bounded subprocesses](#bounded-subprocesses) go the other way. They are not
requests this build makes; they are the provider's own CLI making its own, so nothing here dresses
them up. Where the protocol asks who woke the CLI — Codex's `initialize` takes a `clientInfo`, and
the app-server puts it in the `User-Agent` of everything it then sends — this build gives its own
name and version.

## Bounded subprocesses

A refresh starts three kinds of process and no others. No collector starts any of them: the two
that concern a provider CLI run on the refresh worker before collection, so nothing driven by the
five-minute timer can spawn on its own account.

The renewal is one mechanism serving three providers, not three rungs. A provider states which
program to run, which arguments, which of this device's variables the child inherits, whether the
sign-in is expiring, whether it is usable, and how to talk to the child; everything else — the
binary lookup, the empty private working directory, the minimal environment, the one spawn, the
hourly floor, and the verdict — is shared, and lives at one call site. "Usable" is deliberately not
"not expiring": a credential the CLI emptied or removed is neither, and that third answer is what
tells a program that signed itself out from one that could not renew.

| Process | Trigger | Bounds |
| --- | --- | --- |
| `/usr/bin/security` | Claude Code's Keychain grant, when collection home is the process `HOME` | Once per refresh, shared by discovery and collection, plus one more when a renewal actually ran and this refresh had held a Keychain secret (a refusal is kept, so a second prompt is not the price of asking Claude Code to start), plus one that asks only whether the entry exists when reading the secret failed; secret held in a redacted type |
| `<binary> --version` | The installed binary's fingerprint is absent or changed, for Claude Code or Codex when this device holds a sign-in for it | Once per installed binary, never more than once an hour; 5 s, 4 KiB, no stdin, `HOME` + `PATH`, empty owner-only cwd created for the run |
| The renewal — `claude mcp list`, `codex -s read-only -a never app-server`, or `grok agent stdio` | That provider's local credential is already expired or within a minute of expiry, **or** the official collection for a discovered grant came back `auth_required` in this refresh (the local clock is not the account). Claude Code additionally needs a `claudeAiOauth` refresh token to renew from, or a Keychain item this process was refused when the file holds no usable grant; Codex an OAuth grant rather than a personal access token | Once an hour per provider on a scheduled refresh, whatever the outcome; a Recheck or a manual refresh skips that hour. 64 KiB of stdout, stderr discarded, empty owner-only cwd created for the run, `HOME` + `PATH` + the variable that names the provider's credential home (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`) + the fixed pair that provider's plan names, which is `TERM=dumb` for Claude Code and nothing for the other two. The deadline is the CLI's own: 10 s for Claude Code, 8 s for Codex, 5 s for Grok |

Each is started as an explicit executable with an argument array, never through a shell, and is
terminated on success, failure, timeout, and cancellation. The binary is resolved by the rules
under [Official CLI identity](#official-cli-identity) in every case.

## Browser session

A stored browser session is the rung after every official credential a provider has, for the five
providers whose web app has a session to read. It exists because a reader signed in at
chatgpt.com, claude.ai, grok.com, kimi.com, or cursor.com already has an account this Mac can be
shown, and the alternative is telling them to sign in somewhere they already are.

It is the **last** rung and only the last rung. A provider's own credential is read first; the
stored session is reached only when that credential is missing entirely or every rung that read it
answered `auth_required`. Any other verdict is the refresh's answer — a rejected reading is not a
reason to spend a second request on the same account — and a credential this Mac was *refused*
(`access_denied`, such as a withheld Keychain item) never reaches it either, because a secret
withheld from this device says nothing about the account. Cursor is the same ladder with a
different first rung: a signed-in Cursor.app session from local desktop state.

Acquisition happens in QuotaBar, never during a refresh:

1. Turning **Browser Sign-in** on asks for consent before any cookie store is opened. The popup names
   the cookie names and hosts from the catalog, that accepted sessions stay in the local service
   database until the scan is turned off, and that nothing is uploaded; the macOS permission each
   browser needs is stated per browser in the Browser Access window instead. Declining leaves the
   preference off and reads nothing.
2. On confirmation the preference is stored immediately. QuotaBar then preflights installed
   browsers: Safari Full Disk Access, Chromium Safe Storage, Firefox none. Missing grants open the
   floating Browser Access window, one row per installed browser. Safari **Open Settings…** jumps
   to System Settings › Full Disk Access, with a QuotaBar icon in the window that is a plain file
   drag of the app for that list, followed by a **Relaunch** row because the grant lands on the next launch;
   a Chrome-family **Allow…** is the system Keychain prompt. Dismissing the window leaves the
   scan on and only reads granted stores; the Agent page keeps one summary row that reopens it.
3. When the preference is on and this Mac's official credential is missing or answered
   `auth_required`, QuotaBar reads every allowed installed browser that is already granted.
   SweetCookieKit queries the catalog's exact hosts and exact Cookie names; expired and unrelated
   records are discarded and logging is disabled. A store macOS refuses is recorded and the scan
   continues. An official credential that still answers skips the jars. Background reads never
   prompt; they skip Safari without Full Disk Access and any Chromium jar whose Keychain ACL is
   not already allowed.
4. Most allowlisted names are a whole sign-in and stay separate candidates, so Cursor's
   `wos-session` and `WorkosCursorSessionToken` are never combined. Two are not: a NextAuth token a
   browser split into numbered chunks (`…session-token.0`, `.1`, `.2`), and Grok's `sso` / `sso-rw`,
   which are one session's two halves — those share one header. A cookie that only says which
   account or organization a session is acting as (`_account`, `lastActiveOrg`) rides along with
   the sessions on its host rather than standing as a candidate. Hosts and browser profiles are
   never combined.
5. A read macOS refuses is not an absent session: the importer reports `access_denied` with the
   browser and one of `full_disk_access`, `keychain_refused`, or `store_unreadable`, which ends the
   attempt and is recorded through the browser-session commit as the `browser_access_denied`
   diagnostics source. The underlying error names a store path and never leaves Swift.
6. Rust revalidates header syntax and the catalog allowlist, then proves the cookie belongs to a
   signed-in account over that provider's fixed HTTPS endpoint before anything is stored — the
   per-provider check is named in each section below. Where the provider's official rung already
   has a `global` account identity, the browser rung builds the same fingerprint from the same
   field, so falling through does not rename the subscription. Validate does not persist; replace
   repeats validation before an atomic SQLite replacement, so a failure keeps the old sessions.
   Turning Browser Sign-in off deletes those rows and the refusals recorded against them.

## Codex

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
   absent, not malformed.
6. Do not fall back after a successful but malformed response; report the parser failure instead.
7. If neither credential exists or both answer `auth_required`, and a stored ChatGPT
   [browser session](#browser-session) exists, read `GET https://chatgpt.com/api/auth/session`
   (then `/backend-api/me`) with the catalog session cookies. That document has to name an
   account — `account.id`, an email, or an `accessToken` — or the session is refused. A session
   `accessToken` is spent as Bearer on the same WHAM URL; otherwise the Cookie header goes to it
   directly. QuotaBar acquires those cookies from `chatgpt.com` / `www.chatgpt.com`: the
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
the installed Codex version read as [Official CLI identity](#official-cli-identity) describes, and
`codex_cli_rs (<platform> <os version>; <arch>)` — no version field at all — when none could be
read. The OAuth rung sends no `User-Agent` of its own. Hidden WebView dashboard scraping and
reset-credit redemption are not used.

## Claude Code

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
4. Call `GET https://api.anthropic.com/api/oauth/usage` with
   `anthropic-beta: oauth-2025-04-20`.
5. Map the five-hour, seven-day, model-scoped, and extra-usage windows that are present. Titles are
   **5 Hours**, **Weekly**, **Sonnet Weekly**, **Opus Weekly**, **OAuth Apps Weekly**,
   **{Model} Only**, **Daily Routines**, and **Extra Usage**. The five-hour and seven-day
   windows are the headline meters (`primary_cadence` `five_hour` and `weekly`); model-scoped
   weeklies, Daily Routines, and Extra Usage are not. Every weekly limit meters one
   seven-day cycle, so a weekly window that reports no reset of its own — model-scoped or not —
   takes the seven-day window's reset.
6. Enrich identity best-effort through `/api/oauth/profile`; usage remains valid if enrichment fails.
7. Usage accepts `utilization` / `resets_at` and the aliases `utilization_pct` / `reset_at`.
8. If no credential exists or the OAuth rung answers `auth_required`, and a stored Claude
   [browser session](#browser-session) exists, send the stored allowlisted Cookie header
   (`sessionKey` plus optional `lastActiveOrg`) to `https://claude.ai/api/organizations`, then
   `/api/account` best-effort for the masked label and plan, then
   `/organizations/{id}/usage`. Prefer the listed org matching `lastActiveOrg`, then the org on
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
Keychain read is performed once per refresh and shared, plus once more when a renewal ran. The usage request presents
`User-Agent: claude-code/<version>`, the official CLI's identity rather than this build's, carrying
the installed Claude Code version read as [Official CLI identity](#official-cli-identity)
describes and falling back to `claude-code/2.1.0` when none could be read. The profile request
sends no `User-Agent` of its own.

## Local Usage logs

Usage parsing is independent from subscription-quota authentication. It reads local agent-owned
JSONL files and emits normalized usage-bearing model output facts plus typed scan coverage; it never
reads provider tokens for this path. One fact represents one persisted assistant/output response
whose Usage is measurable. Aggregated managed-data rows retain the released `requests` field; the
local-v3 summary exposes their sum as `messages`. This is neither a conversation count nor a session
count, and sessions are intentionally not collected. In v3 summaries, `total_tokens` is
`input_tokens + output_tokens`; cache-read and cache-write input tokens are subsets of input, and
reasoning tokens are a subset of output.

Provider grouping is by the vendor whose model answered, resolved from the raw model name by the
model catalog's family rules ([ADR 0009](decisions/0009-versioned-model-catalog.md)); `client`
records which agent emitted the usage-bearing output, and neither the agent nor the billing channel
chooses the group. The billing channel stays on every fact, resolved as the sections below say,
because pricing and audit depend on it; it says who was paid, not who made the model, and is never
consulted for the group. Summaries are nested as `agents[].providers[].models[]`; a name no family
claims is the `unknown` provider within its originating client.

A provider id resolves a channel only when it is a registered id that authenticates against that
vendor's own endpoints. Gateway spellings that merely proxy a vendor, such as an `-oauth` suffix on a
registered id, are not registered and stay unknown. `kimi-for-coding` and `moonshotai` resolve
`moonshot_direct`, and `deepseek` resolves `deepseek_direct`, for every collector that reads an
explicit provider id: OpenCode, Pi, and Cursor. Relay reports every channel it stores as stored;
[ADR 0018](decisions/0018-single-managed-data-contract.md) retired the narrowing that once rewrote
channels newer than a released client to `unknown`.

### Report-time model catalog

Collectors preserve every non-empty bounded `model` value exactly as reported, including punctuation,
case, and unknown provider strings. Model cleanup is applied only while building a report from the
stored facts. The shared catalog names a model's vendor by explicit lowercase `families` prefixes,
matched ASCII case-insensitively with the longest prefix winning, and matches an alias on an explicit
`reported_model` and that vendor, with optional exact agent `client` and
`[effective_from, effective_to)` UTC-date scope; it does not use regex, fuzzy matching, or inferred
aliases. Resolved model groups use the stable
canonical ID, while unresolved breakdowns retain the raw value. Updating the catalog regroups
historical rows on the next report without reparsing source files or modifying SQLite/Relay facts.
This view is independent of pricing: pricing sees the raw model first, and normalization does not
make an otherwise unpriced fact priced.

### Codex Usage

1. Discover rollout JSONL files below `$CODEX_HOME/sessions` and
   `$CODEX_HOME/archived_sessions`, defaulting `CODEX_HOME` to `~/.codex`.
2. Track model and service-tier settings in file order. Convert each `token_count` record to a
   request delta, preferring a provider-supplied last-request usage and otherwise subtracting the
   previous cumulative total.
3. Preserve input, cache-read, inferred cache-write, output, reasoning, model, tier, speed, and
   context bucket. Without an explicit provider value, use the Codex default `openai_direct` channel;
   when `payload.model_provider` is present, only `openai` maps to `openai_direct` with an explicit
   source. Observed values such as `custom` or `rightcode` remain the unknown channel; the collector
   never infers a billing channel from model text. Codex `total_tokens` is a context counter, not the
   sum used for billing facts. Codex logs do not supply source cost.
4. Duplicate cumulative totals do not emit another request. Leading subagent facts that inherit but
   initially omit the model are buffered until that rollout supplies its model context. Model
   identifiers are opaque provider text and are preserved as received, including punctuation such as
   `GPT-5.5[1m]`; only empty/control-text identifiers and malformed numeric or timestamp data are
   isolated. An isolated record or file makes only its own coverage partial and never suppresses
   valid facts from other files.

### Claude Code Usage

1. Discover JSONL files below `$CLAUDE_CONFIG_DIR/projects`, defaulting `CLAUDE_CONFIG_DIR` to
   `~/.claude`.
2. Parse assistant usage records and retain the provider model plus input, cache-read,
   five-minute/one-hour cache-write, output, service tier, context bucket, and tool request counts
   that are explicitly represented. Empty optional dimension strings mean unknown. Claude's
   provider-owned `<synthetic>` model marker normalizes to `synthetic` only when the record contains
   tokens, billable tools, or nonzero source cost; an empty internal marker emits no Usage fact.
3. Resolve `anthropic_direct` only for a Claude model. Third-party models use the explicit unknown
   channel instead of being misclassified as Anthropic. Source-reported cost is retained only with its
   request-coverage count so an incomplete amount cannot be treated as a complete total.
4. Unknown usage-shaped records, malformed timestamps/dimensions, unreadable sources, oversized
   lines, and truncated tails make coverage partial.

### Grok Usage

1. Discover `updates.jsonl` below `$GROK_HOME/sessions`, defaulting `GROK_HOME` to `~/.grok`.
2. Parse `_x.ai/session/update` records whose nested `sessionUpdate` is `turn_completed` and Usage is
   present. Preserve the numeric Unix timestamp, exact reported model, inclusive input, cache
   read/creation, output, reasoning, exact source cost, and the `xai_direct` channel. Canceled turns
   with null Usage emit no fact.
3. Grok reports completed output turns as `numTurns`; use that value for `messages`, not the lower-level
   `modelCalls`. Current records contain one `modelUsage` entry. A multi-model record is partial until
   Grok exposes per-model output-turn counts, so the collector never invents message attribution.
4. `inputTokens` already includes cache-read and cache-creation tokens. Validate those fields as input
   subsets and do not add them again.

### OpenCode Usage

1. Prefer the read-only SQLite message store at `$XDG_DATA_HOME/opencode/opencode.db`, defaulting
   `XDG_DATA_HOME` to `~/.local/share`. If it is absent, read legacy message JSON below
   `storage/message`.
2. Parse assistant messages with nonzero tokens or source cost. Add cache-read and cache-write tokens
   to uncached input so protocol input remains the billable total. Resolve a billing channel only
   from an explicit recognized `providerID`; custom providers remain unknown. Gateway spellings such
   as `kimi-for-coding-oauth`, `right-code`, and `crabot-codex` are not registered ids and stay
   unknown.
3. Rust opens the SQLite database read-only and never mutates the agent-owned store.

### Pi Usage

1. Discover JSONL sessions below `$PI_CODING_AGENT_DIR/sessions` when configured; otherwise scan
   both `~/.pi/agent/sessions` and the older `~/.local/share/pi-coding-agent/sessions` location.
2. Parse persisted assistant messages and retain their provider, model, token/cache/reasoning usage,
   and nonzero source cost. Resolve only explicit recognized provider channels.

### Cursor Usage

1. Discover Composer JSONL under `projects/*/agent-transcripts` and CLI `store.db` files under
   `chats`, both inside `$CURSOR_HOME` or `~/.cursor`. Those two subtrees are the discovery roots;
   the Cursor home itself is not walked, because its `extensions/` tree alone exceeds the
   discovery bounds and would end the scan before it reached `projects/`. Also open the desktop
   `state.vscdb` at
   `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` on macOS and
   `$XDG_CONFIG_HOME/Cursor/User/globalStorage/state.vscdb` on Linux, defaulting `XDG_CONFIG_HOME`
   to `~/.config`. Rust opens those SQLite files read-only and never mutates Cursor-owned stores.
2. Emit a fact only from an explicit usage-shaped record: JSONL `tokenCount` / `usage` /
   `message.usage`, desktop `cursorDiskKV` `bubbleId:` rows with `tokenCount`, or CLI `blobs` JSON
   that carries the same fields. Ignore zero-token/tool/cost records. Do not estimate tokens from
   transcript text, and do not treat `composerData.promptTokenBreakdown.totalUsedTokens` or
   `contextTokensUsed` as billing facts; those are conversation context meters, like Codex
   `total_tokens`.
3. Prefer per-bubble `tokenCount.inputTokens` / `outputTokens`. When an assistant bubble omits
   input, attach the preceding same-composer user bubble's tokens so one output response stays one
   fact. Preserve cache and reasoning fields only when the source reports them. Model identifiers
   stay opaque provider text (`modelInfo.modelName`, `model`, or `message.model`). Resolve a billing
   channel only from an explicit recognized provider field; never infer one from the model string.
   Cursor house models remain the unknown channel inside the `cursor` client.
4. Agent-transcript JSONL often has role/message text and no usage; that is complete empty coverage,
   not a malformed source. Binary or protobuf blobs are skipped. An unreadable database, invalid
   timestamp/model/usage field, or truncated source makes only that file partial.

Cursor is part of the single BillingAgent set every managed contract carries.

All scanners preserve non-empty bounded model identifiers as opaque provider text, ignore zero-
token/tool/cost internal records, and use canonical `[start_at, end_at)` UTC-hour boundaries,
bounded directory traversal, a two-million-record scan ceiling, bounded line sizes, cancellation,
and source-change checks. SQLite records an opaque file identity, size, modification time, and
parser revision. Unchanged files are skipped; a changed file's normalized rows are replaced
transactionally. Paths and file-index metadata never enter a protocol submission or IPC state. Only
complete coverage is eligible for authoritative remote replacement; empty complete coverage is valid.
Discovery always covers every canonical local source. Local reports cover indexed history, while
remote replacement remains split losslessly into bounded protocol ranges. Record/file skips and
upload partitions are summarized by the QuotaBar diagnostics report.

## Grok

1. Discover `$GROK_HOME/auth.json` or `~/.grok/auth.json`.
2. Prefer the non-empty `https://auth.x.ai::<client-id>` entry with the latest expiry, then legacy
   sign-in entries.
3. A cached token that is expired or within one minute of expiry is the first case where this
   build starts a provider's CLI. Grok's access token lives about six hours and only the Grok CLI
   can renew it, so a Mac that has not opened Grok since breakfast would otherwise report an
   expired sign-in all day. If the official reading then answers `auth_required` while this Mac
   still holds a grant, the same CLI is asked once more in that refresh. On the refresh worker,
   before collection, `grok agent stdio` is run once:
   `initialize`, then `authenticate` with `methodId: cached_token`, which renews from the refresh
   token the CLI already holds. The reply is read before stdin closes, because closing it is how a
   stdio agent is told to shut down. `cached_token` is the only method ever asked for — the method
   Grok 1.0.5 advertises, `grok.com`, prints a device code and waits for a person, which nothing on
   a timer may start. Bounded to five seconds for the whole exchange, 64 KiB of stdout, stderr
   discarded, an empty private working directory created for the run, and an environment holding
   only `HOME`, `PATH`, and `GROK_HOME`; the child is terminated on timeout, cancellation, or an
   over-long answer. At most one attempt per hour,
   recorded in `cache.sqlite` metadata with the time and the outcome, so a CLI that
   cannot renew is not started every five minutes. Afterwards `auth.json` is read again: an
   unexpired token continues to step 4 in the same refresh, and anything else is `auth_required`
   with "Open Grok to refresh the sign-in". No Grok CLI on this Mac means no attempt and no record.
4. Call `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the local Grok OAuth
   token. HTTP 401/403 is `auth_required`. A valid cached token works without the `grok` executable.
5. Prefer `config.creditUsagePercent` and `config.currentPeriod`. For non-unified accounts, retain the
   deprecated `config.used.val / config.monthlyLimit.val * 100` fields documented by Grok Build. A
   new period that omits those usage fields is 0% used, not malformed.
6. When the proxy is unreachable (not rejected, not malformed), `POST
   https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` as gRPC-web with the same
   OAuth token as `Authorization: Bearer`. This is CodexBar's last Automatic step; Quota runs it
   before the stored browser session because it needs no extra credential. If it also fails, report
   the proxy outcome.
7. Billing does not name the tier. Best-effort and bounded to two seconds, read
   `GET https://cli-chat-proxy.grok.com/v1/settings` with the same headers and map
   `subscription_tier_display` (for example `SuperGrok Heavy`) to the plan slug `supergrok_heavy`.
   When that is absent, infer a weak hint from local credentials only: OIDC scopes under
   `https://auth.x.ai::` (and `auth_mode: oidc`) map to `supergrok`; other `auth_mode` values may be
   kept as a plan slug when they look like a plan name. Do not invent a plan when no signal is present.
8. If no credential exists or both token rungs answer `auth_required`, and a stored Grok
   [browser session](#browser-session) exists, call the same gRPC-web billing RPC with the catalog
   `sso` / `sso-rw` cookies instead of the Bearer token, and map used percent and reset from the
   protobuf payload. The RPC names nobody, so a clean answer is the whole account check: grok.com
   refuses a session it does not recognise, which is `auth_required` rather than a parser failure.
   grok.com may also reject cookie-only requests that lack the browser Web Key Exchange proof;
   that too is `auth_required`. The reading is source-scoped, and its label is "Grok".
   QuotaBar acquires those cookies from `grok.com` / `www.grok.com`.

The billing RPC exposes only the reset instant, whichever credential reached it: 20–45 days out is
**Monthly**, anything nearer is the **Weekly** credit pool, and no reset stays **Billing Cycle**.

The local service never submits the refresh token itself, never writes `auth.json`, and never
starts Grok's interactive browser login. That CLI is solely responsible for refresh-token rotation
and credential-file writes; step 3 asks it to perform one, and never performs one itself. Proxy
requests carry
`X-XAI-Token-Auth: xai-grok-cli` and the gRPC-web billing call carries `x-user-agent: connect-es/2.1.1`
with grok.com `Origin` and `Referer`, because those endpoints answer only requests that identify as
Grok's own clients; sending another program's client identity is a provider-terms risk this build
takes knowingly.

Local context-token or session totals are not subscription quota.

## OpenRouter

Aligned with CodexBar's OpenRouter provider (credits + API-key limit meters).

1. Resolve the API key in order:
   1. Owner-only config at `$XDG_CONFIG_HOME/quota/providers.json` or
      `~/.config/quota/providers.json` (`schema_version: 1`, `providers.openrouter.api_key`),
      written by QuotaBar Settings through the private service.
   2. Else `OPENROUTER_API_KEY` from the process environment.
   Use the fixed `https://openrouter.ai/api/v1` endpoint. Custom base URLs and URL environment
   overrides are not supported.
2. Concurrently call `GET {base}/credits` and best-effort `GET {base}/key`; both use
   `Authorization: Bearer <key>` and a product `X-Title` header. The latter supplies per-key limit,
   remaining, reset window, and spend fields. Key failure must not discard a usable credits result.
   If both independent endpoints are unavailable or rate-limited, preserve `unavailable`; do not
   convert that state to malformed-data `error`.
3. Map windows (remaining is always `100 - used_percent` in consumers). Absolute USD fields are
   optional protocol extensions for credits-class UIs:
   - **API Key Budget** (primary when present; **API Key Daily** / **Weekly** / **Monthly** when
     `limit_reset` names a period): when `limit > 0`, used amount prefers
     `limit - clamp(limit_remaining)`, else the spend field matching `limit_reset`
     (`usage_daily` / `usage_weekly` / `usage_monthly`), else cumulative `usage`. Emit
     `remaining_value` / `limit_value` / `value_unit: "usd"` alongside `used_percent`.
   - **Balance**: when `total_credits > 0`, emit a balance-only window titled **Balance (USD)** using
     `remaining_value: total_credits - total_usage` and `value_unit: "usd"`; values may be up to ~60s
     stale. Do not treat rechargeable credits as a fixed limit or show a percentage meter. The title
     matches DeepSeek's USD wallet; consumers may collapse every balance-only window to **Balance**.
   The snapshot plan badge is **Credits**; the provider header already identifies OpenRouter, so the
   channel name is not repeated in the plan position.
4. Absent key → `auth_required` with guidance to configure QuotaBar (or set
   `OPENROUTER_API_KEY`). HTTP 401/403 →
   `auth_required`. Never print the API key, Authorization header, or response bodies.
   IPC state and menubar UI only show a masked tip (`OpenRouter ···abcd`).

Config directory is `0700` and `providers.json` is `0600`. Multi-account labeled keys are out of
scope. Dashboard cookies and browser scrapes are not strategies.

## DeepSeek

Aligned with CodexBar's DeepSeek **API-key balance** path. CodexBar's Automatic also has a Platform
Web path that reads Chrome `localStorage` `userToken` on `platform.deepseek.com`; Quota does **not**
import browser localStorage (see [`security.md`](security.md)). Platform detailed usage therefore
stays out of scope unless a future allowlisted, user-supplied token channel is added.

1. Resolve the API key in order:
   1. Owner-only config at `$XDG_CONFIG_HOME/quota/providers.json` or
      `~/.config/quota/providers.json` (`providers.deepseek.api_key`), written by QuotaBar
      Settings through the private service.
   2. Else `DEEPSEEK_API_KEY`, then `DEEPSEEK_KEY`, from the process environment.
   Use the fixed `https://api.deepseek.com` endpoint. Custom base URLs and URL environment
   overrides are not supported.
2. Call `GET {base}/user/balance` with `Authorization: Bearer <key>`.
3. Parse every `balance_infos` row. Map each currency with `total_balance > 0` as its own
   balance-only window (`remaining_value`; USD also sets `value_unit: "usd"`). Do **not** prefer a
   zero USD row over a positive CNY (or other) balance. If every currency is zero, keep one zero
   USD (or first) row so the account still appears. No lifetime spend ratio is available.
   The snapshot plan badge is **Credits**; the provider header identifies DeepSeek, so the channel
   name is not repeated in the plan position.
4. Absent key → `auth_required` with guidance to configure QuotaBar (or set
   `DEEPSEEK_API_KEY`). HTTP 401/403 → `auth_required`. Never print the API key or Authorization
   header. Platform-session detailed usage endpoints are not used.

## Kimi Code

Aligned with CodexBar's Kimi Code Automatic order: API key → CLI credential → web cookie.

1. Resolve the API key in order:
   1. Owner-only config `providers.kimi.api_key`.
   2. Else `KIMI_CODE_API_KEY`, then `KIMI_API_KEY`.
   Use the fixed `https://api.kimi.com` endpoint. Custom base URLs and URL environment overrides
   are not supported.
2. Call `GET {base}/coding/v1/usages` with `Authorization: Bearer <key>`.
3. Map windows:
   - **Weekly** from top-level `usage` (request counts; `value_unit: "count"`).
   - **5 Hours** only from `limits[]` where window duration is exactly 300 minutes (also when it is
     the only entry).
4. If no API key is configured, or the Code API returns 401/403, read
   `$KIMI_CODE_HOME/credentials/kimi-code.json` or `~/.kimi-code/credentials/kimi-code.json`
   read-only. Use a fresh `access_token` (`expires_at` more than 60 seconds away) against the same
   `/coding/v1/usages` URL. Do not redeem `refresh_token` or write `device_id` / credential files.
5. If the key and the CLI credential are both absent or unauthorized, and a stored Kimi
   [browser session](#browser-session) exists, `POST
   https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages` with
   `{"scope": ["FEATURE_CODING"]}`, sending the `kimi-auth` cookie value as both
   `Authorization: Bearer` and the Cookie header, with the console's `Origin` and `Referer` — the
   way kimi.com's own console does. Map the `FEATURE_CODING` usage object with the same weekly /
   5-hour rules; an answer that carries no coding scope is refused. The reading is source-scoped,
   and its label is "Kimi". QuotaBar acquires `kimi-auth` from `www.kimi.com` / `kimi.com`.
6. Absent key, CLI credential, and browser session → `auth_required`. HTTP 401/403 →
   `auth_required`.

The CLI-credential request carries `X-Msh-Platform: kimi_code_cli`, because Kimi honors that token
only from requests identifying as its CLI; sending another program's client identity is a
provider-terms risk this build takes knowingly. The credential file is read only: this build never
starts the Kimi CLI.

## LiteLLM

Aligned with CodexBar's LiteLLM virtual-key budget path.

1. Resolve API key (`providers.litellm.api_key` or `LITELLM_API_KEY`) **and** base URL
   (`providers.litellm.base_url` or `LITELLM_BASE_URL`). Base URL is **required** (no public default).
   HTTPS is required except loopback / RFC1918 / `.local` HTTP for private LiteLLM proxies. A trailing
   `/v1` is stripped before management endpoints.
2. `GET {root}/key/info` → `user_id` / `team_id`.
3. After key discovery, request the present user and team resources concurrently:
   - `GET {root}/user/info?user_id=…` → personal spend / max_budget.
   - `GET {root}/team/info?team_id=…` → team spend / max_budget.
4. Map budget windows with `remaining_value`, `limit_value`, and `value_unit: "usd"` when
   `max_budget > 0`. Spend without a hard budget is not emitted as a quota window; never treat
   spend as a budget or fabricate remaining quota.
5. Missing key or base URL → `auth_required` (discovery unavailable). HTTP 401/403 → `auth_required`.

OpenRouter, DeepSeek, and Kimi always use their fixed official origins; custom base URLs are rejected.

## Cursor

Cursor prefers a signed-in Cursor.app session, then a stored browser session. It is the only
provider whose catalog row is `exclusive`: it has no CLI sign-in command and no API key, so
Settings omits the sign-in row for it. Quota snapshots follow the product default and sync to the
managed Account.

1. Discover a usable Cursor.app session from the desktop `state.vscdb` `ItemTable` key
   `cursorAuth/accessToken`. On macOS that file is
   `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`. On Linux it is
   `$XDG_CONFIG_HOME/Cursor/User/globalStorage/state.vscdb`, defaulting `XDG_CONFIG_HOME` to
   `~/.config`. Open the database read-only. When WAL sidecars are present, read them; when they are
   absent and WAL mode remains in the header, use SQLite immutable mode so the service does not
   recreate files in Cursor's directory. The JWT must include `sub` and `exp` more than 60 seconds
   away. The local service never refreshes it. Derive
   `WorkosCursorSessionToken={userID}%3A%3A{token}` from the last `|` component of `sub`. Isolated
   or remapped collection homes only read that remapped desktop path.
2. Acquisition follows [Browser session](#browser-session): consent first, then
   `https://authenticator.cursor.sh/` opened in the one resolved browser.
3. SweetCookieKit queries the catalog's four exact hosts (`cursor.com`, `www.cursor.com`,
   `cursor.sh`, `authenticator.cursor.sh`) and the three exact WorkOS session Cookie names
   (`WorkosCursorSessionToken`, `wos-session`, `__Secure-wos-session`). All three are whole
   sessions, so each name on each host is one candidate and none of them is ever combined.
4. Rust validates header syntax and the catalog allowlist, then calls fixed
   `GET https://cursor.com/api/auth/me` with no redirects and a ten-second timeout. Stable `sub` is
   the preferred namespaced fingerprint input; normalized email is the fallback. Only the hash and
   masked email return to Swift. Validate does not persist; commit repeats validation before an
   atomic SQLite replacement, so failures keep the old session.
5. Routine refresh prefers the live Cursor.app session when it is usable, otherwise the Rust-owned
   stored browser session, and calls `GET https://cursor.com/api/usage-summary`. HTTP 401/403 on the
   app session falls back to the stored browser session when one exists. The official Cursor Models
   and Other Models windows map from `individualUsage.plan.autoPercentUsed` and `apiPercentUsed`.
   Other Models also carries the included API dollar remaining from `plan.used` / `limit` /
   `remaining` (cents). Cursor Models is percent-only. `totalPercentUsed` is not a third quota.
   Individual, **On-Demand**, **Team Pool**, and **Team On-Demand** cents-based limits map to remaining USD
   windows. HTTP 401/403 is `auth_required`; malformed/partial payloads do not expose provider
   response data.
6. Two dashboard calls are best-effort with a five-second cap; neither failure fails the refresh:
   - `POST https://cursor.com/api/dashboard/get-sand-usage-status` (empty JSON body, `Origin`
     header) is the weekly **Grok Bot** allowance. Emit it after the included windows only when
     `hasNonZeroIncludedLimit` is true, from `usagePercent`, `nextResetTimestampUtc`, and
     `currentPeriodStart`.
   - `GET https://cursor.com/api/usage?user=<sub>` with the `/api/auth/me` subject is the legacy
     request-based plan. When `gpt-4.maxRequestUsage` is positive, a single **Requests** window
     (`numRequestsTotal`, else `numRequests`; `value_unit: "count"`) replaces Cursor Models, Other
     Models, and Grok Bot, which only describe usage-based pricing. On-Demand and team windows
     remain.
7. Catalog `account_sync` is true, so Cursor snapshots enter managed envelopes and Account
   summaries. Browser cookies and the Cursor.app access token still never leave the local service.

## Identity and normalization

- A global `account.fingerprint` is SHA-256 over the provider, the identifier namespace, and the
  stable quota-owner identifier: Codex uses account ID; Claude Code uses organization ID; Grok uses
  team ID when present and otherwise user ID; Cursor uses its stable user `sub` and falls back to a
  normalized email; OpenRouter, DeepSeek, Kimi Code, and LiteLLM use a
  SHA-256 of the API key under the `api_key` namespace (never the raw key).
- Cursor explicitly uses normalized email as a fingerprint fallback only when `/api/auth/me` omits
  `sub`. For every other provider, email is display enrichment only and never a global identity; a
  missing quota-owner identifier uses a stable source-scoped fingerprint. QuotaBar does not treat
  that shared source hash as picker identity: sign-in choices stay distinct by cookie-header
  fingerprint so two valid Grok, Kimi, or Codex sessions cannot silently overwrite each other.
  Every normalized account declares its fingerprint scope.
- Account labels use a masked email or a non-sensitive display name.
- A collection attempt records its stable source identifier and an explicit outcome.
- One provider failure does not discard successful results from other requested providers.
- Requested providers collect concurrently while the report preserves catalog order
  (`PROVIDER_ORDER`): Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, then Cursor.
  Multiple sessions within one provider remain sequential so provider-owned credential refreshes do
  not race. A provider result with both successful and failed sessions remains explicitly partial in
  component state.
