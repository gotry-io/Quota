import Foundation
import QuotaPresentation
import Testing

private struct Observation: QuotaObservationFreshness {
  var isAvailable = true
  var validUntil: Date?
}

struct QuotaObservationFreshnessTests {
  private let now = Date(timeIntervalSince1970: 1_786_000_000)

  @Test
  func validityInstantExpiresAnObservationTheSourceStillCallsAvailable() {
    #expect(!Observation(validUntil: now.addingTimeInterval(1)).isStale(now: now))
    #expect(Observation(validUntil: now).isStale(now: now))
    #expect(Observation(validUntil: now.addingTimeInterval(-1)).isStale(now: now))
  }

  @Test
  func anyStatusOtherThanAvailableStandsAndAnUnstampedReadingIsNotAgedOutHere() {
    #expect(
      Observation(isAvailable: false, validUntil: now.addingTimeInterval(3_600)).isStale(now: now)
    )
    #expect(!Observation(validUntil: nil).isStale(now: now))
  }
}
