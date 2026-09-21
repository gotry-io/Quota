# ADR 0057: Content is opaque; glass is chrome

- Status: Accepted
- Date: 2026-09-21

## Context

Plan 9 put Liquid Glass on QuotaBar's Quota and Usage data cards (`quotaCardSurface()` called
`glassEffect` on macOS 26). Apple's guidance is that glass is the layer that floats over
content — sidebar, toolbar, the menu-bar panel, transient menus — and that content itself
should be opaque so numbers keep their contrast over whatever is behind the window. Quota iOS
already follows that rule: `QuotaCard` is grouped fill, not glass. No earlier ADR recorded
Plan 9's glass on those cards.

## Decision

**Data cards are opaque. Glass is chrome.** The rule is for every Apple client.

QuotaBar `quotaCardSurface()` is one opaque surface on every macOS release: the
`surface.content` fill, 20 pt continuous corners, and the `border.subtle` hairline. It does
not call `glassEffect`. `quotaFloatingSurface()`, the sidebar, toolbar, scroll-edge effect,
and the menu-bar panel stay on glass (or the material fallback below macOS 26).

Quota iOS keeps opaque cards and system glass on bars and account controls. Widgets never
call `glassEffect`.

## Consequences

Numbers on Quota and Usage cards contrast against a real fill, not against wallpaper
composited through glass. `ContrastTokenTests` in apple-shared pin primary, secondary, and
tone-meter pairings on `surface.content` in light and dark. Chrome still uses native glass
on macOS 26.
