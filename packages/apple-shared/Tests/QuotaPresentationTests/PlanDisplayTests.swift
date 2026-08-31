import QuotaPresentation
import Testing

struct PlanDisplayTests {
  @Test
  func mapsKnownPlanSlugs() {
    #expect(PlanDisplay.displayName("plus") == "Plus")
    #expect(PlanDisplay.displayName("PRO") == "Pro")
    #expect(PlanDisplay.displayName("prolite") == "Pro Lite")
    #expect(PlanDisplay.displayName("pro_lite") == "Pro Lite")
    #expect(PlanDisplay.displayName("max") == "Max")
    #expect(PlanDisplay.displayName("max_5x") == "Max 5x")
    #expect(PlanDisplay.displayName("max_20x") == "Max 20x")
    #expect(PlanDisplay.displayName("team") == "Team")
    #expect(PlanDisplay.displayName("supergrok") == "SuperGrok")
    #expect(PlanDisplay.displayName("super_grok") == "SuperGrok")
    #expect(PlanDisplay.displayName("SuperGrok") == "SuperGrok")
    #expect(PlanDisplay.displayName("edu") == "Edu")
    #expect(PlanDisplay.displayName("education") == "Education")
  }

  @Test
  func preservesAlreadyFormattedNames() {
    #expect(PlanDisplay.displayName("Plus") == "Plus")
    #expect(PlanDisplay.displayName("Max") == "Max")
    #expect(PlanDisplay.displayName("Custom Plan") == "Custom Plan")
  }

  @Test
  func titleCasesUnknownSlugsAndDropsEmptyValues() {
    #expect(PlanDisplay.displayName("foo_bar") == "Foo Bar")
    #expect(PlanDisplay.displayName("  ") == nil)
    #expect(PlanDisplay.displayName(nil) == nil)
  }

  @Test
  func separatesPlanBadgeFromAccountLabel() {
    #expect(PlanDisplay.planBadge("prolite") == "Pro Lite")
    #expect(PlanDisplay.planBadge(nil) == nil)
    #expect(PlanDisplay.accountLabel("eg***@dhao.me") == "eg***@dhao.me")
    #expect(PlanDisplay.accountLabel("  ") == nil)
    #expect(PlanDisplay.accountLabel(nil) == nil)
  }
}
