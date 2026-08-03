import SwiftUI

enum QuotaDesign {
  enum Layout {
    static let panelWidth: CGFloat = 360
    /// Preferred height for typical 1–2 provider overviews.
    static let overviewPanelHeight: CGFloat = 440
    static let overviewPanelMinHeight: CGFloat = 380
    /// Settings and deeper pages need more vertical room than Overview.
    static let settingsPanelHeight: CGFloat = 520
    static let settingsPanelMinHeight: CGFloat = 480
    static let panelMaxHeight: CGFloat = 560
    static let panelHorizontalPadding: CGFloat = 16
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
    static let navigationControlSize: CGFloat = 28
    static let providerRowVerticalPadding: CGFloat = 10
    static let progressHeight: CGFloat = 8
    static let tagCornerRadius: CGFloat = 3
  }

  enum Typography {
    static let panelTitle = Font.system(.headline, design: .rounded, weight: .semibold)
    static let providerTitle = Font.system(.subheadline, weight: .medium)
    static let quotaLabel = Font.system(.caption, weight: .medium)
    static let remainingValue = Font.system(.subheadline, weight: .semibold)
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
      .foregroundStyle(isEnabled ? QuotaPalette.onPrimary : QuotaPalette.body)
      .padding(.horizontal, 18)
      .frame(minHeight: 36)
      .background(
        isEnabled
          ? (configuration.isPressed ? QuotaPalette.inkDeep : QuotaPalette.primary)
          : QuotaPalette.soft
      )
      .clipShape(Capsule())
  }
}
