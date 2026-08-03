# ADR 0004: Anonymous Relay controllers

- Status: accepted
- Date: 2026-08-03

## Decision

QuotaRelay has no human account or user identity model. It isolates devices under anonymous
controllers represented only by high-entropy capability credentials.

QuotaBar registers one controller directly with a managed Relay on first use. The Relay returns the
plaintext controller bearer once, stores only its hash, and QuotaBar stores it only in the local
Keychain. A self-hosted Relay creates the same logical controller from its deployment-provided
bootstrap credential; it does not expose anonymous controller registration.

A controller bearer may approve or deny pairing, read snapshots from its devices, list those
devices, and revoke them. A device bearer may upload snapshots for only its own device and may
revoke only itself. Creating a pairing remains unauthenticated: its single-use verification code is
the explicit capability by which QuotaBar associates the requesting device with its controller.

Devices are revoked immediately when either the device or its controller requests revocation. A
managed controller may also delete itself, atomically invalidating its credential and cascading its
devices and snapshots. The Relay revokes a device after 30 days without a successful report, using
`created_at` until the first report and `last_seen_at` thereafter. Request-path enforcement provides
the authorization boundary; runtime maintenance sweeps persist revocation even when no client
returns. The same maintenance deletes a managed controller once the controller is at least 30 days
old and none of its devices has been active during that window. Self-hosted controllers are
permanent and are never removed by maintenance.

## Rationale

QuotaBar needs a private boundary for cross-device reads and revocation, but that boundary does not
need an email address, external subject, login session, or recoverable account. An opaque controller
capability provides the required authorization without collecting identity.

Giving every anonymously registered device access to a global registry would expose snapshots and
allow unrelated devices to be revoked. Giving a device only a self-scoped credential would prevent
QuotaBar from discovering and managing the CLI devices explicitly paired with it. The controller is
therefore an authorization grouping, not a representation of a person.

## Consequences

- Managed Relay setup requires no sign-in and retains no account identity.
- Losing QuotaBar's controller credential loses access to that controller; v1 has no recovery or
  cross-Mac synchronization path. An abandoned managed controller and its cascaded data are removed
  after its device-activity retention window elapses.
- Removing a managed controller locally must delete it from the Relay before erasing its Keychain
  capability whenever the Relay is reachable. If local state is erased while offline, inactivity
  expiry bounds the orphan device lifetime.
- Explicit managed deletion persists an enrollment opt-out across QuotaBar restarts. Reconnecting
  is a user action that creates a new controller; background polling cannot silently reverse a
  deletion.
- `multi_tenant` describes isolated anonymous controllers sharing one managed runtime, not user
  accounts.
- Anonymous controller registration and device-code pairing remain application-rate-limited, and
  all persisted bearer material remains hashed.
