# Grok

Catalog id `grok`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

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
   new period that omits those usage fields is 0% used, not malformed. When those money fields are
   present, also emit `remaining_value` / `limit_value` / `value_unit: credits` — Grok credits are
   not dollars. Unified accounts that only report `creditUsagePercent` stay percent-only.
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
   [browser session](../provider-collection.md#browser-session) exists, call the same gRPC-web billing RPC with the catalog
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
