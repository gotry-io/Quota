import AppKit
import SwiftUI

/// Palette for QuotaBar on native menubar material.
/// Structural chrome (hairlines, tracks, soft fills) uses system adaptive colors so it
/// sits cleanly on the host menu-bar panel background. Brand marks and usage tones stay product-owned.
enum QuotaPalette {
  // MARK: Core text (system adaptive for material harmony)

  static let ink = Color(nsColor: .labelColor)
  static let inkDeep = Color(nsColor: .labelColor)
  static let charcoal = Color(nsColor: .secondaryLabelColor)
  static let body = Color(nsColor: .secondaryLabelColor)
  static let mute = Color(nsColor: .tertiaryLabelColor)

  static let onPrimary = Color(nsColor: .alternateSelectedControlTextColor)
  static let primary = Color(nsColor: .labelColor)

  // MARK: Structural chrome on material

  /// Separators / tag strokes — system separator, not a fixed paper gray.
  static let hairline = Color(nsColor: .separatorColor)
  static let hairlineStrong = Color(nsColor: .separatorColor)

  /// Soft control fill that stays translucent on material.
  static let soft = Color(nsColor: .quaternaryLabelColor).opacity(0.35)

  /// Progress track under usage fill — light veil, not a solid slab.
  static let progressTrack = Color.primary.opacity(0.08)

  static let focusRing = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255).opacity(0.5)

  // MARK: Usage tones (Quota-specific)
  // One step darker/muted than pure Tailwind-600 so meters sit on default
  // MenuBarExtra chrome without glowing.

  static let usageHealthy = Color(red: 21 / 255, green: 128 / 255, blue: 61 / 255)
  static let usageWarning = Color(red: 180 / 255, green: 83 / 255, blue: 9 / 255)
  static let usageCritical = Color(red: 185 / 255, green: 28 / 255, blue: 28 / 255)

  // MARK: Provider brand tints (marks only)

  static let brandClaude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
  /// Lobe Icons `codex-color` brand stop (mid gradient #7A9DFF → #3941FF family).
  static let brandCodex = Color(red: 122 / 255, green: 157 / 255, blue: 255 / 255)
  static let brandGrokLight = Color(red: 38 / 255, green: 38 / 255, blue: 42 / 255)
  static let brandGrokDark = Color(red: 228 / 255, green: 228 / 255, blue: 231 / 255)

  static func brandColor(for provider: ProviderID, colorScheme: ColorScheme) -> Color {
    switch provider {
    case .claude:
      return brandClaude
    case .codex:
      return brandCodex
    case .grok:
      return colorScheme == .dark ? brandGrokDark : brandGrokLight
    }
  }

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
    if remaining >= 40 {
      return .healthy
    }
    if remaining >= 15 {
      return .warning
    }
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
