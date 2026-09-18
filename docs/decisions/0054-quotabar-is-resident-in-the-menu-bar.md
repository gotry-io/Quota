# ADR 0054: QuotaBar is resident in the menu bar

- Status: Accepted
- Date: 2026-09-18
- Amends [ADR 0052](0052-quotabar-is-the-app-and-the-menu-bar-is-part-of-it.md)

## Context

[ADR 0052](0052-quotabar-is-the-app-and-the-menu-bar-is-part-of-it.md) made QuotaBar a regular Dock
app: **Show in Dock** defaulted on, a manual launch opened the main window, and ⌘Q terminated the
process — including the menu-bar item. After using that shape, the owner’s complaint is the other
way: launching opens a desktop window; closing it leaves a Dock icon; Quit then takes the menu bar
with it. The product wanted is a resident menu-bar tool whose window comes and goes.

## Decision

**What stays.** QuotaBar is still one process with one main window. The 320×480 panel is still the
glance surface. A launch as a Login Item is still silent. Closing the main window still never quits.
A Dock click or `open -a` while running still shows the main window. Browser Access and Sparkle
windows are still not registered with `WindowActivation`.

**Show in Dock defaults off.** `dock.shown` fallback is `false`: accessory until the main window is
open, regular while it is. An installation that never wrote the key takes the new default; one that
stored a value is read as written. The General toggle, copy, and hint stay; the hint is **Keep
QuotaBar in the Dock when its window is closed**.

**A plain Quit with the main window open closes the window.** `applicationShouldTerminate` decides
before invalidating anything. `QuitDecision.resolve(windowPresented:fullQuitRequested:systemQuit:)`
returns `.closeWindow` or `.terminate`. Close goes through the same `performClose` path as ⌘W so
`WindowActivation` drops to accessory. The first downgrade shows an informational alert (**QuotaBar
is still running in the menu bar**) once, stored as `quit.keepRunningExplained`.

Three exemptions still terminate:

1. **Full quit requested.** Panel overflow **Quit QuotaBar**, App-menu **Quit QuotaBar Completely**
   ⌥⌘Q, Browser Access relaunch, and Sparkle `updaterWillRelaunchApplication` set the flag then
   terminate, so an update is never downgraded to closing a window.
2. **System quit.** A `kAEQuitApplication` event whose `keyAEQuitReason` (`why?`) param is present
   — log out, restart, shut down, any value.
3. **No window.** With the window closed, a Dock ▸ Quit or ⌘Q finds nothing to close and quits for
   real. The App-menu **Quit QuotaBar** ⌘Q keeps its title and shortcut.

**A manual launch opens the window only until QuotaBar has something to show.**
`LaunchWindowPreference` (`launch.opensMainWindow`, default off) is **Open window at launch** on
General, under Launch at Login. `launch.hasShownQuota` is set the first time a non-empty overview
arrives and is never cleared. `LaunchPresentation.resolve(loginItem:opensWindow:hasShownQuota:)`
returns `.silent` for a Login Item, `.mainWindow` when the preference is on or quota has not been
shown, and `.panel` otherwise — opening the menu-bar panel after the status items exist so the
launch is visibly acknowledged.

A miniaturized main window counts as open for this rule: it is not on screen, but it is still the
app's window, so a plain Quit closes it rather than ending the process behind it.

## Consequences

QuotaBar lives in the menu bar. The Dock icon is optional and, by default, exists only while the
main window is open. ⌘Q with that window open is Close; quitting the process is a named action.

**Main menu.** The QuotaBar menu gains **Quit QuotaBar Completely** ⌥⌘Q under **Quit QuotaBar** ⌘Q.
The rest of the menu bar is unchanged.

**Release.** This record does not bump the version.
