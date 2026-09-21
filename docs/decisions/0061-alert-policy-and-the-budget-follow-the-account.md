# ADR 0061: Alert policy and the budget follow the Account

- Status: Accepted
- Date: 2026-09-21
- Updates [ADR 0013](0013-readonly-ios-account-client.md), [ADR 0027](0027-one-token-per-client.md),
  [ADR 0053](0053-one-alert-delivery-package-for-both-apps.md)
- Supersedes the budget section of [ADR 0040](0040-a-period-is-folded-where-its-days-already-are.md)

## Context

Remaining-quota thresholds, reset reminders, pace alerts, and the monthly API-equivalent budget
were each device's own preference. Signing in on a second device did not bring them. [ADR
0040](0040-a-period-is-folded-where-its-days-already-are.md) said the budget was never uploaded
because it was not a fact about the Account. The owner decision is that those policy fields
follow the Account, and that notification delivery stays per device.

`account:manage` is granted only to browser sessions, and every such route also demands a web
`Origin`, so neither app can write anything today ([ADR 0013](0013-readonly-ios-account-client.md),
[ADR 0027](0027-one-token-per-client.md)). A new scope is required for this one document.

Three clients edit one map of thresholds. Whole-document last-writer-wins would let a phone that
knows one subscription erase the Mac's five.

## Decision

**Alert policy and the budget follow the Account. Delivery stays per device.**

The document is `GET` / `PUT /api/v2/account/settings` (control plane, `PROTOCOL_VERSION` 2):

```json
{
  "protocol_version": 2,
  "revision": 7,
  "updated_at": "2026-09-21T10:00:00Z",
  "alerts": {
    "reset_reminders": true,
    "pace_alerts": true,
    "thresholds": { "a1b2c3d4e5f6": [20, 10] }
  },
  "budget": { "amount_usd": "250.00", "alerts": true }
}
```

- `thresholds` keys are `SHA-256(provider|fingerprint|scope|source_id)[0:12]` in hex. Values are
  1–2 integers in 1…99, strictly descending. At most 256 selectors. Absence of a selector means
  the default pair `[20, 10]`.
- `budget.amount_usd` is a decimal string with at most two fraction digits, greater than 0 and at
  most 1_000_000, or `null` for no budget.
- `enabled` is not in the document. It is the per-device permission mirror: both apps force it
  off when the system denies notifications. Dedup state and pending reminders stay per device
  ([ADR 0053](0053-one-alert-delivery-package-for-both-apps.md)).
- An Account with no row answers the defaults at `revision: 0`.

**Writes are compare-and-set, not last-writer-wins.** `GET` answers `ETag: "<revision>"` and
`Cache-Control: private, no-cache`; `If-None-Match` is 304. `PUT` requires `If-Match`. Missing is
`428 precondition_required`. Stale is `412` with the current document in the body. A client that
gets 412 re-applies its one edit to the fresh document and retries once. Selectors it does not
recognise are written back untouched. Never prune.

**`account:settings` authorizes this document and nothing else.** It is granted to web, device,
and reader sessions from now on, and migration 0033 adds it to every live session. `PUT` requires
it; a `web` session additionally passes `requireWebOrigin`. Native clients present a bearer token
and need no Origin. Rate limit: `profileMutation` (30 / 10 min) per Account.

**First sync.** No row (`revision: 0`) and non-default local values → the device seeds the Account
(`PUT`, `If-Match: "0"`; a 412 means another device won, so adopt). A row → the Account wins;
local policy fields are overwritten with no prompt. The one merge: local thresholds for selectors
the Account document does not name are added to it once. Signed out, the last local values stay
and keep working. Signing into a different Account adopts that Account's document by the same
rule.

**One measuring basis.** Signed in, every client measures the budget against the Account's
calendar month. Signed out, against what the device has. The UI says which.

Shipped UserDefaults / `localStorage` keys stay the local copy of this document
([ADR 0053](0053-one-alert-delivery-package-for-both-apps.md)). The language-neutral contract is
`packages/protocol/fixtures/account-settings-conformance.json`.

## Consequences

- A second device sees the same thresholds and the same budget amount without a prompt.
- A phone that knows one subscription cannot erase the Mac's map: 412 plus re-apply is the
  concurrency rule.
- iOS and QuotaBar may write this one Account document. They still cannot manage identities,
  delete the Account, or publish a profile.
- The budget section of [ADR 0040](0040-a-period-is-folded-where-its-days-already-are.md) no
  longer describes the product: the amount follows the Account, and signed-in clients measure
  the same month.
