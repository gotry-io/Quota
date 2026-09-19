import Foundation
import QuotaWidgetData
import Testing

@testable import QuotaWidgetViews

struct LockScreenRemainingTests {
  private let now = Date(timeIntervalSince1970: 1_786_723_200)

  @Test
  func accessoryFamiliesSpeakRemainingNotUsed() {
    let item = WidgetQuotaItem(
      selectionID: "0123456789ab",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 71,
      remainingValue: 3.75,
      unit: .usd,
      hasLimit: true
    )
    #expect(OverviewWidgetContent.percentLabel(for: item) == "71%")
    #expect(OverviewWidgetContent.inlineLabel(for: item) == "Weekly 71%")
    let spoken = lockScreenAccessibility(item: item, now: now)
    #expect(spoken.contains("remaining"))
    #expect(!spoken.contains("used"))
    #expect(!spoken.contains("29%"))
  }
}
