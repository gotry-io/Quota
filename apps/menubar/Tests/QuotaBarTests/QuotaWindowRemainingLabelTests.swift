import QuotaWire
import Testing

@testable import QuotaBar

struct QuotaWindowRemainingLabelTests {
  @Test
  func cursorOtherModelsKeepsIncludedMoneyOutOfOverview() {
    let window = QuotaWindow(
      id: "other_models",
      title: "Other Models",
      usedPercent: 63.102,
      remainingValue: 14.55,
      limitValue: 400,
      valueUnit: .usd
    )
    #expect(window.remainingValue == 14.55)
    #expect(window.limitValue == 400)
    #expect(window.remainingDisplayLabel == "36.9% · $14.55")
    #expect(window.overviewRemainingDisplayLabel(provider: .cursor) == "36.9%")
    #expect(window.overviewRemainingDisplayLabel(provider: .openrouter) == "36.9% · $14.55")
  }
}
