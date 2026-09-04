<!-- Draft — pending owner review -->

# App Store screenshots

Upload the PNGs in `dist/ios-store-screenshots/<device>/` directly in App Store Connect.
Do **not** add a device bezel, status-bar restyle overlay, or caption bar. The owner pastes
the files into the 6.9" and 6.3" iPhone slots.

## Store sizes

| Slot | Simulator (preferred) | Typical pixel size (portrait) | Output directory |
| --- | --- | --- | --- |
| 6.9" | iPhone 17 Pro Max | 1320 × 2868 | `dist/ios-store-screenshots/iphone-17-pro-max/` |
| 6.3" | iPhone 17 | 1206 × 2622 | `dist/ios-store-screenshots/iphone-17/` |

If a named simulator is not installed, the capture script skips it and prints why. It may
use a size-equivalent fallback (iPhone 17 Pro for 6.3", iPhone 16 Pro Max for 6.9", and so
on) or, if those are missing too, the first available iPhone. Recapture on the two preferred
simulators before submitting.

## Capture

From the repository root:

```bash
./scripts/ios-store-screenshots.sh
```

The script:

1. Resolves **iPhone 17 Pro Max** and **iPhone 17** the same way
   `scripts/ios-ui-screenshots.sh` reads `xcrun simctl list devices available -j`.
2. If `apps/ios/UITests/QuotaUITests.swift` exists, runs `xcodebuild test
   -only-testing:QuotaUITests` per device, then `xcrun xcresulttool export attachments`
   (same export path as the UI screenshot script). Attachment names map to the files
   below.
3. Otherwise it builds a DEBUG `Quota.app`, installs it, launches with
   `--visual-fixture`, and writes `simctl io screenshot` PNGs. DEBUG is required: visual
   fixtures are compiled out of Release.

`dist/` is gitignored. Re-run the script after UI changes.

## Files per device

| PNG | Fixture / UI test | What it should show |
| --- | --- | --- |
| `content.png` | `content` | Signed-in Overview: remaining quota, Devices, Today |
| `usage-content.png` | `usage-content` | Usage tab with period totals |
| `subscription-detail.png` | `subscription-detail` | One subscription’s detail |
| `settings.png` | `settings` | Settings (notifications, account, Log Out) |
| `no-devices.png` | `no-devices` | Signed-in Overview with no collection Device yet |

On a `main`-based tree that only has Overview + Connect Account, the simctl path captures
`content` from `--visual-fixture content` and `no-devices` from `--visual-fixture empty`
(empty `devices[]` and empty quota). `usage-content`, `subscription-detail`, and `settings`
are skipped until those screens and UI tests exist. The script prints each skip.

## App Store Connect

Create the 1.0 iOS version, open the en-US screenshot set, and drop the 6.9" PNGs into the
6.9" well and the 6.3" PNGs into the 6.3" well, in the order: content, usage, subscription
detail, settings, no-devices (omit any file the script skipped). iPad shots are not in this
task.
