# QuotaBar Menu Panel Design

This file is the canonical visual and interaction specification for the native macOS QuotaBar menu
panel. Website marketing UI belongs in `apps/web/DESIGN.md`.

## Product character

QuotaBar should feel like a precise macOS instrument: compact, calm, legible, and immediately useful.
It uses system materials and controls, a restrained blue accent, and dense information hierarchy.
The panel is an app-owned SwiftUI surface, not a website compressed into a popover.

Core rules:

1. Remaining quota is the primary value. Usage and account state support it without competing.
2. One header, one footer, and one typed navigation stack are shared by every page.
3. Account actions are plain user tasks: continue with GitHub, inspect devices, inspect Usage, log
   out.
4. QuotaBar displays typed local-service results. Provider configuration exposes only intentional
   API-key entry and masked saved state, never stored secrets, opaque account identifiers, or raw
   diagnostics.
5. Every action remains keyboard reachable, VoiceOver labelled, and usable with Reduce Motion and
   large text.

## Window and layout tokens

| Token | Value | Purpose |
| --- | ---: | --- |
| `panelWidth` | 320pt | Fixed menu-panel width |
| `panelMaxHeight` | 480pt | Shared fixed panel height |
| `panelHorizontalPadding` | 16pt | Header, content, and footer gutter |
| `pageVerticalPadding` | 16pt | Page content inset |
| `headerHeight` | 44pt | Navigation and title chrome |
| `footerHeight` | 36pt | Last-sync action |
| `minimumInteractiveDimension` | 28pt | Minimum pointer target |
| `settingsRowHeight` | 38pt | Single-line settings row |
| `settingsListRowHeight` | 46pt | Title/subtitle list row |
| `fieldMinHeight` | 32pt | Compact controls and command surfaces |
| `controlMinHeight` | 36pt | Primary capsule button |
| `groupCornerRadius` | 10pt | Persistent settings group |
| `rowCornerRadius` | 6pt | Nested hover/press surface |
| `fieldCornerRadius` | 7pt | Editable/control surface |
| `groupContentInset` | 8pt | Content inside a group |
| `groupSurfaceInset` | 4pt | Hover surface inset |

Spacing uses 4, 6, 8, 12, and 16pt semantic steps. Avoid page-specific magic numbers. Scroll only the
page body; header and footer remain fixed. Content aligns to the same 16pt guide at every depth.

## Material and color

Production inherits the menu extra's system material. Add only adaptive semantic layers:

- Panel: transparent material plus `panelWash`.
- Group: `settingsGroupFill` with a continuous 10pt silhouette.
- Control: `fieldFill`, with `fieldFillFocused` and the accent focus ring.
- Transient: regular material plus `floatingMenuFill`, a 0.5pt adaptive edge, and restrained shadow.
- Hover/press: `rowHoverFill` and `rowPressedFill` nested inside the group.

Use `QuotaPalette` roles instead of fixed RGB values. `ink` is for primary text and marks, `body` for
supporting copy, `mute` for tertiary metadata, `accent` for primary action/focus/progress, and
`critical` only for failure or destructive meaning. Native system red remains the destructive color.

Do not add decorative gradients, oversized cards, colored page backgrounds, or custom window chrome.

## Typography

Use semantic roles from `QuotaDesign.Typography`:

| Role | Size/weight | Use |
| --- | --- | --- |
| `panelTitle` | 13pt semibold | Header title |
| `emptyTitle` | 13pt medium rounded | Empty-state title |
| `rowTitle` | 13pt medium | Provider/account title and primary buttons |
| `settingsLabel` | 12pt medium | Settings labels |
| `sectionHeader` | 11pt semibold | Quiet section titles |
| `listSecondary` | 10.5pt regular | One-line row support |
| `secondary` | 11pt regular | Body support and recovery copy |
| `meta` | 10pt regular | Age, state, and tertiary metadata |
| `mono` / `monoMeta` | 11pt / 10pt | Commands and technical values |
| `remainingValue` | 13pt semibold | Remaining quota |

Dynamic Type scales semantic text roles. Utility symbols keep their optical sizes, while their hit
targets stay at least 28pt. Technical strings and chevrons never receive primary-text emphasis.

## Shell

The header shows:

- Overview: Quota mark, **QuotaBar**, and Settings gear.
- Child page: Back, page title, and no redundant trailing action.
- Settings root: Back, **Settings**, and an overflow menu containing **Quit QuotaBar**.

The footer is a single quiet button: **Last checked HH:MM**, or **Not checked** before any sync. It is
the sync completion clock, not the age of every provider observation. Selecting it runs one sync;
clicks while a sync is active are ignored.

Navigation transitions move horizontally by direction and combine with opacity. Reduce Motion uses
opacity only. A page change clears transient focus/menu state. Escape dismisses a transient menu;
Back returns one level.

## Information architecture

```text
Overview
└── Settings
    ├── Devices
    ├── Usage
    └── Agents
        └── Provider
```

### Overview

Render the service-provided Overview in saved catalog order. Each provider row may contain multiple
account observations; Rust has already merged global identities and selected one freshest valid
observation. Swift never repeats that policy. Never add or average percentages across devices.

Each quota observation shows:

- provider brand and name;
- optional masked account label and normalized plan badge;
- remaining value as the strongest number;
- one meter per quota window when a percent is meaningful;
- reset time, stale state, and selected source display name as quiet metadata;
- **Local** for signed-out local collection or **Device** for an account observation.

Expired `valid_until` and explicit stale status use stale presentation. A provider authentication
failure is a setup task, not a generic network error. Never display collector raw output.

Empty Overview recovery says to sign in to a provider CLI or enable an agent in Settings. A failed
current sync keeps last-known content visible and adds one inline warning.

### Settings

Settings section order is fixed:

1. **Account**
2. **General**
3. **Account Data**
4. **Local Providers**
5. **About**

Account states:

- Signed out or not checked: short benefit copy and **Continue with GitHub**.
- Login running: browser completion copy and **Cancel**. Cancellation sends the typed service
  operation and closes the browser flow.
- Signed in: one compact account row with a local avatar, account display label, and **Log Out**.
  The first click opens a native confirmation with **Cancel** and destructive **Log Out** actions;
  it states that the remote Device and synced data remain.
- Logout pending: explicit offline completion copy and **Retry Logout**.
- Removed or expired device session: concise reconnect copy; never show raw reason codes or ids.

The Account group is the only place for account authentication actions. Buttons invoke typed private
service operations; there are no embedded web views.
The account row is followed by a **Manage account** link to the web account surface.

Usage is a first-class destination showing This Mac without requiring an account. General contains
the native mini **Launch at Login** switch. Account Data contains Devices. Local Providers contains
Agents. About contains version, Website, and Feedback. The Usage source control is a compact native
segmented control inside the shared Settings group surface.

### Devices

Devices is read-only in QuotaBar. Show account device display name, platform, Active/Offline/Signed
out state, and compact last-seen age. Never display raw device ids. Empty and signed-out states point
back to the Account action in Settings. Device deletion and account administration live on the web
account surface.

### Usage

Usage defaults to the typed all-history local report. When an account summary is available, a segmented
This Mac/Account control changes the source without changing the presentation. It contains:

- Period: inclusive `from` and `to` dates.
- Tokens: input, cached input, output, reasoning, and requests.
- Cost: amount, basis, pricing catalog revision, and unpriced row count.
- Models: model-dimension rows with compact token/request totals and estimated cost.
- Coverage: Codex, Claude Code, Grok, OpenCode, and Pi complete/partial range counts.

Usage counts use locale-aware decimal formatting below 1,000 and compact SI-style `k`, `M`, and `B`
suffixes for larger values. Model rows are sorted by token volume, then model name.

Cost copy is exact:

- complete: `$X estimated`;
- partial: `≥ $X partial`;
- unavailable: `— unpriced`.

Do not infer missing prices, silently treat partial cost as total cost, or recompute typed output.
USD formatting may show up to six fractional digits so small costs remain meaningful.

### Agents

Agents has **Shown in Overview** and **Hidden from Overview** groups. Shown providers support drag
reordering and VoiceOver Move Up/Move Down actions. A quiet desktop symbol means an account device
has a presentable observation for that provider.

Provider detail contains:

- **Overview**: provider-wide visibility switch;
- **Reporting From**: This Mac or account device display names, source kind, optional stale state,
  and compact observation age;
- **This Mac Sign-in**: the catalog-provided copyable official-provider command; or
- **This Mac Configuration**: native secure API-key entry, optional base URL when catalog-enabled,
  masked saved state, Save, and Remove.

QuotaBar never reads provider credential files. New values travel only over private child stdin and
Swift clears the field after Save; the service owns validation, owner-only persistence, and masking.

## Shared components

| Component | Contract |
| --- | --- |
| `MenuBarShell` | Fixed header/body/footer geometry |
| `MenuBarHeader` | Back/title/root actions and keyboard-safe transient menu |
| `SettingsSection` | Quiet label plus adaptive group surface |
| `SettingsListRow` | Shared icon/title/subtitle/trailing alignment |
| `QuotaCommandRow` | Selectable official-provider sign-in command and Copy/Copied feedback |
| `QuotaPrimaryButtonStyle` | Accent capsule for the primary task |
| `QuotaListRowButtonStyle` | Nested hover/press feedback with full-row hit target |
| `ProviderBrandIcon` | Catalog brand resource with stable optical sizing |

Prefer these components over page-local replicas. Provider assets remain in
`Resources/BrandIcons`; do not copy their geometry into SwiftUI paths.

## Accessibility and input

- Every icon-only button has an accessibility label and Help tooltip.
- Rows combine or replace child accessibility deliberately; never announce raw opaque identifiers.
- Disclosure rows announce their destination and current summary.
- Login exposes a real Cancel action while the service's browser flow runs.
- Drag reordering has Move Up and Move Down accessibility actions.
- Focus rings use the native/accent treatment and are never suppressed on editable controls.
- Large text may increase content height; ScrollView must retain access to every row.
- Do not rely on color alone for stale, partial, unavailable, or signed-out state.

## Visual QA matrix

Required fixture states are loading, signed-in content, cached content with a sync warning,
signed-out provider issues, and service unavailable. Required routes are Overview, Settings, Agents,
both provider setup variants, Devices, and Usage. Inspect light and dark appearances, standard and
accessibility text sizes, keyboard traversal, VoiceOver labels, and Reduce Motion transitions.

Synthetic fixtures may contain display labels and opaque ids needed for typed models, but must never
contain access tokens, refresh tokens, provider secrets, or raw production data.
