import Foundation

/// Remaining-quota tone: healthy ≥40, warning ≥15, otherwise critical.
public enum QuotaTone: Sendable, Equatable {
  case healthy
  case warning
  case critical

  /// Remaining percent at or above this is healthy.
  public static let healthyPercent: Double = 40

  /// Remaining percent at or above this (and below ``healthyPercent``) is warning.
  public static let warningPercent: Double = 15

  /// Clamp `percent` to 0…100, then classify against the shared bands.
  public static func remaining(percent: Double) -> QuotaTone {
    let remaining = min(max(percent, 0), 100)
    if remaining >= healthyPercent { return .healthy }
    if remaining >= warningPercent { return .warning }
    return .critical
  }
}
