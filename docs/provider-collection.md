# Provider collection

This document is the source of truth for current provider discovery and collection strategy order.
All implementations must also satisfy the credential, network, process, redaction, and fixture rules
in [`security.md`](security.md).

QuotaCLI owns provider access and emits normalized protocol models. QuotaRelay never handles the
provider-specific inputs described here.

## Codex

1. Discover `$CODEX_HOME/auth.json` or `~/.codex/auth.json`.
2. Prefer `GET https://chatgpt.com/backend-api/wham/usage` using the local OAuth access token and,
   when present, `ChatGPT-Account-Id`.
3. Map primary, secondary, and additional rate-limit windows without changing their used/remaining
   meaning.
4. Fall back to `codex -s read-only -a untrusted app-server` and call
   `account/rateLimits/read` when the direct OAuth result is unusable.
5. Do not fall back after a successful but malformed response; report the parser failure instead.

CodexBar, dashboard-cookie import, credential refresh, and reset-credit redemption are not runtime
dependencies or fallback strategies.

## Claude Code

1. Discover `$CLAUDE_CONFIG_DIR/.credentials.json`, `~/.claude/.credentials.json`, or the macOS
   Keychain generic password service `Claude Code-credentials`.
2. Parse only `claudeAiOauth` and require `accessToken` with a usable `user:profile` scope.
3. Call `GET https://api.anthropic.com/api/oauth/usage` with
   `anthropic-beta: oauth-2025-04-20`.
4. Map the five-hour, seven-day, model-scoped, and extra-usage windows that are present.
5. Enrich identity best-effort through `/api/oauth/profile`; usage remains valid if enrichment fails.

An absent, stale, or unreadable session is `auth_required`. A Claude Code installation configured
only for a third-party API gateway does not provide Anthropic subscription OAuth quota. Browser
cookies and interactive PTY login are not fallback strategies.

## Grok

1. Discover `$GROK_HOME/auth.json` or `~/.grok/auth.json`.
2. Prefer a non-empty `https://auth.x.ai::<client-id>` entry, then legacy sign-in entries.
3. Resolve `grok` from `PATH` and spawn `grok agent stdio`.
4. Send newline-delimited JSON-RPC `initialize`, then `x.ai/billing`.
5. Map `usage.totalUsed.val / monthlyLimit.val * 100` to a billing-cycle window.
6. Treat `-32601 Method not found` as `unsupported` and login guidance as `auth_required`.

Local context-token or session totals are not subscription quota. Browser-cookie and browser billing
fallbacks are out of scope.

## Identity and normalization

- `account.fingerprint` is SHA-256 over the provider and the most stable non-secret identifier.
- Account labels use a masked email or a non-sensitive display name.
- A collection attempt records its stable source identifier and an explicit outcome.
- One provider failure does not discard successful results from other requested providers.
- The CLI preserves provider order: Codex, Claude Code, then Grok.
