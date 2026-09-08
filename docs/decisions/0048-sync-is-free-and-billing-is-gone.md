# ADR 0048: Sync is free, and billing is gone

- Status: Accepted
- Date: 2026-09-08
- Supersedes [ADR 0033](0033-entitlement-is-read-from-revenuecat.md) and
  [ADR 0047](0047-quota-pro-is-one-product-and-a-code-is-a-grant.md)
- Updates [ADR 0041](0041-ios-is-a-device-when-sync-is-paid.md), whose write gate is removed
- Extends [ADR 0006](0006-managed-account-device-usage.md) and
  [ADR 0028](0028-the-boundary-answers-the-write.md)

## Context

[ADR 0033](0033-entitlement-is-read-from-revenuecat.md) made multi-device sync a paid capability
read from RevenueCat, and [ADR 0047](0047-quota-pro-is-one-product-and-a-code-is-a-grant.md) named
the product Quota Pro and made a redemption code a promotional grant. Between them they added a
store integration, a webhook, four D1 tables, an admin route, a redeem route, six error codes, a
402 at four write endpoints, and a paywall on three clients — all so that an Account could be told
it may not write its own readings.

Nothing was ever charged. What that machinery bought was a decision that has now been made the
other way: the readings a person's own devices collect are worth more merged than withheld, and
the cost of holding them is D1's, not a subscriber's.

## Decision

**Multi-device sync is free for every Account, and Relay has no billing system.** There is no
entitlement, no product, no paywall, no redemption code, and no switch that would restore one.

- **Every logged-in Device writes.** `PUT /api/v6/device/snapshots`, `PUT /api/v6/device/usage`,
  `GET /api/v2/device/sync`, and `PUT /api/v2/device/profile` are decided by the session alone —
  a Device generation that is current and a `device:write` scope. There is no 402 anywhere in
  Relay, and no `relay_write_refused` line, because there is no refusal left to record.
- **The Account reads carry no entitlement.** `GET /api/v2/account` and
  `GET /api/v6/account/summary` drop `entitlement` and `purchase`. The summary ETag no longer
  has an entitlement component; it moves with the Account, its Devices, its snapshots, and its
  Usage revision.
- **The routes are gone, not disabled.** `POST /api/billing/revenuecat/webhook`,
  `POST /api/admin/redemption-codes`, and `POST /api/v2/account/redeem` are removed, along with
  `REVENUECAT_WEBHOOK_SECRET`, `REVENUECAT_SECRET_KEY`, `REVENUECAT_WEB_PURCHASE_URL`, and
  `REDEMPTION_ADMIN_SECRET`. `RelayErrorCode` loses `subscription_required`, `code_invalid`,
  `code_expired`, `code_already_redeemed`, `code_exhausted`, and `billing_unavailable`.
- **The tables are dropped.** Migration `0031_drop_billing.sql` drops `code_redemptions`,
  `redemption_codes`, `entitlement_events`, and `entitlements`. The applied migrations that
  created them are not rewritten.
- **The clients lose the surface, not just the switch.** Quota Pro, the paywall, the Mac's Web
  Purchase Link, the website's redeem form, and every "Sync is off" string are deleted from
  iOS, QuotaBar, and the website rather than hidden behind a flag.

## Why

A gate that never collected money is pure cost: it is the largest single source of error codes,
client state, and product copy in a repository whose subject is quota, and every one of those
pieces has to be answered by three runtimes. Removing it removes the reason for a store
integration, the reason for a cache with a staleness flag, and the reason a phone that has just
collected a reading has to ask permission before sending it.

## What was given up

There is no revenue gate, so nothing bounds how much an Account may store except Relay's own
free-tier budget — the D1 daily row limits that [ADR 0031](0031-the-usage-fold-is-stored.md)
already made the binding constraint on the Account path. Growth is now answered by the fold, the
retention sweeps, and the query shapes, with no billing lever behind them.

Accounts that hold a RevenueCat entitlement or a redeemed code keep nothing here: the rows are
dropped and RevenueCat is no longer read. The repository has no released paid build, so nothing
that shipped is being taken away.

## When to revisit

If Quota is to charge for something. That change starts here, not from the removed code: none of
it is left to switch back on.
