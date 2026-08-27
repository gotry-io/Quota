import Foundation
import Testing

@testable import QuotaPresentation

struct DeviceActivityTests {
  private let now = Date(timeIntervalSince1970: 1_786_300_000)

  @Test
  func theVerdictComesFromTheNewerOfTheTwoWitnessedInstants() {
    // A device that has not called in a day can still have sent a reading minutes ago.
    let reported = DeviceActivity.make(
      lastSeenAt: now.addingTimeInterval(-86_400),
      lastObservedAt: now.addingTimeInterval(-120),
      now: now
    )
    #expect(reported.status == .active)
    #expect(reported.since == now.addingTimeInterval(-120))
  }

  @Test
  func underHalfAnHourIsActiveUpToADayIsIdleAndBeyondIsNotReporting() {
    func status(secondsAgo: TimeInterval) -> DeviceActivity.Status {
      DeviceActivity.make(
        lastSeenAt: now.addingTimeInterval(-secondsAgo), lastObservedAt: nil, now: now
      ).status
    }

    #expect(status(secondsAgo: 300) == .active)
    #expect(status(secondsAgo: 30 * 60 - 1) == .active)
    #expect(status(secondsAgo: 30 * 60) == .idle)
    #expect(status(secondsAgo: 3 * 3_600) == .idle)
    #expect(status(secondsAgo: 24 * 3_600) == .notReporting)
    #expect(status(secondsAgo: 3 * 86_400) == .notReporting)
  }

  /// A device nobody has ever heard from is not reporting, and there is no age to blame it on.
  @Test
  func aDeviceNeverHeardFromHasNoAgeToShow() {
    let unheard = DeviceActivity.make(lastSeenAt: nil, lastObservedAt: nil, now: now)
    #expect(unheard.status == .notReporting)
    #expect(unheard.since == nil)
    #expect(unheard.label == "Not reporting")
  }

  /// The words are the shared vocabulary's, and a surface reads them rather than spelling them.
  @Test
  func theLabelIsTheSharedWordForTheVerdict() {
    #expect(DeviceActivity.Status.active.rawValue == "Active")
    #expect(DeviceActivity.Status.idle.rawValue == "Idle")
    #expect(DeviceActivity.Status.notReporting.rawValue == "Not reporting")
  }
}
