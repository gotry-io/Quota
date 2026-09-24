import Foundation
import QuotaPresentation
import Testing

private struct Observation: QuotaObservationFreshness {
  var reportedState = QuotaObservationState.available
  var validUntil: Date?
}

struct QuotaObservationFreshnessTests {
  private let now = Date(timeIntervalSince1970: 1_786_000_000)

  @Test
  func aReadingAgesOutAtTheInstantItsSourceStamped() {
    #expect(Observation(validUntil: now.addingTimeInterval(1)).observedState(now: now) == .available)
    #expect(Observation(validUntil: now).observedState(now: now) == .stale)
    // Nothing ages out a reading whose source never stamped one.
    #expect(!Observation(validUntil: nil).isStale(now: now))
  }

  @Test
  func aReportedFailureStandsBeforeTheReadingHasAgedOut() {
    let observation = Observation(
      reportedState: .signInNeeded,
      validUntil: now.addingTimeInterval(3_600)
    )
    #expect(observation.observedState(now: now) == .signInNeeded)
    #expect(observation.stateLabel(now: now) == "Sign-in needed")
    #expect(observation.isStale(now: now))
  }
}
