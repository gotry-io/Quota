---
version: alpha
name: Quota-design-analysis
description: |
  A deliberately minimal, native-first system for QuotaBar, QuotaCLI, and QuotaRelay. QuotaBar
  treats subscription quota as calm operational information: a paper-white menu panel, compact
  provider rows, monochrome progress meters, black pill actions, and a single line-drawn quota
  gauge as the only ornamental element. There are no gradients, promotional illustrations, or
  custom shadows. The palette is pure black, pure white, and three neutral grays; interactive
  elements use fully rounded pill geometry (`{rounded.full}`), while the few containing surfaces
  use `{rounded.lg}`. SF Pro Rounded carries headings, the system sans carries interface text, and
  ui-monospace identifies commands, device IDs, and pairing codes. Local providers, remote edge
  devices, Relay configuration, empty states, and diagnostics all use the same flat visual grammar.

colors:
  primary: "#000000"
  on-primary: "#ffffff"
  ink: "#000000"
  ink-deep: "#090909"
  charcoal: "#525252"
  body: "#737373"
  mute: "#a3a3a3"
  canvas: "#ffffff"
  surface-soft: "#fafafa"
  surface-card: "#ffffff"
  hairline: "#e5e5e5"
  hairline-strong: "#d4d4d4"
  on-dark: "#ffffff"
  on-dark-mute: "rgba(255,255,255,0.7)"
  surface-dark: "#171717"
  focus-ring: "rgba(59,130,246,0.5)"
  link: "#000000"
  link-mute: "#737373"
  terminal-red: "#ff5f56"
  terminal-yellow: "#ffbd2e"
  terminal-green: "#27c93f"

typography:
  display-xl:
    fontFamily: SF Pro Rounded
    fontSize: 36px
    fontWeight: 500
    lineHeight: 1.11
    letterSpacing: 0
  display-lg:
    fontFamily: SF Pro Rounded
    fontSize: 30px
    fontWeight: 500
    lineHeight: 1.2
    letterSpacing: 0
  heading-lg:
    fontFamily: SF Pro Rounded
    fontSize: 24px
    fontWeight: 600
    lineHeight: 1.33
    letterSpacing: 0
  heading-md:
    fontFamily: ui-sans-serif
    fontSize: 20px
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: 0
  heading-sm:
    fontFamily: ui-sans-serif
    fontSize: 18px
    fontWeight: 500
    lineHeight: 1.56
    letterSpacing: 0
  body-md:
    fontFamily: ui-sans-serif
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: 0
  body-strong:
    fontFamily: ui-sans-serif
    fontSize: 16px
    fontWeight: 500
    lineHeight: 1.5
    letterSpacing: 0
  body-sm:
    fontFamily: ui-sans-serif
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: 0
  body-sm-strong:
    fontFamily: ui-sans-serif
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.43
    letterSpacing: 0
  caption-sm:
    fontFamily: ui-sans-serif
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: 0
  code-md:
    fontFamily: ui-monospace
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: 0
  code-sm:
    fontFamily: ui-monospace
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: 0
  button-md:
    fontFamily: ui-sans-serif
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1
    letterSpacing: 0

rounded:
  none: 0px
  sm: 6px
  md: 8px
  lg: 12px
  full: 9999px

spacing:
  xxs: 2px
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
  xxl: 32px
  section: 88px

components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: 8px 20px
    height: 36px
  button-primary-active:
    backgroundColor: "{colors.ink-deep}"
    textColor: "{colors.on-primary}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
  button-secondary:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: 8px 20px
    height: 36px
  button-pill-on-dark:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.button-md}"
    rounded: "{rounded.full}"
    padding: 8px 20px
  button-disabled:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.body}"
    rounded: "{rounded.full}"
  search-pill:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.full}"
    padding: 8px 16px
    height: 36px
  search-pill-focused:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
  text-input:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.full}"
    padding: 8px 16px
    height: 40px
  text-input-focused:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
  command-pill:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.code-md}"
    rounded: "{rounded.full}"
    padding: 12px 20px
    height: 48px
  command-tag:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.code-sm}"
    rounded: "{rounded.full}"
    padding: 6px 12px
  terminal-card:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.code-sm}"
    rounded: "{rounded.lg}"
    padding: 16px
  terminal-traffic-lights:
    rounded: "{rounded.full}"
    size: 12px
  terminal-close-dot:
    backgroundColor: "{colors.terminal-red}"
    rounded: "{rounded.full}"
    size: 12px
  terminal-minimize-dot:
    backgroundColor: "{colors.terminal-yellow}"
    rounded: "{rounded.full}"
    size: 12px
  terminal-zoom-dot:
    backgroundColor: "{colors.terminal-green}"
    rounded: "{rounded.full}"
    size: 12px
  quota-card:
    backgroundColor: "{colors.surface-card}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 32px
  quota-card-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.on-dark}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 32px
  provider-row:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.none}"
    padding: 16px 0px
  provider-meta:
    textColor: "{colors.charcoal}"
    typography: "{typography.body-sm}"
  quota-progress-track:
    backgroundColor: "{colors.hairline}"
    rounded: "{rounded.full}"
    height: 6px
  quota-progress-fill:
    backgroundColor: "{colors.primary}"
    rounded: "{rounded.full}"
    height: 6px
  status-pill:
    backgroundColor: "{colors.surface-soft}"
    textColor: "{colors.charcoal}"
    typography: "{typography.caption-sm}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  device-card:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 24px
  relay-card:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 24px
  empty-state:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.body}"
    typography: "{typography.body-md}"
    rounded: "{rounded.none}"
    padding: 32px 24px
  link-inline:
    textColor: "{colors.link}"
    typography: "{typography.body-md}"
  link-mute:
    textColor: "{colors.link-mute}"
    typography: "{typography.body-sm}"
  panel-header:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm-strong}"
    rounded: "{rounded.none}"
    height: 56px
  panel-footer:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.body}"
    typography: "{typography.caption-sm}"
    rounded: "{rounded.none}"
    padding: 16px 0px
  hairline-strong:
    backgroundColor: "{colors.hairline-strong}"
    height: 1px
  focus-ring:
    backgroundColor: "{colors.focus-ring}"
    rounded: "{rounded.full}"
  on-dark-meta:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.on-dark-mute}"
    typography: "{typography.body-sm}"
  muted-caption:
    textColor: "{colors.mute}"
    typography: "{typography.caption-sm}"
  cta-strip-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.on-dark}"
    typography: "{typography.heading-lg}"
    rounded: "{rounded.lg}"
    padding: 24px 32px
---

## Overview

QuotaBar is an operational utility, not an analytics dashboard. Opening the menu bar panel should
feel like reading a short, carefully typeset status note: the current machine first, its providers
directly below, remote devices after a quiet section break, and settings at the bottom. The user
should understand remaining quota and reset time within one glance and leave without navigating.

The visual system is intentionally monochrome. Quota is represented by proportion, typography,
icons, and explicit status labels rather than green/yellow/red thresholds. A black fill inside a
soft-gray pill track communicates remaining capacity. Auth failures, stale data, unsupported quota,
and revoked devices are distinguished with line icons and text, so color is never the only signal.

All product surfaces share one geometry. Interactive controls use `{rounded.full}`; cards use
`{rounded.lg}`; structural rows and dividers use `{rounded.none}`. There are no custom shadows or
gradients. Native macOS window material, menu-bar placement, and system focus effects may remain,
but the product does not add another elevation layer on top of the platform.

Typography pairs SF Pro Rounded for display roles with the macOS system sans for ordinary controls
and `ui-monospace` for commands, pairing codes, fingerprints, and device identifiers. The rounded
display face and pill controls provide warmth without competing with the quota data.

**Key Characteristics:**

- Paper-white `{colors.canvas}` throughout the menu panel, onboarding, and settings surfaces.
- Pure-black `{colors.primary}` for the only high-emphasis action in a viewport.
- Pill geometry for buttons, filters, status chips, quota meters, search, and text fields.
- Flat 12px cards for Relay profiles, remote devices, pairing, and larger quota summaries.
- Provider rows remain compact and border-separated; the menu panel is not a stack of dashboard cards.
- Quota status is encoded through amount, label, icon, and freshness—not chromatic thresholds.
- Monospaced commands and device identifiers are treated as primary content.
- A line-drawn circular quota gauge is the only custom illustration.

## Colors

> **Source surfaces:** QuotaBar menu panel, onboarding, settings, device pairing, and QuotaCLI
> examples. The palette is identical across surfaces; only density and content change.

### Brand & Accent

- **Pure Black** (`{colors.primary}` — `#000000`): the brand, primary action, selected meter fill,
  active icon, and strongest text. Quota has no separate brand hue.
- **Ink Deep** (`{colors.ink-deep}` — `#090909`): pressed primary-button surface.

### Surface

- **Canvas** (`{colors.canvas}` — `#ffffff`): the application background and default control surface.
- **Soft Surface** (`{colors.surface-soft}` — `#fafafa`): status pills, command pills, search controls,
  and the lightest possible grouped-row distinction.
- **Surface Card** (`{colors.surface-card}` — `#ffffff`): card surface when a named token is required.
- **Surface Dark** (`{colors.surface-dark}` — `#171717`): one optional attention surface per viewport,
  such as the active pairing instruction or the quota requiring immediate review.
- **Hairline** (`{colors.hairline}` — `#e5e5e5`): card borders, quota tracks, and row dividers.
- **Hairline Strong** (`{colors.hairline-strong}` — `#d4d4d4`): focused structural separation and
  secondary-button borders.

### Text

- **Ink** (`{colors.ink}` — `#000000`): provider names, remaining quota, headings, and primary links.
- **Charcoal** (`{colors.charcoal}` — `#525252`): plan labels, device metadata, and disabled secondary copy.
- **Body** (`{colors.body}` — `#737373`): reset times, Relay descriptions, help, and utility links.
- **Mute** (`{colors.mute}` — `#a3a3a3`): placeholders, unavailable values, and lowest-priority metadata.
- **On Dark** (`{colors.on-dark}` — `#ffffff`): primary content on `{colors.surface-dark}`.
- **On Dark Mute** (`{colors.on-dark-mute}` — `rgba(255,255,255,0.7)`): supporting content on the
  dark attention surface.

### Semantic

QuotaBar does not introduce success, warning, or error hues. Semantic meaning must survive grayscale,
high-contrast mode, and reduced-transparency mode:

- **Available:** quota amount, reset time, and a standard gauge icon.
- **Stale:** `Stale` label plus clock icon and last observation time.
- **Authentication required:** `Sign in again` label plus key icon.
- **Unavailable:** em dash for the amount plus an explicit reason.
- **Unsupported:** `Not supported` label plus information icon.
- **Revoked:** `Revoked` label plus slash-circle icon.

The macOS traffic-light colors retain their standard values only inside `{components.terminal-card}`:

- **Terminal Red** (`{colors.terminal-red}` — `#ff5f56`).
- **Terminal Yellow** (`{colors.terminal-yellow}` — `#ffbd2e`).
- **Terminal Green** (`{colors.terminal-green}` — `#27c93f`).

They must not be reused for quota state.

### Focus

- **Focus Ring** (`{colors.focus-ring}` — `rgba(59,130,246,0.5)`): the sole blue token, reserved for
  keyboard focus and native accessibility indication.

### System Appearance

The canonical design is light. A future dark appearance should map the same semantic tokens through
macOS dynamic colors rather than invert hexadecimal values ad hoc. Until a complete dark token set
is specified and contrast-tested, QuotaBar should ship the reference light appearance.

## Typography

### Font Family

- **SF Pro Rounded** for product title and display headings. In SwiftUI use the system rounded design;
  do not bundle a font file.
- **ui-sans-serif** for provider rows, controls, help, buttons, reset times, and settings.
- **ui-monospace** for CLI commands, pairing codes, certificate fingerprints, IDs, and diagnostic output.

This is intentionally native typography. Product identity comes from the relationship between a
rounded heading and exact operational data, not from a custom typeface.

### Hierarchy

| Token | Size | Weight | Line Height | Letter Spacing | Use |
|---|---|---|---|---|---|
| `{typography.display-xl}` | 36px | 500 | 1.11 | 0 | Onboarding title and marketing headline |
| `{typography.display-lg}` | 30px | 500 | 1.2 | 0 | Settings or pairing section headline |
| `{typography.heading-lg}` | 24px | 600 | 1.33 | 0 | Large quota summary and onboarding step |
| `{typography.heading-md}` | 20px | 500 | 1.4 | 0 | Panel title, device group title, card title |
| `{typography.heading-sm}` | 18px | 500 | 1.56 | 0 | Provider detail title and form section title |
| `{typography.body-md}` | 16px | 400 | 1.5 | 0 | Default settings and onboarding copy |
| `{typography.body-strong}` | 16px | 500 | 1.5 | 0 | Remaining-quota value and inline emphasis |
| `{typography.body-sm}` | 14px | 400 | 1.43 | 0 | Reset time, plan, device, and Relay metadata |
| `{typography.body-sm-strong}` | 14px | 500 | 1.43 | 0 | Provider name, button label, selected navigation |
| `{typography.caption-sm}` | 12px | 400 | 1.33 | 0 | Freshness, status chip, and smallest utility copy |
| `{typography.code-md}` | 16px | 400 | 1.5 | 0 | Pairing command or setup command |
| `{typography.code-sm}` | 14px | 400 | 1.43 | 0 | IDs, fingerprints, and diagnostic output |
| `{typography.button-md}` | 14px | 500 | 1 | 0 | Every pill button label |

### Principles

- Use 400 for ordinary copy and 500 for most emphasis. Weight 600 is limited to
  `{typography.heading-lg}`.
- Use tabular numerals for percentages, times, limits, and countdowns so values do not jump during refresh.
- Use a true ellipsis for truncated account labels and never truncate the quota amount.
- Keep provider name and remaining value on one line; move reset time below rather than compressing type.
- Prefer sentence case. Uppercase is reserved for short technical identifiers provided by a protocol.
- Never encode freshness or severity through weight alone; pair type with label and icon.

### Font Substitutes

SF Pro Rounded is present on the target macOS platform. Web documentation falls back to
`system-ui`; Nunito is the closest open substitute when a rounded display face is mandatory.
Inter may substitute for body text, while JetBrains Mono or Fira Code may substitute for
`ui-monospace` outside native Apple surfaces.

## Layout

### Spacing System

- **Base unit:** 8px, with 2px and 4px steps for icon and baseline corrections.
- **Tokens:** `{spacing.xxs}` (2px) · `{spacing.xs}` (4px) · `{spacing.sm}` (8px) ·
  `{spacing.md}` (12px) · `{spacing.lg}` (16px) · `{spacing.xl}` (24px) ·
  `{spacing.xxl}` (32px) · `{spacing.section}` (88px).
- **Menu panel padding:** `{spacing.lg}` (16px).
- **Provider row:** `{spacing.lg}` (16px) vertical, no added horizontal padding inside the panel column.
- **Settings card:** `{spacing.xl}` (24px); large summary card may use `{spacing.xxl}` (32px).
- **Full-page section rhythm:** `{spacing.section}` (88px) for onboarding and future web surfaces only.

### Menu Bar Panel

- Preferred width: 360px; supported range: 340–400px.
- Maximum visible height: 640px; provider/device content scrolls while header and footer remain stable.
- One content column only.
- Header height: 56px.
- Local device appears first and does not require a card border.
- Remote devices follow as named groups separated by one hairline and `{spacing.xl}` top space.
- Provider rows are ordered Codex, Claude Code, Grok unless the user explicitly reorders them.
- Settings and Quit remain low-emphasis footer actions.

### Settings Window

- Preferred content width: 760px; maximum 960px.
- At 760px and above, use a narrow navigation column plus one detail column.
- Below 760px, navigation becomes a top pill selector and content remains single-column.
- Never use more than two columns.
- Relay and device collections use 12px cards with 24px padding and 16px gaps.

### Onboarding & Pairing

- Center a single reading column no wider than 560px.
- Use the line-drawn quota gauge at 80–120px once, above the headline.
- Present one task per step: discover local providers, choose Relay, pair device, confirm.
- Pairing commands use `{components.command-pill}` when short and `{components.terminal-card}` when
  output or multiple lines are required.
- Primary and secondary actions sit in one horizontal row and stack only when space is insufficient.

### Whitespace Philosophy

Whitespace separates concepts; cards do not. The menu panel should look closer to a concise status
document than a monitoring dashboard. Do not wrap every provider or value in a surface. A provider
row earns a card only in a dedicated detail screen where it needs controls or diagnostics.

## Elevation & Depth

| Level | Treatment | Use |
|---|---|---|
| 0 — Flat | No border, no custom shadow | Menu panel, headers, provider rows, empty states |
| 1 — Hairline border | 1px solid `{colors.hairline}` | Relay cards, device cards, terminal output, settings groups |
| 2 — Inverted dark | `{colors.surface-dark}` fill | One attention or pairing surface per viewport |

Quota does not define drop-shadow tokens. Native macOS menu and window shadows belong to the
platform and are not recreated inside the content. Popovers, cards, menus, and tooltips must not
stack custom shadows on top of platform elevation.

### Decorative Depth

The only custom illustration is a line-drawn circular quota gauge. Its stroke uses `{colors.ink}`
and its empty segment uses `{colors.hairline}`. A small line icon may identify providers, devices,
Relay, authentication, refresh, settings, and freshness. Icons are functional and monochrome;
there is no photography, texture, glow, glass effect, or background artwork.

## Shapes

### Border Radius Scale

| Token | Value | Use |
|---|---|---|
| `{rounded.none}` | 0px | Structural rows, section dividers, header, footer |
| `{rounded.sm}` | 6px | Inline code and compact technical labels |
| `{rounded.md}` | 8px | Rare native menu or transient utility surface |
| `{rounded.lg}` | 12px | Quota cards, Relay cards, device cards, terminal output |
| `{rounded.full}` | 9999px | Buttons, inputs, tabs, filters, status pills, quota meters |

The working vocabulary is binary: `{rounded.full}` for interaction and `{rounded.lg}` for
containment. `{rounded.sm}` and `{rounded.md}` exist for system compatibility and must not become
new default shapes.

### Icon Geometry

- Product mark: circular quota gauge, 2px line stroke at large sizes and 1–1.5px at menu-bar sizes.
- Menu-bar icon: template image, 16×16pt, monochrome, no percentage text inside the glyph.
- Provider icons: monochrome template icons or text labels; do not introduce original brand colors.
- Utility icons: SF Symbols with regular or medium weight and consistent optical size.
- Progress tracks: 6px height with `{rounded.full}` ends.

## Components

> Hover is not a primary macOS interaction state. Specifications cover Default, Focused,
> Active/Pressed, Disabled, and Selected only where those states exist.

### Buttons

**`button-primary`** — universal high-emphasis action

- Background `{colors.primary}`, text `{colors.on-primary}`, type `{typography.button-md}`,
  padding `8px 20px`, height `36px`, rounded `{rounded.full}`.
- Use for `Pair device`, `Add Relay`, `Open settings`, `Retry`, or the current step's single action.
- Pressed state uses `{components.button-primary-active}`.
- At most one black pill is visible in a compact panel region.

**`button-secondary`** — bordered alternative

- Background `{colors.canvas}`, text `{colors.ink}`, 1px `{colors.hairline-strong}` border,
  type `{typography.button-md}`, padding `8px 20px`, height `36px`, rounded `{rounded.full}`.
- Use for `Cancel`, `Later`, `Copy`, `Refresh`, and secondary configuration actions.

**`button-pill-on-dark`** — action on inverted surface

- Background `{colors.canvas}`, text `{colors.ink}`, type `{typography.button-md}`, padding
  `8px 20px`, rounded `{rounded.full}`.

**`button-disabled`**

- Background `{colors.surface-soft}`, text `{colors.mute}`, rounded `{rounded.full}`.
- Disabled controls retain their label and must not rely on opacity below readable contrast.

### Inputs & Search

**`search-pill`** and **`search-pill-focused`**

- Default: `{colors.surface-soft}` background, `{colors.ink}` text,
  `{typography.body-sm}`, padding `8px 16px`, height `36px`, rounded `{rounded.full}`.
- Focused: `{colors.canvas}` background with `{colors.focus-ring}`.
- Use only when device/provider collections are large enough to require filtering.

**`text-input`** and **`text-input-focused`**

- Default: `{colors.canvas}`, 1px `{colors.hairline}` border, `{typography.body-md}`,
  padding `8px 16px`, height `40px`, rounded `{rounded.full}`.
- Focused: 1px `{colors.ink}` border plus the native focus ring.
- Relay URL fields show the full scheme and hostname; truncation is not allowed while editing.

### Quota Display

**`provider-row`** — standard menu-panel unit

- Background `{colors.canvas}`, padding `16px 0`, no corner radius, and 1px bottom
  `{colors.hairline}` except for the final row in a group.
- First line: provider name in `{typography.body-sm-strong}` and remaining percentage or explicit
  status in `{typography.body-strong}`.
- Second line: plan/account label and reset time in `{typography.body-sm}` `{colors.body}`.
- Third line: optional 6px quota meter with 8px top gap.
- Clicking the row opens details; the full row is the hit target.

**`quota-progress-track`** and **`quota-progress-fill`**

- Track: `{colors.hairline}`, 6px height, `{rounded.full}`.
- Fill: `{colors.primary}`, 6px height, `{rounded.full}`.
- The filled proportion always represents **remaining**, never sometimes used and sometimes remaining.
- Show the numeric value next to the provider name; the meter is supplementary.
- For unlimited or unknown quota, replace the meter with an explicit text label.

**`quota-card`** — expanded quota detail

- Background `{colors.canvas}`, 1px `{colors.hairline}` border, padding `{spacing.xxl}` (32px),
  rounded `{rounded.lg}`.
- Contains provider, account, plan, one or more quota windows, observation source, freshness, and
  last refresh time.
- Multiple windows are stacked as flat rows inside one card, not nested cards.

**`quota-card-dark`** — rare attention variant

- Same structure as `quota-card` with `{colors.surface-dark}`, `{colors.on-dark}`, and
  `{colors.on-dark-mute}`.
- Use at most once per viewport and only when the product must direct immediate attention.
- Still include an explicit state label; inversion alone is not semantic communication.

**`status-pill`**

- `{colors.surface-soft}` background, `{colors.charcoal}` text, `{typography.caption-sm}`, padding
  `4px 8px`, rounded `{rounded.full}`.
- Text examples: `Local`, `Remote`, `Stale`, `Auth required`, `Unsupported`, `Revoked`.
- Never display a colored dot without a text label.

### Relay & Device

**`relay-card`**

- Background `{colors.canvas}`, 1px `{colors.hairline}` border, padding `{spacing.xl}` (24px),
  rounded `{rounded.lg}`.
- Shows profile name, base URL, managed/self-hosted mode, connectivity, and advertised capabilities.
- Credential contents never appear. A Keychain reference may be described only as `Stored securely`.

**`device-card`**

- Same geometry as `relay-card`.
- Shows display name, shortened device ID, last seen time, provider count, and state.
- `Revoke` is a text or secondary control until confirmation; it must not become a chromatic red button.

### Commands & Diagnostics

**`command-pill`** — single-line setup command

- `{colors.surface-soft}` background, `{colors.ink}` in `{typography.code-md}`, padding
  `12px 20px`, height `48px`, rounded `{rounded.full}`.
- Contains a short command such as `quotacli pair --relay https://quota.gotry.io` and a right-aligned
  copy control.
- If the command cannot fit without losing essential text, use a terminal card instead.

**`command-tag`** — compact technical value

- `{colors.surface-soft}`, `{colors.ink}`, `{typography.code-sm}`, padding `6px 12px`,
  rounded `{rounded.full}`.
- Use for provider source names, protocol versions, and shortened fingerprints.

**`terminal-card`** — multiline CLI or diagnostic output

- `{colors.canvas}`, 1px `{colors.hairline}` border, padding `{spacing.lg}` (16px),
  rounded `{rounded.lg}`.
- Text uses `{typography.code-sm}`; comments and timestamps use `{colors.mute}`.
- macOS traffic-light dots may appear only in illustrative documentation, not in live diagnostic panes.

### Empty & Error States

**`empty-state`**

- Flat `{colors.canvas}` surface, `{colors.body}` text, `{typography.body-md}`, padding `32px 24px`.
- May include the line-drawn quota gauge or one SF Symbol, a short heading, one sentence, and one action.
- Examples: no provider session, no Relay profile, no remote device, no quota endpoint support.

Error states reuse the same component. They replace the illustration with a functional icon and add
a clear recovery action. Do not create alert banners for ordinary provider failures.

### Navigation & Footer

**`panel-header`**

- `{colors.canvas}` background, `{colors.ink}` text, height 56px, no radius.
- QuotaBar title or current device on the left; freshness and refresh control on the right.
- No border unless content scrolls beneath it, in which case add one bottom hairline.

**`panel-footer`**

- `{colors.canvas}`, optional top `{colors.hairline}` border, padding `16px 0`,
  `{typography.caption-sm}` `{colors.body}`.
- Contains low-emphasis `Settings`, `About`, and `Quit` actions. Do not repeat primary actions here.

**`link-inline`** and **`link-mute`**

- Inline links use `{colors.ink}` and underline.
- Secondary links use `{colors.body}` and underline.
- Do not use blue except the focus ring.

## Do's and Don'ts

### Do

- Treat the menu panel as a short operational document with one reading column.
- Keep the palette grayscale and use labels plus icons for semantic state.
- Use `{rounded.full}` for interactive controls and `{rounded.lg}` for containing cards.
- Use `{components.provider-row}` as the default quota presentation.
- Keep every percentage definition consistent: the primary number and meter show remaining quota.
- Show reset time and freshness near the corresponding quota window.
- Keep local and remote source identity visible.
- Use monospaced text for commands, pairing codes, fingerprints, and device IDs.
- Preserve native keyboard focus, VoiceOver labels, Reduce Motion, and Increase Contrast behavior.
- Keep provider credentials and full account identifiers out of UI, logs, screenshots, and design fixtures.

### Don't

- Don't add gradients, custom shadows, glass backgrounds, glow, or decorative blur.
- Don't introduce provider brand colors or traffic-light semantics into quota displays.
- Don't turn every provider row into a floating card.
- Don't use ring charts without a numeric label and reset time.
- Don't switch between `used` and `remaining` representations across providers.
- Don't use `{rounded.md}` as a compromise radius; interaction is pill, containment is 12px.
- Don't add a dark attention card more than once per viewport.
- Don't hide unavailable, stale, unsupported, or authentication-required states behind an empty value.
- Don't truncate Relay URLs while editing or pairing commands before the meaningful hostname.
- Don't create hover-only affordances; every action must remain discoverable by keyboard and touch/trackpad.

## Responsive Behavior

### Surface Widths

| Name | Width | Key Changes |
|---|---|---|
| menu-compact | 340px | Tightest supported menu panel; metadata may wrap to two lines |
| menu-default | 360px | Canonical one-column QuotaBar panel |
| menu-wide | 400px | Long account and device labels receive more room |
| settings-compact | <760px | Top pill navigation, one content column, stacked actions |
| settings-default | 760–960px | Navigation column plus one detail column |
| onboarding | 560px max | Centered single reading column |

### Touch & Click Targets

- Pill buttons remain 36px high with enough horizontal padding for a comfortably larger effective target.
- Text inputs remain 40px high.
- Provider rows have at least 52px of vertical hit area and normally occupy 64–80px.
- Icon-only controls receive at least a 32×32pt hit target and an accessibility label.
- Destructive confirmation controls must be reachable without precision pointing.

### Collapsing Strategy

- **Menu panel:** width stays fixed by profile; content scrolls vertically and never becomes two columns.
- **Provider row:** plan and reset metadata wrap below the primary line; percentage never truncates.
- **Settings:** sidebar becomes a top pill selector below 760px.
- **Card actions:** horizontal button row becomes vertical, with primary action first.
- **Commands:** short commands wrap inside `{components.command-pill}` only when still readable; otherwise
  switch to `{components.terminal-card}` with horizontal scrolling.
- **Quota windows:** stack vertically; never squeeze two meters side by side below 560px.
- **Section spacing:** `{spacing.section}` (88px) on full-width surfaces, 64px below 760px, 48px below 560px.

### Native Accessibility Behavior

- Dynamic Type or larger accessibility text may increase panel height and row wrapping; content must scroll.
- Increase Contrast strengthens hairlines from `{colors.hairline}` toward `{colors.hairline-strong}`.
- Reduce Transparency replaces any native translucent window material with `{colors.canvas}`.
- Reduce Motion removes progress interpolation and refresh transitions; data updates instantly.
- VoiceOver reads provider, remaining quota, reset time, freshness, device, and source as one coherent row.

## Iteration Guide

1. Work on one component at a time and resolve every referenced front-matter token.
2. Use token and component names directly, such as `{colors.primary}`, `{rounded.full}`, and
   `{components.provider-row}`.
3. Run `npx @google/design.md lint DESIGN.md` after structural edits.
4. Add explicit variants (`-active`, `-disabled`, `-focused`) instead of hiding variant values in prose.
5. Default interface copy to `{typography.body-md}` or `{typography.body-sm}`; reserve display tokens
   for onboarding, settings titles, and large summaries.
6. Keep `{colors.primary}` scarce: one high-emphasis black pill per compact visual region.
7. Before adding a component, test whether provider row, pill, flat card, command pill, or terminal card
   already expresses the requirement.
8. Verify quota fixtures for all six states: available, stale, auth required, unavailable, unsupported,
   and error.
9. Review local and remote devices at 340px, 360px, 400px, 560px, and 760px widths.
10. Treat the reference design as the source for color, type, spacing, radius, and elevation unless this
    document explicitly defines a native QuotaBar adaptation.

## Known Gaps

- Production QuotaBar screens have not yet been visually captured; this specification guides their first pass.
- A complete dark-appearance token set is intentionally deferred.
- Hover states are not documented; macOS focus, pressed, selected, and disabled states take priority.
- Menu-bar icon and line-drawn quota-gauge assets are not finalized.
- Long provider/account combinations need validation with real anonymized data.
- Device pairing, certificate management, quota history, and notification screens are not yet implemented.
- Provider detail layouts for multiple accounts and multiple quota windows require usability testing.
- The future public website may reuse these tokens, but marketing navigation and pricing layouts are out of scope.

## Reference

This system adapts the monochrome palette, typography, spacing, pill geometry, flat-card treatment,
and zero-custom-shadow principles documented in the
[Ollama DESIGN.md reference](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/ollama/DESIGN.md).
