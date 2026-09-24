import Foundation
import QuotaAlerts
import QuotaPresentation
import Testing

struct AlertCopyTests {
  private let now = Date(timeIntervalSince1970: 1_773_576_000)
  private let utc = TimeZone(secondsFromGMT: 0)!

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

  @Test func paceBodyUsesTheSharedHeadline() {
    let resetsAt = now.addingTimeInterval(2 * 3_600)
    let lasts = QuotaPace.lasts(
      QuotaPaceProjection(tempo: .onTrack, deltaPercent: 0, projectedAtReset: 100)
    )
    #expect(AlertCopy.paceBody(pace: lasts, resetsAt: resetsAt) == "Expected to last until reset")
    let runsOut = QuotaPace.runsOut(
      QuotaPaceProjection(tempo: .ahead, deltaPercent: 70, projectedAtReset: 170),
      exhaustsAt: now
    )
    #expect(
      AlertCopy.paceBody(pace: runsOut, resetsAt: resetsAt)
        == "May run out about 2h before reset"
    )
    #expect(AlertCopy.paceBody(pace: .none, resetsAt: resetsAt) == nil)
  }
}
