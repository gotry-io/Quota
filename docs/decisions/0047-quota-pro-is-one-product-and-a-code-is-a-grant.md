# ADR 0047: Quota Pro is one product, and a code is a grant

> Superseded by [ADR 0048](0048-sync-is-free-and-billing-is-gone.md): there is no product and no
> code, because sync is free.

- Status: Accepted
- Date: 2026-09-07
- Updates [ADR 0033](0033-entitlement-is-read-from-revenuecat.md)

## Context

[ADR 0033](0033-entitlement-is-read-from-revenuecat.md) made RevenueCat the billing system of
record and named the paid write gate `sync`, with `quota_sync_monthly` and `quota_sync_yearly`.
The product being sold is one thing — Quota Pro — billed monthly or yearly, and a later Lifetime
has to be representable even while it is not sold. Community codes have to grant that same
entitlement without Relay becoming a store.

## Decision

**There is one entitlement, `pro`.** Product ids are `quota_pro_monthly` and `quota_pro_yearly`.
The write gate is unchanged: snapshots, Usage, the device profile, and device sync still answer
402 `subscription_required` unless status is `active` or `grace`. The message is
`Quota Pro is required.` Lifetime is not a store product in this change. It is the same
entitlement with `expires_at: null` and `will_renew: false` — there is nothing to renew. Relay
accepts RevenueCat `NON_RENEWING_PURCHASE` for that row.

**A code is a grant Relay issues and RevenueCat records.** Relay stores the code, checks it, and
counts redemptions. A redeem reserves its count first, in one atomic write, so two concurrent
redeems of a one-use code cannot both be granted; the reservation is given back when the grant
fails. A reserved redeem then calls RevenueCat
`POST /v1/subscribers/{account_id}/entitlements/pro/promotional` with the code's duration
(`weekly`, `monthly`, `two_month`, `three_month`, `six_month`, `yearly`, `lifetime`). The
subscriber that comes back is folded and stored the same way a REST refresh is. RevenueCat
remains the system of record; the D1 row remains a cache.

**Redeem is a web action.** The Account owns the entitlement, so a web session or an App session
with `account:read` may redeem at `POST /api/v2/account/redeem`. The form lives on the website
and Mac opens that page. iOS does not present a custom code field: App Review 3.1.1 refuses
license keys, and the phone redeems only through Apple's Offer Code sheet. A web redeem reaches
iOS through the same Account entitlement.

Codes are 16 Crockford characters, shown as `QUOTA-XXXX-XXXX-XXXX-XXXX`.
`POST /api/admin/redemption-codes` issues them under `REDEMPTION_ADMIN_SECRET`.

## Why

One entitlement keeps every client on one paywall. Promotional grants reuse RevenueCat's
duration vocabulary instead of inventing a second grant table that would have to be reconciled
with webhooks. Putting the custom field only on the web keeps the iOS binary inside Apple's
own redeem path.

## What was given up

A code that was redeemed and later rolled back or deleted in RevenueCat is not uncounted here.
Relay recorded the redemption when the grant succeeded, and it does not watch RevenueCat for a
later reversal of that promotional entitlement.

## When to revisit

If Lifetime is sold as a store product, if Apple's Offer Code path is no longer enough on iOS,
or if a reversed promotional grant has to unwind the redemption count.
