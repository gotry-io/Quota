import SwiftUI

enum QuotaTheme {
  static let emerald = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.510, green: 0.867, blue: 0.722, alpha: 1)
        : UIColor(red: 0.031, green: 0.455, blue: 0.337, alpha: 1)
    }
  )

  static let meterTrack = Color(uiColor: .tertiarySystemFill)

  static let minimumTouchTarget: CGFloat = 44
  static let activityCellSize: CGFloat = 14
  static let activityCellGap: CGFloat = 4
  static let activityCellCorner: CGFloat = 3
  static let activityWeekdayWidth: CGFloat = 28
  /// Trailing space so a one-week last month still shows its full 3-letter abbreviation.
  static let activityMonthLabelOverflow: CGFloat = 28

  /// Five-step Activity fill, matching the website's emerald ramp.
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

  static func activityBorder(_ level: Int) -> Color {
    Color(
      uiColor: UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        switch level {
        case 1:
          return dark
            ? UIColor(red: 0.102, green: 0.478, blue: 0.345, alpha: 1)
            : UIColor(red: 0.604, green: 0.851, blue: 0.749, alpha: 1)
        case 2:
          return dark
            ? UIColor(red: 0.184, green: 0.639, blue: 0.478, alpha: 1)
            : UIColor(red: 0.369, green: 0.792, blue: 0.627, alpha: 1)
        case 3:
          return dark
            ? UIColor(red: 0.510, green: 0.867, blue: 0.722, alpha: 1)
            : UIColor(red: 0.031, green: 0.455, blue: 0.337, alpha: 1)
        case 4:
          return dark
            ? UIColor(red: 0.714, green: 0.918, blue: 0.831, alpha: 1)
            : UIColor(red: 0.024, green: 0.353, blue: 0.263, alpha: 1)
        default:
          return UIColor.separator
        }
      })
  }
}
