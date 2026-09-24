import QuotaPresentation
import Testing

struct PlanDisplayTests {
  /// Plan slugs reach a client with any case and separator; each spelling finds the one catalog
  /// name rather than falling through to a title-cased slug.
  @Test
  func aSlugInAnySpellingReachesTheCatalogName() {
    #expect(PlanDisplay.displayName("PRO") == "Pro")
    #expect(PlanDisplay.displayName("pro_lite") == "Pro Lite")
    #expect(PlanDisplay.displayName("super_grok") == "SuperGrok")
    #expect(PlanDisplay.displayName("max_5x") == "Max 5x")
    #expect(PlanDisplay.displayName("Max 20X") == "Max 20x")
  }

  /// A plan the catalog does not name is shown as the provider wrote it when it is already
  /// formatted, title-cased when it is a slug, and not at all when it is blank.
  @Test
  func anUnknownPlanIsKeptOrTitleCasedAndABlankOneIsNoPlan() {
    #expect(PlanDisplay.displayName("Custom Plan") == "Custom Plan")
    #expect(PlanDisplay.displayName("foo_bar") == "Foo Bar")
    #expect(PlanDisplay.displayName("  ") == nil)
    #expect(PlanDisplay.displayName(nil) == nil)
  }
}
