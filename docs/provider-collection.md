# Provider collection

This document is the source of truth for current provider discovery and collection strategy order.
All implementations must also satisfy the credential, network, process, redaction, and fixture rules
in [`security.md`](security.md). For an external baseline of CodexBar's quota, usage, and fallback
behavior across its full provider set, see
[`codexbar-platform-capabilities.md`](codexbar-platform-capabilities.md).

The shared Rust service owns provider access and emits normalized protocol models for QuotaBar and
Linux `quotacli`. QuotaRelay never handles the provider-specific inputs described here.
Provider collection does not initiate account authentication; Linux account login uses the separate
headless Device Authorization Grant described in [`security.md`](security.md).

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
Cookie hosts/names, and browser-priority prefix; capabilities may coexist.

Supported order today: Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, Cursor.

API-key HTTPS providers share the bounded request, credential resolution, URL validation, and
snapshot helpers in `packages/service/src/providers/common/`.

`auth_required` carries a result message when discovery found a source and the provider then rejected
it. A stored sign-in the provider no longer accepts recovers differently from a provider that was
never set up on this device, and that second case keeps the bare outcome and the client's setup copy.

Every collected snapshot carries `valid_until`, derived from the observation as described in
[`architecture.md`](architecture.md). Collectors do not set it and providers do not report it.

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
5. Fall back to `codex -s read-only -a untrusted app-server` and call
   `account/rateLimits/read` when the direct OAuth result is unavailable or rejects the cached
   access token. Codex owns any access-token renewal performed while its app-server starts.
6. If OAuth credentials are missing or WHAM/RPC return 401/403, and a stored ChatGPT browser session
   exists, read `GET https://chatgpt.com/api/auth/session` (then `/backend-api/me`) with the catalog
   session cookies. Use a session `accessToken` as Bearer for the same WHAM URL when present;
   otherwise send the Cookie header. QuotaBar acquires those cookies from `chatgpt.com`.
7. Do not fall back after a successful but malformed response; report the parser failure instead.

The local service never submits the Codex refresh token or writes `auth.json`. `CODEX_CLI_PATH` can identify
the executable when it is outside `PATH`; the service also checks common user-local and Homebrew paths
plus the signed CLI embedded in Codex and ChatGPT desktop apps for GUI launches. Hidden WebView
dashboard scraping and reset-credit redemption are not used.

## Claude Code

1. Discover `$CLAUDE_CONFIG_DIR/.credentials.json`, `~/.claude/.credentials.json`, or the macOS
   Keychain generic password service `Claude Code-credentials` when collection home is the
   process `HOME`. Isolated or remapped homes do not read the live Keychain.
2. Parse only `claudeAiOauth` and require `accessToken` with a usable `user:profile` scope.
3. On macOS, when the token is expired or within one minute of expiry, run the official Claude CLI's
   interactive `/status` path in a bounded probe-only PTY. The probe disables tools, auto-update, and
   deep-link registration; it does not run a model prompt or an authentication command. Reload the
   file or Keychain entry after Claude rotates its own credentials. The probe runs with
   `--allowed-tools "" --strict-mcp-config` and is driven by the CLI's output, matched without
   regard to spacing: it answers Claude's interactive prompts from a fixed table (the first-run
   folder-trust dialog for the stable, empty, owner-only probe directory under the user temp root;
   "ready to code" / "press Enter" notices; the command's own palette row), submits the slash command
   with a carriage return once output settles, treats `/usage` as rendered when the session row
   carries a percentage (nudging a panel that is still loading, leaving one that reports a load
   failure), closes the panel with Escape, then submits `/exit`. A TUI that does not leave within
   the grace period is stopped, and the whole probe is capped at 45 seconds.
4. Call `GET https://api.anthropic.com/api/oauth/usage` with
   `anthropic-beta: oauth-2025-04-20`.
5. On HTTP 401, perform the same Claude-owned refresh once, reload credentials, and retry exactly
   once. Do not refresh for missing scopes, rate limits, malformed responses, or other failures.
6. Map the five-hour, seven-day, model-scoped, and extra-usage windows that are present. Every
   weekly limit meters one seven-day cycle, so a weekly window that reports no reset of its own —
   model-scoped or not — takes the seven-day window's reset. This applies to both the OAuth body and
   the CLI panel.
7. Enrich identity best-effort through `/api/oauth/profile`; usage remains valid if enrichment fails.
8. If local OAuth credentials exist but the usage API fails (except a successful but malformed
   body), and the official Claude CLI is available on macOS, run the same bounded PTY probe with
   `/usage` and map the Settings/Usage panel. Each window is a title followed by a bar and
   `<n>% used`; take that value verbatim (a `left` / `remaining` / `available` phrasing is converted
   to used percent), matching without regard to spacing because the TUI places words with cursor
   moves. `Current session` is the five-hour window, `Current week (all models)` is
   `seven_day`, `Current week (Sonnet only)` / `(Opus)` keep their OAuth ids, and any other
   `Current week (<Model>)` row is the same `claude-weekly-scoped-<model>` window the OAuth usage
   body reports. A window's own `Resets 4pm (Asia/Shanghai)` / `Resets Aug 25 at 9am` line is read as
   a fixed grammar rather than as words, because compaction removes the spacing the TUI never
   guaranteed: the panel prints local wall-clock time, an unnamed zone is the collection timezone, a
   named zone that does not resolve is refused rather than read in this machine's, and the instant
   must fall inside the window it belongs to. Anything that does not match exactly leaves the reset
   unset rather than guessing. Missing credentials skip the probe so an unsigned-in machine
   never spawns the CLI.
9. If OAuth and CLI usage are unavailable or return 401/403, and a stored Claude browser session
   exists, send the stored allowlisted Cookie header (`sessionKey` plus optional `lastActiveOrg`)
   to `https://claude.ai/api/organizations` then `/organizations/{id}/usage`. Prefer the listed org
   matching `lastActiveOrg`, then the org on `/api/account`, unless that org is `api_disabled`;
   otherwise the first chat-capable org. Validate by mapping usage, not by the org list alone. Usage
   accepts OAuth `utilization` / `resets_at` and the web aliases `utilization_pct` / `reset_at`. The
   `sessionKey` value must start with `sk-ant-`. QuotaBar acquires `sessionKey` and optional
   `lastActiveOrg` from `claude.ai` through the same allowlisted browser-session flow as Cursor.

An absent, stale, or unreadable session is `auth_required`. A Claude Code installation configured
only for a third-party API gateway does not provide Anthropic subscription OAuth quota unless a
valid `claude.ai` browser session is stored. Interactive PTY login is not a fallback. The local
service never submits the Claude refresh token or writes its credential file or Keychain entry. `CLAUDE_CLI_PATH` can identify the
executable when it is outside `PATH`; the native installer, legacy installer, Homebrew, and cmux
locations are also checked for GUI launches. Platforms without the bounded local PTY adapter retain
direct usage collection and report `auth_required` if Claude rejects the cached token.

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
`clients[].providers[].models[]`; unknown channels remain the `unknown` provider within their
originating client.

A provider id resolves a channel only when it is a registered id that authenticates against that
vendor's own endpoints. Gateway spellings that merely proxy a vendor, such as an `-oauth` suffix on a
registered id, are not registered and stay unknown. `kimi-for-coding` and `moonshotai` resolve
`moonshot_direct`, and `deepseek` resolves `deepseek_direct`, for every collector that reads an
explicit provider id: OpenCode, Pi, and Cursor. Both channels were added after menubar-v0.0.19, so
responses narrow them for callers that do not send `usage_channels=1`;
[ADR 0012](decisions/0012-managed-data-v3.md) owns that rule.

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

Cursor enters the BillingAgent enum only in managed-data v3. The released v2 enum remains closed,
and v2 routes filter Cursor rows and snapshots so menubar-v0.0.9 through 0.0.11 continue decoding.

All scanners preserve non-empty bounded model identifiers as opaque provider text, ignore zero-
token/tool/cost internal records, and use canonical `[start_at, end_at)` UTC-hour boundaries,
bounded directory traversal, a two-million-record scan ceiling, bounded line sizes, cancellation,
and source-change checks. SQLite records an opaque file identity, size, modification time, and
parser revision. Unchanged files are skipped; a changed file's normalized rows are replaced
transactionally. Paths and file-index metadata never enter a protocol submission or IPC state. Only
complete coverage is eligible for authoritative remote replacement; empty complete coverage is valid.
Discovery always covers every canonical local source. Local reports cover indexed history, while
remote replacement remains split losslessly into bounded protocol ranges. Record/file skips and
upload partitions are summarized by the unified `quotacli doctor`/QuotaBar diagnostics report.

## Grok

1. Discover `$GROK_HOME/auth.json` or `~/.grok/auth.json`.
2. Prefer the non-empty `https://auth.x.ai::<client-id>` entry with the latest expiry, then legacy
   sign-in entries.
3. If the cached token is expired or within one minute of expiry, snapshot readable `auth.json`, then
   run the official Grok CLI headless `grok agent stdio` flow (`initialize` + `authenticate` with
   `cached_token` only). Reload only on real credential rotation. If the CLI deletes `auth.json` after
   a failed silent refresh, restore the snapshot and treat refresh as unsuccessful.
4. Call `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the local Grok OAuth
   token. On HTTP 401/403, run the same CLI refresh only when credentials have not already rotated,
   then retry once. A failed/no-op refresh must not suppress that retry. A valid cached token works
   without the `grok` executable.
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
8. If the provider-owned refresh is unavailable or the retried request is unauthorized, report
   `auth_required` and require `grok login`.
9. If OAuth credentials are missing or billing returns 401/403, and a stored Grok browser session
   exists, call the same gRPC-web billing RPC with the catalog `sso` / `sso-rw` cookies. Map used
   percent and reset from the protobuf payload. The RPC exposes only the reset instant: 20–45 days
   out is **Monthly**, anything nearer is the **Weekly** credit pool, and no reset stays
   **Billing cycle**. QuotaBar acquires those cookies from `grok.com`. grok.com may reject
   cookie-only requests that lack the browser Web Key Exchange proof; that is `auth_required`, not a
   parser failure.

The local service never submits the refresh token itself and never starts Grok's interactive browser login.
The provider-owned CLI is solely responsible for refresh-token rotation and credential-file writes;
The service only restores a pre-refresh snapshot when that CLI leaves credentials unreadable.
`GROK_CLI_PATH` can identify the executable when it is outside `PATH`; it also checks Grok's
installer directory, common user-local paths, and Homebrew paths for GUI launches.

Local context-token or session totals are not subscription quota.

## OpenRouter

Aligned with CodexBar's OpenRouter provider (credits + API-key limit meters).

1. Resolve the API key in order:
   1. Owner-only config at `$XDG_CONFIG_HOME/quotacli/providers.json` or
      `~/.config/quotacli/providers.json` (`schema_version: 1`, `providers.openrouter.api_key`),
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
   1. Owner-only config at `$XDG_CONFIG_HOME/quotacli/providers.json` or
      `~/.config/quotacli/providers.json` (`providers.deepseek.api_key`), written by QuotaBar
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
   - **5 hour** only from `limits[]` where window duration is exactly 300 minutes (also when it is
     the only entry).
4. If no API key is configured, or the Code API returns 401/403, read
   `$KIMI_CODE_HOME/credentials/kimi-code.json` or `~/.kimi-code/credentials/kimi-code.json`
   read-only. Use a fresh `access_token` (`expires_at` more than 60 seconds away) against the same
   `/coding/v1/usages` URL. Do not redeem `refresh_token` or write `device_id` / credential files.
5. If API and CLI credentials are unavailable or unauthorized, and a stored Kimi browser session
   exists, `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages` with
   `Authorization: Bearer` from the `kimi-auth` cookie. Map the `FEATURE_CODING` usage object with
   the same weekly / 5-hour rules. QuotaBar acquires `kimi-auth` from `www.kimi.com` / `kimi.com`.
6. Absent key/CLI credential and no browser session → `auth_required`. HTTP 401/403 →
   `auth_required`.

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

Cursor prefers a signed-in Cursor.app session, then a stored browser session. Codex, Claude, Grok,
and Kimi declare the same catalog browser-session capability alongside their existing OAuth/API-key
sources. Quota snapshots follow the product default and sync to the managed Account.

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
2. QuotaBar opens `https://authenticator.cursor.sh/` in one explicit supported browser and polls
   only that browser's profiles. If the default HTTPS handler is unsupported, the user chooses a
   supported browser before any URL opens. Linux QuotaCLI does not acquire browser sessions.
3. SweetCookieKit queries the catalog's four exact hosts (`cursor.com`, `www.cursor.com`,
   `cursor.sh`, `authenticator.cursor.sh`) and seven exact session Cookie names. Expired/unrelated
   records are discarded and logging is disabled. Complementary same-host cookies share one header
   (Grok `sso`/`sso-rw`, numbered ChatGPT session-token chunks, plus optional `_account` or
   `lastActiveOrg`). Unrelated allowlisted names stay one candidate each, so Cursor
   `wos-session` and `WorkosCursorSessionToken` are never combined. Hosts and browser profiles are
   never combined.
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
7. Catalog `account_sync` is true and `account_sync_protocol` is 3, so Cursor snapshots enter v3
   envelopes and Account summaries. Browser cookies and the Cursor.app access token still never
   leave the local service. Released v2 routes keep the original provider enum and filter Cursor
   observations.

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
