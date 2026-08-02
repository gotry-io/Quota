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
