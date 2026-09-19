import Foundation
import QuotaPresentation
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

  @Test
  func accessoryFamiliesSpeakThePaceHeadline() {
    let resetsAt = now.addingTimeInterval(2 * 3_600)
    let item = WidgetQuotaItem(
      selectionID: "0123456789ab",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 20,
      hasLimit: true,
      resetsAt: resetsAt,
      pace: .runsOut(
        QuotaPaceProjection(tempo: .ahead, deltaPercent: 70, projectedAtReset: 170),
        exhaustsAt: now
      )
    )
    let spoken = lockScreenAccessibility(item: item, now: now)
    #expect(spoken.contains("May run out about 2h before reset"))
    #expect(!spoken.contains("Ahead"))
    #expect(!spoken.contains("runs out"))
  }
}
