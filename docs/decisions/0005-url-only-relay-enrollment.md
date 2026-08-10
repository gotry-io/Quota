# ADR 0005: URL-only Relay enrollment and private QuotaBar device groups

> Status: Superseded by [ADR 0006](./0006-managed-account-device-usage.md) on 2026-08-10.

- Status: accepted
- Date: 2026-08-04
- Builds on: [ADR 0002](./0002-relay-device-code-pairing.md) and
  [ADR 0004](./0004-anonymous-relay-owners.md)

## Context

QuotaRelay needs an authorization boundary so one QuotaBar can read and revoke only the devices it
paired. That boundary is not a user account and does not confer Relay administration rights.
Exposing that implementation capability, Relay profiles, or server capabilities as setup concepts
would make a simple device-pairing task look like server administration.

The managed and self-hosted runtimes already share the same pairing and storage core. Their product
model should also be the same: a Relay is an endpoint, while each QuotaBar privately owns the group
of devices that it explicitly pairs through that endpoint.

## Decision

### Product model

Users configure only a Relay URL. QuotaBar presents two remote-device operations:

1. pair a device through the selected Relay; and
2. view or remove devices paired by this QuotaBar.

There is no user-facing owner, owner credential, Relay profile administration, server
token, capability list, or global device registry. A custom Relay differs from the official Relay
only by its URL.

QuotaBar may retain endpoint/profile records internally to bind discovery metadata and local owner
credential references to the correct Relay instance. Those records are implementation state, not a
product object that users name, make default, or manage on a separate screen.

### Private authorization boundary

For each QuotaBar installation and Relay endpoint, QuotaBar automatically registers an anonymous,
opaque owner capability. Protocol v1 represents this boundary with owner endpoints and wire fields.
The capability is never requested from the user, rendered in UI, written to profile metadata,
logged, or treated as a Relay-administration credential. The plaintext value is returned once and
stored only in a user-only local Application Support file; Relay stores only its hash.

The capability authorizes only the private group created by that QuotaBar on that Relay: approving
or denying its pairing sessions, reading snapshots from its paired devices, listing those devices,
and revoking those devices. It cannot enumerate another QuotaBar's group, alter Relay configuration,
or administer the server. Both managed and self-hosted runtimes allow this anonymous registration
and enforce the same isolation.

This hidden capability is necessary because knowledge of a Relay URL or an eight-character pairing
code must not grant access to existing device snapshots. It is an authorization grouping, not a
human identity, account, recovery secret, or product-level management token.

### Pairing and device lifecycle

QuotaCLI's v1 device-code flow selects a Relay URL, creates a
short-lived pairing session, shows the human-readable code, and polls with its secret device code.
QuotaBar discovers that same endpoint, automatically ensures its private owner capability, and
approves the code. Relay then returns a separate write-only, self-scoped device bearer to QuotaCLI.

A paired device owns its reporting lifecycle. It can revoke itself when `quotacli relay unpair` is
run. QuotaBar retains a small **Remove Device** action for its own group so a lost or compromised
machine can be revoked without access to that machine. Relay revokes devices after 30 days without a
successful report, and removes an inactive anonymous owner group after the same bounded inactivity
window. Explicit owner deletion invalidates the capability and cascades its devices and snapshots.
Self-hosted owner groups are not permanent.

Pairing remains single-use, short-lived, and rate-limited. Device and owner bearers remain distinct:
a device can upload and revoke only itself; an owner can read and manage only its own paired group.

### Self-hosted Relay admission

A self-hosted runtime needs only its normal listener, public URL, and persistent storage
configuration. Anonymous owner registration uses the same application rate limits, hashed bearer storage, inactivity
collection, bounded snapshot retention, and per-owner isolation as the managed runtime.

An Internet-exposed self-hosted Relay can still receive registration and pairing traffic from
unknown clients. This does not expose another owner's data, but it can consume bounded service
resources. Operators who need a private service should restrict network access at the reverse proxy,
firewall, VPN, or identity-aware gateway. Quota does not turn that deployment policy into another
credential field in QuotaBar.

### QuotaBar information architecture

Settings contains a single **Remote Devices** destination. It opens one list of devices paired by
this QuotaBar, with the canonical Relay URL shown as quiet metadata only when it disambiguates
devices from multiple endpoints. The only prominent action is **Pair Device**.

Pairing defaults to the official Relay. The user may choose a previously used endpoint or **Other
Relay…** and enter its URL. QuotaBar validates Relay discovery and instance binding, registers its
private capability when necessary, then accepts the pairing code. There is no separate **Add
Relay** flow and no advanced credential section.

Deleting all QuotaBar data still attempts to delete each reachable owner group before erasing the
local owners file. If the Relay is unreachable and the user explicitly chooses local-only deletion,
inactivity collection bounds the orphaned remote data lifetime.

### Protocol and persistence

Protocol v1 starts with owner terminology: `POST /api/v1/owners` returns `owner_token`, and owner
authorization is kept separate from device authorization. The Relay schema starts directly with
`owners`, `owner_sessions`, devices, pairing sessions, snapshots, and rate-limit counters.

No product or retained production database predates this decision. Replaced schemas, bootstrap
paths, aliases, optional decoding defaults, and data-upgrade branches are deleted instead of carried
forward. Local development databases are disposable and must be recreated from the canonical
initial migration.

## Consequences

- Managed and self-hosted pairing have one mental model and one QuotaBar flow.
- Users never copy, label, rotate, or reason about owner credentials.
- QuotaBar still holds a least-privileged local owner capability because private reads and
  lost-device revocation cannot be secured by URL knowledge alone.
- Losing local QuotaBar state loses access to that isolated device group; v1 still has no identity,
  recovery, or cross-Mac synchronization model. An explicit Pair Device action may create a fresh
  isolated owner for the same URL when saved access is missing, rejected, expired, or bound to an
  old Relay instance; it does not recover the old group. Inactivity collection bounds abandoned
  data.
- A self-hosted Relay's exposure policy is an infrastructure concern. Relay-level rate limiting,
  retention, and isolation remain mandatory even on a privately deployed instance.
- Internal endpoint records remain an implementation detail, but user-visible flows and copy
  describe endpoints and remote devices rather than owners or Relay administration.
