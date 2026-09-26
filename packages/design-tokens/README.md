# Design tokens

`tokens.json` is the only hand-edited colour, tone-threshold, spacing, and radius source for
Quota Web, Quota iOS, and QuotaBar. What those colours mean, and the copy every client prints,
live in [`docs/design.md`](../../docs/design.md).

Run `pnpm generate:design-tokens` after editing it. That writes:

- `apps/web/src/lib/styles/tokens.generated.css` — CSS custom properties with `light-dark()`
- `apps/web/src/lib/tokens.generated.ts` — remaining-quota band thresholds and the model colour
  families
- `packages/apple-shared/Sources/QuotaPresentation/DesignTokens.generated.swift` — Foundation-only
  RGB, thresholds, spacing, and radii (Apple overrides already applied), plus
  `DesignTokens.Color.model(_:shade:)` over `DesignTokens.ModelFamily`

Model colours are `color.model.<provider>.<1–4>` and `color.model.other`; each publishes exactly
`--model-<provider>-<n>` or `--model-other`, and the generator refuses any other name.

`pnpm check:design-tokens` (`--check`) refuses a commit whose generated files drifted.

Apple maps `text.primary` and `text.meta` to system label colours, and overrides `text.secondary`
in light appearance so support text stays ≥ 4.5:1 on grouped backgrounds. Card radius is 20 on
Apple and 16 on the web. Those are explicit `overrides.apple` entries, not a second palette.
