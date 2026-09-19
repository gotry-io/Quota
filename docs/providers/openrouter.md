# OpenRouter

Catalog id `openrouter`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

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
