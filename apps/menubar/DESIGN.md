---
version: alpha
name: QuotaBar-design
description: |
  Design system for QuotaBar, the native macOS menu-bar app. This document describes the shipped
  panel as implemented in SwiftUI — not the marketing website. QuotaBar is a dense operational
  utility on system material chrome: compact provider rows, monochrome provider marks, restrained
  Emerald-or-Mint/orange/red semantic meters, quiet provenance labels, and a single typed page stack
  (Overview → Settings → Agents / Remote Devices). Website tokens live in apps/web/DESIGN.md and
  must not be treated as menubar requirements.
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

- Tokens: `Sources/QuotaBar/Core/Appearance/QuotaDesign.swift`, `QuotaPalette.swift`
- Controls: `Sources/QuotaBar/Core/Appearance/QuotaControls.swift`
- Components: `Sources/QuotaBar/Core/Appearance/Components/*`
- Design assets: `Sources/QuotaBar/Core/Appearance/*BrandIcon.swift`,
  `Sources/QuotaBar/Resources/BrandIcons/*`, and `Support/QuotaBar*.svg`
- `Sources/QuotaBar/Features/MenuBar/*`
- `Sources/QuotaBar/Features/Settings/*`

### Design-system architecture

```text
Core/Appearance/
├── QuotaDesign.swift       layout, spacing, typography, motion constants
├── QuotaPalette.swift      adaptive structural and semantic colors
├── QuotaControls.swift     native-backed fields, menus, and button styles
├── Components/             reusable page composition
│   ├── QuotaComponents.swift
│   ├── SettingsListRow.swift
│   └── SettingsSection.swift
├── ProviderBrandIcon.swift
└── QuotaBrandIcon.swift
```

Dependency direction is one-way: Features compose Components; Components use Controls and tokens;
tokens never depend on a Feature. Feature views own product state and content only. They must not
redraw a shared group surface, copy affordance, row layout, field, menu, brand mark, or semantic
color locally.

Promote a view into `Components/` only when it has at least two real call sites or owns a cross-page
invariant such as accessibility, interaction state, or surface geometry. Keep one-off page layout in
the Feature. This prevents a component library made of speculative wrappers.

## Product principles

1. **Native host, product interior** — `MenuBarExtra` supplies the window material and system shadow.
   One low-opacity adaptive `windowBackgroundColor` wash quiets vivid wallpaper bleed-through without
   replacing that material. Header, content, and footer stay on this continuous plane; groups and
   controls use translucent raised surfaces without opaque paper cards, borders, or shadows;
   transient menus alone use a soft elevation shadow.
2. **Operational density** — Overview stays compact; Settings/deeper pages are taller. Prefer
   tighter vertical rhythm over large empty canvas.
3. **Restrained semantic color** — structure stays system adaptive; meters and primary actions use
   accent/orange/red only. Auth/stale/errors still use text and icons, never provider brand colors.
4. **One shell, one stack** — Overview is root. Settings, Remote Devices, and Pair Device push on one
   app-owned path with a leading back control. No second navigation bar.
5. **Account-owned provenance** — every account keeps identity/plan in a fixed header and its
   selected source/freshness/observation time in a fixed footer; hover strengthens that whole footer
   as one unit but never inserts content.
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
| `headerHeight` | 44 | Fixed shell header row |
| `footerHeight` | 36 | Shell footer |
| `minimumInteractiveDimension` | 28 | Apple HIG recommended minimum response dimension on macOS |
| `headerControlWidth` | 28 | Back / gear / plus / ellipsis response width |
| `headerControlSurfaceSize` | 24 | Compact hover/pressed surface inside the 28×44 target |
| `headerMenuWidth` | 220 | Settings overflow list, trailing-aligned to the 16pt shell guide |
| `headerGlyphWidth` | 16 | Optical box for header action symbols |
| `headerBrandSize` | 18 | Root brand mark; leading edge sits on the shell content guide |
| `headerAccessoryWidth` | 28 | Navigation/action slot, identical to its response width |
| `providerRowVerticalPadding` | 10 | Provider block / dense list row vertical padding |
| `settingsRowHeight` | 38 | Single-line Settings home row |
| `settingsListRowHeight` | 46 | Two-line Devices / provider Overview row |
| `progressHeight` | 8 | Remaining meter thickness |
| `controlMinHeight` | 36 | Primary button min height |
| `fieldMinHeight` | 32 | Single-line text field / menu-field chrome |
| `fieldCornerRadius` | 7 | Fields (nested in groups) |
| `groupCornerRadius` | 10 | Settings groups and read-only modules |
| `groupContentInset` | 8 | Row/form content inset inside a group |
| `groupSurfaceInset` | 4 | Equal inset for row hover/pressed surfaces inside a group |
| `rowCornerRadius` | 6 | Hover / pressed surface nested inside a group |
| `floatingMenuCornerRadius` | 12 | Transient menu silhouette |
| `floatingMenuRowCornerRadius` | 8 | Menu-row hover surface; outer radius minus the 4pt inset |
| `floatingMenuShadowRadius` / `Y` | 12 / 5 | Restrained ambient separation from page content |

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
2. Navigation chrome and grouped content use related but independent grids. The root brand starts
   on the 16pt shell guide; Back and trailing actions occupy 28pt navigation slots. Settings row
   content begins 8pt inside its group. Never shift shell chrome to match an inner list icon.
3. Settings and task pages use `pageVerticalPadding` (16). Overview uses 0.
4. Prefer `Spacing.*` tokens over raw literals for stacks and clusters.
5. Empty states may add `emptyStateVerticalPadding`, never a second horizontal gutter.
6. Group geometry is harmonic: 10pt outer radius − 4pt surface inset = 6pt row radius. Row content
   sits another 4pt inside the interaction surface (`groupContentInset` = 8).
7. A row style owns its 4pt interaction-surface inset. Group and menu containers must not add a
   second vertical inset: the first/last highlight stays exactly 4pt from every outer edge.

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
- **Settings trailing:** `ellipsis` opens a 220pt Quota overflow menu (Delete all data…, Quit),
  trailing-aligned below the trigger. It floats over content without changing page geometry and
  never invokes a system menu or popover.
- **Remote Devices trailing:** `plus` with accessibility label **Pair Device**.
- **Configurable provider detail trailing:** quiet accent text **Save** (API key form commit /
  empty-key delete). Its text edge reaches the shell's 16pt trailing guide. Non-configurable
  providers keep no trailing action.
- **Pair Device:** no trailing action; 8-cell code entry auto-submits when complete.
- **Other pages:** no trailing control; back returns through the stack. Root brand and Back reserve
  the same 28pt navigation slot so the page-title guide stays stable. The root mark aligns to the
  shell edge; grouped row icons remain one content level inward. Back uses `chevron.backward` at a
  smaller optical size than gear / plus / overflow. All actions keep a 28×44pt target and 24×24pt
  visible hover surface.
- Footer shows a refresh affordance on the **right** only (`Last checked …` / `Not checked`).
  Refresh stays in the background without swapping, disabling, or dimming the label. That time is
  **orchestration** (last local collect and/or Relay pull), not per-provider data age. Version lives
  in Settings → About.
- Header and footer have no independent background layer. Their system dividers render at 35%
  opacity to establish the shell boundary without cutting the native material into three bands.
- Provider observation time is never aggregated. Each account shows its selected source and its own
  snapshot `observed_at` in the fixed account footer; VoiceOver exposes both values.

### Interaction and accessibility

- Custom controls follow Apple's macOS accessibility guidance: target at least 28×28pt; 20×20pt is
  an exceptional lower bound, not the normal design target.
- Visual density never shrinks response geometry. Header icons use 28×44pt targets, text actions
  such as Refresh and Copy have at least 28pt height, and disclosure/link rows expose the whole row.
- Agent visibility uses one native mini switch on the **provider detail** page (not the Agents
  list). Text fields use `.quotaTextFieldStyle()`; focus layers a low-strength accent tint plus a
  1.5pt inner accent ring. Keyboard navigation stays intact.
- Every icon-only action has an accessibility label and macOS hover help. Destination rows,
  disclosures, and header icons use a neutral hover surface plus an accent pressed state. Grouped
  row surfaces inset 4pt on every side; row content starts 8pt from the group edge. Outer radius 10
  and inner radius 6 keep the curves concentric. The hit target still spans the full row. Hover
  feedback is a translucent fill, not a drop shadow.
- Overview provider blocks are informational rather than destinations, so they do not draw a
  full-row hover surface or shadow. Hover raises the icon and all text in the already-present account
  footer together; it never changes geometry.
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
| **Agents** | Two title-only groups: Enabled and Disabled, matching Show in Overview. |
| **Provider** | Overview visibility switch; API-key form or copyable CLI sign-in command. |
| **Devices** | Device list; header `plus` pairs. |
| **About** | Version, website, feedback (same icon+title row style). |

### Remote Devices

- Aggregate devices this QuotaBar owns across internal endpoint records.
- Devices share one raised Settings group; rows do not become individual cards and do not add
  hairline separators. Keep a compact two-line body (name + health, last report); do not stack a
  full-width action row under each device.
- Row priority: device name and a quiet health/last-report label. Show the Relay endpoint as subdued
  metadata only when more than one endpoint needs disambiguation; use the canonical URL so ports
  and schemes cannot collapse to the same label.
- Empty state: `Pair a device to see its quota in QuotaBar.` The header `plus` is the only
  **Pair Device** action; do not repeat it as a colored body button.
- **Remove** is a short trailing plain destructive text action (not a full-width button) that
  confirms the device will stop reporting to this QuotaBar.

### Settings density

- Settings is **menu-dense**, not Overview-dense. Body labels use `settingsLabel` (12pt medium),
  still below Overview `rowTitle` (13pt). One-line list support uses `listSecondary` (10.5pt regular
  in `body`); generic secondary/meta remain 11/10pt.
- **Grouping** uses the raised translucent `settingsGroupFill` on continuous rounded rects — not
  stacks of hairline `Divider`s. In light appearance it lifts toward white instead of darkening the
  material into a gray slab; in dark appearance it lifts with a small white wash. Section title sits
  above the group; groups stack with `Spacing.md`. In-group rows share one fill with no inter-row
  dividers. Group fill has horizontal inset only.
- Section title → body uses `Spacing.xs` (6).
- **Shared row chrome** (`SettingsListRow`): leading mark (16pt) + title (+ optional one-line
  subtitle) + trailing. The row owns its 8pt content inset and full-width hit target. Its interaction
  surface stays 4pt inside the group on every side, leaving another 4pt between fill and horizontal
  content. Fixed heights — do not free-size rows per content:
  - Home and title-only Agents: `settingsRowHeight` **38**
  - Two-line Devices / provider Overview: `settingsListRowHeight` **46**
- Title-only stacked rows **vertically center** the title (no empty meta slot pushing it up). With a
  subtitle, title + support stack and stay centered in the same 46pt height.
- Agents rows never repeat scan errors, configuration state, recovery text, commands, or key masks.
  Enabled / Disabled reflects only the Show in Overview preference; VoiceOver receives that state in
  the row hint. Enabled rows add a quiet 28pt reorder handle before the chevron. Dragging the handle
  reorders locally in a stable global coordinate space, avoiding a system drag session inside the
  menu panel. Adjacent rows use a 60% enter / 40% return hysteresis band so pointer noise near the
  midpoint cannot make them oscillate. The saved order is the Overview provider order; Disabled
  stays in catalog order.
  VoiceOver exposes only valid Move Up / Move Down actions: the first row has no Move Up and the last
  row has no Move Down. Disabling and later re-enabling a provider restores its position in the full
  saved provider order.
- Multi-line forms (API key, sign-in command) keep `groupContentInset` horizontally and
  `settingsRowVerticalPadding` vertically. Toggles use the native mini switch with the adaptive
  Quota accent.
- Home rows are icon + title (+ trailing). Launch at Login has no recovery copy under the row.
- About matches the same icon+title density. Links stay full-row tappable via `contentShape`.
- Devices list uses the same grouped card + `SettingsListRow` language as Agents (no hairline
  dividers).

### Pair Device

- No page intro / pairing-code how-to prose — section headers + controls only.
- Default endpoint: official Quota Relay. Known endpoints and **Other Relay…** (reveals Relay URL).
- Task order is endpoint → pairing code → device commands. Installation help remains a secondary
  disclosure, not a prerequisite form.
- For **Other Relay…**, keep the `--relay <relay-url>` command preview visible. Replace the
  placeholder and enable Copy/code entry only when the custom URL is structurally valid; never show
  the fallback official command.
- Show the endpoint-correct command with a copy affordance under **On the device**, without a
  redundant Pair label. The QuotaCLI disclosure and expanded command likewise avoid a redundant
  Install label. Its hover surface contains both chevron and title. A complete eight-character paste works,
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

### Surface hierarchy

The panel uses three persistent levels plus one transient menu level; page-specific surfaces are not
allowed:

| Level | Token / host | Meaning | Examples |
| --- | --- | --- | --- |
| Panel | native `MenuBarExtra` material + `panelWash` | continuous canvas | header, page, footer |
| Group | `settingsGroupFill` | related or read-only content | Settings groups, Devices list, command preview |
| Control | `fieldFill` | editable or selectable value | text field, Relay pop-up, pairing cells |
| Transient | regular material + `floatingMenuFill` | temporary choice/action layer | Settings overflow, Relay options |

Hover, pressed, focus, error, and disabled are overlays on these levels, never additional opaque
cards. A Transient surface is the sole exception because it must separate from existing content
legibly; it uses a 0.5pt adaptive edge and a restrained two-layer shadow. Pair Device therefore keeps
sections on Panel, the command preview on Group, Relay / URL / pairing-code inputs on Control, and
Relay options on Transient.

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
| `panelWash` | adaptive `windowBackgroundColor` @ 20% (light) / 14% (dark) |
| `settingsGroupFill` | white @ 16% (light) / white @ 4.5% (dark) |
| `floatingMenuFill` | white @ 32% (light) / 9% (dark), layered over regular material |
| `floatingMenuShadow` | black @ 13% (light) / 30% (dark), softened in two layers |
| `rowHoverFill` | black @ 3% (light) / white @ 6% (dark) |
| `fieldFill` | white @ 44% (light) / white @ 12% (dark) |
| `progressTrack` | black @ 10% (light) / white @ 12% (dark) |

Shell dividers use the system `Divider` at 35% opacity (no fixed gray overlay). Shared borders use
`hairlineBorder` (`hairline` @ 80%). Neutral hover never adds brand color; pressed rows and focused
fields layer the adaptive accent at 11% (light) / 16% (dark).

`QuotaPalette` is the only source for application colors. Features may select a semantic text or
meter role, but they do not construct `Color` / `NSColor`, repeat adaptive providers, or paint shared
surface fills. Components own Group, Control, interaction, and Transient fills so light/dark tuning
changes once and propagates everywhere.

### Semantic (three roles only)

| Role | Source | Use |
| --- | --- | --- |
| Accent | Emerald `#087456` (light) / Soft Mint `#82ddb8` (dark) | primary actions, focus, healthy meter fill |
| Warning | `systemOrange` | remaining 15%–39% meter fill |
| Critical | `systemRed` | remaining &lt; 15% meter fill |

Compact Mint `#39c991` is an asset-only optical color for the diagonal tail in 16–64px app icons
and the favicon. It is intentionally more saturated than Soft Mint so the short stroke survives at
small sizes; it is never a UI accent, semantic state, or full-mark color.

The macOS app-icon masters alone may model restrained material depth: one upper-left light source,
a low-contrast Brand Surface gradient, tonal Emerald/Mint mark gradients, and a low-opacity contact
shadow under the large mark. This exception does not permit gradients, highlights, or persistent
shadows in the menu panel or website product mark. The compact 16–64px glyph remains flat so its
silhouette and color separation survive rasterization.

| Token | Value | Use |
| --- | --- | --- |
| provider marks | `ink` | All providers share ink template tint |
| remaining % text | `ink` | All thresholds; the meter carries semantic color |
| primary button | accent fill + contrast-selected black/white label | AA contrast in both appearances |

Stale rows further dim the meter fill (~55% of the tone), mute the percentage text, and prefix the
account footer timestamp with `Stale ·`. The numeric percentage and filled meter length preserve
meaning without relying on hue;
errors and destructive actions retain explicit labels or icons. Do not introduce provider colors,
tinted cards, gradients, persistent-surface shadows, or additional status colors. Emerald is the
healthy product accent, not a generic success indicator.

## Typography

System SF only. Prefer **semantic** roles from `QuotaDesign.Typography` and the view helpers below.
Text roles use compact base sizes at the standard setting and scale explicitly from Extra Large
through Accessibility 5. This keeps normal menu-panel density while making the macOS Dynamic Type
environment observable and testable. Avoid bare `.caption` / `.subheadline` /
`.font(.system(size:))` in features.

| Role | Base font | Color | Helper |
| --- | --- | --- | --- |
| Panel title | 13pt system semibold | `ink` | (header only) |
| Empty title | 13pt rounded medium | `ink` | `quotaEmptyTitleStyle` |
| Row / entity title | 13pt medium | `ink` | `quotaRowTitleStyle` |
| Settings label | 12pt medium | `ink` | `quotaSettingsLabelStyle` |
| Section header | 11pt semibold | `body` | `quotaSectionHeaderStyle` |
| List support / summary | 10.5pt regular | `body` | `quotaListSecondaryStyle` |
| Secondary / quiet action / issue | 11pt regular | `body` | `quotaSecondaryStyle` |
| Meta / tags / source | 10pt regular | `mute` | `quotaMetaStyle` |
| Mono (URL/command/id) | 11pt monospaced | `body` (never `ink`) | `quotaMonoStyle` |
| Mono meta (instance id) | 10pt monospaced | `mute` | `quotaMonoMetaStyle` |
| Mono Settings value | 10pt monospaced | `body` | `quotaMonoListValueStyle` |
| Chevron / affordance | 11 / 10 semibold | `mute` | `quotaChevronStyle` / `quotaAffordanceStyle` |
| Empty icon | 28 regular | `body` | `quotaEmptyIconStyle` |
| Remaining % | 13pt semibold | `ink` (`mute` when stale) | `quotaFont(.remainingValue)` |
| Window title | 11pt medium | `body` | `quotaFont(.quotaLabel)` |
| Pairing code | fixed `.title3` mono semibold | ink via field | — |

Hierarchy: **panelTitle ≥ emptyTitle > rowTitle > settingsLabel > sectionHeader > listSecondary >
meta**.
Section headers stay quieter than row titles so groups don't overpower content.
Technical strings and chevrons never use `ink`. One helper per font+color pair — no aliases.
Utility icons and the eight-cell pairing-code geometry stay fixed because they already provide a
large target and must fit the 288pt content width; all explanatory and actionable text around them
scales.

No website display scale (30–36px) inside the panel.

## Iconography

Quota uses separate full and compact optical masters. Do not derive the compact mark by scaling the
full mark or add the full mark's circular node to compact assets.

| Surface | Output size | Canonical asset | Geometry |
| --- | --- | --- | --- |
| App icon, large | 128–1024px | `Support/QuotaBarIcon.svg` | Full orbital-node double ring |
| App icon, compact | 16–64px | `Support/QuotaBarSmallIcon.svg` | Single Emerald arc + Compact Mint short diagonal tail |
| Menu bar status item | 18pt | `Resources/BrandIcons/quota.svg` | Single arc + short diagonal tail, monochrome template |

### Product-mark masters

- **Large app-icon master:** 1024×1024 transparent canvas with a gently graded Brand Surface plate at
  `(100, 100)`, size `824×824`, corner radius `185`. The full mark is centered at `(512, 512)` and
  occupies about 78% of the plate: Soft Mint outer capacity track (`r=288`, `64px` stroke), Emerald
  inner quota arc (`r=172`, `88px` stroke), and an Emerald node centered at `(715.6, 715.6)` with
  radius `40`. A Brand Surface knockout of radius `68` replaces the outer-track segment behind the
  node, creating even negative space; the node must touch neither ring. The outer track is a circle,
  not an arc with ordinary rounded endpoints. The surface and mark use one restrained upper-left
  light source, and one low-opacity underlay separates the mark from the plate without gloss,
  texture, extrusion, or a second hard shadow.
- **Compact app-icon master:** the same transparent canvas and graded inset plate, but one Emerald open arc
  plus a Compact Mint (`#39c991`) short diagonal tail. It intentionally preserves the earlier
  Q-gauge silhouette because
  the two rings and circular knockout lose separation at 16–64px. The tail uses the arc's line weight
  and stays inside the plate safe area.
- **Menu bar status item:** the compact Q-gauge geometry rendered at 18pt as a pure monochrome
  Template Image. macOS owns its light, dark, highlighted, and disabled tinting. Do not use Emerald,
  Mint, the app-icon plate, the second ring, or the circular node in this asset.
- **ICNS mapping:** `generate-brand-assets.sh` assigns the compact master to 16/32/64px
  representations and the full master to 128/256/512/1024px representations, then bakes the soft
  platform-style contact shadow. This mapping is part of the design, not a build optimization.
- **Semantic invariant:** the orbital node is a fixed brand element, not a live quota value or
  status indicator. Do not rotate it, animate it around the track, resize it by remaining quota, or
  recolor it for warning/critical thresholds; live values belong to labeled meters in the panel.
- **Provider marks:** Lobe monochrome SVGs (`openai`, `claude`, `grok` from lobehub.com/icons),
  pre-rasterized to 24pt@2x template bitmaps and tinted with system label ink.
- **Source labels:** SF Symbols — `laptopcomputer` (Local), `network` (Remote),
  `laptopcomputer.and.iphone` (mixed).
- **Utility:** SF Symbols for back, gear, ellipsis, stale clock, empty states.

### Asset ownership and reuse

| Asset family | Canonical source | Runtime wrapper / consumer |
| --- | --- | --- |
| Quota app masters | `Support/QuotaBarIcon.svg`, `Support/QuotaBarSmallIcon.svg` | `generate-brand-assets.sh` → `QuotaBar.icns` |
| Menu-bar template mark | `Sources/QuotaBar/Resources/BrandIcons/quota.svg` | `QuotaBrandIcon` |
| Provider marks | `Sources/QuotaBar/Resources/BrandIcons/{provider}.svg` | `ProviderBrandIcon` |
| UI symbols | Apple SF Symbols | component or control that owns the interaction |

SVG masters are the design assets; generated PNG/ICNS outputs are build artifacts of those masters,
not alternate sources of truth. Feature views never load asset paths or apply ad hoc tint directly:
they request `QuotaBrandIcon` / `ProviderBrandIcon`, which enforce template rendering and palette
ownership. Do not copy SVG geometry into SwiftUI paths or create page-specific mark variants.

## Components

The component library is internal SwiftUI code under `Core/Appearance/Components`. Components own
their complete visual and interaction contract; call sites supply content and business state.

| Component | Owns | Current consumers |
| --- | --- | --- |
| `.quotaGroupSurface()` | adaptive Group fill + continuous r=10 silhouette | `SettingsSection`, Pair Device command previews |
| `SettingsSection` | section header spacing/inset + shared Group surface | Settings, Agents, Provider, Remote Devices |
| `SettingsListRow` | icon column, title/subtitle hierarchy, fixed height, content inset | Settings, Agents, Provider Overview, Devices |
| `QuotaCommandRow` | mono command, selection, Copy/Copied state, clipboard write, disabled state, accessibility | Provider Sign-in, Pair Device pair/install commands |
| `.quotaTextFieldStyle()` | native field behavior + Control surface/focus/clear chrome | API-key and Relay forms |
| `QuotaPopUpField` | selection trigger, floating menu, dismissal, keyboard/focus behavior | Relay selection |
| `QuotaListRowButtonStyle` | inset neutral hover + pressed feedback | destinations, links, disclosures |
| `QuotaHeaderButtonStyle` | 28×44 target + 24×24 visible hover surface | Back, gear, plus, overflow |
| `ProviderBrandIcon` / `QuotaBrandIcon` | template rendering, sizing, system tint | Provider rows, Settings rows, shell header |

Reuse rules:

1. Feature code may use `QuotaPalette` for semantic content color, but persistent surface fills are
   component-owned. `settingsGroupFill` must be drawn through `.quotaGroupSurface()`.
2. Copyable command UI always uses `QuotaCommandRow`; pages must not own duplicate pasteboard state,
   Copy/Copied timing, padding, or accessibility labels.
3. Settings destinations use `SettingsListRow` inside `SettingsSection`; title-only rows use 38pt,
   two-line rows use 46pt.
4. Extend an existing component when the visual/interaction contract is the same. Add a new
   component only when the contract is meaningfully different, not merely because the content is.
5. Shared components contain their accessibility behavior and Reduce Motion handling. Feature views
   add only domain-specific labels, values, and actions.

### Provider row

```text
[brand] Codex
eg***@example.com                                 Pro Lite
Weekly                           29% left
████████░░░░
Resets Sat, 12:51 PM
 This Mac                              Stale · 2min ago
```

Rules:

1. Provider icon + name is a provider-only heading. Single- and multi-account providers use exactly
   the same account structure beneath it; the Provider row never absorbs account identity or plan.
2. Every account has a fixed one-line header: account id leading + plan trailing. Plan slugs
   are normalized for display only (`prolite` → `Pro Lite`, `supergrok` → `SuperGrok`, OIDC Grok
   hint → SuperGrok). Missing account ids fall back to `Account n`.
3. Provider failure status (if any) sits beside the provider name. Authentication-required rows
   omit the redundant Needs Sign-In title and show `Account setup required.` below the name. Account
   `Stale` belongs with its
   observation time in the account footer because it describes data freshness, not the plan.
4. Quota/budget windows show title left, **strong remaining %** right with the explicit word `left`,
   an 8px meter, then a locale-appropriate weekday/time reset without routine seconds. Balance-only
   windows show the remaining amount without a meter. Spend without a hard limit is not a quota
   window and never synthesizes a remaining amount, percent, or budget.
5. Percentage text stays readable ink; the meter uses accent/orange/red by threshold. Filled
   proportion is always **remaining**.
6. Window meta is reset timing only. A fixed footer after all windows shows selected source leading
   and compact snapshot age trailing: `Stale · 2min ago` when stale or `2min ago` when fresh. Visual
   units are `s` / `min` / `h` / `d` / `w` / `y`; VoiceOver receives a full named relative time.
   Provenance is never aggregated at Provider level; accounts from different devices or observation
   times stay explicit.
7. Provider hover adds no background, radius, shadow, or layout. It raises the source icon, source
   name, stale state, and observation age together from `mute` to `body` over 100ms. Account separators
   are quieter than Provider separators.

### Source label

- Mute **icon + device name** for each account's **selected** observation source, shown leading in
  the account footer. It shares the footer's font, baseline, color, and hover transition.
- Must match `SubscriptionResolver`’s chosen snapshot — never a multi-source blend.
- Icons: `laptopcomputer` (local) / `network` (remote).
- Name: `This Mac` or Relay device `displayName` (fallback `Relay Device`) — visible inline, no
  `.help` tooltip.
- VoiceOver: `Source: {name}` (combined into the provider row’s observation value).

### Provider status (failure / recovery)

Collapse protocol outcomes into three quiet UI states:

| UI | Protocol outcomes | Beside name | Detail |
| --- | --- | --- | --- |
| Account setup required | `auth_required` | none | `Account setup required.` |
| Unavailable | `unavailable`, `unsupported` | mute text | short reason if useful |
| Can’t Refresh | `error` | mute text | short reason if useful |

Rules:

- No bordered chips/CTAs for auth or errors. Status is quiet text beside the provider name.
- Success rows keep the Provider title account-free; identity/plan live in each account header and
  provenance/freshness live in each account footer.
- Issue-only rows (no accounts) expose the local source beneath the recovery detail when the failure
  came from local collection; hover only raises its contrast.
- When any presentable account exists for a provider (local or remote), suppress local
  setup-required / Unavailable / Can’t Refresh chrome for that provider. Do not blend local auth
  failure with successful remote quota.
- `Stale` is quiet account-footer metadata (freshness of otherwise successful data). Remote device
  `Active` / `Waiting` state uses the same icon-and-text restraint.
- Settings Agents rows do not reuse recovery detail. Recovery stays on Overview provider status;
  configuration actions live on the provider detail page.

### Stale freshness

- Prefixes the account's trailing compact age as `Stale · 2min ago`.
- Uses the same typography, baseline, color, and hover transition as the whole account footer; it has
  no independent tag chrome because it describes the data timestamp, not the account or plan.

### Form controls

Product form chrome lives in `QuotaControls.swift`; reusable composition lives in `Components/`;
geometry and color come from `QuotaDesign` and `QuotaPalette`. Use native interaction behavior where
it exists; customize only the compact surface needed to keep the panel coherent. Do not combine a
system control bezel with a second custom field background.

#### Text field (`.quotaTextFieldStyle()`)

```text
┌───────────────────────────────────┬────┐
│  mono 11 content                  │  × │  borderless fill · r=7 · minH 32
└───────────────────────────────────┴────┘
```

| State | Fill |
| --- | --- |
| Rest | `fieldFill` clean adaptive control surface |
| Focus | `fieldFill` + adaptive accent tint + 1.5pt inner accent ring |
| Disabled | same chrome at ~55% opacity |

- Resting controls have no stroke. Keyboard focus adds the ring instead of relying on fill alone.
  Light controls lift farther toward white than groups; dark controls use a stronger white wash.
- Optional trailing **×** (`xmark.circle.fill`, mute) clears draft text only; hit target 28×28.
- Secrets use `SecureField`; non-secrets (base URL, Relay URL) use plain `TextField`.
- Pass `isFocused` from the field's `@FocusState`.
- Pairing cells keep independent 28×28 geometry and use the same `fieldCornerRadius` 7, focus ring,
  and control fill as other editable fields.

#### Form commit (API key)

- **Explicit Save in the shell header trailing ops area only** (quiet accent text `Save`) — never a
  body button, never auto-save on blur, Return, or leave.
- **Non-empty key + Save** → write key (+ LiteLLM base URL when applicable).
- **Empty key + Save** when already configured:
  - LiteLLM base URL draft **differs** from disk → update base URL only (key field is empty by
    design when a key is stored);
  - base URL **unchanged** → delete the stored credential.
- In-field × only clears draft text, never the store.
- Failures go to the **shell title bar** (`pageIssue`). No instructional body copy above fields.
- Body is fields only; commit is header-owned. The Agents list communicates configuration through
  its two groups rather than per-row status text.

#### Buttons

| Level | Style | Visual | Use |
| --- | --- | --- | --- |
| Primary | `QuotaPrimaryButtonStyle` | Accent capsule, `onAccent` label, minH 36, pad 18 | Empty-state Retry; at most one high-emphasis pill in a compact region |
| Header text | trailing `textAction` | Quiet accent `settingsLabel`, no chrome | Provider **Save** |
| Quiet | `.buttonStyle(.plain)` | No chrome; `body` / `mute` text | Copy, field × |
| List/header action | Quota row/header styles | Inset neutral hover, accent press; no persistent fill or shadow | destinations, links, header icons, disclosures |
| Destructive quiet | plain + role/critical | No chrome; destructive label | Remove Device |

Primary press feedback is a slight scale change (not translucent accent) so label contrast stays
stable on light and dark material. Do not put form Save as a filled body control next to fields.

Copy is not assembled as a bare quiet button in Features. `QuotaCommandRow` owns its label state,
clipboard write, 1.5s reset, 28pt response height, disabled opacity, and VoiceOver label. The command
remains selectable independently of Copy.

#### Toggle

- Use the native macOS switch with `.controlSize(.mini)` inside grouped rows.
- Tint it with the adaptive Quota accent; do not reimplement track, thumb, keyboard, disabled, or
  accessibility behavior.
- Used for Launch at Login and Show in Overview.

#### Pop-up field (`QuotaPopUpField`)

Relay endpoint selection is fully Quota-owned: `fieldFill` + r=7 label chrome (full width, minH 32)
with a quiet rotating `chevron.down`. Its options float below the field without moving later form
content. Settings overflow uses the same transient surface: regular material plus a light adaptive
wash, r=12 continuous corners, a 0.5pt edge, and a soft two-layer shadow. Each menu row keeps a 4pt
inset on all four sides and an r=8 hover surface so its curve is concentric with the menu; the menu
stack adds no second top/bottom padding. Relay marks the selection with an accent checkmark. Opening
is anchored to its trigger (top-leading for Relay, top-trailing for
Settings) and uses only a nearly imperceptible 98→100% scale plus fade (120ms ease-out); closing is
an 80ms fade. There is no translation or spring. Clicking outside or choosing an item collapses the
menu, and Reduce Motion removes the transition. Opening moves keyboard focus to the selected Relay
or first enabled action. Up/Down moves through enabled rows without wrapping, Return or Space
activates the focused row, and Escape closes the menu and restores focus to its trigger. Disabled
Settings actions are skipped.

### Settings

- Sections: General, Sources (Agents + Devices), About on home; Agents list → provider detail;
  Remote Devices → Pair Device.
- General: Launch at Login (title + native mini switch). UI reads/writes `SMAppService.mainApp`
  only — not a separate UserDefaults preference — so System Settings changes stay aligned on next
  Settings open. First production launch seeds default-on once when still unregistered.
- Agents list: two destination-only groups, **Enabled** and **Disabled**, derived only from the Show
  in Overview preference. Rows contain brand icon, name, and chevron via `SettingsListRow` at the
  title-only `settingsRowHeight`; no configuration inference, helper prose, visibility switch, key
  mask, recovery detail, or command appears on the list. Enabled rows are draggable by their reorder
  affordance; `provider.display_order` persists that sequence, and Overview consumes it directly.
  Disabled rows remain in catalog order and are not draggable.
- Devices list: same grouped + list-row language; subtitle is health · short last-seen (· endpoint
  when multi-Relay). Trailing **Remove** stays plain destructive text.
- Provider detail: Overview contains only the **Show in Overview** product toggle. The second group
  is either the API-key form or a copyable CLI sign-in command; no scan/recovery status is repeated
  on this page. Visibility defaults from `defaultVisible`.
- API-key forms: fields only (no status blurb); SecureField plus a LiteLLM base URL field when
  applicable, in-field ×; header **Save** (empty key deletes); failures in the title bar; never show
  the full key.
- Non-configurable Sign-in: login command (mono) + quiet **Copy**, no surrounding explanation.
- Overflow menu (ellipsis): app-owned transient list with Delete all QuotaBar data… (critical) and
  Quit QuotaBar. It uses r12 outer / 4pt inset / r8 hover geometry.
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
- Per-account data age comes from that account's selected snapshot `observed_at`. Keep its compact
  age in the account footer; do not aggregate it at Provider level or stitch it next to per-window
  Resets.

## Do / Don’t

### Do

- Keep the host `MenuBarExtra` background and system separators/tracks.
- Keep Overview denser than Settings.
- Keep provider marks monochrome; tone meters by remaining opacity tiers.
- Keep account provenance and freshness in its fixed footer (source leading, Stale/age trailing).
- Honor Reduce Motion and VoiceOver labels on combined provider rows.
- Use `.quotaTextFieldStyle()`, `QuotaPopUpField`, and native mini switches for Settings/Pair Device
  inputs so surface hierarchy and platform behavior stay consistent.

### Don’t

- Reintroduce fixed `#E5E5E5` hairline overlays or solid paper canvas as the panel fill.
- Use website display typography or large marketing cards in the menu panel.
- Show Local/Remote as heavy filled badges.
- Put version in the footer or Quit as an always-visible Settings row.
- Drive QuotaBar visuals from `apps/web/DESIGN.md`.
- Add system-bezeled fields or Pickers inside custom control surfaces.

## Reference

This document is the canonical QuotaBar UI source. Keep implementation and tests aligned with it.
Website design is specified separately in [`apps/web/DESIGN.md`](../web/DESIGN.md).
