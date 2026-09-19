# LiteLLM

Catalog id `litellm`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

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
