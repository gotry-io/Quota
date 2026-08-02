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
- Read provider sessions without modifying credential files or Keychain entries.
- Store QuotaBar Relay credentials in Keychain. Store edge credentials in the platform credential
  store or a user-only (`0600`) file.
- Derive account fingerprints from stable non-secret identifiers, never from access tokens when a
  stable identifier is available.
- Mask account labels. Do not emit raw account IDs, organization IDs, or full email addresses.

## Network, processes, and diagnostics

- Send provider credentials only to the fixed official HTTPS endpoints documented in
  [`provider-collection.md`](provider-collection.md).
- Do not import browser cookies or hidden WebView state.
- Spawn explicit executables with argument arrays; never construct a shell command from provider or
  user-controlled data.
- HTTP requests have a 20-second timeout and 1 MiB response-body limit.
- JSON-RPC has a 1 MiB stdout-line limit and 64 KiB stderr-capture limit.
- Respect cancellation and terminate child processes on success, failure, timeout, and cancellation.
- Diagnostics use allowlisted error classifications. They must not contain raw HTTP bodies,
  subprocess stderr, JWTs, account identifiers, or full email addresses.
- Tests and fixtures use synthetic credentials and identities only.

## Relay authentication and storage

- Use one-time enrollment tokens. Do not reuse user read credentials as device write credentials.
- Separate `quota:read`, `device:manage`, and `quota:write:self` scopes.
- Bind every device credential to its Relay issuer and instance ID.
- Persist hashes of owner/session bearer tokens, never plaintext bearer tokens.
- Store only normalized snapshots, device public keys, credential hashes, and required ownership data
  in D1/SQLite.
- Keep D1 migrations explicit and review changes that broaden retained user data.
- A self-hosted Relay requires a persistent SQLite volume and fails closed when storage cannot open.

## Failure behavior

- A provider failure must not fabricate a quota value.
- Preserve last-known-good remote snapshots on transient failures and mark them stale.
- Authentication, unavailable, unsupported, stale, and malformed-data outcomes remain explicit in
  normalized output.
