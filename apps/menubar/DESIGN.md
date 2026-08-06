---
version: alpha
name: QuotaBar-design
description: |
  Design system for QuotaBar, the native macOS menu-bar app. This document describes the shipped
  panel as implemented in SwiftUI — not the marketing website. QuotaBar is a dense operational
  utility on system material chrome: compact provider rows, monochrome provider marks, restrained
  accent/orange/red semantic meters, quiet provenance labels, and a single typed page stack
  (Overview → Settings → Remote Devices → Pair Device). Website tokens live in apps/web/DESIGN.md
  and must not be treated as menubar requirements.
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
3. **Restrained semantic color** — structure stays system adaptive; meters and primary actions use
   accent/orange/red only. Auth/stale/errors still use text and icons, never provider brand colors.
4. **One shell, one stack** — Overview is root. Settings, Remote Devices, and Pair Device push on one
   app-owned path with a leading back control. No second navigation bar.
5. **Quiet provenance** — selected-source icon appears on hover with Observed (not on the title row).
6. **Reduce Motion** — page transitions become opacity-only or instant when Reduce Motion is on.

## Layout tokens

Mapped from `QuotaDesign.Layout`:

| Token | Value | Use |
| --- | --- | --- |
| `panelWidth` | 320 | Fixed panel width |
| `panelMaxHeight` | 480 | Fixed panel height for every page |
| `panelHorizontalPadding` | 16 | Single horizontal gutter for header, page body, and footer |
| `panelContentWidth` | 288 | `panelWidth - 2 × gutter`; page content must fit here |
| `pageVerticalPadding` | 16 | Settings / task page body top+bottom inset |
| `emptyStateVerticalPadding` | 24 | Extra vertical room for centered empty states only |
| `headerHeight` | 44 | Shell header |
| `footerHeight` | 36 | Shell footer |
| `minimumInteractiveDimension` | 28 | Apple HIG recommended minimum response dimension on macOS |
| `backTitleOffset` | 20 | Compact visual back/title relationship; not the button response width |
| `headerControlWidth` | 28 | Back / gear / plus / ellipsis response width |
| `providerRowVerticalPadding` | 10 | Provider block / dense list row vertical padding |
| `progressHeight` | 8 | Remaining meter thickness |
| `controlMinHeight` | 36 | Primary button min height |
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
| `sectionRows` | 8 | Dense stacks inside a section (About rows, device metadata) |
| `meta` | 4 | Reset/help lines |
| `inline` | 8 | Button/field clusters |
| `iconLabel` | 6 | Icon + text pairs |

Rules:

1. Header, page body, and footer all use `panelHorizontalPadding` (16). No tighter header-only inset.
2. Header icon *glyphs* sit on that 16pt content edge; hit targets grow inward, not outward.
3. Settings and task pages use `pageVerticalPadding` (16). Overview uses 0.
4. Prefer `Spacing.*` tokens over raw literals for stacks and clusters.
5. Empty states may add `emptyStateVerticalPadding`, never a second horizontal gutter.

### Shell anatomy

```text
┌─ header 44 ──────────────────────────────────────┐
│ [←] Title                              trailing  │
├──────────────────────────────────────────────────┤
│ content (scroll)                                 │
├──────────────────────────────────────────────────┤
│ footer 36                    Last checked 3:41 PM│
└──────────────────────────────────────────────────┘
```

- **Overview trailing:** gear → opens Settings.
- **Settings trailing:** `ellipsis` overflow menu (Delete all data…, Quit).
- **Remote Devices trailing:** `plus` with accessibility label **Pair Device**.
- **Pair Device:** no trailing action; 8-cell code entry auto-submits when complete.
- **Other pages:** no trailing control; back returns through the stack. Back uses a compact 20pt
  visual slot so the title stays attached to the chevron, while its response region remains
  28×44pt by overlapping the otherwise noninteractive title gap.
- Footer shows refresh affordance on the **right** only (`Last checked …` / `Not checked` /
  `Refreshing…`). That time is **orchestration** (last local collect and/or Relay pull), not
  per-provider data age. Version lives in Settings → About.
- Provider observation time (`observed_at`) is **not** shown after window Resets lines. On hover
  over a provider block, show a single meta row: **source icon leading** + `Observed … ago`
  trailing (shared across its windows). VoiceOver always exposes source + observation age.

### Interaction and accessibility

- Custom controls follow Apple's macOS accessibility guidance: target at least 28×28pt; 20×20pt is
  an exceptional lower bound, not the normal design target.
- Visual density never shrinks response geometry. Header icons use 28×44pt targets, text actions
  such as Refresh and Copy have at least 28pt height, and disclosure/link rows expose the whole row.
- Agent visibility uses one native Toggle on the **provider detail** page (not the Agents list).
  Native Picker and text-field behavior stays intact, including keyboard navigation and focus
  treatment.
- Every icon-only action has an accessibility label and macOS hover help. Plain buttons use
  SwiftUI's native style for pressed, focused, and disabled states.
- The eight pairing-code fields remain separate 28×28pt edit targets so pointer and VoiceOver users
  can address an individual character without breaking the fixed 288pt content width.

### Settings information architecture

Multi-level stack (same shell back control throughout):

```text
Settings
├── General          [icon] Launch at Login          [toggle]
├── Sources          [icon] Agents                   ›
│                    [icon] Devices                  ›
│                         └── Agents list → Provider detail
│                         └── Devices list → Pair Device
└── About            [icon] Version / Website / Feedback
```

All Settings home rows share **icon + title** (+ trailing control/value/chevron). Agents and Devices
live in one **Sources** group.

| Page | Content |
| --- | --- |
| **Settings** | Dense menu rows only; no inline API-key forms. |
| **Agents** | Provider list → detail (visibility + API key when configurable). |
| **Provider** | Visibility; ambient recovery **or** API-key form → `~/.config/quotacli/providers.json`. |
| **Devices** | Device list; header `plus` pairs. |
| **About** | Version, website, feedback (same icon+title row style). |

### Remote Devices

- Aggregate devices this QuotaBar owns across internal endpoint records.
- Rows are flat list items separated by system `Divider`s — not rounded cards. Keep a compact
  two-line body (name + health, last report) with an 8pt vertical pad; do not stack a full-width
  action row under each device.
- Row priority: device name and a quiet health/last-report label. Show the Relay endpoint as subdued
  metadata only when more than one endpoint needs disambiguation; use the canonical URL so ports
  and schemes cannot collapse to the same label.
- Empty state: `Pair a device to see its quota in QuotaBar.` The header `plus` is the only
  **Pair Device** action; do not repeat it as a colored body button.
- **Remove** is a short trailing plain destructive text action (not a full-width button) that
  confirms the device will stop reporting to this QuotaBar.

### Settings density

- Settings is **menu-dense**, not Overview-dense. Body labels use `settingsLabel` (11pt medium), not
  Overview `rowTitle` (13pt). Secondary/meta stay 11/10pt.
- **Grouping** uses a soft translucent fill (`QuotaPalette.settingsGroupFill`) on continuous rounded
  rects — not stacks of hairline `Divider`s. Section title sits above the group; groups stack with
  `Spacing.md`. In-group rows share one fill with no inter-row dividers. Group fill has horizontal
  inset only.
- Section title → body uses `Spacing.xs` (6).
- **Shared row chrome** (`SettingsListRow`): leading mark (16pt) + title (+ optional one-line
  subtitle) + trailing. Fixed heights — do not free-size rows per content:
  - Home (General / Sources / About): `settingsRowHeight` **36**
  - Agents / Devices / provider Overview: `settingsListRowHeight` **44**
- Title-only stacked rows **vertically center** the title (no empty meta slot pushing it up). With a
  subtitle, title + meta stack and stay centered in the same 44pt height.
- Multi-line forms (API key, sign-in copy) keep `settingsRowVerticalPadding` (8). Toggles use
  `.controlSize(.mini)` only — do not put minHeight on the switch itself.
- Home rows are icon + title (+ trailing). Launch at Login has no recovery copy under the row.
- About matches the same icon+title density. Links stay full-row tappable via `contentShape`.
- Devices list uses the same grouped card + `SettingsListRow` language as Agents (no hairline
  dividers).

### Pair Device

- Default endpoint: official Quota Relay. Known endpoints and **Other Relay…** (reveals Relay URL).
- Task order is endpoint → visible `quotacli relay pair` command → pairing code. Installation help is
  secondary disclosure, not a prerequisite form.
- For **Other Relay…**, keep the `--relay <relay-url>` command preview visible. Replace the
  placeholder and enable Copy/code entry only when the custom URL is structurally valid; never show
  the fallback official command.
- Show the endpoint-correct command with a copy affordance. A complete eight-character paste works,
  and the code auto-submits when complete. VoiceOver exposes the visual cells as eight labeled edit
  fields rather than merging interactive controls into one static element.
- Pairing success requires both owner approval and device join (QuotaCLI consuming the session).
  Stay on Pair Device with `Pairing…` until the new device appears in the owner device list; only
  then navigate back to Remote Devices. Approval alone is an intermediate state and must not finish
  the flow. If the device never joins before the short timeout, keep the user on Pair Device and
  show a recovery error (`Keep QuotaCLI running, then enter a new pairing code`).
- First remote quota may still arrive after join, once the device pushes snapshots. A joined device
  can therefore appear as Waiting / Never reported immediately after a successful pair.
- No profile name, owner credential, capability, default profile, or admin copy.

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

Dividers use the system `Divider` (no fixed gray overlay). Shared borders use
`hairlineBorder` (`hairline` @ 80%). Status chips use `QuotaStatusTag`.

### Semantic (three roles only)

| Role | Source | Use |
| --- | --- | --- |
| Accent | `controlAccentColor` (indigo product fallback) | primary actions, focus, healthy meter fill |
| Warning | `systemOrange` | remaining 15%–39% meter fill |
| Critical | `systemRed` | remaining &lt; 15% meter fill |

| Token | Value | Use |
| --- | --- | --- |
| provider marks | `ink` | All providers share ink template tint |
| remaining % text | `ink` | All thresholds; the meter carries semantic color |
| primary button | accent fill + contrast-selected black/white label | AA contrast for every system accent |

Stale rows further dim the meter fill (~55% of the tone), mute the percentage text, and still show a
Stale tag. The numeric percentage and filled meter length preserve meaning without relying on hue;
errors and destructive actions retain explicit labels or icons. Do not introduce provider colors,
success green, tinted cards, gradients, shadows, or extra status colors.

## Typography

System SF only. Prefer **semantic** roles from `QuotaDesign.Typography` and the view helpers below.
Text roles use compact base sizes at the standard setting and scale explicitly from Extra Large
through Accessibility 5. This keeps normal menu-panel density while making the macOS Dynamic Type
environment observable and testable. Avoid bare `.caption` / `.subheadline` /
`.font(.system(size:))` in features.

| Role | Base font | Color | Helper |
| --- | --- | --- | --- |
| Panel title | 13pt rounded semibold | `ink` | (header only) |
| Empty title | 13pt rounded medium | `ink` | `quotaEmptyTitleStyle` |
| Row / entity title | 13pt medium | `ink` | `quotaRowTitleStyle` |
| Section header | 11pt semibold | `mute` | `quotaSectionHeaderStyle` |
| Secondary / quiet action / issue | 11pt regular | `body` | `quotaSecondaryStyle` |
| Meta / tags / source | 10pt regular | `mute` | `quotaMetaStyle` |
| Mono (URL/command/id) | 11pt monospaced | `body` (never `ink`) | `quotaMonoStyle` |
| Mono meta (instance id) | 10pt monospaced | `mute` | `quotaMonoMetaStyle` |
| Chevron / affordance | 11 / 10 semibold | `mute` | `quotaChevronStyle` / `quotaAffordanceStyle` |
| Empty icon | 28 regular | `body` | `quotaEmptyIconStyle` |
| Remaining % | 13pt semibold | `ink` (`mute` when stale) | `quotaFont(.remainingValue)` |
| Window title | 11pt medium | `body` | `quotaFont(.quotaLabel)` |
| Pairing code | fixed `.title3` mono semibold | ink via field | — |

Hierarchy: **panelTitle ≥ emptyTitle > rowTitle > sectionHeader > secondary > meta**.
Section headers stay quieter than row titles so groups don't overpower content.
Technical strings and chevrons never use `ink`. One helper per font+color pair — no aliases.
Utility icons and the eight-cell pairing-code geometry stay fixed because they already provide a
large target and must fit the 288pt content width; all explanatory and actionable text around them
scales.

No website display scale (30–36px) inside the panel.

## Iconography

- **Menu bar status item:** the custom Q gauge in `Resources/BrandIcons/quota.svg`, rendered at
  18pt as one solid gauge arc and an inward diagonal tail. Small template marks omit the muted outer
  arc because partial-alpha strokes become soft at menu-bar resolution.
- **Application icon:** 1024×1024 master on a **transparent** canvas. The white rounded plate is
  drawn inset (~100px margin / side → ~824×824 plate, corner radius ~185) so Dock/Finder optical
  size matches other macOS icons; the Q mark sits smaller inside that plate. Do not fill the full
  canvas edge-to-edge. `generate-brand-assets.sh` bakes a soft contact drop shadow after
  rasterization (similar to News/Photos icns soft-alpha rim). `Support/QuotaBarIcon.svg` is the
  double-ring master; `Support/QuotaBarSmallIcon.svg` is the single-ring 16–64px optical master.
- **Provider marks:** Lobe monochrome SVGs (`openai`, `claude`, `grok` from lobehub.com/icons),
  pre-rasterized to 24pt@2x template bitmaps and tinted with system label ink.
- **Source labels:** SF Symbols — `laptopcomputer` (Local), `network` (Remote),
  `laptopcomputer.and.iphone` (mixed).
- **Utility:** SF Symbols for back, gear, ellipsis, stale clock, empty states.

## Components

### Provider row

```text
[brand] Codex  Pro Lite                    eg***@example.com
Weekly                           29% left
████████░░░░
Resets Sat, 12:51 PM
 This Mac                     Observed 2 minutes ago   ← hover only
```

Rules:

1. Provider icon + name leading; **single-account plan** sits immediately after the name (mute,
   plain text — no plan chip). Plan slugs normalized for display only (`prolite` → `Pro Lite`,
   `supergrok` → `SuperGrok`, OIDC Grok hint → SuperGrok). Masked account / key label is
   **trailing** alone — not combined with plan.
2. Status (if any) sits beside the provider name — not on the trailing identity edge.
3. Each window: title left, **strong remaining %** right with the explicit word `left`, 8px meter,
   then a locale-appropriate weekday/time reset without routine seconds.
4. Percentage text stays readable ink; the meter uses accent/orange/red by threshold. Filled
   proportion is always **remaining**.
5. Window meta is reset timing only. On hover over the provider block: **source icon + device name
   leading** + `Observed … ago` trailing (not after Resets). No separate source tooltip.
6. **Multi-account:** each account keeps its own identity row (plan/label + optional Stale) and its
   own source label. Provider hover meta still shows source + Observed for the newest snapshot.

### Source label

- Mute **icon + device name** for the **selected** observation source of the newest account snapshot
  shown on the hover meta row (with Observed). Not on the title row.
- Must match `SubscriptionResolver`’s chosen snapshot — never a multi-source blend.
- Icons: `laptopcomputer` (local) / `network` (remote).
- Name: `This Mac` or Relay device `displayName` (fallback `Relay Device`) — visible inline, no
  `.help` tooltip.
- VoiceOver: `Source: {name}` (combined into the provider row’s observation value).

### Provider status (failure / recovery)

Collapse protocol outcomes into three quiet UI states:

| UI | Protocol outcomes | Beside name | Detail |
| --- | --- | --- | --- |
| Needs Sign-In | `auth_required` | mute text | `Run \`… login\`` |
| Unavailable | `unavailable`, `unsupported` | mute text | short reason if useful |
| Can’t Refresh | `error` | mute text | short reason if useful |

Rules:

- No bordered chips/CTAs for auth or errors. Status is quiet text beside the provider name.
- Title-row trailing edge is the masked account/key label for single-account success rows — not
  provenance or plan.
- Issue-only rows (no accounts) still expose the local source icon on the hover meta row when the
  failure came from local collection.
- When any presentable account exists for a provider (local or remote), suppress local
  Needs Sign-In / Unavailable / Can’t Refresh chrome for that provider. Do not blend local auth
  failure with successful remote quota.
- `Stale` remains the only outlined status tag (freshness of otherwise successful data). Remote
  device `Active` / `Waiting` state is quiet icon-and-text metadata without tag chrome.
- Settings Agents rows reuse the same recovery detail; healthy success shows no status chrome.

### Stale tag

- Small outlined tag with clock symbol + `Stale` (still the one exception that keeps light chrome).
- Appears near the account/provider header when data is stale.

### Primary button

- Accent-filled pill with a black-or-white label selected from the resolved accent for AA contrast;
  min height 36, horizontal padding 18.
- Press feedback uses a slight scale change, not translucent accent fill, so label contrast remains
  stable on both light and dark material.
- At most one high-emphasis pill visible in a compact region (empty-state Retry, etc.).

### Settings

- Sections: General, Sources (Agents + Devices), About on home; Agents list → provider detail;
  Remote Devices → Pair Device.
- General: native Launch at Login toggle (title + mini Toggle, row min height 28). UI reads/writes
  `SMAppService.mainApp` only — not a separate UserDefaults preference — so System Settings changes
  stay aligned on next Settings open. First production launch seeds default-on once when still
  unregistered.
- Agents list: helper copy, then destination rows (brand icon, name, optional recovery/API-key
  detail, chevron) via `SettingsListRow` at `settingsListRowHeight`. No visibility switch on the
  list. Title-only rows center the name; subtitle rows stack within the same height.
- Devices list: same grouped + list-row language; subtitle is health · short last-seen (· endpoint
  when multi-Relay). Trailing **Remove** stays plain destructive text.
- Provider detail: **Show in Overview** toggle (always interactive; auth failures still appear in
  Overview when enabled) plus API key or sign-in copy. Defaults from `defaultVisible`.
  - Signed-in / success: no status chrome under the name.
  - Not signed in / error / unavailable: short recovery detail (catalog `loginCommand`).
- API-key forms: SecureField + Save/Clear on configurable provider detail; never show the full key.
- Overflow menu (ellipsis): Delete all QuotaBar data…, Quit QuotaBar.
- About: Version, Website, Feedback rows (no product-name label, no copyright blurb). Rows share
  compact text height; do not force `minimumInteractiveDimension` as the About row body height.

### Navigation motion

- Forward: insert from trailing + opacity; remove toward leading + opacity.
- Back: reverse.
- Duration ~0.28s snappy; Reduce Motion → opacity only or none.
- Panel height is fixed at `panelMaxHeight` for every page.

## Content rules

- Primary number and meter = **remaining** quota, never used-by-default.
- Empty Overview recovery is expressed as user tasks: sign in to a provider CLI, pair a remote
  device, or enable an agent. Never instruct the user to add, connect, or manage a Relay.
- Do not invent Grok plan from billing; OIDC/`auth_mode` hint → `supergrok` display only.
- Never show raw tokens, full emails, or unredacted account ids.
- Cache-first launch: show last local report immediately, refresh in background (plan fields may
  appear after refresh when collector semantics change).
- Per-provider data age comes from the selected snapshot’s `observed_at` (hover on the provider
  block). Do not stitch Observed next to per-window Resets.

## Do / Don’t

### Do

- Keep the host `MenuBarExtra` background and system separators/tracks.
- Keep Overview denser than Settings.
- Keep provider marks monochrome; tone meters by remaining opacity tiers.
- Put provenance on the hover meta row (source leading, Observed trailing).
- Honor Reduce Motion and VoiceOver labels on combined provider rows.

### Don’t

- Reintroduce fixed `#E5E5E5` hairline overlays or solid paper canvas as the panel fill.
- Use website display typography or large marketing cards in the menu panel.
- Show Local/Remote as heavy filled badges.
- Put version in the footer or Quit as an always-visible Settings row.
- Drive QuotaBar visuals from `apps/web/DESIGN.md`.

## Reference

This document is the canonical QuotaBar UI source. Keep implementation and tests aligned with it.
Website design is specified separately in [`apps/web/DESIGN.md`](../web/DESIGN.md).
