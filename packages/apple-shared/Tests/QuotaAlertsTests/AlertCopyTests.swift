import Foundation
import QuotaAlerts
import Testing

struct AlertCopyTests {
  private let now = Date(timeIntervalSince1970: 1_773_576_000)
  private let utc = TimeZone(secondsFromGMT: 0)!

  @Test func titleJoinsProviderDisplayNameAndWindowTitle() {
    #expect(AlertCopy.title(providerDisplayName: "Codex", windowTitle: "Weekly") == "Codex · Weekly")
  }

  @Test func thresholdBodyUsesIntegerPercentAndLowercaseResetCountdown() {
    let resetsAt = now.addingTimeInterval(42 * 60)
    #expect(
      AlertCopy.thresholdBody(
        remainingPercent: 12,
        resetsAt: resetsAt,
        now: now,
        timeZone: utc
      ) == "12% left · resets in 42m"
    )
  }

  @Test func thresholdBodyOmitsResetWhenTheInstantHasPassedOrIsMissing() {
    #expect(
      AlertCopy.thresholdBody(
        remainingPercent: 12,
        resetsAt: nil,
        now: now,
        timeZone: utc
      ) == "12% left"
    )
    #expect(
      AlertCopy.thresholdBody(
        remainingPercent: 12,
        resetsAt: now.addingTimeInterval(-1),
        now: now,
        timeZone: utc
      ) == "12% left"
    )
  }

  @Test func resetBodyIsTheWindowTitlePlusQuotaReset() {
    #expect(AlertCopy.resetBody(windowTitle: "Weekly") == "Weekly quota reset")
  }
}
