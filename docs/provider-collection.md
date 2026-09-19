# Provider collection

This document is the source of truth for current provider discovery and collection strategy order.
All implementations must also satisfy the credential, network, process, redaction, and fixture rules
in [`security.md`](security.md). A dated CodexBar comparison (research, not a compatibility contract) is
[`research/codexbar-platform-capabilities-2026-09-19.md`](research/codexbar-platform-capabilities-2026-09-19.md).

Per-provider request, parser, and credential specifics live in [`providers/<id>.md`](#providers),
named by the catalog id. Local Usage parsers live in [`usage-sources.md`](usage-sources.md).

The shared Rust service owns provider access and emits normalized protocol models for QuotaBar.
QuotaRelay never handles the provider-specific inputs described here. Provider collection does not
initiate account authentication; account login is the browser flow described in
[`security.md`](security.md).

## Registration (monorepo)

Product metadata lives in `packages/provider/catalog.json` (not in this file). Collection
**strategy** for each provider is documented in [`providers/<id>.md`](#providers), named by the catalog id.

To add a provider:

1. Catalog row in `packages/provider/catalog.json`, validated by `catalog.schema.json`.
2. Strategy file at `docs/providers/<id>.md`.
3. Collector implementation under `packages/service/src/providers/`.
4. Registry entry in `packages/service/src/providers/mod.rs`.
5. `pnpm generate:provider-catalog` for protocol, Rust, and Swift provider IDs, then `pnpm generate:reference`.
6. Optional QuotaBar brand SVG named by `brand_icon_asset`.

API-key providers declare credential and base-URL capabilities so QuotaBar Settings can render the
correct native fields. Browser-session capability separately declares its HTTPS login URL, exact
Cookie hosts/names, and browser-priority prefix; capabilities may coexist. Every provider with a
signed-in web session declares one — Codex, Claude Code, Grok, Kimi Code, and Cursor — and it is
always the last rung, described once under [Browser session](#browser-session).

Supported order today: Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, Cursor,
Gemini CLI, GitHub Copilot, Antigravity, OpenCode Go.

## Service status

Catalog `status_page` declares whether this build polls an official status page. `kind` is
`statuspage_v2` or `none`. `statuspage_v2` is Atlassian Statuspage `GET {url}` of
`/api/v2/status.json`; this build reads only `status.indicator` (`none` / `minor` / `major` /
`critical`) and `status.description`. `none` means there is no machine-readable Statuspage v2
feed: the helper does not scrape HTML and does not invent a second parser.

Verified 2026-09-06 (no redirects; this client's HTTP stack follows none):

| Provider | Kind | URL |
| --- | --- | --- |
| Codex | `statuspage_v2` | `https://status.openai.com/api/v2/status.json` (incident.io page; still answers Statuspage v2 `status.indicator` / `status.description`) |
| Claude Code | `statuspage_v2` | `https://status.claude.com/api/v2/status.json` (`status.anthropic.com` 301s here) |
| Grok | `none` | `https://status.x.ai/` (custom page, Cloudflare 403 on `/api/v2/status.json`) |
| OpenRouter | `none` | `https://status.openrouter.ai/` (OnlineOrNot HTML, no Statuspage v2) |
| DeepSeek | `none` | `https://status.deepseek.com/` (Flashcat HTML; `/api/v2/status.json` is 404) |
| Kimi Code | `statuspage_v2` | `https://status.moonshot.cn/api/v2/status.json` |
| LiteLLM | `none` | no official page |
| Cursor | `statuspage_v2` | `https://status.cursor.com/api/v2/status.json` |
| Antigravity | `none` | `https://www.google.com/appsstatus/dashboard/` (Google Workspace HTML; no Statuspage v2) |
| OpenCode Go | `none` | no official page |

The local helper polls every ten minutes (and once at scheduler start) with
`User-Agent: Quota/<version>`, a ten-second timeout, and a 64 KiB body cap. A failed poll keeps
the last reading. Quota iOS uses the same URL list through `QuotaProviderStatus` on the device.
Relay publishes the same feeds at public `GET /api/v2/providers/status` (no principal, no cookie):
the Worker polls `statuspage_v2` URLs with a five-second timeout, stores last-good readings in
`caches.default` for ten minutes, and answers `unknown` when a poll fails with nothing cached
([ADR 0044](decisions/0044-relay-publishes-provider-status.md)). The website Overview draws a 6
pt incident dot from that read; a public profile does not. The menu-bar icon does not overlay an
incident mark.

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
otherwise identify as `Quota/<version>`, except where a provider file says the provider only answers
its own client.

How long a collected snapshot describes current quota is derived from the reading itself, as
described in [`architecture.md`](architecture.md). Collectors do not report it, providers do not
report it, and nothing stamps it onto the upload.

## Official CLI identity

Two endpoints answer the provider's own command-line client and nothing else, so the Codex and
Claude Code requests in those provider files present that client's `User-Agent`. Sending another program's client
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
  the fallback stated in that provider's file.

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

Quota iOS reads the same rung with `QuotaProviderWeb` in `packages/apple-client`, on the device the
reader signed in on rather than from a Mac's cookie jars. It has no other rung and no cookie jar to
import: the session comes from a sign-in the reader completes inside the app, in a web view whose
store is discarded with the sheet, and is kept in that device's Keychain
([ADR 0034](decisions/0034-ios-collects-for-itself.md)). Both runtimes answer
`packages/protocol/fixtures/provider-web-conformance.json`, so the request sequence, the
classifications, and the account fingerprint below are one rule and not two.

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
   per-provider check is named in that provider's file. Where the provider's official rung already
   has a `global` account identity, the browser rung builds the same fingerprint from the same
   field, so falling through does not rename the subscription. Validate does not persist; replace
   repeats validation before an atomic SQLite replacement, so a failure keeps the old sessions.
   Turning Browser Sign-in off deletes those rows and the refusals recorded against them.

## Providers

| Catalog id | Provider | Strategy |
| --- | --- | --- |
| `codex` | Codex | [Codex](providers/codex.md) |
| `claude` | Claude Code | [Claude Code](providers/claude.md) |
| `grok` | Grok | [Grok](providers/grok.md) |
| `openrouter` | OpenRouter | [OpenRouter](providers/openrouter.md) |
| `deepseek` | DeepSeek | [DeepSeek](providers/deepseek.md) |
| `kimi` | Kimi Code | [Kimi Code](providers/kimi.md) |
| `litellm` | LiteLLM | [LiteLLM](providers/litellm.md) |
| `cursor` | Cursor | [Cursor](providers/cursor.md) |
| `gemini` | Gemini CLI | [Gemini CLI](providers/gemini.md) |
| `copilot` | GitHub Copilot | [GitHub Copilot](providers/copilot.md) |
| `antigravity` | Antigravity | [Antigravity](providers/antigravity.md) |
| `opencode_go` | OpenCode Go | [OpenCode Go](providers/opencode_go.md) |

## Local Usage logs

Parsers, what is read, and the local-only attribution boundary live in
[`usage-sources.md`](usage-sources.md).

## Identity and normalization

- A global `account.fingerprint` is SHA-256 over the provider, the identifier namespace, and the
  stable quota-owner identifier: Codex uses account ID; Claude Code uses organization ID; Grok uses
  team ID when present and otherwise user ID; Cursor uses its stable user `sub` and falls back to a
  normalized email; Gemini CLI uses the OAuth access-token JWT email (else `sub`); GitHub Copilot
  uses the `login` from `copilot_internal/user`; Antigravity uses the OAuth access-token JWT email
  (else stored email, else `sub`); OpenRouter, DeepSeek, Kimi Code, LiteLLM, and OpenCode Go use a
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
  (`PROVIDER_ORDER`): Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, Cursor,
  Gemini CLI, GitHub Copilot, Antigravity, then OpenCode Go.
  Multiple sessions within one provider remain sequential so provider-owned credential refreshes do
  not race. A provider result with both successful and failed sessions remains explicitly partial in
  component state.
