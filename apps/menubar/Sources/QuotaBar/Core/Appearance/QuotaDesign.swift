import SwiftUI

enum QuotaDesign {
  enum Layout {
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 520
    static let panelHorizontalPadding: CGFloat = 16
    static let headerHeight: CGFloat = 48
    static let footerHeight: CGFloat = 40
    static let navigationControlSize: CGFloat = 32
    static let providerRowVerticalPadding: CGFloat = 16
    static let progressHeight: CGFloat = 6
    static let tagCornerRadius: CGFloat = 3
  }

  enum Typography {
    static let panelTitle = Font.system(.headline, design: .rounded, weight: .semibold)
    static let providerTitle = Font.system(.subheadline, weight: .medium)
    static let quotaLabel = Font.system(.caption, weight: .medium)
    static let metadata = Font.caption
    static let resetTime = Font.caption2
    static let statusTag = Font.caption2
    static let sourceTag = Font.system(.caption2, weight: .medium)
  }
}

struct QuotaPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.subheadline, weight: .medium))
      .foregroundStyle(isEnabled ? Color.white : QuotaPalette.body)
      .padding(.horizontal, 18)
      .frame(minHeight: 36)
      .background(
        isEnabled
          ? Color.black.opacity(configuration.isPressed ? 0.82 : 1)
          : QuotaPalette.soft
      )
      .clipShape(Capsule())
  }
}
