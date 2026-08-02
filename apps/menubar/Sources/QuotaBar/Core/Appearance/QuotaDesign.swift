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
    static let panelTitle = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let providerTitle = Font.system(size: 14, weight: .medium)
    static let quotaLabel = Font.system(size: 12, weight: .medium)
    static let metadata = Font.system(size: 12)
    static let resetTime = Font.system(size: 11)
    static let statusTag = Font.system(size: 10)
    static let sourceTag = Font.system(size: 9, weight: .medium)
  }

  enum Motion {
    static let navigationDuration = 0.18
  }
}
