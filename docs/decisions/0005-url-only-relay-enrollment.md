# ADR 0005: URL-only Relay enrollment and private QuotaBar device groups

- Status: Superseded by [ADR 0006](./0006-managed-account-device-usage.md) on 2026-08-10
- Date: 2026-08-04

A user configured only a Relay URL. QuotaBar offered two remote-device operations — pair a device,
and view or remove the devices this QuotaBar paired — and no user-facing owner, owner credential,
Relay profile, server token, capability list, or global registry; a custom Relay differed from the
official one only by its address. Behind that, QuotaBar silently registered an anonymous owner
capability per installation and endpoint ([ADR 0004](./0004-anonymous-relay-owners.md)), stored the
plaintext in a user-only file, and used it to approve the device-code sessions of
[ADR 0002](./0002-relay-device-code-pairing.md); the capability authorized only that private group
and never Relay administration. Settings held one **Remote Devices** list whose only prominent
action was **Pair Device**, self-hosted admission needed nothing beyond a listener, URL, and
storage, and exposure policy stayed an infrastructure concern rather than another credential field.
Protocol v1 spoke owner terminology, and no retained production data predated the decision, so
replaced schemas were deleted rather than migrated.

It was replaced because hiding a capability is not the same as not needing one: with the Account of
[ADR 0006](./0006-managed-account-device-usage.md), the authorization boundary is something the user
can sign back into, so the hidden owner credential and its URL-only framing had nothing left to do.
