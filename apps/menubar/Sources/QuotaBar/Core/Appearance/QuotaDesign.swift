import SwiftUI

enum QuotaDesign {
  enum Layout {
    static let panelWidth: CGFloat = 320
    /// Fixed panel height for every page. MenuBarExtra first-open ignores flexible heights.
    static let panelMaxHeight: CGFloat = 560

    /// Single page gutter for every scroll/page body. Do not stack a second
    /// horizontal inset on top of this at the page level.
    static let panelHorizontalPadding: CGFloat = 16
    /// Usable width inside the page gutter.
    static var panelContentWidth: CGFloat { panelWidth - (panelHorizontalPadding * 2) }

    /// Vertical inset for Settings / Relay / form page bodies.
    static let pageVerticalPadding: CGFloat = 16
    /// Extra vertical room only for centered empty states.
    static let emptyStateVerticalPadding: CGFloat = 24

    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
    static let navigationControlSize: CGFloat = 28
    static let providerRowVerticalPadding: CGFloat = 10
    static let progressHeight: CGFloat = 8
    static let tagCornerRadius: CGFloat = 3
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
  }

  /// Shared vertical/horizontal rhythm. Prefer these over raw literals.
  enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16

    /// Page-level section stack (Settings sections, Relay card lists).
    static let section: CGFloat = lg
    /// Content inside a section or form group.
    static let sectionBody: CGFloat = md
    /// Stack of cards/rows.
    static let cardStack: CGFloat = lg
    /// Content inside a card.
    static let cardBody: CGFloat = 10
    /// Dense meta lines (reset time, command captions).
    static let meta: CGFloat = xxs
    /// Inline control clusters.
    static let inline: CGFloat = sm
    /// Icon + label pairs.
    static let iconLabel: CGFloat = xs
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
