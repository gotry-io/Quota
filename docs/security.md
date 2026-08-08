# Security baseline

This document is the source of truth for Quota's trust, credential, transport, logging, and retained
data requirements.

## Trust boundary

- Provider credentials remain on the machine running QuotaCLI.
- Relay accepts normalized quota snapshots and device/authentication material only. It must not run
  provider collectors or expose arbitrary command execution.
- The Relay agent is outbound-only.

## Credentials and identity

- Never upload, persist, print, or log provider access tokens, refresh tokens, cookies, credential
  files, raw credential payloads, or authorization headers.
- Do not modify provider credential files or Keychain entries directly. QuotaCLI may invoke the
  official provider CLI through the bounded flows documented in [`provider-collection.md`](provider-collection.md):
  Codex app-server, Claude Code's probe-only `/status` PTY, and Grok's headless cached-token ACP
  authentication. Only the provider CLI owns refresh-token exchange and credential rotation.
- QuotaBar may cache one last normalized local collection report in its application preferences for
  immediate startup. The cache may contain masked labels and account fingerprints, but never raw
  provider responses, credential payloads, access tokens, refresh tokens, cookies, or headers.
- Store each QuotaBar Relay owner bearer only in a user-only (`0600`) file at
  `~/Library/Application Support/io.gotry.quotabar/owners.json` (directory `0700`). Internal Relay
  endpoint metadata in UserDefaults stores only its derived credential reference, never the bearer.
  Store Relay device credentials in the platform credential store or a user-only (`0600`) file.
- QuotaBar registers an anonymous owner capability for any discovered Relay URL without an account
  and moves the returned bearer directly into `owners.json`. Users never enter, view, or name that
  capability. QuotaBar must canonicalize and verify the Relay through discovery before registration,
  then store the bearer only in that file. The bearer must never enter endpoint metadata, UserDefaults,
  or other application preferences.
- Relay setup failures, safe error presentation, fixtures, logs, and screenshots must never echo or
  persist an owner bearer or an Authorization header.
- Choosing Delete All QuotaBar Data deletes each reachable owner group remotely before deleting the
  local owners file; owner deletion cascades its devices and snapshots. QuotaBar deletes orphaned
  owner records that have no endpoint reference at startup. Background polling never recreates an
  endpoint the user did not pair again. When the user explicitly starts Pair Device, a missing,
  rejected, expired, or instance-mismatched owner capability may be replaced with a new isolated
  owner after its unusable local endpoint record is removed; the inaccessible old group remains
  bounded by inactivity collection. Ordinary Finder app removal has no uninstall callback, so
  guaranteed credential cleanup remains an explicit in-app operation.
- The `VISUAL_TEST` Relay owner-path acceptance flow uses an isolated `owners.json` path, a unique
  UserDefaults suite, loopback networking, and isolated CLI storage. It must remove the endpoint
  record, owners file, defaults domain, CLI credential, SQLite database, and child processes on
  completion or cooperative cancellation.
- Only the provider-specific, stable quota-owner identifiers documented in
  [`provider-collection.md`](provider-collection.md) may produce a globally scoped account
  fingerprint. Namespace the identifier type before hashing it. For OpenRouter, the global identity
  material is a hash of the API key under the `api_key` namespace; the raw key must never appear in
  reports, logs, or diagnostics.
- Optional API-key providers (catalog `config.kind === "api_key"`) may store secrets only in the
  owner-only QuotaCLI config file (`$XDG_CONFIG_HOME/quotacli/providers.json` or
  `~/.config/quotacli/providers.json`, directory `0700`, file `0600`). QuotaBar Settings writes the
  same file. Never store provider API keys in UserDefaults, logs, or Relay payloads. Prefer
  interactive `quotacli config set <provider>` (hidden prompt); do not accept raw keys on argv or
  unbounded secret stdin. `config get` / `list` and Settings UI may show only a masked tip.
  QuotaCLI and QuotaBar coordinate updates with an owner-only lock directory and use atomic file
  replacement, so concurrent writers cannot lose another provider's update.
  API keys available only from process environment are foreground-only: the macOS LaunchAgent
  intentionally does not inherit provider secret variables and therefore cannot collect them.
- Plans, OAuth scopes, tokens, email addresses, and anonymous fallback values must not produce a
  globally scoped fingerprint. When the quota owner is unavailable, emit a source-scoped
  fingerprint. Every normalized account must declare its fingerprint scope.
- Mask account labels. Do not emit raw account IDs, organization IDs, or full email addresses.

## Network, processes, and diagnostics

- Send provider credentials only to the fixed official HTTPS endpoints documented in
  [`provider-collection.md`](provider-collection.md).
- Do not import browser cookies or hidden WebView state.
- Spawn explicit executables with argument arrays; never construct a shell command from provider or
  user-controlled data.
- Claude's macOS PTY adapter uses a fixed Quota-owned `expect` program and passes the resolved Claude
  executable as an argument; it never interpolates provider data into executable code.
- HTTP requests have a 20-second timeout and 1 MiB response-body limit.
- JSON-RPC has a 1 MiB stdout-line limit and 64 KiB stderr-capture limit.
- QuotaBar bounds each bundled QuotaCLI collection to 60 seconds and 1 MiB of stdout. It discards
  helper stderr and terminates the helper on timeout, cancellation, or output overflow.
- Respect cancellation and terminate child processes on success, failure, timeout, and cancellation.
- Diagnostics use allowlisted error classifications. They must not contain raw HTTP bodies,
  subprocess stderr, JWTs, account identifiers, or full email addresses.
- Tests and fixtures use synthetic credentials and identities only.

## Relay authentication and storage

- Device enrollment follows
  [`decisions/0002-relay-device-code-pairing.md`](decisions/0002-relay-device-code-pairing.md).
- Do not reuse owner read credentials as device write credentials.
- Owner bearer credentials may carry `quota:read` and `device:manage`; device bearer
  credentials carry only `quota:write:self`. These are distinct credential classes: a device may
  write snapshots only for its own device ID and may revoke only itself.
- Store each device credential together with its Relay URL and instance ID; never send it to a
  different Relay.
- Before collection or authenticated upload, QuotaCLI discovers the credential's saved Relay URL
  without Authorization and requires the advertised instance ID to match the saved instance ID. A
  mismatch sends no device credential and starts no provider collection.
- Before every authenticated owner request, QuotaBar discovers the endpoint record's canonical
  Relay origin without Authorization and requires the advertised instance ID to match that record.
  It refuses redirects and sends no owner bearer after a mismatch.
- QuotaCLI's file-backed Relay device credential lives at
  `$XDG_CONFIG_HOME/quotacli/device.json` or `~/.config/quotacli/device.json`. Its containing
  QuotaCLI directory is `0700`, its credential file is `0600`, writes use a same-directory temporary
  file and atomic rename, and POSIX reads reject group/other-accessible directories or files.
- QuotaCLI's macOS Relay LaunchAgent plist is written atomically as `0600`, contains no Relay or
  provider credential, and invokes a resolved executable with a fixed `relay push` argument array
  rather than a shell command. It inherits only `PATH`, `XDG_CONFIG_HOME`, `CODEX_HOME`,
  `CLAUDE_CONFIG_DIR`, `GROK_HOME`, and the three provider CLI path overrides; launchctl output is
  bounded and never rendered to users. Pairing installs the agent; unpairing removes it.
- QuotaCLI persists the next device snapshot sequence only after Relay acceptance. Retrying after a
  local persistence failure reuses the prior sequence and relies on Relay's idempotent `204`
  response for that device sequence.
- Unpairing first stops the macOS reporting service when present, verifies the bound Relay instance,
  and uses the device bearer to revoke that device remotely. It deletes the local credential only
  after the Relay returns the idempotent successful self-revocation response. A token hash belonging
  to that already-revoked device receives the same success; an unknown or rejected credential does
  not prove deletion and remains local for retry or explicit local-only cleanup.
- Persist only hashes of device and owner bearer tokens and pairing device/user codes, never their
  plaintext values. Return a generated owner bearer only once at anonymous registration and a
  generated device bearer only once when pairing is consumed.
- A self-hosted Relay starts with public URL and persistent SQLite configuration only. It does not
  accept or require a deployment bootstrap credential. Operators who need a private service restrict
  network access at the reverse proxy, firewall, VPN, or identity-aware gateway; that policy is not
  another QuotaBar credential field.
- Persist rate limits as fixed-window counters keyed by hashes of their action and subject. Do not
  retain the raw rate-limit subject, and delete expired counters while consuming new requests. The
  managed runtime derives anonymous-client subjects only from Cloudflare's trusted connecting-IP
  metadata; the self-hosted runtime does not trust forwarding headers. Owner registration and pairing
  rate limits remain effective in both modes.
- Revoke devices after 30 days without a successful report. Enforce inactivity during device
  authorization as well as scheduled maintenance so an expired token cannot regain activity.
- Delete an anonymous owner group once it is at least 30 days old and none of its devices has been
  active during that window. Cascade its sessions, devices, snapshots, and associated pairing state.
  Apply this lifecycle in both managed and self-hosted modes. Delete expired pairing sessions after
  a 24-hour diagnostic retention window.
- Device revocation prevents further reads and writes but does not delete retained normalized
  snapshots. Deleting an owner group is the authenticated operation that cascades its devices and
  snapshots; local-only cleanup cannot make that guarantee.
- Store only normalized snapshots, credential hashes, required owner and lifecycle metadata,
  and bounded rate-limit counters in D1/SQLite. Accept at most 32 observations in one snapshot
  envelope. Do not retain account identities or external subjects.
- Keep D1 migrations explicit and review changes that broaden retained data.
- A self-hosted Relay requires a persistent SQLite volume and fails closed when storage cannot open.

## Failure behavior

- A provider failure must not fabricate a quota value.
- Preserve last-known-good remote snapshots on transient failures and mark them stale.
- Authentication, unavailable, unsupported, stale, and malformed-data outcomes remain explicit in
  normalized output.
