# Provider collection

This document is the source of truth for current provider discovery and collection strategy order.
All implementations must also satisfy the credential, network, process, redaction, and fixture rules
in [`security.md`](security.md).

QuotaCLI owns provider access and emits normalized protocol models. QuotaRelay never handles the
provider-specific inputs described here.

## Registration (monorepo)

Product metadata and wiring live in `packages/provider/src/catalog.ts` (not in this file). Collection
**strategy** for each provider is documented in the sections below.

To add a provider:

1. Catalog row in `packages/provider/src/catalog.ts`.
2. Strategy section in this document.
3. Collector implementation under `packages/provider/src/providers/<id>/`.
4. Factory entry in `packages/provider/src/registry.ts` (`COLLECTOR_FACTORIES`).
5. `pnpm generate:provider-catalog` for protocol `ProviderId` and Swift `ProviderID`.
6. Optional QuotaBar brand SVG named by `brandIconAsset`.

API-key providers set `config.kind: "api_key"` so `quotacli config` and QuotaBar Settings pick them up
automatically. Ambient session providers leave `config: null`.

Supported order today: Codex, Claude Code, Grok, OpenRouter.

## Codex

1. Discover `$CODEX_HOME/auth.json` or `~/.codex/auth.json`.
2. Prefer `GET https://chatgpt.com/backend-api/wham/usage` using the local OAuth access token and,
   when present, `ChatGPT-Account-Id`.
3. Map primary, secondary, and additional rate-limit windows without changing their used/remaining
   meaning.
4. Fall back to `codex -s read-only -a untrusted app-server` and call
   `account/rateLimits/read` when the direct OAuth result is unavailable or rejects the cached
   access token. Codex owns any access-token renewal performed while its app-server starts.
5. Do not fall back after a successful but malformed response; report the parser failure instead.

QuotaCLI never submits the Codex refresh token or writes `auth.json`. `CODEX_CLI_PATH` can identify
the executable when it is outside `PATH`; QuotaCLI also checks common user-local and Homebrew paths
plus the signed CLI embedded in Codex and ChatGPT desktop apps for GUI launches. Dashboard-cookie
import and reset-credit redemption are not fallback strategies.

## Claude Code

1. Discover `$CLAUDE_CONFIG_DIR/.credentials.json`, `~/.claude/.credentials.json`, or the macOS
   Keychain generic password service `Claude Code-credentials`.
2. Parse only `claudeAiOauth` and require `accessToken` with a usable `user:profile` scope.
3. On macOS, when the token is expired or within one minute of expiry, run the official Claude CLI's
   interactive `/status` path in a bounded probe-only PTY. The probe disables tools, auto-update, and
   deep-link registration; it does not run a model prompt or an authentication command. Reload the
   file or Keychain entry after Claude rotates its own credentials.
4. Call `GET https://api.anthropic.com/api/oauth/usage` with
   `anthropic-beta: oauth-2025-04-20`.
5. On HTTP 401, perform the same Claude-owned refresh once, reload credentials, and retry exactly
   once. Do not refresh for missing scopes, rate limits, malformed responses, or other failures.
6. Map the five-hour, seven-day, model-scoped, and extra-usage windows that are present.
7. Enrich identity best-effort through `/api/oauth/profile`; usage remains valid if enrichment fails.

An absent, stale, or unreadable session is `auth_required`. A Claude Code installation configured
only for a third-party API gateway does not provide Anthropic subscription OAuth quota. Browser
cookies and interactive PTY login are not fallback strategies. QuotaCLI never submits the Claude
refresh token or writes its credential file or Keychain entry. `CLAUDE_CLI_PATH` can identify the
executable when it is outside `PATH`; the native installer, legacy installer, Homebrew, and cmux
locations are also checked for GUI launches. Platforms without the bounded local PTY adapter retain
direct usage collection and report `auth_required` if Claude rejects the cached token.

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
   deprecated `config.used.val / config.monthlyLimit.val * 100` fields documented by Grok Build.
6. Billing does not expose a subscription plan field. Infer a CodexBar-compatible plan hint from local
   credentials only: OIDC scopes under `https://auth.x.ai::` (and `auth_mode: oidc`) map to
   `supergrok`; other `auth_mode` values may be kept as a weak plan slug when they look like a plan
   name. Do not invent a plan when neither signal is present.
7. If the provider-owned refresh is unavailable or the retried request is unauthorized, report
   `auth_required` and require `grok login`.

QuotaCLI never submits the refresh token itself and never starts Grok's interactive browser login.
The provider-owned CLI is solely responsible for refresh-token rotation and credential-file writes;
QuotaCLI only restores a pre-refresh snapshot when that CLI leaves credentials unreadable.
`GROK_CLI_PATH` can identify the executable when it is outside `PATH`; QuotaCLI also checks Grok's
installer directory, common user-local paths, and Homebrew paths for GUI launches.

Local context-token or session totals are not subscription quota. Browser-cookie and browser billing
fallbacks are out of scope.

## OpenRouter

Aligned with CodexBar's OpenRouter provider (credits + API-key limit meters).

1. Resolve the API key in order:
   1. Owner-only config at `$XDG_CONFIG_HOME/quotacli/providers.json` or
      `~/.config/quotacli/providers.json` (`schema_version: 1`, `providers.openrouter.api_key`),
      written by `quotacli config set openrouter --api-key-stdin` or QuotaBar Settings.
   2. Else `OPENROUTER_API_KEY` from the process environment.
   Optional base URL: config `base_url`, else `OPENROUTER_API_URL` (HTTPS only; default
   `https://openrouter.ai/api/v1`).
2. Call `GET {base}/credits` with `Authorization: Bearer <key>` and a product `X-Title` header.
3. Best-effort call `GET {base}/key` for per-key limit, remaining, reset window, and spend fields.
   Key failure must not discard a usable credits result.
4. Map windows (remaining is always `100 - used_percent` in consumers). Absolute USD fields are
   optional protocol extensions for credits-class UIs:
   - **API key budget** (primary when present): when `limit > 0`, used amount prefers
     `limit - clamp(limit_remaining)`, else the spend field matching `limit_reset`
     (`usage_daily` / `usage_weekly` / `usage_monthly`), else cumulative `usage`. Emit
     `remaining_value` / `limit_value` / `value_unit: "usd"` alongside `used_percent`.
   - **Credits**: when `total_credits > 0`, used percent is `total_usage / total_credits * 100`
     (balance = `total_credits - total_usage` on OpenRouter's side; values may be up to ~60s stale).
     Emit the same absolute USD fields for the credits window.
5. Absent key → `auth_required` with guidance to run
   `quotacli config set openrouter --api-key-stdin` (or set `OPENROUTER_API_KEY`). HTTP 401/403 →
   `auth_required`. Never print the API key, Authorization header, or response bodies.
   `config get` / `list` and menubar UI only show a masked tip (`OpenRouter ···abcd`).

Config directory is `0700` and `providers.json` is `0600`. Multi-account labeled keys are out of
scope for v1. Dashboard cookies and browser scrapes are not strategies.

## Identity and normalization

- A global `account.fingerprint` is SHA-256 over the provider, the identifier namespace, and the
  stable quota-owner identifier: Codex uses account ID; Claude Code uses organization ID; Grok uses
  team ID when present and otherwise user ID; OpenRouter uses a SHA-256 of the API key under the
  `api_key` namespace (never the raw key).
- Email is display enrichment only and never a global deduplication identity. If the provider does
  not expose its quota-owner identifier, collection still succeeds with a stable source-scoped
  fingerprint. Consumers interpret an absent `fingerprint_scope` as source-scoped for version 1
  compatibility.
- Account labels use a masked email or a non-sensitive display name.
- A collection attempt records its stable source identifier and an explicit outcome.
- One provider failure does not discard successful results from other requested providers.
- The CLI preserves provider order from the catalog (`PROVIDER_ORDER`): Codex, Claude Code, Grok,
  then OpenRouter.
