import SwiftUI

enum QuotaTheme {
  static let emerald = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.510, green: 0.867, blue: 0.722, alpha: 1)
        : UIColor(red: 0.031, green: 0.455, blue: 0.337, alpha: 1)
    }
  )

  static let groupedFill = Color(uiColor: .systemGroupedBackground)
  static let hairline = Color(uiColor: .separator)
  static let meterTrack = Color(uiColor: .tertiarySystemFill)

  static let cardCornerRadius: CGFloat = 16
  static let contentGutter: CGFloat = 20
  static let contentMaxWidth: CGFloat = 720
  static let minimumTouchTarget: CGFloat = 44
  static let activityCellSize: CGFloat = 14
  static let activityCellGap: CGFloat = 4
  static let activityCellCorner: CGFloat = 3
  static let activityWeekdayWidth: CGFloat = 28

  static var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
  }

  /// Five-step Activity fill, matching the website's emerald ramp.
  static func activityFill(_ level: Int) -> Color {
    Color(uiColor: UIColor { traits in
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
    Color(uiColor: UIColor { traits in
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

/// Soft emerald ambient wash so glass and material surfaces read against the field.
struct QuotaAmbientBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let washOpacity = colorScheme == .dark ? 0.22 : 0.12
    let secondaryOpacity = colorScheme == .dark ? 0.10 : 0.06
    ZStack {
      QuotaTheme.groupedFill
      RadialGradient(
        colors: [
          QuotaTheme.emerald.opacity(washOpacity),
          Color.clear,
        ],
        center: UnitPoint(x: 0.5, y: 0.0),
        startRadius: 8,
        endRadius: 460
      )
      RadialGradient(
        colors: [
          QuotaTheme.emerald.opacity(secondaryOpacity),
          Color.clear,
        ],
        center: UnitPoint(x: 0.85, y: 1.05),
        startRadius: 4,
        endRadius: 320
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}

/// One semantic card surface: native Liquid Glass on iOS 26, system Material earlier.
struct QuotaSurfaceModifier: ViewModifier {
  var showsStroke: Bool = false

  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content
        .glassEffect(.regular, in: QuotaTheme.cardShape)
    } else {
      content
        .background(.regularMaterial, in: QuotaTheme.cardShape)
        .overlay {
          if showsStroke {
            QuotaTheme.cardShape
              .strokeBorder(QuotaTheme.hairline, lineWidth: 0.5)
          }
        }
    }
  }
}

extension View {
  /// Apply the shared Quota card surface (glass on iOS 26, Material fallback otherwise).
  func quotaSurface(showsStroke: Bool = false) -> some View {
    modifier(QuotaSurfaceModifier(showsStroke: showsStroke))
  }

  /// Primary call-to-action styling: glassProminent on iOS 26, borderedProminent earlier.
  @ViewBuilder
  func quotaProminentButtonStyle() -> some View {
    if #available(iOS 26, *) {
      self
        .buttonStyle(.glassProminent)
        .tint(QuotaTheme.emerald)
    } else {
      self
        .buttonStyle(.borderedProminent)
        .tint(QuotaTheme.emerald)
    }
  }
}
