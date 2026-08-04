import AppKit
import SwiftUI

/// Palette for QuotaBar on native menu-bar chrome.
/// Prefer system adaptive colors so marks and meters stay quiet on the host background.
enum QuotaPalette {
  // MARK: Core text (system adaptive)

  static let ink = Color(nsColor: .labelColor)
  static let body = Color(nsColor: .secondaryLabelColor)
  static let mute = Color(nsColor: .tertiaryLabelColor)
  static let onPrimary = Color(nsColor: .alternateSelectedControlTextColor)

  // MARK: Structural chrome

  static let hairline = Color(nsColor: .separatorColor)
  /// Shared card/tag/field border — one opacity, no per-call drift.
  static let hairlineBorder = Color(nsColor: .separatorColor).opacity(0.8)
  static let soft = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
  static let progressTrack = Color.primary.opacity(0.08)

  // MARK: Usage meters (monochrome, remaining-based)

  static let usageHealthy = Color.primary.opacity(0.28)
  static let usageWarning = Color.primary.opacity(0.48)
  static let usageCritical = Color.primary.opacity(0.78)

  static func usageColor(remainingPercent: Double) -> Color {
    QuotaUsageTone.tone(remainingPercent: remainingPercent).color
  }
}

enum QuotaUsageTone: Equatable, Sendable {
  case healthy
  case warning
  case critical

  static func tone(remainingPercent: Double) -> QuotaUsageTone {
    let remaining = min(max(remainingPercent, 0), 100)
    if remaining >= 40 { return .healthy }
    if remaining >= 15 { return .warning }
    return .critical
  }

  var color: Color {
    switch self {
    case .healthy: QuotaPalette.usageHealthy
    case .warning: QuotaPalette.usageWarning
    case .critical: QuotaPalette.usageCritical
    }
  }
}
