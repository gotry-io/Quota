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
Cookie hosts/names, and browser-priority prefix. Only a provider with no other way to be read
declares one, and Cursor is the only such provider; a provider whose own program renews its grant
declares none, so QuotaBar never opens a cookie store for it.

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
provider CLI earns, and the one `grok agent stdio` an already-expired Grok token earns. Each is
listed with its trigger and its bounds under [Bounded subprocesses](#bounded-subprocesses). Requests
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

The version in those headers is the version of the CLI installed on this device, not a constant:

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

## Bounded subprocesses

A refresh starts three processes and no others. No collector starts any of them: the two that
concern a provider CLI run on the refresh worker before collection, so nothing driven by the
five-minute timer can spawn on its own account.

| Process | Trigger | Bounds |
| --- | --- | --- |
| `/usr/bin/security` | Claude Code's Keychain grant, when collection home is the process `HOME` | Once per refresh, shared by discovery and collection; secret held in a redacted type |
| `<binary> --version` | The installed binary's fingerprint is absent or changed, for a CLI this device holds a sign-in for | Once per installed binary, never more than once an hour; 5 s, 4 KiB, no stdin, `HOME` + `PATH` |
| `grok agent stdio` | Grok's local token is already expired or within a minute of expiry | Once an hour whatever the outcome; 5 s for the whole handshake, 64 KiB, `HOME` + `PATH` + `GROK_HOME` |

Each is started as an explicit executable with an argument array, never through a shell, and is
terminated on success, failure, timeout, and cancellation. The binary is resolved by the rules
under [Official CLI identity](#official-cli-identity) in every case.

## Codex

1. Discover `$CODEX_HOME/auth.json` or `~/.codex/auth.json`.
2. Prefer a top-level `personal_access_token` / `personalAccessToken` when present:
   `GET https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami` with
   `Authorization: Bearer <PAT>`, then the same WHAM usage URL with
   `ChatGPT-Account-Id` from whoami (`chatgpt_account_id`). PAT identity comes from whoami, not a
   stale managed-workspace account id. Only HTTP 401/403 falls through to OAuth; a successful but
   malformed WHAM body is reported as an error.
3. Else prefer `GET https://chatgpt.com/backend-api/wham/usage` using the local OAuth access token and,
   when present, `ChatGPT-Account-Id`.
4. Map primary, secondary, additional, and dedicated `code_review_rate_limit` windows without
   changing their used/remaining meaning. Classify primary and secondary by reported duration
   (5-hour, weekly, or 30-day monthly) rather than by payload slot, so a Free-tier monthly
   window is not labeled as 5-hour. A null code-review object is absent, not malformed.
5. Do not fall back after a successful but malformed response; report the parser failure instead.
   There is no further rung: absent or rejected credentials are `auth_required`.

The local service never submits the Codex refresh token or writes `auth.json`, and never starts the
Codex CLI to read quota: a grant Codex no longer accepts is reported as `auth_required`, and the
reader renews it by opening Codex. The PAT requests present `originator: codex_cli_rs` and the Codex
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
2. Parse only `claudeAiOauth` and require `accessToken` with a usable `user:profile` scope. A grant
   that is expired or within one minute of expiry is `auth_required`: Claude Code owns renewal, and
   this build no longer drives it.
3. Call `GET https://api.anthropic.com/api/oauth/usage` with
   `anthropic-beta: oauth-2025-04-20`.
4. Map the five-hour, seven-day, model-scoped, and extra-usage windows that are present. Every
   weekly limit meters one seven-day cycle, so a weekly window that reports no reset of its own —
   model-scoped or not — takes the seven-day window's reset.
5. Enrich identity best-effort through `/api/oauth/profile`; usage remains valid if enrichment fails.
6. Usage accepts `utilization` / `resets_at` and the aliases `utilization_pct` / `reset_at`.
   There is no further rung: absent or rejected credentials are `auth_required`.

An absent, stale, or unreadable session is `auth_required`. A Claude Code installation configured
only for a third-party API gateway does not provide Anthropic subscription OAuth quota.
Collection never drives the Claude CLI to read quota, in any form:
an expired grant is reported as the sign-in it is, and the reader renews it by opening Claude Code.
The local service never submits the Claude refresh token or writes its credential file or Keychain
entry. The Keychain read is performed once per refresh and shared. The usage request presents
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

Provider grouping uses the normalized fact's explicit billing channel, including a documented
collector-owned default where the source has one. It never derives provider ownership from model
text or from `client`. The local-v3 `provider` is the channel's inference provider; `client` records
which agent emitted the usage-bearing output. Summaries are nested as
`agents[].providers[].models[]`; unknown channels remain the `unknown` provider within their
originating client.

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
stored facts. The shared catalog matches an explicit `reported_model` and inference `provider`, with
optional exact agent `client` and `[effective_from, effective_to)` UTC-date scope; it does not use regex,
automatic case/trim rules, fuzzy matching, or inferred aliases. Resolved model groups use the stable
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

1. Discover `$CURSOR_HOME` or `~/.cursor` for Composer JSONL under `projects/*/agent-transcripts`
   and CLI `store.db` files under `chats`. Also open the desktop `state.vscdb` at
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
3. A cached token that is expired or within one minute of expiry is the one case where this build
   starts a provider's CLI. Grok's access token lives about six hours and only the Grok CLI can
   renew it, so a Mac that has not opened Grok since breakfast would otherwise report an expired
   sign-in all day. On the refresh worker, before collection, `grok agent stdio` is run once:
   `initialize`, then `authenticate` with `methodId: cached_token`, which renews from the refresh
   token the CLI already holds. The reply is read before stdin closes, because closing it is how a
   stdio agent is told to shut down. `cached_token` is the only method ever asked for — the method
   Grok 1.0.5 advertises, `grok.com`, prints a device code and waits for a person, which nothing on
   a timer may start. Bounded to five seconds for the whole exchange, 64 KiB of stdout, stderr
   discarded, and an environment holding only `HOME`, `PATH`, and `GROK_HOME`; the child is
   terminated on timeout, cancellation, or an over-long answer. At most one attempt per hour,
   recorded in `cache.sqlite` metadata with the binary's fingerprint and the outcome, so a CLI that
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
8. Absent or rejected credentials are `auth_required`; there is no further rung. The billing RPC
   exposes only the reset instant: 20–45 days out is **Monthly**, anything nearer is the **Weekly**
   credit pool, and no reset stays **Billing cycle**.

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
   - **API key budget** (primary when present): when `limit > 0`, used amount prefers
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

Aligned with CodexBar's Kimi Code Automatic order, minus its web-cookie rung: API key → CLI
credential.

1. Resolve the API key in order:
   1. Owner-only config `providers.kimi.api_key`.
   2. Else `KIMI_CODE_API_KEY`, then `KIMI_API_KEY`.
   Use the fixed `https://api.kimi.com` endpoint. Custom base URLs and URL environment overrides
   are not supported.
2. Call `GET {base}/coding/v1/usages` with `Authorization: Bearer <key>`.
3. Map windows:
   - **Weekly** from top-level `usage` (request counts; `value_unit: "count"`).
   - **5 hour** only from `limits[]` where window duration is exactly 300 minutes (also when it is
     the only entry).
4. If no API key is configured, or the Code API returns 401/403, read
   `$KIMI_CODE_HOME/credentials/kimi-code.json` or `~/.kimi-code/credentials/kimi-code.json`
   read-only. Use a fresh `access_token` (`expires_at` more than 60 seconds away) against the same
   `/coding/v1/usages` URL. Do not redeem `refresh_token` or write `device_id` / credential files.
5. Absent key and CLI credential → `auth_required`; there is no further rung. HTTP 401/403 →
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
provider that declares a browser session at all: it has no CLI sign-in command and no API key, so
without one there is nothing to read. Quota snapshots follow the product default and sync to the
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
2. QuotaBar resolves one explicit supported browser — the default HTTPS handler, or a choice the
   user makes when that handler is unsupported — and then asks for consent before opening any
   cookie store. The popup names that browser, the permission macOS will ask for, the exact hosts
   and Cookie names, that the accepted session stays in the local service database until
   disconnected, and that nothing is uploaded. Declining reads nothing. On confirmation QuotaBar
   opens `https://authenticator.cursor.sh/` in that browser and polls only its profiles.
3. SweetCookieKit queries the catalog's four exact hosts (`cursor.com`, `www.cursor.com`,
   `cursor.sh`, `authenticator.cursor.sh`) and the three exact WorkOS session Cookie names
   (`WorkosCursorSessionToken`, `wos-session`, `__Secure-wos-session`). Expired/unrelated records
   are discarded and logging is disabled. Each allowlisted name on each host is one candidate;
   names, hosts, and browser profiles are never combined.
   A read macOS refuses is not an absent session: the importer reports `access_denied` with the
   browser and one of `full_disk_access`, `keychain_refused`, or `store_unreadable`, which ends the
   attempt and is recorded through the browser-session commit as the `browser_access_denied`
   diagnostics source. The underlying error names a store path and never leaves Swift.
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
   Individual, on-demand, team pool, and team on-demand cents-based limits map to remaining USD
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
     Models, and Grok Bot, which only describe usage-based pricing. On-demand and team windows
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
  fingerprint so two valid sessions cannot silently overwrite each other.
  Every normalized account declares its fingerprint scope.
- Account labels use a masked email or a non-sensitive display name.
- A collection attempt records its stable source identifier and an explicit outcome.
- One provider failure does not discard successful results from other requested providers.
- Requested providers collect concurrently while the report preserves catalog order
  (`PROVIDER_ORDER`): Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, then Cursor.
  Multiple sessions within one provider remain sequential so provider-owned credential refreshes do
  not race. A provider result with both successful and failed sessions remains explicitly partial in
  component state.
