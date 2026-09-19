# Kimi Code

Catalog id `kimi`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

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
   [browser session](../provider-collection.md#browser-session) exists, `POST
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
