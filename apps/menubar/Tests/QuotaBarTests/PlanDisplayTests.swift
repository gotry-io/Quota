import Testing

@testable import QuotaBar

struct PlanDisplayTests {
  @Test
  func mapsKnownPlanSlugs() {
    #expect(PlanDisplay.displayName("plus") == "Plus")
    #expect(PlanDisplay.displayName("PRO") == "Pro")
    #expect(PlanDisplay.displayName("prolite") == "Pro Lite")
    #expect(PlanDisplay.displayName("pro_lite") == "Pro Lite")
    #expect(PlanDisplay.displayName("max") == "Max")
    #expect(PlanDisplay.displayName("team") == "Team")
    #expect(PlanDisplay.displayName("supergrok") == "SuperGrok")
    #expect(PlanDisplay.displayName("super_grok") == "SuperGrok")
    #expect(PlanDisplay.displayName("SuperGrok") == "SuperGrok")
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
  }

  @Test
  func buildsPlainAccountSummary() {
    #expect(
      PlanDisplay.accountSummary(plan: "prolite", label: "eg***@dhao.me")
        == "Pro Lite · eg***@dhao.me"
    )
    #expect(
      PlanDisplay.accountSummary(plan: "supergrok", label: "pv***@gmail.com")
        == "SuperGrok · pv***@gmail.com"
    )
    #expect(PlanDisplay.accountSummary(plan: nil, label: "pv***@gmail.com") == "pv***@gmail.com")
    #expect(PlanDisplay.accountSummary(plan: "max", label: nil) == "Max")
    #expect(PlanDisplay.accountSummary(plan: "  ", label: "  ") == nil)
  }
}

struct QuotaUsageToneTests {
  @Test
  func classifiesRemainingPercentThresholds() {
    #expect(QuotaUsageTone.tone(remainingPercent: 100) == .healthy)
    #expect(QuotaUsageTone.tone(remainingPercent: 40) == .healthy)
    #expect(QuotaUsageTone.tone(remainingPercent: 39.9) == .warning)
    #expect(QuotaUsageTone.tone(remainingPercent: 15) == .warning)
    #expect(QuotaUsageTone.tone(remainingPercent: 14.9) == .critical)
    #expect(QuotaUsageTone.tone(remainingPercent: 0) == .critical)
  }
}
