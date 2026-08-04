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
3. **Color is secondary signal** — brand tints identify providers; usage tones color remaining
   meters/percents; auth/stale/errors still use text and icons.
4. **One shell, one stack** — Overview is root. Settings, Relays, pairing, and devices push on one
   app-owned path with a leading back control. No second navigation bar.
5. **Quiet provenance** — Local/Remote is trailing mute meta (symbol + text), not a bordered chip.
6. **Reduce Motion** — page transitions become opacity-only or instant when Reduce Motion is on.

## Layout tokens

Mapped from `QuotaDesign.Layout`:

| Token | Value | Use |
| --- | --- | --- |
| `panelWidth` | 320 | Fixed panel width |
| `panelMaxHeight` | 560 | Fixed panel height for every page |
| `panelHorizontalPadding` | 16 | Single page gutter for every page body |
| `panelContentWidth` | 288 | `panelWidth - 2 × gutter`; page content must fit here |
| `pageVerticalPadding` | 16 | Settings / Relay / form page body top+bottom inset |
| `emptyStateVerticalPadding` | 24 | Extra vertical room for centered empty states only |
| `headerHeight` | 44 | Shell header |
| `footerHeight` | 36 | Shell footer |
| `navigationControlSize` | 28 | Back / gear / ellipsis hit targets |
| `providerRowVerticalPadding` | 10 | Provider block vertical padding |
| `progressHeight` | 8 | Remaining meter thickness |
| `cardPadding` | 16 | Relay card internal padding |
| `cardCornerRadius` | 12 | Relay card corner |
| `tagCornerRadius` | 3 | Stale tag corner only |

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

1. Every page body uses `panelHorizontalPadding` once. No second page-level horizontal inset.
2. Settings/Relay/form pages use `pageVerticalPadding` (16). Overview uses 0.
3. Prefer `Spacing.*` tokens over raw literals for stacks and clusters.
4. Empty states may add `emptyStateVerticalPadding`, never a second horizontal gutter.

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
| `ink` / `primary` | `NSColor.labelColor` |
| `charcoal` / `body` | `NSColor.secondaryLabelColor` |
| `mute` | `NSColor.tertiaryLabelColor` |
| `hairline` | `NSColor.separatorColor` |
| `soft` | `quaternaryLabelColor` @ ~35% opacity |
| `progressTrack` | `Color.primary` @ 8% opacity |
| `onPrimary` | `alternateSelectedControlTextColor` |

Dividers use the system `Divider` (no fixed gray overlay).

### Product-owned accents

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `brand.codex` | `#7A9DFF` | same | Lobe Codex color mid-stop; template tint |
| `brand.claude` | `#D97757` | same | Claude warm orange tint |
| `brand.grok` | `#26262A` | `#E4E4E7` | Near-black / lifted gray |
| `usage.healthy` | `#15803D` | same | Remaining ≥ 40% |
| `usage.warning` | `#B45309` | same | Remaining ≥ 15% and < 40% |
| `usage.critical` | `#B91C1C` | same | Remaining < 15% |

Stale rows keep the usage tone at ~55% opacity and still show a Stale tag.

## Typography

System SF only (`QuotaDesign.Typography`):

| Role | Font |
| --- | --- |
| Panel title | `.headline`, rounded, semibold |
| Provider title | `.subheadline`, medium |
| Remaining % | `.subheadline`, semibold, monospaced digits |
| Window title | `.caption`, medium |
| Plan · account | `.caption`, medium |
| Reset / help | `.caption2` |
| Source label | `.caption2`, medium |
| Status tag | `.caption2` |

No website display scale (30–36px) inside the panel.

## Iconography

- **Menu bar status item:** system template glyph (monochrome).
- **Provider marks:** Lobe monochrome SVGs, pre-rasterized to 24pt@2x template bitmaps, tinted with
  brand colors. Codex path data must keep explicit arc flags (no SVG compact `01` flag gluing) so
  CoreSVG does not drop contours.
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

### Source label

- Not a bordered chip.
- Trailing, mute, icon + text.
- Copy: `Local` | `Remote` | `Local + Remote` | `Local + N remote` | `N remote`.

### Provider status (failure / recovery)

Collapse protocol outcomes into three quiet UI states:

| UI | Protocol outcomes | Trailing | Detail |
| --- | --- | --- | --- |
| Needs Sign-In | `auth_required` | mute text | `Run \`… login\`` |
| Unavailable | `unavailable`, `unsupported` | mute text | short reason if useful |
| Can’t Refresh | `error` | mute text | short reason if useful |

Rules:

- No bordered chips/CTAs for auth or errors. Status is quiet text beside the provider name.
- Trailing edge stays provenance-only (`Local` / `Remote` / mixed). Never replace source labels with status.
- Issue-only rows (no accounts) still show `Local` when the failure came from local collection.
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
  - Signed-in / success: no status title or “CLI ready” copy — only the toggle (enabled).
  - Not signed in / error / unavailable: short recovery detail (e.g. `Run claude auth login`);
    toggle disabled and dimmed.
- Overflow menu (ellipsis): Delete all QuotaBar data…, Quit QuotaBar.
- About holds product name + version only (not footer).

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
- Tint provider marks; tone meters by remaining thresholds.
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
