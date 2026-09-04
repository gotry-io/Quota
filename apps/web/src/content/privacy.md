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

## What Quota does not collect

> Draft — pending review

- Provider credentials, tokens, or cookies
- Prompts, completions, or tool payloads
- Local paths
- Session or conversation IDs

## Who processes the data

> Draft — pending review

- Cloudflare, for QuotaRelay on Workers and D1
- GitHub, for Account sign-in

## How long data is kept

> Draft — pending review

- Quota observations: 7 days
- Hourly Usage: 400 days
- Daily rollups: 800 days
- Sessions: 90 days

## Deletion

> Draft — pending review

Sign in and open [Account](/my) to delete a Device or the Account. Deleting a Device removes that
Device and its Quota and Usage data. Deleting the Account removes the Account.

## Contact

> Draft — pending review

Questions about this draft: support@gotry.io
