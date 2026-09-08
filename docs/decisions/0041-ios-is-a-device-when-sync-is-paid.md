# ADR 0041: The phone is a Device, and paid sync is what its readings are worth

> Updated by [ADR 0048](0048-sync-is-free-and-billing-is-gone.md): the phone is still a Device,
> but there is no write gate on what it uploads. `GET /api/v2/device/sync` answers the generation
> and nothing else; there is no 402 and no sync-off banner.

- Status: Accepted
- Date: 2026-09-06
- Updates [ADR 0013](0013-readonly-ios-account-client.md), which decided `quota-ios` never
  receives write authority
- Extends [ADR 0027](0027-one-token-per-client.md), [ADR 0033](0033-entitlement-is-read-from-revenuecat.md),
  and [ADR 0034](0034-ios-collects-for-itself.md)

## Context

[ADR 0034](0034-ios-collects-for-itself.md) let the phone read a provider's own web session for
itself, and said in as many words that where those readings should go next was a separate
decision. This is that decision.

Today the readings stop on the phone. A person who connects Claude on their iPhone sees it on the
iPhone; the Mac that reports to the same Account does not, and neither does the website. That is
not a boundary anyone asked for — it is what a client with no Device and no `device:write` scope
could do. Meanwhile the write side of Relay already answers the question this raises: since
[ADR 0033](0033-entitlement-is-read-from-revenuecat.md), what a Device may write is decided by the
Account's entitlement at the write, not by which product is asking.

## Decision

**A Quota iOS session names a Device when the phone presents an installation, and reads only when
it does not.** The exchange (`POST /oauth/v2/token`) and the native Apple sign-in
(`POST /oauth/v2/apple`) both take an optional `installation_id`, `device_display_name`, and
`platform: ios`. The three travel together: an installation with no name to list it under is not
a Device an Account could ever show, and a request carrying only part of the set is refused as
malformed rather than quietly read as a reader's.

- **It is QuotaBar's path, not a second one beside it.** The installation is hashed the same way,
  the Device is found or created by installation the same way, the sessions that Device already
  had are revoked the same way, and one row is written carrying `[account:read, device:write]`.
  A client still holds one session ([ADR 0027](0027-one-token-per-client.md)); what changed is
  that two clients can now open the kind that names a Device. `PlatformSchema` gains `ios`, which
  is what makes that Device reportable at all.
- **The phone always presents its installation.** Whether its readings are worth uploading is a
  question about the Account, and the Account is not known until the session exists. So the app
  registers at sign-in, exactly as a Mac does, and the entitlement decides what happens next —
  which is the rule [ADR 0033](0033-entitlement-is-read-from-revenuecat.md) already states for
  every Mac that signs in before buying anything.
- **Sync is the write gate, and the phone reads it at the boundary.** Each refresh that collected
  something asks `GET /api/v2/device/sync` — which answers the generation the envelope must name,
  and answers 402 when sync is not paid for — and then `PUT /api/v6/device/snapshots`. A 402
  stops that refresh and shows the sync-off banner
  ([ADR 0033](0033-entitlement-is-read-from-revenuecat.md)'s copy, already on screen for an
  Account whose summary says the same). The next refresh asks again, because an entitlement that
  has just been bought is not still refused.
- **Only readings go.** The cookies stay in this device's Keychain and are never uploaded, which
  is unchanged from [ADR 0034](0034-ios-collects-for-itself.md). Usage is not uploaded either:
  this phone runs no agent, so it has none, and `PUT /api/v6/device/usage` has no caller here.
- **The installation id is the phone's own.** One Keychain item,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronizable, so a backup restored
  onto a second phone does not make two phones one Device. The display name is what the system
  calls this device.
- **The phone appears where every Device appears.** Relay's Account summary lists it like any
  other, so QuotaBar, the website, and the phone itself show it with an iOS glyph. Devices on the
  phone then shows the Account's row for it rather than the one it used to draw for itself: a
  registered iPhone is one of the Devices in the list, not a second row beside itself. A phone
  whose session names no Device keeps that local row, because nothing else reports it.

## Why

The merge that puts a phone's reading beside a Mac's already exists and is judged by one
conformance fixture in three runtimes ([ADR 0003](0003-observation-preserving-subscription-merge.md)).
What was missing was only the authority to send. Granting it as a Device rather than as a new kind
of writer means no new grant, no new scope, no new route, and no second rule about what a write
is worth — the boundary that answers a Mac answers the phone.

## What was given up

An Account that has signed in on a phone now has a Device row for it whether or not sync is ever
bought. That row reports nothing until it is, which is the same state a Mac that signed in before
buying is in, and Delete Device on the website ends it the same way.

A lost phone now holds a credential that can write to an Account, where before it held one that
could only read. It is bounded the way a Mac's is: the session dies with the Device's generation,
Delete Device advances that generation, and revoking the session is one request.

## When to revisit

If a phone ever runs an agent, Usage becomes a thing it has and
`PUT /api/v6/device/usage` becomes a route it calls; nothing about this record would have to
change for that except what is uploaded.
