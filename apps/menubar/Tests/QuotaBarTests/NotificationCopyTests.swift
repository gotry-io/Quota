import Foundation
import Testing

@testable import QuotaBar

struct NotificationCopyTests {
  private let now = Date(timeIntervalSince1970: 1_773_576_000)
  private let utc = TimeZone(secondsFromGMT: 0)!

  @Test func titleJoinsProviderDisplayNameAndWindowTitle() {
    #expect(NotificationCopy.title(providerDisplayName: "Codex", windowTitle: "Weekly")
      == "Codex · Weekly")
  }

  @Test func thresholdBodyUsesIntegerPercentAndLowercaseResetCountdown() {
    let resetsAt = now.addingTimeInterval(42 * 60)
    #expect(
      NotificationCopy.thresholdBody(
        remainingPercent: 12,
        resetsAt: resetsAt,
        now: now,
        timeZone: utc
      ) == "12% left · resets in 42m"
    )
  }

  @Test func thresholdBodyOmitsResetWhenTheInstantHasPassedOrIsMissing() {
    #expect(
      NotificationCopy.thresholdBody(
        remainingPercent: 12,
        resetsAt: nil,
        now: now,
        timeZone: utc
      ) == "12% left"
    )
    #expect(
      NotificationCopy.thresholdBody(
        remainingPercent: 12,
        resetsAt: now.addingTimeInterval(-1),
        now: now,
        timeZone: utc
      ) == "12% left"
    )
  }

  @Test func resetBodyIsTheWindowTitlePlusQuotaReset() {
    #expect(NotificationCopy.resetBody(windowTitle: "Weekly") == "Weekly quota reset")
  }
}
