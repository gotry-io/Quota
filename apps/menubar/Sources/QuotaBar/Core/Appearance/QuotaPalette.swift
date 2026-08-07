import AppKit
import SwiftUI

/// Palette for QuotaBar on native menu-bar chrome.
/// System adaptive neutrals for structure; three semantic colors for status and actions.
enum QuotaPalette {
  // MARK: Core text (system adaptive)

  static let ink = Color(nsColor: .labelColor)
  static let body = Color(nsColor: .secondaryLabelColor)
  static let mute = Color(nsColor: .tertiaryLabelColor)

  // MARK: Structural chrome

  static let hairline = Color(nsColor: .separatorColor)
  /// Shared card/tag/field border — one opacity, no per-call drift.
  static let hairlineBorder = Color(nsColor: .separatorColor).opacity(0.8)
  static let soft = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
  /// Settings grouped list fill — light translucent wash on material chrome.
  static let settingsGroupFill = Color.primary.opacity(0.055)
  /// Text fields: borderless recessed fill (just deeper than group chrome).
  static let fieldFill = Color.primary.opacity(0.06)
  /// Text fields when focused — a step deeper, still quiet on material.
  static let fieldFillFocused = Color.primary.opacity(0.09)
  static let progressTrack = Color.primary.opacity(0.08)

  // MARK: Semantic (accent / warning / critical)

  /// Product accent with indigo fallback when the control accent is not usable.
  static let accent = Color(nsColor: adaptiveAccent)
  /// Black or white, selected from the resolved accent to retain at least AA text contrast.
  static let onAccent = Color(nsColor: adaptiveOnAccent)
  /// Toggle ON track — accent wash (readable on material; not solid primary fill).
  static let toggleOnTrack = Color(nsColor: adaptiveAccent).opacity(0.55)
  /// Toggle thumb — always light; on/off is carried by the track wash.
  static let toggleThumb = Color(nsColor: .controlBackgroundColor)
  static let warning = Color(nsColor: .systemOrange)
  static let critical = Color(nsColor: .systemRed)

  // MARK: Usage meters (remaining-based)

  static func usageColor(remainingPercent: Double) -> Color {
    QuotaUsageTone.tone(remainingPercent: remainingPercent).meterColor
  }

  static func accessibleTextColor(for background: NSColor) -> NSColor {
    guard background.usingColorSpace(NSColorSpace.sRGB) != nil else { return .white }
    let whiteContrast = contrastRatio(foreground: .white, background: background)
    let blackContrast = contrastRatio(foreground: .black, background: background)
    return whiteContrast >= blackContrast ? .white : .black
  }

  static func contrastRatio(foreground: NSColor, background: NSColor) -> Double {
    let foregroundLuminance = relativeLuminance(foreground)
    let backgroundLuminance = relativeLuminance(background)
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  static func resolvedColor(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(NSColorSpace.sRGB)
    }
    return resolved ?? color
  }

  private static let adaptiveAccent = NSColor(
    name: nil,
    dynamicProvider: { appearance in resolvedAccent(for: appearance) }
  )

  private static let adaptiveOnAccent = NSColor(
    name: nil,
    dynamicProvider: { appearance in
      accessibleTextColor(for: resolvedAccent(for: appearance))
    }
  )

  private static func resolvedAccent(for appearance: NSAppearance) -> NSColor {
    let controlAccent = resolvedColor(.controlAccentColor, for: appearance)
    guard controlAccent.usingColorSpace(NSColorSpace.sRGB) != nil else {
      return resolvedColor(.systemIndigo, for: appearance)
    }
    return controlAccent
  }

  private static func relativeLuminance(_ color: NSColor) -> Double {
    guard let rgb = color.usingColorSpace(NSColorSpace.sRGB) else { return 0 }
    let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { component in
      let value = Double(component)
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
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

  /// Meter fill: accent when healthy, semantic colors for warning/critical.
  var meterColor: Color {
    switch self {
    case .healthy: QuotaPalette.accent
    case .warning: QuotaPalette.warning
    case .critical: QuotaPalette.critical
    }
  }

}
