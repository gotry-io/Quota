import Foundation

/// How recently a device spoke, from the two things Relay actually witnessed: when the device
/// last called, and when the newest reading it sent was taken.
///
/// A device that is asleep or closed is quiet, not broken, so nothing here calls a device
/// unhealthy. A row states one verdict and the one age it came from, never a list of instants —
/// the rule is **Shared product vocabulary** in `apps/menubar/DESIGN.md`, and this is the one
/// place every Apple client answers it.
public struct DeviceActivity: Equatable, Sendable {
  public enum Status: String, Equatable, Sendable {
    case active = "Active"
    case idle = "Idle"
    case notReporting = "Not reporting"
  }

  public let status: Status
  /// The instant the verdict came from, or `nil` for a device never heard from at all.
  public let since: Date?

  public var label: String { status.rawValue }

  public init(status: Status, since: Date?) {
    self.status = status
    self.since = since
  }

  /// Under half an hour is Active, up to a day is Idle, and beyond that is Not reporting.
  public static func make(lastSeenAt: Date?, lastObservedAt: Date?, now: Date) -> Self {
    guard let newest = [lastSeenAt, lastObservedAt].compactMap({ $0 }).max() else {
      return Self(status: .notReporting, since: nil)
    }
    let age = now.timeIntervalSince(newest)
    if age < activeWithin { return Self(status: .active, since: newest) }
    if age < idleWithin { return Self(status: .idle, since: newest) }
    return Self(status: .notReporting, since: newest)
  }

  private static let activeWithin: TimeInterval = 30 * 60
  private static let idleWithin: TimeInterval = 24 * 60 * 60
}
