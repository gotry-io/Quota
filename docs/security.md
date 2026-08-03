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
- Store QuotaBar Relay credentials in Keychain. Store edge credentials in the platform credential
  store or a user-only (`0600`) file.
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
- Do not reuse user read credentials as device write credentials.
- Owner bearer sessions may carry `quota:read` and `device:manage`; device bearer credentials carry
  only `quota:write:self`. These are distinct credential classes, and a device credential may write
  snapshots only for its own device ID.
- Store each device credential together with its Relay URL and instance ID; never send it to a
  different Relay.
- QuotaCLI's file-backed edge credential lives under `XDG_CONFIG_HOME` or the user's `.config`
  directory. Its containing QuotaCLI directory is `0700`, its credential file is `0600`, writes use
  a same-directory temporary file and atomic rename, and POSIX reads reject group/other-accessible
  directories or files.
- Local unpairing deletes only the local credential and must state that the owner still needs to
  revoke the remote device through QuotaBar or Relay device management.
- Persist only hashes of device and owner-session bearer tokens and pairing device/user codes, never
  their plaintext values. Return a generated device bearer credential only once when pairing is
  consumed.
- A self-hosted Relay must receive `QUOTA_RELAY_OWNER_TOKEN` through its deployment environment and
  fail startup when it is missing, shorter than 32 characters, or surrounded by whitespace. Hash it
  before persistence, never include it in logs or errors, and replace the fixed bootstrap session on
  every startup so rotation immediately invalidates the prior bearer.
- Persist rate limits as fixed-window counters keyed by hashes of their action and subject. Do not
  retain the raw rate-limit subject, and delete expired counters while consuming new requests.
- Store only normalized snapshots, credential hashes, required ownership and lifecycle metadata, and
  bounded rate-limit counters in D1/SQLite.
- Keep D1 migrations explicit and review changes that broaden retained user data.
- A self-hosted Relay requires a persistent SQLite volume and fails closed when storage cannot open.

## Failure behavior

- A provider failure must not fabricate a quota value.
- Preserve last-known-good remote snapshots on transient failures and mark them stale.
- Authentication, unavailable, unsupported, stale, and malformed-data outcomes remain explicit in
  normalized output.
