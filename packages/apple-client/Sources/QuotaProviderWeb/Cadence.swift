import Foundation
import QuotaWire

/// The recurring allowance a window meters. The service names these once for the same reason:
/// the id a client trusts, the title a person reads, and the member on the wire cannot drift
/// apart if one value answers for all three.
enum Cadence: Int, Comparable, Sendable {
  case fiveHour
  case weekly
  case monthly

  var wire: String {
    switch self {
    case .fiveHour: "five_hour"
    case .weekly: "weekly"
    case .monthly: "monthly"
    }
  }

  var title: String {
    switch self {
    case .fiveHour: "5 Hours"
    case .weekly: "Weekly"
    case .monthly: "Monthly"
    }
  }

  var primaryCadence: PrimaryCadence {
    switch self {
    case .fiveHour: .fiveHour
    case .weekly: .weekly
    case .monthly: .monthly
    }
  }

  static func < (lhs: Cadence, rhs: Cadence) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension QuotaWindow {
  /// The one place this library turns a provider's numbers into a window, so the rounding and
  /// the clamp happen once.
  static func make(
    id: String,
    title: String,
    usedPercent: Double,
    resetsAt: Int? = nil,
    durationSeconds: Int? = nil,
    primaryCadence: PrimaryCadence? = nil
  ) -> QuotaWindow {
    QuotaWindow(
      id: id,
      title: title,
      usedPercent: ProviderJSON.clampPercent(usedPercent),
      resetsAt: resetsAt.map { Date(timeIntervalSince1970: Double($0)) },
      durationSeconds: durationSeconds,
      primaryCadence: primaryCadence
    )
  }
}
