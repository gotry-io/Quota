# Quota iOS Design

This file is the canonical visual and interaction specification for the native iOS Quota app and its
WidgetKit surfaces. Website marketing UI belongs in `apps/web/DESIGN.md`. QuotaBar's menu panel
belongs in `apps/menubar/DESIGN.md`.

## Product character

Quota on iPhone and iPad is a read-only Account instrument: remaining quota first, Today Usage
second, GitHub identity as context. It uses native SwiftUI, system materials, and a restrained
emerald accent. It is not a compressed website and not the QuotaBar menu panel.

Core rules:

1. Remaining quota is the primary value. Today tokens and API-equivalent cost support it.
2. Connect Account and Log Out are the only account actions in this slice.
3. Last-good Account data stays visible across transient failures. A banner states that in words,
   not color alone.
4. Views render typed `packages/apple-client` results. They never show tokens, opaque session
   material, raw JSON, or device identifiers.
5. Every control is VoiceOver labelled and usable with Dynamic Type, Reduce Motion, and light or
   dark appearance.
6. Widgets render only the non-secret App Group snapshot. They never authenticate, call Relay, or
   invent a second data path.

This slice is Connect Account → Overview, plus Home Screen / Lock Screen overview widgets. It does
not ship the later Usage / Account tab shell.

## Surfaces

```text
Connect Account
Overview
Widget overview (small, medium, circular, rectangular)
```

### Connect Account

Shown when no Keychain account session exists, including after logout and after an expired refresh.

- Product name **Quota**.
- One sentence: remaining quota and Today Usage for the signed-in GitHub Account.
- Primary action **Connect Account**.
- Quiet note that this device does not collect or upload local usage.
- Optional status line after an expired session: **Session expired. Connect Account to continue.**

Connect Account starts `ASWebAuthenticationSession` for the Relay authorize URL. The system sheet
owns cancel. The app never embeds a web view.

Layout is a calm centered instrument: compact Quota mark, value proposition, privacy note, and the
primary action inside one semantic surface. Status banners (connecting, failure, expired) sit
inside that panel. Hit targets stay at least 44pt.

### Overview

Shown when a session exists. Content comes from the last complete Account summary, then from a
refresh of Today.

Header:

- Title is the account display label, or **Account** when the label is absent.
- Trailing **Log Out** uses a native confirmation: remote Account data remains; this device forgets
  the session.

Body, in order:

1. Banner, when needed.
2. Account context: display label plus compact refreshed age (`Updated 15min`). Standard Dynamic
   Type keeps a single-line horizontal row; accessibility sizes stack label and age vertically with
   full wrapping (no one-line ellipsis). VoiceOver always reads the full label and last-updated
   time.
3. Provider quota cards in catalog order. Each observation shows provider name, optional account
   label and plan, remaining value as the strongest number, one meter per percent window, and reset
   time. Remaining has no "left" or "remaining" suffix. Budget windows with an amount use
   `71% · $3.75`, percent-only windows use `71%`, and balance-only windows use **Balance** plus the
   unit amount.
4. Today: input tokens, output tokens, and API-equivalent cost. Complete cost is `$X.XX`, partial
   is `≥ $X.XX`, unavailable is **— unpriced**.

Pull to refresh runs one Today fetch. A fetch in flight ignores additional refresh requests.

Glance hierarchy follows the same information order as the Nowdex-inspired widgets (remaining first,
then provider/window, then support ages). Do not copy Nowdex assets or layout chrome.

### Widget overview

Widgets use the information hierarchy inspired by Nowdex: strongest remaining label first, then
provider and window, then reset and updated age. Do not copy Nowdex assets or layout chrome.

Families:

| Family | Content |
| --- | --- |
| systemSmall | Primary (most constrained) item: remaining, provider, window, reset/updated age |
| systemMedium | Up to two most constrained items, compact Today tokens and cost, and **Updated** age |
| accessoryCircular | Percent windows use an `accessoryCircular` Gauge ring; balance-only shows the amount |
| accessoryRectangular | Primary remaining, provider · window, optional reset age |

Shared rules:

- Format with `RemainingQuotaFormat`, `CompactCountFormat`, `UsageCostFormat`, and
  `CompactAgeFormat`. Digits are monospaced. Semantic text styles and colors only.
- Mark the strongest remaining value with `widgetAccentable()`.
- Use `containerBackground(for: .widget)`. Do not call `glassEffect`. On iOS 26 the system owns
  widget Liquid Glass, accented, and vibrant rendering inside that container; on iOS 17–25 the
  system material fallback applies.
- When a window's reset instant is at or before the entry date, reset age copy is **now** (never
  `0s`).
- `widgetURL` is `io.gotry.quota:/overview`.
- Placeholder is a redacted/skeleton overview. Missing, corrupt, or oversize snapshot files show
  safe **No data yet** copy. Timelines refresh about every fifteen minutes so ages advance; there is
  no extension network or background task.

## Liquid Glass (main app)

Quota on iOS 26 uses Apple's native SwiftUI glass APIs. There is no third-party UI kit and no custom
glass shader.

Progressive behavior:

| Surface | iOS 26 | iOS 17–25 |
| --- | --- | --- |
| Semantic cards, banners, Connect panel | `glassEffect(.regular, in: continuous 16pt shape)` | `.regularMaterial` in the same continuous shape |
| Primary button | `.glassProminent` with emerald tint | `.borderedProminent` with emerald tint |
| Navigation / toolbar | System navigation chrome | System navigation chrome |

Rules:

1. One glass/material surface per semantic card. Nested rows, meters, and plan chips stay plain.
2. An ambient Quota backdrop (semantic grouped fill plus a restrained emerald wash, light and dark)
   sits behind content so glass and material read clearly.
3. Surface and button modifiers live in `QuotaTheme` (`quotaSurface`, `quotaProminentButtonStyle`).
   Views do not invent alternate corner radii or fills.
4. Widgets never call `glassEffect`; system widget chrome owns that rendering.

## States

| State | Presentation |
| --- | --- |
| Loading, no cache | Centered progress and **Loading account…** |
| Empty quota | **No quota reported yet.** Collection happens on a Mac or Linux device. |
| Empty Today | **No Usage for Today.** |
| Offline or failed refresh, cache present | Last-good content plus **Showing saved account data. Could not refresh.** |
| Offline or failed refresh, no cache | Empty Overview plus **Could not refresh account data. Pull to try again.** |
| Expired session | Connect Account with **Session expired. Connect Account to continue.** |
| Connect running | Connect Account with **Continue in the browser.** |
| Widget no-data | **No data yet** (or accessory em dash); no error chrome |
| Widget placeholder | Redacted remaining / provider skeleton |

A banner always includes a symbol and a sentence. Color never carries status alone.

## Layout and type

Use the system grouped background (under the ambient wash) and semantic text styles (`largeTitle` /
`title2` for remaining values, `headline` for provider names, `subheadline` and `footnote` for
support). Cards are continuous 16pt corners. Content has a readable measure: 20pt horizontal gutter
and a maximum 720pt column on iPad.

Spacing uses 8, 12, 16, and 24pt. Hit targets stay at least 44pt. Dynamic Type may wrap every
label; do not clip remaining values. Accessibility text sizes and widget no-data layouts must keep
the strongest remaining figure readable (`minimumScaleFactor` is preferred over truncation of the
primary value).

The accent is adaptive emerald (`#087456` light, `#82ddb8` dark). Ink, body, and mute follow
`Color.primary` / `Color.secondary` / tertiary label. Critical red is only for Log Out
confirmation and unrecoverable failure copy.

Widgets stay denser: `title2` / `title3` / `headline` for remaining, `subheadline` / `caption` for
provider and support, and no custom card chrome beyond the system widget container.

## Accessibility

- Icon-only controls have accessibility labels.
- Remaining meters expose the remaining percent and window title, not only a graphic.
- Cost states include the words **complete**, **partial**, or **unpriced**.
- Fetched time / refreshed age includes **Last updated**.
- Widget entries combine provider, remaining, reset, stale, and updated age into one label.
- Do not announce raw account, device, or token identifiers.
- Reduce Motion uses opacity-only transitions for Connect ↔ Overview phase changes.

## Visual QA

Inspect Connect Account, loading, signed-in content, empty quota/Today, cached content with a
refresh banner, expired session, and each widget family in placeholder, content, and no-data
states. Check iPhone and iPad, light and dark, standard and accessibility text sizes, VoiceOver
labels, and Reduce Motion. Synthetic fixtures may contain display labels only; they must never
contain access tokens, refresh tokens, or production data.

### DEBUG visual fixtures

For deterministic simulator screenshots (DEBUG builds only), pass a launch argument:

```text
--visual-fixture signed-out
--visual-fixture content
--visual-fixture cached-error
--visual-fixture empty
```

| Fixture | UI state |
| --- | --- |
| `signed-out` | Connect Account, no session restore |
| `content` | Signed-in Overview with synthetic Codex / Claude / Grok windows and Today values |
| `cached-error` | Same content plus **Showing saved account data. Could not refresh.** |
| `empty` | Signed-in Overview with empty quota and **No Usage for Today.** |

Fixtures construct `AppModel` UI state in-process, skip Keychain/network restore, and never embed
access tokens, refresh tokens, or production data. Release builds ignore the flag. Launch-time
fixtures anchor synthetic timestamps to the process launch instant so Updated age and reset
instants stay current; unit tests inject `VisualFixture.referenceDate` for determinism.
