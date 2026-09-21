# Privacy

Effective date: TBD

This page is a skeleton of what QuotaRelay retains for an Account. It follows the security baseline
and is not in force until review removes the Draft label.

## What Quota collects

> Draft — pending review

- A keyed HMAC of the GitHub subject that identifies the Account
- The Account display name from the public GitHub profile
- Device display name and platform
- Normalized quota observations
- Sparse hourly Usage rows and daily rollups
- Account settings: remaining-quota thresholds keyed by an opaque subscription selector, reset and
  pace switches, an optional monthly budget amount, and whether quota history follows the Account.
  Retained until the Account is deleted.
- Downsampled remaining-quota history, only while the Account's history switch is on: buckets of
  remaining-percent readings named by provider and an opaque subscription identifier, no credential
  and no label. Kept as long as the chart for that window shows — two days for a five-hour window,
  up to thirty days for weekly and monthly ones. Deleted when the switch is turned off, when the
  Device is deleted, or when the Account is deleted. Default is on the device; nothing is uploaded
  until the switch is on.

## What Quota does not collect

> Draft — pending review

- Provider credentials, tokens, or cookies
- Prompts, completions, or tool payloads
- Local paths
- Session or conversation IDs

## Who processes the data

> Draft — pending review

- Cloudflare, as the CDN in front of QuotaRelay (Node and SQLite on the origin host)
- GitHub, for Account sign-in

## How long data is kept

> Draft — pending review

- Quota observations: 7 days
- Hourly Usage: 400 days
- Daily rollups: 800 days
- Quota history buckets (while the Account switch is on): as long as the chart for that window
  shows — two days for a five-hour window, up to thirty days for weekly and monthly ones
- Sessions: 90 days

## Deletion

> Draft — pending review

Sign in and open [Account](/my) to delete a Device or the Account. Deleting a Device removes that
Device and its Quota, Usage, and uploaded quota-history data. Deleting the Account removes the
Account. Turning off “Share quota history across your devices” deletes the uploaded buckets.

## Contact

> Draft — pending review

Questions about this draft: support@gotry.io
