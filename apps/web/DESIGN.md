---
version: alpha
name: Quota-web-design
description: |
  Design system for the Quota public website (quota.gotry.io) and related marketing/static surfaces.
  Paper canvas, pure black CTAs, no gradients or custom shadows — aligned to the Ollama design
  grammar. SF Pro Rounded for display, system sans for UI, ui-monospace for commands. This file is
  not the QuotaBar menu-panel system; native menubar UI is specified in apps/menubar/DESIGN.md.

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
  brand-codex: "#7a9dff"
  brand-claude: "#d97757"
  brand-grok: "#26262a"
  brand-grok-dark: "#e4e4e7"
  usage-healthy: "#16a34a"
  usage-warning: "#d97706"
  usage-critical: "#dc2626"

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
  panel-title:
    fontFamily: SF Pro Rounded
    fontSize: 17px
    fontWeight: 600
    lineHeight: 1.18
    letterSpacing: 0
  quota-label:
    fontFamily: ui-sans-serif
    fontSize: 12px
    fontWeight: 500
    lineHeight: 1.33
    letterSpacing: 0
  status-tag:
    fontFamily: ui-sans-serif
    fontSize: 10px
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: 0
  source-tag:
    fontFamily: ui-sans-serif
    fontSize: 9px
    fontWeight: 500
    lineHeight: 1.2
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
    padding: 10px 0px
  provider-meta:
    textColor: "{colors.charcoal}"
    typography: "{typography.body-sm}"
  quota-progress-track:
    backgroundColor: "{colors.hairline}"
    rounded: "{rounded.full}"
    height: 8px
  quota-progress-fill:
    backgroundColor: "{colors.usage-healthy}"
    rounded: "{rounded.full}"
    height: 8px
  quota-progress-fill-warning:
    backgroundColor: "{colors.usage-warning}"
    rounded: "{rounded.full}"
    height: 8px
  quota-progress-fill-critical:
    backgroundColor: "{colors.usage-critical}"
    rounded: "{rounded.full}"
    height: 8px
  status-tag:
    textColor: "{colors.charcoal}"
    typography: "{typography.status-tag}"
    rounded: 3px
    padding: 2px 5px
  source-label:
    textColor: "{colors.mute}"
    typography: "{typography.source-tag}"
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
    typography: "{typography.panel-title}"
    rounded: "{rounded.none}"
    height: 44px
  panel-footer:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.body}"
    typography: "{typography.caption-sm}"
    rounded: "{rounded.none}"
    height: 36px
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

## Scope

| Surface | Design source |
| --- | --- |
| Public website / static marketing | **`apps/web/DESIGN.md`** (this file) |
| QuotaBar macOS menu panel | `apps/menubar/DESIGN.md` |

Do not drive QuotaBar SwiftUI from this document. Menubar uses system material, adaptive chrome, and
denser operational layout documented there.

## Overview

The Quota website is a documentation-first product surface, not an analytics dashboard. Pages should
feel like a carefully typeset status note: clear hierarchy, one reading column, black pill actions,
and restrained neutrals. Product names (Quota, QuotaBar, QuotaCLI, QuotaRelay) and provider marks
may appear, but interactive marketing chrome stays minimal.

The visual system is inspired by Ollama's documentation-first minimalism. Light mode is paper-white
canvas and pure black ink; dark mode is an inverted adaptation of the same fixed tokens. Page
chrome, actions, tags, and empty states stay monochrome. Provider identity may use light brand
tints on monochrome SVG marks in marketing illustrations. There are no gradients or custom shadows.
Depth is hairline borders and at most one inverted dark surface per viewport.

All website surfaces share one geometry. Interactive controls use `{rounded.full}`; cards use
`{rounded.lg}` (12px); structural rows and dividers use `{rounded.none}`.

Typography pairs SF Pro Rounded for display roles with the system sans for ordinary controls and
`ui-monospace` for commands and identifiers.

**Key Characteristics:**

- Solid `{colors.canvas}` page background (not system material).
- Pure-black `{colors.primary}` for the only high-emphasis action in a viewport.
- Pill geometry for buttons, filters, search, and text fields.
- Flat 12px cards for feature and install blocks.
- One reading column; marketing pages are not a stack of dashboard widgets.
- Monospaced commands and device identifiers are treated as primary content.
- A line-drawn circular quota gauge is the only custom illustration.

## Colors

> **Source surfaces:** public website, install/docs marketing blocks, and static Cloudflare pages.
> QuotaBar menu-panel tokens are out of scope here — see `apps/menubar/DESIGN.md`.

### Brand & Accent

- **Pure Black** (`{colors.primary}` — `#000000`): the product brand, primary action, and strongest
  text. Panel chrome stays neutral.
- **Ink Deep** (`{colors.ink-deep}` — `#090909`): pressed primary-button surface.
- **Provider brand tints**: Codex `{colors.brand-codex}` (Lobe `codex-color` blue `#7a9dff`), Claude
  `{colors.brand-claude}`, Grok `{colors.brand-grok}` / `{colors.brand-grok-dark}` — used only to
  tint monochrome provider SVG marks.
- **Usage tones**: `{colors.usage-healthy}` (≥40% remaining), `{colors.usage-warning}` (≥15%),
  `{colors.usage-critical}` (<15%) for meter fill and trailing percent.

### Surface

- **Canvas** (`{colors.canvas}` — `#ffffff` light / inverted dark): the panel background and default
  control surface. This is a product fill, not a system material.
- **Soft Surface** (`{colors.surface-soft}` — `#fafafa`): command pills, search controls, and the
  lightest possible grouped-row distinction.
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
- **Authentication required:** omit the agent from the quota overview and show quiet `Not signed in`
  text beside its visibility switch in Settings.
- **Unavailable:** omit the agent from the quota overview and show an explicit reason in Settings.
- **Unsupported:** omit the agent from the quota overview and show `Unsupported` in Settings.
- **Error:** omit the agent from the quota overview and show `Error` in Settings.
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

QuotaBar always follows the current macOS appearance through SwiftUI's inherited environment. It
does not expose an appearance setting or apply a `preferredColorScheme` override. Native surfaces
use the containing menu window's default background; text, separators, controls, status tags, and
meters map through AppKit semantic colors. The hexadecimal palette above remains the light-reference
palette for documentation and web use. Dark appearance comes from the same semantic colors rather
than a separate custom palette or manual inversion.

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
| `{typography.caption-sm}` | 12px | 400 | 1.33 | 0 | Freshness and small utility copy |
| `{typography.code-md}` | 16px | 400 | 1.5 | 0 | Pairing command or setup command |
| `{typography.code-sm}` | 14px | 400 | 1.43 | 0 | IDs, fingerprints, and diagnostic output |
| `{typography.button-md}` | 14px | 500 | 1 | 0 | Every pill button label |
| `{typography.panel-title}` | 17px | 600 | 1.18 | 0 | Compact QuotaBar and Settings header title |
| `{typography.quota-label}` | 12px | 500 | 1.33 | 0 | Quota window name and remaining value |
| `{typography.status-tag}` | 10px | 400 | 1.2 | 0 | Compact semantic tag |
| `{typography.source-tag}` | 9px | 500 | 1.2 | 0 | Compact local/remote provenance summary |

### Principles

- Use 400 for ordinary copy and 500 for most emphasis. Weight 600 is limited to
  `{typography.heading-lg}` and the compact `{typography.panel-title}`.
- Use tabular numerals for percentages, times, limits, and countdowns so values do not jump during refresh.
- Use a true ellipsis for truncated account labels and never truncate the quota amount.
- Keep each quota-window name and remaining value on one line; move reset time below rather than
  compressing type.
- Native SwiftUI surfaces map compact roles to semantic text styles instead of fixed font sizes.
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
- Header height: 44px; title type is `{typography.panel-title}`.
- Footer height: 36px.
- Resolved subscription rows appear in provider order; local and remote observations may contribute
  to the same row without being numerically combined.
- Remote device inventory and revocation belong to the selected Relay profile in Settings rather
  than appearing as a second Overview section.
- Provider rows are ordered Codex, Claude Code, Grok unless the user explicitly reorders them.
- On launch, render the last normalized local report immediately and refresh it in the background;
  never replace cached quota with a loading-only screen.
- The top-right settings control pushes the Settings home destination on the panel's single typed,
  application-owned page stack. The shared shell renders every destination and owns the sole
  leading back control; destinations do not add a system navigation bar, trailing close button, or
  nested navigation stack.
- Replace the shell's current page directly. Do not add a second navigation container. Page changes
  use a short forward/back slide+opacity transition; honor Reduce Motion with opacity-only or none.
- The shared shell supplies the only page-level canvas fill and corner radius. Scroll regions,
  sections, cards, and bottom action areas stay on that canvas and use spacing, strokes, or
  dividers for structure. Reserve local background fills for independent controls such as buttons,
  fields, tags, and meters — never nest system materials.
- The footer shows a clickable last-refresh time on the right. Version lives only in Settings → About.

### Settings Panel

- Settings remain inside the 340–400px menu-bar panel; do not open a separate settings window.
- Visible-agent controls and About information are flat sections. Quit and delete-all live in the
  Settings header overflow menu.
- Relay profile listing, setup, detail, pairing decisions, and device management use deeper
  destinations in the same typed stack.
- The managed Relay is enrolled automatically with an anonymous controller capability; do not add
  account, sign-in, or manually copied managed-token UI. Self-hosted Relay setup asks for its URL
  and controller token in a secure field.
- `Delete all QuotaBar data` is a destructive Settings overflow action. It deletes managed controllers
  while online before clearing local profiles, cached quota, preferences, and QuotaBar Keychain entries.
  When remote deletion fails, require a separate `Delete Locally Anyway` confirmation and explain
  that the managed controller and Relay data may remain while paired devices continue reporting.
- Removing the managed Relay or deleting all data persists a disconnected state across app
  restarts. `Reconnect Quota Relay` is the only UI action that clears it and creates a new anonymous
  controller; ordinary polling must not silently undo a destructive user action.
- Provider switches list all supported agents and describe unsigned or unavailable sessions as
  quiet secondary text.
- A provider enters the quota overview only when collection succeeds and at least one `available`
  or `stale` snapshot contains a quota window. Authentication, unavailable, unsupported, empty, and
  error outcomes remain discoverable in Settings instead of becoming provider rows.

### Compact Menu Language

The following roles are the canonical display grammar for QuotaBar. New menu-panel UI reuses these
roles rather than introducing one-off sizes, containers, tags, or transitions.

| Role | Canonical treatment | Purpose |
|---|---|---|
| Panel | Overview 360×440 (380–560); Settings/deeper 360×520 (480–560) | Compact overview, roomy settings stack |
| Header | 48px, 16px inset, 17px semibold title, 32px edge control | Current location and one edge action |
| Navigation | One typed application-owned stack, shared-shell leading back | Embedded Settings and Relay detail destinations |
| Provider | 16px vertical inset, 14px medium name, flat separators | One authenticated provider with usable quota |
| Quota window | 12px medium labels, 6px remaining meter, 11px reset time | Repeatable unit across every provider |
| Source tag | 9px medium, 1×5px inset, 3px radius, transparent fill | Quiet local/remote provenance summary |
| Status tag | 10px regular, 2×5px inset, 3px radius, transparent fill | Secondary state on an otherwise displayable row |
| Footer | 40px, 12px text | Version on the left; the sole refresh action on the right |

The overview answers only “how much quota remains?” Provider configuration and collection health
belong to Settings. This separation prevents transient diagnostics or unsigned agents from changing
the overview's visual inventory during repeated refreshes.

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
Relay, authentication, refresh, settings, and freshness. Utility icons stay monochrome; provider
marks use brand-tinted monochrome SVGs. There is no photography, texture, glow, glass effect, or
background artwork.

## Shapes

### Border Radius Scale

| Token | Value | Use |
|---|---|---|
| `{rounded.none}` | 0px | Structural rows, section dividers, header, footer |
| `{rounded.sm}` | 6px | Inline code and compact technical labels |
| `{rounded.md}` | 8px | Rare native menu or transient utility surface |
| `{rounded.lg}` | 12px | Quota cards, Relay cards, device cards, terminal output |
| `{rounded.full}` | 9999px | Buttons, inputs, tabs, filters, quota meters |

The working vocabulary is binary: `{rounded.full}` for interaction and `{rounded.lg}` for
containment. `{rounded.sm}` and `{rounded.md}` exist for system compatibility and must not become
new default shapes.

### Icon Geometry

- Product mark: circular quota gauge, 2px line stroke at large sizes and 1–1.5px at menu-bar sizes.
- Menu-bar icon: template image, 16×16pt, monochrome, no percentage text inside the glyph.
- Provider icons: use the Codex, Claude Code, and Grok monochrome SVG assets from Lobe Icons as
  template images tinted with `{colors.brand-*}` tokens; do not substitute SF Symbols or multicolor
  artwork.
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

- Background `{colors.canvas}`, padding `10px 0`, no corner radius, and 1px bottom
  `{colors.hairline}` except for the final row in a group.
- First line: brand-tinted provider icon + provider name in `{typography.body-sm-strong}`. When it
  has one resolved subscription, place that subscription's source label at the trailing edge of the
  provider row; when it has several, place each source label at the trailing edge of its account
  row. Do not place an enlarged remaining value in this title row.
- Second line: account identity as plain metadata text in `{typography.caption-sm}` medium
  `{colors.body}`: `Pro Lite · eg***@example.com` when both exist, otherwise just the plan or
  masked label. No filled plan chip. Normalize wire plan slugs for display only
  (`plus` → `Plus`, `prolite` → `Pro Lite`, `supergrok` → `SuperGrok`) without rewriting stored
  values. When the provider API omits plan, show only the account label and do not invent a plan
  name.
- Every quota window, including the first, uses the same compact row: window title on the left and a
  stronger remaining percentage on the right, then an 8px meter, then a compact absolute reset time
  (`MM-dd HH:mm:ss`). Remaining percent and meter fill share the usage tone color.
- Clicking the row opens details; the full row is the hit target.

**`quota-progress-track`** and **`quota-progress-fill`**

- Track: `{colors.hairline}`, 8px height, `{rounded.full}`.
- Fill: usage tone by remaining percent — `{colors.usage-healthy}` (≥40%),
  `{colors.usage-warning}` (≥15%), `{colors.usage-critical}` (<15%); 8px height, `{rounded.full}`.
  Stale rows keep the same tone at reduced opacity and still show the Stale tag.
- The filled proportion always represents **remaining**, never sometimes used and sometimes remaining.
- Show the numeric remaining value at the trailing edge as the primary anchor
  (`{typography.body-sm-strong}` / semibold subheadline); omit the trailing word `left` in the
  visible label. The meter is supplementary.
- Reset timestamps use a compact absolute form rather than relative countdown copy.
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

**`status-tag`**

- Transparent background, a subtle `{colors.hairline}` border, `{colors.charcoal}` text,
  `{typography.status-tag}`, padding `2px 5px`, 3px radius.
- Text examples: `Stale`, `Unsupported`, `Unavailable`, `Revoked`.
- Never display a colored dot without a text label.

**`source-label`**

- No chip chrome: quiet `{colors.mute}` SF Symbol + text at `{typography.source-tag}`.
- Trailing-aligned on the provider/account row. Symbols: laptop for Local, network for Remote,
  laptop+phone for mixed Local+Remote.
- Values remain `Local`, `Remote`, `Local + Remote`, `Local + N remote`, or `N remote`.
- Origin only; authentication and error states stay in Settings or a semantic status treatment.

### Relay & Device

**`relay-card`**

- Background `{colors.canvas}`, 1px `{colors.hairline}` border, padding `{spacing.xl}` (24px),
  rounded `{rounded.lg}`.
- Shows profile name, base URL, managed/self-hosted mode, connectivity, and advertised capabilities.
- Credential contents never appear. A Keychain reference may be described only as `Stored securely`.

**`device-card`**

- Same geometry as `relay-card`.
- Shows display name, shortened device ID, last seen or revoked time, last accepted sequence, and
  state. The device API does not expose a provider count, so the card must not infer or fabricate one.
- `Revoke` is a text or secondary control until confirmation; it must not become a chromatic red button.

### Commands & Diagnostics

**`command-pill`** — single-line setup command

- `{colors.surface-soft}` background, `{colors.ink}` in `{typography.code-md}`, padding
  `12px 20px`, height `48px`, rounded `{rounded.full}`.
- Contains a short command such as `quotacli relay pair` and a right-aligned
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

- `{colors.canvas}` background, `{colors.ink}` text, height 44px, no local radius (shell provides
  `{rounded.lg}`). Leading back control aligns to the content inset; trailing settings/menu control
  mirrors it.
- The overview shows a compact `QuotaBar` title on the left and a quiet settings control on the
  right. Settings shows a leading back control followed by its title, with a trailing overflow menu
  for destructive/account actions. Source labels belong to subscription rows, not the panel header.
- One bottom hairline separates header from content.

**`panel-footer`**

- `{colors.canvas}`, top `{colors.hairline}` border, height 36px,
  `{typography.caption-sm}` `{colors.body}`.
- Shows last-refresh time on the right as the one refresh action (`Refreshing…` while collection
  runs). Version lives only in Settings → About — not in the footer.
- Quit and delete-all live in the Settings overflow menu, not the footer.

**`link-inline`** and **`link-mute`**

- Inline links use `{colors.ink}` and underline.
- Secondary links use `{colors.body}` and underline.
- Do not use blue except the focus ring.

## Do's and Don'ts

### Do

- Treat the menu panel as a short operational document with one reading column on solid canvas.
- Prefer fixed product tokens over system label/separator/material colors inside the panel.
- Keep structural chrome grayscale; use labels plus icons for semantic state; brand tints only on
  provider marks; usage tones only on meters/percents.
- Use `{rounded.full}` for interactive controls and `{rounded.lg}` for the panel shell and cards.
- Use `{components.provider-row}` as the default quota presentation.
- Keep every percentage definition consistent: the primary number and meter show remaining quota.
- Show absolute reset timestamps and freshness near the corresponding quota window.
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
- Don't hide a stale state on an otherwise displayable quota row. Authentication, unavailable,
  unsupported, empty, and error outcomes are omitted from the overview and identified in Settings.
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
- **Settings:** remains a single-column embedded panel with flat sections.
- **Card actions:** horizontal button row becomes vertical, with primary action first.
- **Commands:** short commands wrap inside `{components.command-pill}` only when still readable; otherwise
  switch to `{components.terminal-card}` with horizontal scrolling.
- **Quota windows:** stack vertically; never squeeze two meters side by side below 560px.
- **Section spacing:** `{spacing.section}` (88px) on full-width surfaces, 64px below 760px, 48px below 560px.

### Native Accessibility Behavior

- Dynamic Type or larger accessibility text may increase panel height and row wrapping; content must scroll.
- Increase Contrast strengthens hairlines from `{colors.hairline}` toward `{colors.hairline-strong}`.
- The panel already uses solid `{colors.canvas}`; Reduce Transparency must not reintroduce blur.
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
8. Verify quota fixtures for all six states across overview and Settings: available, stale, auth
   required, unavailable, unsupported, and error.
9. Review local and remote devices at 340px, 360px, 400px, 560px, and 760px widths.
10. Treat the reference design as the source for color, type, spacing, radius, and elevation unless this
    document explicitly defines a native QuotaBar adaptation.

## Known Gaps

- Final light- and dark-appearance screenshots still require release-candidate validation.
- Hover states are not documented; macOS focus, pressed, selected, and disabled states take priority.
- Menu-bar icon and line-drawn quota-gauge assets are not finalized.
- Long provider/account combinations need validation with real anonymized data.
- Certificate management, quota history, and notification screens are not yet implemented.
- Provider detail layouts for multiple accounts and multiple quota windows require usability testing.
- The future public website may reuse these tokens, but marketing navigation and pricing layouts are out of scope.

## Reference

This system adapts the restrained palette, typography, spacing, pill geometry, flat-card treatment,
solid-canvas surfaces, and zero-custom-shadow principles documented in the
[Ollama DESIGN.md reference](https://raw.githubusercontent.com/VoltAgent/awesome-design-md/refs/heads/main/design-md/ollama/DESIGN.md).
Native QuotaBar UI is specified separately in [`apps/menubar/DESIGN.md`](../menubar/DESIGN.md).
