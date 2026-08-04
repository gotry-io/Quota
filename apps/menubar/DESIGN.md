---
version: alpha
name: QuotaBar-design
description: |
  Design system for QuotaBar, the native macOS menu-bar app. This document describes the shipped
  panel as implemented in SwiftUI — not the marketing website. QuotaBar is a dense operational
  utility on system material chrome: compact provider rows, brand-tinted monochrome marks, semantic
  usage meters, quiet provenance labels, and a single typed page stack inside one shared shell.
  Website tokens live in apps/web/DESIGN.md and must not be treated as menubar requirements.
---

# QuotaBar Design System

## Scope

| Surface | Design source |
| --- | --- |
| QuotaBar menu panel (this app) | **`apps/menubar/DESIGN.md`** (this file) |
| Public website | `apps/web/DESIGN.md` |
| CLI text output | no visual design system |

When menubar UI and website tokens disagree, **prefer this file for QuotaBar**. Do not pull solid
paper-canvas, marketing display type, or website card chrome into the menu panel unless this
document is updated first.

Canonical implementation:

- `Sources/QuotaBar/Core/Appearance/QuotaPalette.swift`
- `Sources/QuotaBar/Core/Appearance/QuotaDesign.swift`
- `Sources/QuotaBar/Core/Appearance/ProviderBrandIcon.swift`
- `Sources/QuotaBar/Features/MenuBar/*`
- `Sources/QuotaBar/Features/Settings/*`

## Product principles

1. **Native host, product interior** — panel background comes from `MenuBarExtra` window chrome (no
   extra material overlay). Structural
   chrome (dividers, tracks, soft fills, body text) uses system adaptive colors so it sits on
   material without hard paper-gray slabs.
2. **Operational density** — Overview stays compact; Settings/deeper pages are taller. Prefer
   tighter vertical rhythm over large empty canvas.
3. **Monochrome first** — provider marks and usage meters stay on system label ink (opacity tiers
   for remaining). Auth/stale/errors use text and icons, not brand multicolor.
4. **One shell, one stack** — Overview is root. Settings, Relays, pairing, and devices push on one
   app-owned path with a leading back control. No second navigation bar.
5. **Quiet provenance** — trailing mute icon for the selected source only; detail on hover.
6. **Reduce Motion** — page transitions become opacity-only or instant when Reduce Motion is on.

## Layout tokens

Mapped from `QuotaDesign.Layout`:

| Token | Value | Use |
| --- | --- | --- |
| `panelWidth` | 320 | Fixed panel width |
| `panelMaxHeight` | 560 | Fixed panel height for every page |
| `panelHorizontalPadding` | 16 | Single horizontal gutter for header, page body, and footer |
| `panelContentWidth` | 288 | `panelWidth - 2 × gutter`; page content must fit here |
| `pageVerticalPadding` | 16 | Settings / Relay / form page body top+bottom inset |
| `emptyStateVerticalPadding` | 24 | Extra vertical room for centered empty states only |
| `headerHeight` | 44 | Shell header |
| `footerHeight` | 36 | Shell footer |
| `headerControlWidth` | 28 | Gear / plus / ellipsis hit targets |
| `providerRowVerticalPadding` | 10 | Provider block vertical padding |
| `progressHeight` | 8 | Remaining meter thickness |
| `controlMinHeight` | 36 | Primary button min height |
| `cardPadding` | 16 | Relay card internal padding |
| `cardCornerRadius` | 12 | Relay card corner |
| `tagCornerRadius` | 3 | Status tag corner |

### Spacing scale (`QuotaDesign.Spacing`)

| Token | Value | Use |
| --- | --- | --- |
| `xxs` | 4 | Dense meta / tiny gaps |
| `xs` | 6 | Title blocks, icon+label |
| `sm` | 8 | Inline controls |
| `md` | 12 | Section body |
| `lg` | 16 | Page sections / card stacks |
| `section` | 16 | Page-level section stack |
| `sectionBody` | 12 | Inside a section |
| `cardStack` | 16 | Stack of cards |
| `cardBody` | 10 | Inside a card |
| `meta` | 4 | Reset/help lines |
| `inline` | 8 | Button/field clusters |
| `iconLabel` | 6 | Icon + text pairs |

Rules:

1. Header, page body, and footer all use `panelHorizontalPadding` (16). No tighter header-only inset.
2. Header icon *glyphs* sit on that 16pt content edge; hit targets grow inward, not outward.
3. Settings/Relay/form pages use `pageVerticalPadding` (16). Overview uses 0.
4. Prefer `Spacing.*` tokens over raw literals for stacks and clusters.
5. Empty states may add `emptyStateVerticalPadding`, never a second horizontal gutter.

### Shell anatomy

```text
┌─ header 44 ──────────────────────────────────────┐
│ [←] Title                              trailing  │
├──────────────────────────────────────────────────┤
│ content (scroll)                                 │
├──────────────────────────────────────────────────┤
│ footer 36                         Updated 3:41 PM│
└──────────────────────────────────────────────────┘
```

- **Overview trailing:** gear → opens Settings.
- **Settings trailing:** `ellipsis` overflow menu (Delete all data…, Quit).
- **Relays trailing:** `plus` → Pair Device (no bottom primary button on the list).
- **Pair Device:** no trailing action; 8-cell code entry auto-submits when complete.
- **Other pages:** no trailing control; back returns through the stack.
- Footer shows refresh affordance on the **right** only. Version lives in Settings → About.

## Color

### System adaptive (structure)

From `QuotaPalette` — **do not hardcode paper whites/grays for these roles**:

| Role | Source |
| --- | --- |
| `ink` | `NSColor.labelColor` |
| `body` | `NSColor.secondaryLabelColor` |
| `mute` | `NSColor.tertiaryLabelColor` |
| `hairline` | `NSColor.separatorColor` |
| `soft` | `quaternaryLabelColor` @ ~35% opacity |
| `progressTrack` | `Color.primary` @ 8% opacity |
| `onPrimary` | `alternateSelectedControlTextColor` |

Dividers use the system `Divider` (no fixed gray overlay). Shared borders use
`hairlineBorder` (`hairline` @ 80%). Status chips use `QuotaStatusTag`.

### Usage / brand (monochrome on host chrome)

| Token | Value | Use |
| --- | --- | --- |
| provider marks | `ink` | All providers share ink template tint |
| `usage.healthy` | `Color.primary` @ 28% | Remaining ≥ 40% |
| `usage.warning` | `Color.primary` @ 48% | Remaining ≥ 15% and < 40% |
| `usage.critical` | `Color.primary` @ 78% | Remaining < 15% |

Stale rows further dim the usage fill (~55% of the tone) and still show a Stale tag.

## Typography

System SF only. Prefer **semantic** roles from `QuotaDesign.Typography` and the view helpers
below. Avoid bare `.caption` / `.subheadline` / `.font(.system(size:))` in features.

| Role | Font | Color | Helper |
| --- | --- | --- | --- |
| Panel title | `.headline` rounded semibold | `ink` | (header only) |
| Empty title | `.headline` rounded medium | `ink` | `quotaEmptyTitleStyle` |
| Row / entity title | `.subheadline` medium | `ink` | `quotaRowTitleStyle` |
| Section header | `.caption` semibold | `mute` | `quotaSectionHeaderStyle` |
| Secondary / quiet action / issue | `.caption` | `body` | `quotaSecondaryStyle` |
| Meta / tags / source | `.caption2` | `mute` | `quotaMetaStyle` |
| Mono (URL/command/id) | `.caption` monospaced | `body` (never `ink`) | `quotaMonoStyle` |
| Mono meta (instance id) | `.caption2` monospaced | `mute` | `quotaMonoMetaStyle` |
| Chevron / affordance | 11 / 10 semibold | `mute` | `quotaChevronStyle` / `quotaAffordanceStyle` |
| Empty icon | 28 regular | `body` | `quotaEmptyIconStyle` |
| Remaining % | `.subheadline` semibold | usage tone | — |
| Window title | `.caption` medium | `body` | — |
| Pairing code | `.title3` mono semibold | ink via field | — |

Hierarchy: **panelTitle ≥ emptyTitle > rowTitle > sectionHeader > secondary > meta**.
Section headers stay quieter than row titles so groups don't overpower content.
Technical strings and chevrons never use `ink`. One helper per font+color pair — no aliases.

No website display scale (30–36px) inside the panel.

## Iconography

- **Menu bar status item:** the custom Q gauge in `Resources/BrandIcons/quota.svg`, rendered at
  18pt as one solid gauge arc and an inward diagonal tail. Small template marks omit the muted outer
  arc because partial-alpha strokes become soft at menu-bar resolution.
- **Application icon:** `Support/QuotaBarIcon.svg` is the editable double-ring source;
  `Support/QuotaBarSmallIcon.svg` is the single-ring 16–64px optical source. The generated
  `Support/QuotaBar.icns` combines them through `scripts/generate-brand-assets.sh`.
- **Provider marks:** Lobe monochrome SVGs (`openai`, `claude`, `grok` from lobehub.com/icons),
  pre-rasterized to 24pt@2x template bitmaps and tinted with system label ink.
- **Source labels:** SF Symbols — `laptopcomputer` (Local), `network` (Remote),
  `laptopcomputer.and.iphone` (mixed).
- **Utility:** SF Symbols for back, gear, ellipsis, stale clock, empty states.

## Components

### Provider row

```text
[brand] Codex                               Local
Pro Lite · eg***@example.com
Weekly                                29%
████████░░░░
Resets 08-08 12:51:26
```

Rules:

1. Provider icon + name leading; source label trailing (mute).
2. Account line: `Plan · maskedLabel` plain text (no plan chip). Plan slugs normalized for display
   only (`prolite` → `Pro Lite`, `supergrok` → `SuperGrok`, OIDC Grok hint → SuperGrok).
3. Each window: title left, **strong remaining %** right (no trailing word `left`), 8px meter,
   compact absolute reset `MM-dd HH:mm:ss`.
4. Meter fill + % share usage tone. Filled proportion is always **remaining**.
5. Multi-account: per-account identity row carries its own source label and optional Stale tag.

### Source badge

- Trailing mute **icon only** for the **selected** observation source.
- Must match `SubscriptionResolver`’s chosen snapshot — never a multi-source blend.
- Icons: `laptopcomputer` (local) / `network` (remote).
- Hover tooltip: `This Mac` or Relay device `displayName` (fallback `Relay Device`).
- VoiceOver: `Source: {tooltip}`.

### Provider status (failure / recovery)

Collapse protocol outcomes into three quiet UI states:

| UI | Protocol outcomes | Trailing | Detail |
| --- | --- | --- | --- |
| Needs Sign-In | `auth_required` | mute text | `Run \`… login\`` |
| Unavailable | `unavailable`, `unsupported` | mute text | short reason if useful |
| Can’t Refresh | `error` | mute text | short reason if useful |

Rules:

- No bordered chips/CTAs for auth or errors. Status is quiet text beside the provider name.
- Trailing edge stays provenance-only (selected-source icon). Never replace it with status text.
- Issue-only rows (no accounts) still show the local source icon when the failure came from local collection.
- `Stale` remains the only outlined status tag (freshness of otherwise successful data).
- Settings Agents rows reuse the same recovery detail; healthy success shows no status chrome.

### Stale tag

- Small outlined tag with clock symbol + `Stale` (still the one exception that keeps light chrome).
- Appears near the account/provider header when data is stale.

### Primary button

- Black/label-colored pill, min height 36, horizontal padding 18.
- At most one high-emphasis pill visible in a compact region (empty-state Retry, etc.).

### Settings

- Sections: Agents, Remote Quota, About.
- Agents rows: brand icon, name, optional recovery detail, visibility toggle.
  - Visibility toggle is always interactive (auth failures still appear in Overview when enabled).
  - Signed-in / success: no status chrome — only the toggle.
  - Not signed in / error / unavailable: short recovery detail (e.g. `Run \`claude auth login\``).
- Overflow menu (ellipsis): Delete all QuotaBar data…, Quit QuotaBar.
- About: Version, Website, Feedback rows (no product-name label, no copyright blurb).

### Navigation motion

- Forward: insert from trailing + opacity; remove toward leading + opacity.
- Back: reverse.
- Duration ~0.28s snappy; Reduce Motion → opacity only or none.
- Panel height is fixed at `panelMaxHeight` for every page.

## Content rules

- Primary number and meter = **remaining** quota, never used-by-default.
- Do not invent Grok plan from billing; OIDC/`auth_mode` hint → `supergrok` display only.
- Never show raw tokens, full emails, or unredacted account ids.
- Cache-first launch: show last local report immediately, refresh in background (plan fields may
  appear after refresh when collector semantics change).

## Do / Don’t

### Do

- Keep the host `MenuBarExtra` background and system separators/tracks.
- Keep Overview denser than Settings.
- Keep provider marks monochrome; tone meters by remaining opacity tiers.
- Put provenance on the trailing edge as quiet meta.
- Honor Reduce Motion and VoiceOver labels on combined provider rows.

### Don’t

- Reintroduce fixed `#E5E5E5` hairline overlays or solid paper canvas as the panel fill.
- Use website display typography or large marketing cards in the menu panel.
- Show Local/Remote as heavy filled badges.
- Put version in the footer or Quit as an always-visible Settings row.
- Drive QuotaBar visuals from `apps/web/DESIGN.md`.

## Reference

Implementation is the source of truth when this document drifts. Website design:
[`apps/web/DESIGN.md`](../web/DESIGN.md).
