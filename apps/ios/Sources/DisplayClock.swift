import SwiftUI

/// The instant views and owners treat as "now" for ages, ranges, and countdowns.
///
/// Production uses the wall clock. Visual fixtures inject one fixed instant so relative copy and
/// period bounds stay aligned with the synthetic data. Tests can advance a clock without waiting
/// on real time.
struct DisplayClock: Sendable {
  var now: @Sendable () -> Date
  /// True when `now` is a frozen instant rather than the wall clock.
  var isFixed: Bool

  /// Process wall clock. Marketing captures that should look "current" use this.
  static let wall = DisplayClock(now: { Date() }, isFixed: false)

  /// A frozen instant. Fixture launches and deterministic tests use this.
  static func fixed(_ date: Date) -> DisplayClock {
    DisplayClock(now: { date }, isFixed: true)
  }
}

private struct DisplayClockKey: EnvironmentKey {
  static let defaultValue = DisplayClock.wall
}

extension EnvironmentValues {
  var displayClock: DisplayClock {
    get { self[DisplayClockKey.self] }
    set { self[DisplayClockKey.self] = newValue }
  }
}
