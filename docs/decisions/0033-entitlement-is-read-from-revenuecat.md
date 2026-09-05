# ADR 0033: Entitlement is read from RevenueCat

- Status: Accepted
- Date: 2026-09-05
- Extends [ADR 0006](0006-managed-account-device-usage.md) and
  [ADR 0028](0028-the-boundary-answers-the-write.md)

## Context

Multi-device sync is a paid capability. Billing is one system — RevenueCat — across iOS
(StoreKit via the RevenueCat SDK), Mac (a RevenueCat Web Purchase Link), and a later Web
checkout that reuses the same link. Relay is not a store: it does not verify Apple receipts and
it does not talk to Stripe. The Account id (`accounts.id`) is the RevenueCat `app_user_id`.

A device that is not paid must not write snapshots, Usage, the device profile, or the sync
control document. A client that is not paid must still be able to read the Account so it can
show the paywall. A refusal at that write boundary has to leave evidence
([ADR 0028](0028-the-boundary-answers-the-write.md)).

## Decision

**RevenueCat is the billing system of record.** Relay consumes the webhook
(`POST /api/billing/revenuecat/webhook`) and, when the stored row is older than 24 hours or an
`active`/`grace` entitlement has passed `expires_at`, reads
`GET https://api.revenuecat.com/v1/subscribers/{app_user_id}` with the secret API key, 20s
timeout. The webhook `Authorization` header is compared to `REVENUECAT_WEBHOOK_SECRET`. The
entitlement id is `sync`. Product ids are `quota_sync_monthly` and `quota_sync_yearly`.

**The stored row is a cache, not a grant.** `entitlements` holds `status` (`active`, `grace`,
`expired`, `none`), `expires_at`, `will_renew`, `product_id`, `store`, and whether the last
write came from `webhook` or `rest`. An expired row is kept: expiry is not deletion. Events are
stored by RevenueCat `id` so a retry is ignored; the payload drops `email` and `attributes`.
An `app_user_id` that is not an Account is answered 202 and recorded, and does not create an
Account. After a valid Authorization header the webhook answers only 200 or 202.

**Paid sync is the write gate, not the read gate.** `PUT /api/v6/device/snapshots`,
`PUT /api/v6/device/usage`, `GET /api/v2/device/sync`, and `PUT /api/v2/device/profile` answer
402 `subscription_required` when status is not `active` or `grace`, and write a
`relay_write_refused` log line. `GET /api/v2/account`, `GET /api/v6/account/summary`, and
`GET /api/v6/account/usage/activity` are not gated. The Account read carries
`entitlement` and `purchase.web_url` (the Web Purchase Link base with the Account id appended
as the path). The summary carries the same `entitlement` object, and its ETag includes
`entitlements.updated_at`.

**REST failure does not invent access.** A failed refresh returns the stored row with
`stale: true`, or `none` when there is no row.

## Why

Receipt verification and a second billing provider would make Relay a store. RevenueCat already
maps App Store, Web Billing, and later Web onto one entitlement. A 24-hour cache bounds REST
volume; webhook delivery is the path that moves the row when a purchase changes. Reads stay
open so a client that has just expired can still be told to pay.

## What was given up

Relay cannot grant sync without RevenueCat. A webhook outage plus a REST failure leaves the
cached row, marked stale, for up to 24 hours. `GET /v1/subscribers/{id}` creates a RevenueCat
customer when none exists. HMAC webhook signatures are not verified; the configured
Authorization header is.

## When to revisit

If RevenueCat retires REST API v1, if HMAC signing becomes the required webhook proof, or if a
free tier of sync returns.
