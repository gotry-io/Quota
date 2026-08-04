# ADR 0004: Anonymous Relay owners

- Status: accepted
- Date: 2026-08-03
- Updated: 2026-08-04

## Decision

QuotaRelay has no human account or user identity model. It isolates devices under anonymous owners
represented only by high-entropy capability credentials. Managed and self-hosted runtimes use the
same owner registration, authorization, and expiration model.

An owner bearer may approve or deny pairing, read snapshots from its devices, list those devices,
and revoke them. A device bearer may upload snapshots for only its own device and may revoke only
itself. Creating a pairing remains unauthenticated: its single-use verification code is the explicit
capability by which QuotaBar associates the requesting device with its owner.

The Relay returns an owner bearer once, stores only its hash, and QuotaBar stores it only in a
user-only local Application Support file. Owner deletion atomically invalidates the capability and cascades its devices, sessions,
pairing state, and snapshots.

The Relay revokes a device after 30 days without a successful report, using `created_at` until the
first report and `last_seen_at` thereafter. It deletes an owner group after the same bounded
inactivity window when none of its devices has been active. Request-path enforcement provides the
authorization boundary; runtime maintenance persists expiry even when no client returns.

## Rationale

QuotaBar needs a private boundary for cross-device reads and lost-device revocation, but that
boundary does not need an email address, external subject, login session, recoverable account, or
server-administration credential.

Giving every anonymously registered device access to a global registry would expose snapshots and
allow unrelated devices to be revoked. Giving a device only a self-scoped credential would prevent
QuotaBar from discovering and managing the CLI devices explicitly paired with it. The owner is
therefore an authorization grouping, not a representation of a person.

## Consequences

- Anonymous Relay setup requires no sign-in and retains no account identity.
- Losing QuotaBar's capability loses access to that owner group; v1 has no recovery or cross-Mac
  synchronization path. Explicit pairing may create a new group but does not recover the old one.
- Removing an owner group locally deletes it from the Relay before erasing its local owner capability
  whenever the Relay is reachable. If local state is erased while offline, inactivity expiry bounds
  the orphaned group and device lifetime.
- `multi_tenant` describes isolated anonymous owners sharing one runtime, not user accounts.
- Owner registration and device-code pairing remain application-rate-limited, and all persisted
  bearer material remains hashed.
- ADR 0005 defines the URL-only product flow that keeps this capability out of the user interface.
