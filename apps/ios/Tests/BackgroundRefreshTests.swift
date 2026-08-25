import Foundation
import Testing

@testable import Quota

struct BackgroundRefreshTests {
  /// The system launches the app for an identifier it finds in the bundle, so the constant the
  /// code registers and submits under has to be the one the app ships.
  @Test
  func permittedIdentifiersDeclareTheScheduledTask() {
    let permitted =
      Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
    #expect(permitted == [BackgroundRefresh.taskIdentifier])
  }

  /// `BGAppRefreshTask` only runs for an app that declares the fetch background mode.
  @Test
  func backgroundModesDeclareFetch() {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
    #expect(modes?.contains("fetch") == true)
  }

  @Test
  func earliestBeginIsNotSoonerThanHalfAnHour() {
    #expect(BackgroundRefresh.earliestInterval >= 30 * 60)
  }
}
