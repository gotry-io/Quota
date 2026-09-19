import QuotaPresentation
import SwiftUI

enum QuotaTheme {
  static let emerald = Color(
    uiColor: UIColor { traits in
      let rgb = traits.userInterfaceStyle == .dark ? QuotaBrand.mint : QuotaBrand.emerald
      return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
  )

  static let meterTrack = Color(uiColor: .tertiarySystemFill)

  /// Support text. System `secondaryLabel` is 3.3:1 on a light grouped background and 3.4:1
  /// on a light card; this opaque grey is 4.7:1 / 5.3:1 there. Dark keeps `secondaryLabel`,
  /// which already clears 4.5:1.
  static let secondary = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? .secondaryLabel
        : UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
    }
  )

  /// Cached-input chart fill. Translucent emerald on the card was 1.7:1 in light and 2.4:1
  /// in dark; these solids keep a lighter step than fresh emerald and stay ≥ 3:1 on the card.
  static let cachedFill = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.175, green: 0.578, blue: 0.453, alpha: 1)
        : UIColor(red: 0.225, green: 0.564, blue: 0.470, alpha: 1)
    }
  )

  /// The one warning color: a window whose pace runs it out before its reset.
  /// System orange is 2.9:1 on a light card; this darkens it to 4.6:1 there and keeps the
  /// system colour on dark grounds, where it already passes.
  static let warning = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? .systemOrange
        : UIColor(red: 0.72, green: 0.36, blue: 0.0, alpha: 1)
    }
  )

  /// Remaining-quota critical, budget-exhausted meter, and status-dot red.
  /// System red is ~3.5:1 as text on a light card; this darkens it to 5.3:1 there and keeps
  /// the system colour on dark grounds, where it already passes 4.5:1.
  static let critical = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? .systemRed
        : UIColor(red: 0.80, green: 0.18, blue: 0.15, alpha: 1)
    }
  )

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
    Color(
      uiColor: UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        switch level {
        case 1:
          return dark
            ? UIColor(red: 0.075, green: 0.302, blue: 0.227, alpha: 1)
            : UIColor(red: 0.776, green: 0.929, blue: 0.863, alpha: 1)
        case 2:
          return dark
            ? UIColor(red: 0.102, green: 0.478, blue: 0.345, alpha: 1)
            : UIColor(red: 0.510, green: 0.867, blue: 0.722, alpha: 1)
        case 3:
          return UIColor(red: 0.184, green: 0.639, blue: 0.478, alpha: 1)
        case 4:
          return dark
            ? UIColor(red: 0.510, green: 0.867, blue: 0.722, alpha: 1)
            : UIColor(red: 0.031, green: 0.455, blue: 0.337, alpha: 1)
        default:
          return dark
            ? UIColor(red: 0.165, green: 0.165, blue: 0.165, alpha: 1)
            : UIColor(red: 0.937, green: 0.937, blue: 0.937, alpha: 1)
        }
      })
  }

  /// Outline for heatmap cells. Level 0 is the quiet separator. Levels 1–4 are ≥ 3:1 on the
  /// card: light `#2FA37A`, dark a mint that clears the dark card.
  static func activityBorder(_ level: Int) -> Color {
    Color(
      uiColor: UIColor { traits in
        guard level >= 1, level <= 4 else { return .separator }
        return traits.userInterfaceStyle == .dark
          ? UIColor(red: 0.318, green: 0.702, blue: 0.568, alpha: 1)
          : UIColor(red: 0.184, green: 0.639, blue: 0.478, alpha: 1)
      })
  }
}
