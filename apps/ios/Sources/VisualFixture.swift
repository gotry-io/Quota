import Foundation

/// Launch-argument visual fixtures for deterministic simulator screenshots.
/// Parser is always available for unit tests; UI state application is DEBUG-only.
enum VisualFixture: String, CaseIterable, Sendable {
  case signedOut = "signed-out"
  case connecting
  case connectError = "connect-error"
  case expired
  case confirmAccount = "confirm-account"
  case connectRefreshFailed = "connect-refresh-failed"
  case loading
  case content
  case cachedError = "cached-error"
  case empty
  case noDevices = "no-devices"
  case localOnly = "local-only"
  case merged
  case providers
  case activityLoading = "activity-loading"
  case activityFailed = "activity-failed"
  case activityDayEmpty = "activity-day-empty"
  case activityDayFailed = "activity-day-failed"
  case signIn = "sign-in"
  case signInMethods = "sign-in-methods"

  /// Parse `--visual-fixture <name>` from process arguments. Returns nil when absent or unknown.
  static func parse(arguments: [String]) -> VisualFixture? {
    guard let index = arguments.firstIndex(of: "--visual-fixture") else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else { return nil }
    return VisualFixture(rawValue: arguments[valueIndex])
  }
}

#if DEBUG
  extension VisualFixture {
    /// Fixed reference instant for deterministic tests and fixture launches (2026-08-14T16:00:00Z).
    /// `--visual-clock wall` at launch uses the process wall clock instead.
    static let referenceDate = Date(timeIntervalSince1970: 1_786_723_200)
  }
#endif
