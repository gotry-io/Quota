# ADR 0052: QuotaBar is the app, and the menu bar is part of it

- Status: Accepted
- Date: 2026-09-16
- Amended by [ADR 0054](0054-quotabar-is-resident-in-the-menu-bar.md)
- Supersedes the window and activation parts of
  [ADR 0051](0051-the-panel-glances-and-the-windows-explain.md)
- Keeps the data rules of [ADR 0042](0042-quota-history-is-local-samples.md) and
  [ADR 0051](0051-the-panel-glances-and-the-windows-explain.md)

## Context

[ADR 0051](0051-the-panel-glances-and-the-windows-explain.md) gave QuotaBar three surfaces: a
320×480 menu-bar panel that glances, a Settings window for every preference, and a Dashboard
window for this Mac's 30-day history, today's cost, and Usage at width. The process stayed
`LSUIElement`. Opening a titled window switched it to regular activation so a Dock icon and ⌘Tab
entry existed while that window was open; closing the last one returned to accessory.

That shape shipped as `menubar-v0.2.0`. After installing it, the product decision is the other
way: a regular Dock app with one main window is the product, and the menu-bar item is its
companion. Two windows and `LSUIElement` are reversed here. The panel-as-glance, the local
samples, the plan-B `quota_history` read, and the no-upload rule are not.

## Decision

**QuotaBar is one regular app with a Dock icon.** The process is `.regular` by default.
**Show in Dock** (General, default on) can be turned off for menu-bar-only use; then the
[ADR 0051](0051-the-panel-glances-and-the-windows-explain.md) `WindowActivation` rule applies:
regular only while the main window is open, accessory when it closes. Callers still register the
main window and do not branch on the preference.

**One main window** holds a Quota group (**Quota**, **Today**, **Usage**) and a Settings group
(**Account**, **Agents**, **Notifications**, **Menu Bar**, **General**, **Support**). Title
QuotaBar, 960×640 minimum, frame autosave `QuotaBarMainWindow`, `.fullScreenPrimary`. Esc and ⌘W
close it. The selected page persists as `main.page`; the first open lands on Quota. Provider
selection for Quota is a toolbar menu, not sidebar rows.

**The menu-bar item is the glance surface**, not a second product. Overview and one provider's
detail, 320×480, nothing else. Widget deep links `quotabar:/overview` and
`quotabar:/subscriptions/<selection_id>` still land there. `quotabar://dashboard` opens the main
window on Quota.

**Login launch is silent.** A launch as a Login Item does not show the main window. A manual
launch (Finder, Spotlight, `open -a`) shows it after the status items exist. Closing the main
window never quits; a Dock click reopens it. ⌘Q still terminates.

**The data rules of [ADR 0042](0042-quota-history-is-local-samples.md) and
[ADR 0051](0051-the-panel-glances-and-the-windows-explain.md) are unchanged.** Samples stay on
this Mac for thirty days and never upload. The state push keeps the current-window slice Overview
already draws. The main window reads the rest through `quota_history { since }`. The website and
the Account gain no history view. Menu Bar preferences stay one form.

## Consequences

QuotaBar has two surfaces. The panel glances; the main window explains.

**Panel — 320×480.** Overview and one provider's read-only quota detail. The overflow menu
opens the main window; there is no Settings stack inside the extra.

**Main window — 960×640 minimum.** Titled `NSWindow`, `windowBackgroundColor`, 200pt sidebar of
two groups. Quota charts, Today table, Usage at width, and every preference. May go full screen.

**Activation.** QuotaBar is not `LSUIElement`. Show in Dock on (the default) keeps `.regular`.
Show in Dock off is menu-bar-only except while the main window is open. Browser Access and
Sparkle windows are not registered.

**Main menu.** A regular-app menu bar: QuotaBar (About, Check for Updates…, Settings… ⌘,,
Services, Hide ⌘H, Hide Others ⌥⌘H, Show All, Quit ⌘Q), File (Close ⌘W), Edit, View (Quota ⌘1,
Today ⌘2, Usage ⌘3, Refresh ⌘R, Enter Full Screen), Window (Minimize ⌘M, Zoom, QuotaBar, Bring
All to Front), Help (QuotaBar Help, Feedback).

**Visual QA routes.**

```text
Panel       overview | provider-codex
Main        main-quota | main-quota-codex | main-today | main-usage | main-usage-local
            main-account | main-agents | main-agents-codex | main-agents-litellm-key
            main-notifications | main-menu-bar | main-general | main-support
```

**Release.** `menubar-v0.2.1` carries the whole change. Main already holds 0.2.1 from the bot
bump; this record does not bump the version.
