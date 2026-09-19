import QuotaPresentation
import SwiftUI

enum QuotaDesign {
  enum Layout {
    static let cardCornerRadius: CGFloat = DesignTokens.Radius.card
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 12
    static let meterHeight: CGFloat = 8
    static let compactMeterHeight: CGFloat = 4
    static let markSize: CGFloat = 22
    static let detailMarkSize: CGFloat = 40
    static let statTileMinWidth: CGFloat = 140
    static let identityAvatarSize: CGFloat = 44
    static let settingsRowIconSize: CGFloat = 28
    static let deviceSymbolSize: CGFloat = 28
    static let quotaMarkAbout: CGFloat = 64
    static let quotaMarkWelcome: CGFloat = 72
  }

  enum Typography {
    static let statValue = Font.system(.largeTitle, design: .rounded).weight(.semibold)
      .monospacedDigit()
    static let remainingValue = Font.system(.title, design: .rounded).weight(.semibold)
      .monospacedDigit()
    static let cardTitle = Font.headline
    static let support = Font.subheadline
    static let meta = Font.footnote
    static let sectionTitle = Font.title3.weight(.semibold)
  }
}
