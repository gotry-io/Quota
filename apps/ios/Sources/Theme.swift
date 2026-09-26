import QuotaPresentation
import SwiftUI

enum QuotaTheme {
  static let emerald = Color(
    uiColor: UIColor { traits in
      let rgb = traits.userInterfaceStyle == .dark ? QuotaBrand.mint : QuotaBrand.emerald
      return uiColor(rgb)
    }
  )

  static let meterTrack = Color(uiColor: .tertiarySystemFill)

  /// Support text. System `secondaryLabel` is 3.3:1 on a light grouped background and 3.4:1
  /// on a light card; the Apple light override in `tokens.json` is 4.7:1 / 5.3:1 there. Dark
  /// keeps `secondaryLabel`, which already clears 4.5:1.
  static let secondary = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? .secondaryLabel
        : uiColor(DesignTokens.Color.textSecondary.light)
    }
  )

  /// Token-mix fills (docs/design.md colour roles): cached input is the brand colour, ≥ 3:1 on
  /// the card; fresh input is neutral, and is told apart by the legend beside it, not by contrast.
  static let cachedFill = color(DesignTokens.Color.chartCache)
  static let freshInputFill = color(DesignTokens.Color.chartInput)

  /// The one warning color: a window whose pace runs it out before its reset.
  static let warning = color(DesignTokens.Color.quotaWarning)

  /// Remaining-quota critical, budget-exhausted meter, and status-dot red.
  static let critical = color(DesignTokens.Color.quotaCritical)

  static func color(for tone: QuotaTone) -> Color {
    switch tone {
    case .healthy: emerald
    case .warning: warning
    case .critical: critical
    }
  }

  static let minimumTouchTarget: CGFloat = 44
  /// Official status-page incident mark beside a provider name.
  static let statusDotSize: CGFloat = 8
  static let activityCellSize: CGFloat = 14
  static let activityCellGap: CGFloat = 4
  static let activityCellCorner: CGFloat = 3
  static let activityWeekdayWidth: CGFloat = 28
  /// Trailing space so a one-week last month still shows its full 3-letter abbreviation.
  static let activityMonthLabelOverflow: CGFloat = 28
  /// Active / inactive device-capsule wash. 0.18 emerald on a light card left Active text
  /// at 4.43:1; 0.16 keeps the wash and clears 4.5:1.
  static let capsuleFillOpacity: CGFloat = 0.16

  /// Five-step Activity fill, matching the website's emerald ramp. Non-text contrast is the
  /// cell outline, not each fill step (WCAG 1.4.11: the graphical object is distinguishable).
  static func activityFill(_ level: Int) -> Color {
    color(activityFills[min(max(level, 0), 4)])
  }

  /// Outline for heatmap cells. Level 0 is the quiet separator. Levels 1–4 are ≥ 3:1 on the
  /// card: the Apple activity-border override in `tokens.json`.
  static func activityBorder(_ level: Int) -> Color {
    Color(
      uiColor: UIColor { traits in
        guard level >= 1, level <= 4 else { return .separator }
        let pair = activityBorders[level - 1]
        return uiColor(traits.userInterfaceStyle == .dark ? pair.dark : pair.light)
      })
  }

  private static let activityFills = [
    DesignTokens.Color.activity0Fill,
    DesignTokens.Color.activity1Fill,
    DesignTokens.Color.activity2Fill,
    DesignTokens.Color.activity3Fill,
    DesignTokens.Color.activity4Fill,
  ]

  private static let activityBorders = [
    DesignTokens.Color.activity1Border,
    DesignTokens.Color.activity2Border,
    DesignTokens.Color.activity3Border,
    DesignTokens.Color.activity4Border,
  ]

  private static func color(_ pair: DesignTokens.AdaptiveRGB) -> Color {
    Color(
      uiColor: UIColor { traits in
        uiColor(traits.userInterfaceStyle == .dark ? pair.dark : pair.light)
      }
    )
  }

  private static func uiColor(_ rgb: DesignTokens.RGB) -> UIColor {
    UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
  }

  private static func uiColor(_ rgb: QuotaBrand.RGB) -> UIColor {
    UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
  }
}
