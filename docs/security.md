# Security baseline

This document is the source of truth for Quota's trust, credential, transport, logging, and retained
data requirements.

## Trust boundary

- Provider credentials remain on the machine running QuotaCLI.
- Relay accepts normalized quota snapshots and device/authentication material only. It must not run
  provider collectors or expose arbitrary command execution.
- The edge agent is outbound-only.

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
- Store each QuotaBar Relay controller bearer only in Keychain under the fixed
  `io.gotry.quotabar.relay-controller` service with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Relay profile metadata in UserDefaults stores
  only its derived Keychain reference, never the bearer. Store edge credentials in the platform
  credential store or a user-only (`0600`) file.
- QuotaBar registers its anonymous managed controller without an account and moves the returned
  bearer directly into Keychain. Self-hosted Settings accepts a controller bearer only through
  transient `SecureField` state. It must canonicalize and verify the Relay through discovery before
  moving the bearer into Keychain, then clear the transient value after success. The bearer must
  never enter profile metadata or other application preferences.
- Relay setup failures, safe error presentation, fixtures, logs, and screenshots must never echo or
  persist a controller bearer or an Authorization header.
- Removing a managed profile or choosing Delete All QuotaBar Data deletes its anonymous controller
  remotely before deleting its local bearer whenever the Relay is reachable; controller deletion
  cascades its devices and snapshots. QuotaBar deletes orphaned items under its controller Keychain
  service at startup. It retains only a non-secret managed-enrollment opt-out so restarting the app
  cannot recreate a controller after an explicit deletion. Ordinary Finder app removal has no
  uninstall callback, so guaranteed credential cleanup remains an explicit in-app operation.
- The `VISUAL_TEST` Relay controller-path acceptance flow uses a random Keychain service under the
  `io.gotry.quotabar.relay-controller.e2e.*` prefix, a unique UserDefaults suite, a `0600` controller
  token handoff file, loopback networking, and isolated CLI storage. It must delete the handoff
  immediately after Keychain persistence and remove the profile, Keychain item, defaults domain,
  CLI credential, SQLite database, and child processes on completion or cooperative cancellation.
  Production builds continue to use only the fixed Keychain service above.
- Only the provider-specific, stable quota-owner identifiers documented in
  [`provider-collection.md`](provider-collection.md) may produce a globally scoped account
  fingerprint. Namespace the identifier type before hashing it.
- Plans, OAuth scopes, tokens, email addresses, and anonymous fallback values must not produce a
  globally scoped fingerprint. When the quota owner is unavailable, emit a source-scoped
  fingerprint; consumers must also treat a missing fingerprint scope as source-scoped.
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
- Do not reuse controller read credentials as device write credentials.
- Controller bearer credentials may carry `quota:read` and `device:manage`; device bearer
  credentials carry only `quota:write:self`. These are distinct credential classes: a device may
  write snapshots only for its own device ID and may revoke only itself.
- Store each device credential together with its Relay URL and instance ID; never send it to a
  different Relay.
- Before collection or authenticated upload, QuotaCLI discovers the credential's saved Relay URL
  without Authorization and requires the advertised instance ID to match the saved instance ID. A
  mismatch sends no device credential and starts no provider collection.
- Before every authenticated controller request, QuotaBar discovers the profile's canonical Relay
  origin without Authorization and requires the advertised instance ID to match the bound profile.
  It refuses redirects and sends no controller bearer after a mismatch.
- QuotaCLI's file-backed edge credential lives under `XDG_CONFIG_HOME` or the user's `.config`
  directory. Its containing QuotaCLI directory is `0700`, its credential file is `0600`, writes use
  a same-directory temporary file and atomic rename, and POSIX reads reject group/other-accessible
  directories or files.
- QuotaCLI's macOS edge LaunchAgent plist is written atomically as `0600`, contains no Relay or
  provider credential, and invokes a resolved executable with a fixed argument array rather than a
  shell command. It inherits only `PATH`, `XDG_CONFIG_HOME`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`,
  `GROK_HOME`, and the three provider CLI path overrides; launchctl output is bounded and never
  rendered to users.
- QuotaCLI persists the next device snapshot sequence only after Relay acceptance. Retrying after a
  local persistence failure reuses the prior sequence and relies on Relay's idempotent `204`
  response for that device sequence.
- Unpairing first stops the macOS reporting service when present, verifies the bound Relay instance,
  and uses the device bearer to revoke that device remotely. It deletes the local credential only
  after the Relay returns the idempotent successful self-revocation response. A token hash belonging
  to that already-revoked device receives the same success; an unknown or rejected credential does
  not prove deletion and remains local for retry or explicit local-only cleanup.
- Persist only hashes of device and controller bearer tokens and pairing device/user codes, never
  their plaintext values. Return a generated controller bearer only once at managed registration
  and a generated device bearer only once when pairing is consumed.
- A self-hosted Relay must receive `QUOTA_RELAY_CONTROLLER_TOKEN` through its deployment environment
  and fail startup when it is missing, shorter than 32 characters, or surrounded by whitespace.
  Hash it before persistence, never include it in logs or errors, and replace the fixed controller
  credential on every startup so rotation immediately invalidates the prior bearer.
- Persist rate limits as fixed-window counters keyed by hashes of their action and subject. Do not
  retain the raw rate-limit subject, and delete expired counters while consuming new requests. The
  managed runtime derives anonymous-client subjects only from Cloudflare's trusted connecting-IP
  metadata; the self-hosted runtime does not trust forwarding headers.
- Revoke devices after 30 days without a successful report. Enforce inactivity during device
  authorization as well as scheduled maintenance so an expired token cannot regain activity.
- Delete a managed controller once it is at least 30 days old and none of its devices has been active
  during that window. Cascade its sessions, devices, snapshots, and associated pairing state. Never
  apply this garbage collection to the permanent self-hosted controller. Delete expired pairing
  sessions after a 24-hour diagnostic retention window.
- Device revocation prevents further reads and writes but does not delete retained normalized
  snapshots. Deleting a managed controller is the authenticated operation that cascades its devices
  and snapshots; local-only cleanup cannot make that guarantee.
- Store only normalized snapshots, credential hashes, required controller and lifecycle metadata,
  and bounded rate-limit counters in D1/SQLite. Accept at most 32 observations in one snapshot
  envelope. Do not retain account identities or external subjects.
- Keep D1 migrations explicit and review changes that broaden retained data.
- A self-hosted Relay requires a persistent SQLite volume and fails closed when storage cannot open.

## Failure behavior

- A provider failure must not fabricate a quota value.
- Preserve last-known-good remote snapshots on transient failures and mark them stale.
- Authentication, unavailable, unsupported, stale, and malformed-data outcomes remain explicit in
  normalized output.
