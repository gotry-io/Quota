# ADR 0002: Relay device-code pairing

- Status: accepted
- Date: 2026-08-02

## Decision

QuotaCLI uses an explicit OAuth-style Device Code flow to pair an edge machine with QuotaRelay.
Pairing is initiated with:

```text
quotacli edge pair [--relay <url>]
```

When `--relay` is omitted, the command uses `https://quota.gotry.io`. A custom URL selects a
self-hosted or alternate Relay. After pairing, the saved credential remains bound to that Relay;
later commands do not silently switch it to another instance.

The flow is:

1. QuotaCLI discovers the selected Relay.
2. QuotaCLI requests a pairing session without authenticating as an owner.
3. Relay generates a secret device code and a separate human-readable user code.
4. QuotaCLI displays the user code and polls with the secret device code.
5. The user enters the code in an authenticated QuotaBar session and approves the device.
6. Relay generates a high-entropy opaque bearer credential scoped to `quota:write:self`, stores only
   its hash, and returns the plaintext credential once.
7. QuotaCLI stores the credential in the platform credential store or a user-only file.

Pairing stores identity and authorization material only. It does not start recurring quota uploads;
edge reporting requires a separate explicit start or service-install action.

## Credential ownership

- Relay generates the device code, user code, and final device credential.
- QuotaBar authenticates the owner and approves the pending session; it does not mint credentials.
- Address selection is routing, not authorization. Knowing a Relay URL never grants device access.

## Security requirements

- Pairing codes expire after ten minutes or less and are single-use.
- Relay stores hashes of pairing secrets and long-lived bearer material, not plaintext values.
- QuotaCLI stores the credential with the Relay URL and instance ID and never sends it to another
  Relay.
- Pairing creation, approval, and polling are rate-limited.
- Approval requires `device:manage`; the resulting device credential receives only
  `quota:write:self`.
- Polling responses do not reveal owner or account information before approval.
- Revocation immediately invalidates the issued device credential.
- Client certificates, mTLS, and proof-of-possession keys are outside v1; they may be introduced only
  if a demonstrated token-copying threat justifies their lifecycle cost.

## Consequences

- Official-service pairing needs no Relay argument or manually copied token.
- Self-hosted users specify `--relay` and first authenticate QuotaBar as the Relay owner.
- Headless edge machines need only outbound HTTPS access and a way for the user to approve the code
  from QuotaBar.
- Relay persistence must represent pending, approved, denied, consumed, and expired pairing
  states.
