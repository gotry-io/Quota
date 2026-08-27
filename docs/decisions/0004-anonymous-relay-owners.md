# ADR 0004: Anonymous Relay owners

- Status: Superseded by [ADR 0006](./0006-managed-account-device-usage.md) on 2026-08-10
- Date: 2026-08-03

QuotaRelay had no human identity model. Devices were isolated under anonymous owners represented
only by a high-entropy capability credential, and managed and self-hosted runtimes shared one
registration, authorization, and expiry model. An owner bearer could approve or deny a pairing, read
its own devices' snapshots, list them, and revoke them; a device bearer could upload for itself and
revoke itself; creating a pairing stayed unauthenticated because its single-use code was the
capability that bound the requesting device to an owner. Relay returned an owner bearer once and
stored only its hash, QuotaBar kept the plaintext in a user-only Application Support file, and
deleting an owner cascaded its devices, sessions, pairing state, and snapshots. Relay revoked a
device after 30 days without a successful report and collected an owner group after the same
inactivity window. The owner was an authorization grouping, deliberately not a person: no e-mail, no
external subject, no login session, and no recovery.

It was replaced because that had no recovery and no way to reach the same data from a second Mac —
[ADR 0006](./0006-managed-account-device-usage.md) makes the boundary a signed-in Account instead.
