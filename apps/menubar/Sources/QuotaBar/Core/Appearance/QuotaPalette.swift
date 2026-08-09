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
  /// Shared control/surface border — one opacity, no per-call drift.
  static let hairlineBorder = Color(nsColor: .separatorColor).opacity(0.8)
  static let soft = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
  /// A quiet neutral wash over the native panel material limits vivid wallpaper bleed-through.
  static let panelWash = Color(nsColor: adaptivePanelWash)
  /// Group surface: related rows and read-only modules.
  static let settingsGroupFill = Color(nsColor: adaptiveSettingsGroupFill)
  /// Light material wash for transient menus; z-order, not opacity, covers page content.
  static let floatingMenuFill = Color(nsColor: adaptiveFloatingMenuFill)
  /// Adaptive ambient shadow used only by transient menus.
  static let floatingMenuShadow = Color(nsColor: adaptiveFloatingMenuShadow)
  /// Neutral interaction feedback for destination rows and header controls.
  static let rowHoverFill = Color(nsColor: adaptiveRowHoverFill)
  /// Accent is reserved for the active/pressed interaction state.
  static let rowPressedFill = Color(nsColor: adaptiveRowPressedFill)
  /// Editable/selectable control surface, one level above groups.
  static let fieldFill = Color(nsColor: adaptiveFieldFill)
  /// Focus is an accent tint layered over `fieldFill`, never a hard outline.
  static let fieldFillFocused = Color(nsColor: adaptiveFieldFocusTint)
  static let progressTrack = Color(nsColor: adaptiveProgressTrack)

  // MARK: Brand

  /// Primary Quota green used on light surfaces and in the full-color mark.
  static let brandEmerald = Color(nsColor: brandEmeraldNSColor)
  /// Lighter capacity-boundary green used on dark surfaces and in the full-color mark.
  static let brandMint = Color(nsColor: brandMintNSColor)

  // MARK: Semantic (accent / warning / critical)

  /// Adaptive product accent: Emerald in light appearance, Soft Mint in dark appearance.
  static let accent = Color(nsColor: adaptiveAccent)
  /// Black or white, selected from the resolved accent to retain at least AA text contrast.
  static let onAccent = Color(nsColor: adaptiveOnAccent)
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
    dynamicProvider: { appearance in
      resolvedAccent(for: appearance)
    }
  )

  private static let adaptiveOnAccent = NSColor(
    name: nil,
    dynamicProvider: { appearance in
      accessibleTextColor(for: resolvedAccent(for: appearance))
    }
  )

  private static let adaptiveSettingsGroupFill = adaptiveColor(
    light: NSColor.white.withAlphaComponent(0.16),
    dark: NSColor.white.withAlphaComponent(0.045)
  )

  private static let adaptiveFloatingMenuFill = adaptiveColor(
    light: NSColor.white.withAlphaComponent(0.32),
    dark: NSColor.white.withAlphaComponent(0.09)
  )

  private static let adaptiveFloatingMenuShadow = adaptiveColor(
    light: NSColor.black.withAlphaComponent(0.13),
    dark: NSColor.black.withAlphaComponent(0.30)
  )

  private static let adaptiveRowHoverFill = adaptiveColor(
    light: NSColor.black.withAlphaComponent(0.03),
    dark: NSColor.white.withAlphaComponent(0.06)
  )

  private static let adaptivePanelWash = NSColor(
    name: nil,
    dynamicProvider: { appearance in
      resolvedColor(.windowBackgroundColor, for: appearance)
        .withAlphaComponent(isDark(appearance) ? 0.14 : 0.20)
    }
  )

  private static let adaptiveRowPressedFill = NSColor(
    name: nil,
    dynamicProvider: { appearance in
      resolvedAccent(for: appearance).withAlphaComponent(isDark(appearance) ? 0.16 : 0.11)
    }
  )

  private static let adaptiveFieldFill = adaptiveColor(
    light: NSColor.white.withAlphaComponent(0.44),
    dark: NSColor.white.withAlphaComponent(0.12)
  )

  private static let adaptiveFieldFocusTint = NSColor(
    name: nil,
    dynamicProvider: { appearance in
      resolvedAccent(for: appearance).withAlphaComponent(isDark(appearance) ? 0.16 : 0.11)
    }
  )

  private static let adaptiveProgressTrack = adaptiveColor(
    light: NSColor.black.withAlphaComponent(0.10),
    dark: NSColor.white.withAlphaComponent(0.12)
  )

  static func resolvedAccent(for appearance: NSAppearance) -> NSColor {
    isDark(appearance) ? brandMintNSColor : brandEmeraldNSColor
  }

  private static func adaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(
      name: nil,
      dynamicProvider: { appearance in
        isDark(appearance) ? dark : light
      }
    )
  }

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  private static let brandEmeraldNSColor = NSColor(
    srgbRed: 0.031_372_549,
    green: 0.454_901_961,
    blue: 0.337_254_902,
    alpha: 1
  )

  private static let brandMintNSColor = NSColor(
    srgbRed: 0.509_803_922,
    green: 0.866_666_667,
    blue: 0.721_568_627,
    alpha: 1
  )

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
