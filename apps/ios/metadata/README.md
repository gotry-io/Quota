<!-- Draft — pending owner review -->

# Quota iOS App Store metadata (draft)

English listing copy, review notes, privacy labels, age rating, and export-compliance
answers for App Store Connect. **Do not upload until the owner (Kyle) has reviewed every
file.** This folder never talks to App Store Connect; it is source for a person to paste.

Locale for the listing files is **en-US**.

## Draft line

Every file in this tree starts with a draft marker so a half-reviewed paste cannot ship by
accident:

| Kind | First line |
| --- | --- |
| Markdown | `<!-- Draft — pending owner review -->` |
| `.txt` | `# Draft — pending owner review` |

Strip that first line from every `.txt` file before pasting into App Store Connect. The
hash is not part of the field. Markdown files stay in git as the working copy; paste the
body (without the HTML comment) into the matching App Store Connect box.

## App Store Connect field map

| File | App Store Connect field | Limit | Notes |
| --- | --- | --- | --- |
| `en-US/name.txt` | App Information › Name | 30 characters | **Quota – AI Usage** (ASC app 6808567160; "Quota" was already taken, 2026-09-04). On-device display name stays **Quota**. |
| `en-US/subtitle.txt` | App Information › Subtitle | 30 characters | |
| `en-US/description.txt` | App Information › Description | 4,000 characters | |
| `en-US/keywords.txt` | App Information › Keywords | 100 characters | Comma-separated, no competitor names |
| `en-US/promotional_text.txt` | App Information › Promotional Text | 170 characters | Can change without a new binary |
| `en-US/support_url.txt` | App Information › Support URL | URL | |
| `en-US/marketing_url.txt` | App Information › Marketing URL | URL | |
| `en-US/privacy_url.txt` | App Information › Privacy Policy URL | URL | Required |
| `en-US/release_notes.txt` | Version › What's New | 4,000 characters | 1.0 first release |
| `review-notes.md` | App Review Information › Notes | | Includes demo-account placeholders the owner fills |
| `privacy-labels.md` | App Privacy | | Fill the nutrition-label form from the table; must match `PrivacyInfo.xcprivacy` |
| `age-rating.md` | Age Rating questionnaire | | All None / No → **4+** |
| `export-compliance.md` | Export Compliance | | Justification for `ITSAppUsesNonExemptEncryption = false` |
| `screenshots/README.md` | Screenshots (6.9" and 6.3") | | Capture with `scripts/ios-store-screenshots.sh`; upload the PNGs with no device frame or caption overlay |

Version 1.0 uses `MARKETING_VERSION` in `apps/ios/project.yml` once that version is the
release being submitted. This draft does not bump it.

## What still needs the owner

1. Read every `en-US/*.txt` string. Rewrite anything that should not ship.
2. Fill `<DEMO_GITHUB_LOGIN>`, `<DEMO_PASSWORD>`, and `<DEMO_VIDEO_URL>` in
   `review-notes.md`. The demo GitHub account must already have synthetic data uploaded
   from a Mac running QuotaBar.
3. Confirm `/support` and `/privacy` exist on `https://quota.gotry.io` before using those
   URLs in App Store Connect.
4. Recapture screenshots on **iPhone 17 Pro Max (6.9")** and **iPhone 17 (6.3")** if this
   machine used a size-equivalent fallback (see `screenshots/README.md`).
5. Paste privacy labels and the age-rating answers; archive and Generate Privacy Report
   against `PrivacyInfo.xcprivacy` (WP-3.10b).
6. Submit from App Store Connect. Nothing in this tree is an API client.
