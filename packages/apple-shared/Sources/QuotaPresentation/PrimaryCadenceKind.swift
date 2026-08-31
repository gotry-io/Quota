import Foundation

/// Which recurring allowance a headline meter covers, shortest first. Declaration order is the
/// order a stacked item reads: the shorter cadence sits on top.
public enum PrimaryCadenceKind: String, Sendable, CaseIterable, Comparable {
  case fiveHour = "five_hour"
  case weekly
  case monthly

  /// The one-letter form, for a surface that shows cadences stacked against each other. A tag is
  /// read next to its neighbour, so the cadences only have to differ from each other — what that
  /// buys a particular surface is that surface's own business.
  public var compactTag: String {
    switch self {
    case .fiveHour: "H"
    case .weekly: "W"
    case .monthly: "M"
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    guard
      let left = allCases.firstIndex(of: lhs),
      let right = allCases.firstIndex(of: rhs)
    else {
      return false
    }
    return left < right
  }
}
