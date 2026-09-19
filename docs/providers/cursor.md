# Cursor

Catalog id `cursor`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

Cursor prefers a signed-in Cursor.app session, then a stored browser session. It is the only
provider whose catalog row is `exclusive`: it has no CLI sign-in command and no API key, so
Settings omits the sign-in row for it. Quota snapshots follow the product default and sync to the
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
2. Acquisition follows [Browser session](../provider-collection.md#browser-session): consent first, then
   `https://authenticator.cursor.sh/` opened in the one resolved browser.
3. SweetCookieKit queries the catalog's four exact hosts (`cursor.com`, `www.cursor.com`,
   `cursor.sh`, `authenticator.cursor.sh`) and the three exact WorkOS session Cookie names
   (`WorkosCursorSessionToken`, `wos-session`, `__Secure-wos-session`). All three are whole
   sessions, so each name on each host is one candidate and none of them is ever combined.
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
   Individual, **On-Demand**, **Team Pool**, and **Team On-Demand** cents-based limits map to remaining USD
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
     Models, and Grok Bot, which only describe usage-based pricing. On-Demand and team windows
     remain.
7. Catalog `account_sync` is true, so Cursor snapshots enter managed envelopes and Account
   summaries. Browser cookies and the Cursor.app access token still never leave the local service.
