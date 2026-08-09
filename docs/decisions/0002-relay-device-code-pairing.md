# ADR 0002: Relay device-code pairing

- Status: accepted
- Date: 2026-08-02
- Updated: 2026-08-09

## Decision

QuotaCLI uses an explicit OAuth-style Device Code flow to pair a machine with QuotaRelay.
Pairing is initiated with:

```text
quotacli relay pair [--relay <url>]
```

When `--relay` is omitted, the command uses `https://quota.gotry.io`. A custom URL selects a
self-hosted or alternate Relay. After pairing, the saved credential remains bound to that Relay;
later commands do not silently switch it to another instance.

The flow is:

1. QuotaCLI discovers the selected Relay.
2. QuotaCLI requests a pairing session without a owner credential.
3. Relay generates a secret device code and a separate human-readable user code.
4. QuotaCLI displays the user code and polls with the secret device code.
5. The operator enters the code in a QuotaBar instance holding an anonymous owner capability
   and approves the device.
6. Relay generates a high-entropy opaque bearer credential scoped to `quota:write:self`, stores only
   its hash, and returns the plaintext credential once.
7. QuotaCLI stores the credential in the platform credential store or a user-only file.
8. QuotaCLI performs one foreground collection and upload before treating pair as complete, so the
   owner can observe the device as reporting as soon as join succeeds.
9. On macOS, the running QuotaBar app invokes its bundled helper every five minutes. Other
   platforms require an operator-owned external scheduler for recurring uploads.

Pairing therefore authorizes the device and publishes an initial snapshot. Recurring scheduling is
owned by the host: QuotaBar's app lifecycle on macOS and an external scheduler elsewhere. Quitting
QuotaBar pauses macOS uploads without revoking the device; unpairing revokes it. Manual
`quotacli relay push` remains available for one-shot uploads and recovery after a failed initial
push.

## Credential control

- Relay generates the device code, user code, and final device credential.
- QuotaBar authenticates its anonymous owner and approves the pending session; it does not mint
  device credentials.
- Address selection is routing, not authorization. Knowing a Relay URL never grants device access.

## Security requirements

- Pairing codes expire after ten minutes or less and are single-use.
- Relay stores hashes of pairing secrets and long-lived bearer material, not plaintext values.
- QuotaCLI stores the credential with the Relay URL and instance ID and never sends it to another
  Relay.
- Pairing creation, approval, and polling are rate-limited.
- Approval requires `device:manage`; the resulting device credential receives only
  `quota:write:self` and may revoke only itself.
- Polling responses do not reveal owner or device-registry information before approval.
- Revocation immediately invalidates the issued device credential.
- Client certificates, mTLS, and proof-of-possession keys are outside v1; they may be introduced only
  if a demonstrated token-copying threat justifies their lifecycle cost.

## Consequences

- Official-service pairing needs no Relay argument, account, or manually copied token.
- Self-hosted operators specify `--relay`; QuotaBar enrolls a private owner capability automatically
  for that URL. Manual owner credentials are not part of the product model — see
  [ADR 0005](./0005-url-only-relay-enrollment.md).
- Headless machines need only outbound HTTPS access and a way for the operator to approve the
  code from QuotaBar.
- Relay persistence must represent pending, approved, denied, consumed, and expired pairing
  states.
- macOS has no QuotaCLI LaunchAgent. QuotaBar's signed Login Item is the only automatic-start path,
  and recurring uploads stop when QuotaBar exits.
- Earlier releases installed `io.gotry.quotacli.relay`; a macOS push or unpair removes that fixed
  legacy service before continuing so the old and new schedulers cannot race.
