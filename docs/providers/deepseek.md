# DeepSeek

Catalog id `deepseek`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

Aligned with CodexBar's DeepSeek **API-key balance** path. CodexBar's Automatic also has a Platform
Web path that reads Chrome `localStorage` `userToken` on `platform.deepseek.com`; Quota does **not**
import browser localStorage (see [`security.md`](../security.md)). Platform detailed usage therefore
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
