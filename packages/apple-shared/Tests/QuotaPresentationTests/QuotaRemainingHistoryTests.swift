import Foundation
import QuotaPresentation
import Testing

struct QuotaRemainingHistoryTests {
  private let now = Date(timeIntervalSince1970: 1_788_100_000)
  private let cadence = 18_000

  @Test func aResetStartsANewSegmentInsteadOfDrawingALineUp() throws {
    let previousReset = now.addingTimeInterval(-3_600)
    let currentReset = previousReset.addingTimeInterval(Double(cadence))
    let previousStart = previousReset.addingTimeInterval(Double(-cadence))
    let history = try #require(
      QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(resetsAt: currentReset, cadenceSeconds: cadence),
        samples: [
          QuotaSample(
            resetsAt: previousReset,
            observedAt: previousStart.addingTimeInterval(3_600),
            usedPercent: 20
          ),
          QuotaSample(
            resetsAt: previousReset,
            observedAt: previousReset.addingTimeInterval(-60),
            usedPercent: 82
          ),
          QuotaSample(
            resetsAt: currentReset,
            observedAt: previousReset.addingTimeInterval(600),
            usedPercent: 10
          ),
          QuotaSample(
            resetsAt: currentReset,
            observedAt: now,
            usedPercent: 40
          ),
        ],
        usedPercent: 40,
        now: now
      )
    )
    #expect(history.segments.count == 2)
    #expect(history.segments[0].resetsAt == previousReset)
    #expect(history.segments[1].resetsAt == currentReset)
    let previousLast = try #require(history.segments[0].points.last)
    let currentFirst = try #require(history.segments[1].points.first)
    #expect(previousLast.remainingPercent == 18)
    #expect(currentFirst.remainingPercent == 90)
    #expect(currentFirst.remainingPercent > previousLast.remainingPercent)
  }

  @Test func aMissingWindowStaysAGap() throws {
    let firstReset = now.addingTimeInterval(-Double(cadence))
    let thirdReset = firstReset.addingTimeInterval(Double(cadence * 2))
    let history = try #require(
      QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(resetsAt: thirdReset, cadenceSeconds: cadence),
        samples: [
          QuotaSample(
            resetsAt: firstReset,
            observedAt: firstReset.addingTimeInterval(-3_600),
            usedPercent: 50
          ),
          QuotaSample(
            resetsAt: thirdReset,
            observedAt: now,
            usedPercent: 30
          ),
        ],
        usedPercent: 30,
        now: now
      )
    )
    #expect(history.segments.count == 2)
    #expect(QuotaRemainingHistory.hasGap(history, cadenceSeconds: cadence))
    #expect(
      history.segments[1].resetsAt.timeIntervalSince(history.segments[0].resetsAt)
        == Double(cadence * 2)
    )
  }

  @Test func estimateEndpointEqualsThePaceProjection() throws {
    let resetsAt = now.addingTimeInterval(3_600)
    let start = resetsAt.addingTimeInterval(Double(-cadence))
    let lastObserved = start.addingTimeInterval(12_600)
    let used = 58.0
    let history = try #require(
      QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(resetsAt: resetsAt, cadenceSeconds: cadence),
        samples: [
          QuotaSample(
            resetsAt: resetsAt, observedAt: start.addingTimeInterval(3_600), usedPercent: 20),
          QuotaSample(resetsAt: resetsAt, observedAt: lastObserved, usedPercent: used),
        ],
        usedPercent: used,
        now: lastObserved
      )
    )
    let pace = QuotaPace.evaluate(
      QuotaPaceReading(
        usedPercent: used,
        resetsAt: resetsAt,
        cadenceSeconds: cadence,
        isBalanceOnly: false
      ),
      now: lastObserved
    )
    let projected = try #require(pace.projection?.projectedAtReset)
    let estimate = try #require(history.estimate)
    #expect(estimate.isEstimate)
    #expect(estimate.date == resetsAt)
    #expect(
      estimate.remainingPercent
        == RemainingQuotaFormat.remainingPercent(usedPercent: round2(projected))
    )
  }

  @Test func estimateAgreesWithTheHistoryFoldProjection() throws {
    let resetsAt = now.addingTimeInterval(2_700)
    let start = resetsAt.addingTimeInterval(Double(-cadence))
    let lastObserved = start.addingTimeInterval(12_540)
    let samples = [
      QuotaSample(resetsAt: resetsAt, observedAt: start.addingTimeInterval(3_600), usedPercent: 20),
      QuotaSample(resetsAt: resetsAt, observedAt: start.addingTimeInterval(7_200), usedPercent: 38),
      QuotaSample(resetsAt: resetsAt, observedAt: lastObserved, usedPercent: 58),
    ]
    let remaining = try #require(
      QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(resetsAt: resetsAt, cadenceSeconds: cadence),
        samples: samples,
        usedPercent: 58,
        now: lastObserved
      )
    )
    let used = try #require(
      QuotaHistory.fold(
        window: QuotaHistoryReading(resetsAt: resetsAt, cadenceSeconds: cadence),
        samples: samples,
        now: lastObserved,
        utcOffsetSeconds: 0
      )
    )
    let estimate = try #require(remaining.estimate)
    let projection = try #require(used.projection)
    #expect(
      estimate.remainingPercent
        == RemainingQuotaFormat.remainingPercent(usedPercent: projection.usedPercent)
    )
    #expect(remaining.segments.count == 1)
    #expect(remaining.segments[0].points.count == used.points.count)
    for (observed, point) in zip(remaining.segments[0].points, used.points) {
      #expect(
        observed.remainingPercent
          == RemainingQuotaFormat.remainingPercent(usedPercent: point.usedPercent)
      )
    }
  }

  @Test func emptySamplesFoldToNil() {
    #expect(
      QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(
          resetsAt: now.addingTimeInterval(3_600), cadenceSeconds: cadence),
        samples: [],
        usedPercent: 40,
        now: now
      ) == nil
    )
  }

  @Test func noCadenceFoldsToNil() {
    #expect(
      QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(resetsAt: now.addingTimeInterval(3_600), cadenceSeconds: nil),
        samples: [
          QuotaSample(resetsAt: now.addingTimeInterval(3_600), observedAt: now, usedPercent: 40)
        ],
        usedPercent: 40,
        now: now
      ) == nil
    )
  }

  @Test func consecutiveWindowsAreNotAGap() throws {
    let previousReset = now
    let currentReset = previousReset.addingTimeInterval(Double(cadence))
    let history = try #require(
      QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(resetsAt: currentReset, cadenceSeconds: cadence),
        samples: [
          QuotaSample(
            resetsAt: previousReset, observedAt: previousReset.addingTimeInterval(-60),
            usedPercent: 80),
          QuotaSample(
            resetsAt: currentReset, observedAt: previousReset.addingTimeInterval(60),
            usedPercent: 12),
        ],
        usedPercent: 12,
        now: previousReset.addingTimeInterval(60)
      )
    )
    #expect(history.segments.count == 2)
    #expect(!QuotaRemainingHistory.hasGap(history, cadenceSeconds: cadence))
  }

  private func round2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
  }
}
