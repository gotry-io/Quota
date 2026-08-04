import SwiftUI

enum QuotaDesign {
  enum Layout {
    static let panelWidth: CGFloat = 320
    /// Fixed panel height for every page. MenuBarExtra first-open ignores flexible heights.
    static let panelMaxHeight: CGFloat = 560

    /// Single horizontal gutter for header, page body, and footer.
    static let panelHorizontalPadding: CGFloat = 16
    /// Usable width inside the page gutter.
    static var panelContentWidth: CGFloat { panelWidth - (panelHorizontalPadding * 2) }

    static let pageVerticalPadding: CGFloat = 16
    static let emptyStateVerticalPadding: CGFloat = 24

    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
    static let headerControlWidth: CGFloat = 28
    static let providerRowVerticalPadding: CGFloat = 10
    static let progressHeight: CGFloat = 8
    static let tagCornerRadius: CGFloat = 3
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let controlMinHeight: CGFloat = 36

    static let headerIconPointSize: CGFloat = 14
    static let emptyIconPointSize: CGFloat = 28
  }

  /// Shared vertical/horizontal rhythm. Prefer these over raw literals.
  enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16

    static let section: CGFloat = lg
    static let sectionBody: CGFloat = md
    static let cardStack: CGFloat = lg
    static let cardBody: CGFloat = 10
    static let meta: CGFloat = xxs
    static let inline: CGFloat = sm
    static let iconLabel: CGFloat = xs
  }

  /// Semantic type roles. Prefer these over bare `.caption` / `.subheadline`.
  ///
  /// Hierarchy (strong → quiet):
  /// panelTitle ≥ emptyTitle > rowTitle > sectionHeader > secondary > meta
  enum Typography {
    static let panelTitle = Font.system(.headline, design: .rounded, weight: .semibold)
    /// Same size as panelTitle, lighter weight.
    static let emptyTitle = Font.system(.headline, design: .rounded, weight: .medium)
    static let rowTitle = Font.system(.subheadline, weight: .medium)
    static let sectionHeader = Font.system(.caption, weight: .semibold)
    static let secondary = Font.system(.caption)
    static let meta = Font.system(.caption2)
    static let metaMedium = Font.system(.caption2, weight: .medium)
    static let mono = Font.system(.caption, design: .monospaced)
    static let monoMeta = Font.system(.caption2, design: .monospaced)
    static let quotaLabel = Font.system(.caption, weight: .medium)
    static let remainingValue = Font.system(.subheadline, weight: .semibold)

    static let chevron = Font.system(size: 11, weight: .semibold)
    static let affordance = Font.system(size: 10, weight: .medium)
    static let headerIcon = Font.system(size: Layout.headerIconPointSize, weight: .semibold)
    static let emptyIcon = Font.system(size: Layout.emptyIconPointSize, weight: .regular)
    static let pairingCode = Font.system(.title3, design: .monospaced, weight: .semibold)
    static let pairingSeparator = Font.system(.body, weight: .medium)
  }
}

// MARK: - Semantic text styles (one helper per font+color pair)

extension View {
  func quotaSectionHeaderStyle() -> some View {
    font(QuotaDesign.Typography.sectionHeader)
      .foregroundStyle(QuotaPalette.mute)
  }

  func quotaRowTitleStyle() -> some View {
    font(QuotaDesign.Typography.rowTitle)
      .foregroundStyle(QuotaPalette.ink)
  }

  func quotaSecondaryStyle() -> some View {
    font(QuotaDesign.Typography.secondary)
      .foregroundStyle(QuotaPalette.body)
  }

  func quotaMetaStyle() -> some View {
    font(QuotaDesign.Typography.meta)
      .foregroundStyle(QuotaPalette.mute)
  }

  /// Technical mono string (URL, command, id) — never stronger than body.
  func quotaMonoStyle() -> some View {
    font(QuotaDesign.Typography.mono)
      .foregroundStyle(QuotaPalette.body)
  }

  func quotaMonoMetaStyle() -> some View {
    font(QuotaDesign.Typography.monoMeta)
      .foregroundStyle(QuotaPalette.mute)
  }

  func quotaEmptyTitleStyle() -> some View {
    font(QuotaDesign.Typography.emptyTitle)
      .foregroundStyle(QuotaPalette.ink)
  }

  func quotaEmptyIconStyle() -> some View {
    font(QuotaDesign.Typography.emptyIcon)
      .foregroundStyle(QuotaPalette.body)
  }

  func quotaChevronStyle() -> some View {
    font(QuotaDesign.Typography.chevron)
      .foregroundStyle(QuotaPalette.mute)
  }

  func quotaAffordanceStyle() -> some View {
    font(QuotaDesign.Typography.affordance)
      .foregroundStyle(QuotaPalette.mute)
  }
}

// MARK: - Shared chrome

/// Compact mute status chip (Stale, Default, Managed, …).
struct QuotaStatusTag: View {
  let text: String
  var systemImage: String?

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
    }
    .font(QuotaDesign.Typography.meta)
    .foregroundStyle(QuotaPalette.mute)
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .overlay {
      RoundedRectangle(cornerRadius: QuotaDesign.Layout.tagCornerRadius)
        .stroke(QuotaPalette.hairlineBorder, lineWidth: 1)
    }
  }
}

struct QuotaPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(QuotaDesign.Typography.rowTitle)
      .foregroundStyle(isEnabled ? QuotaPalette.onPrimary : QuotaPalette.body)
      .padding(.horizontal, 18)
      .frame(minHeight: QuotaDesign.Layout.controlMinHeight)
      .background(
        isEnabled
          ? (configuration.isPressed ? QuotaPalette.ink.opacity(0.85) : QuotaPalette.ink)
          : QuotaPalette.soft
      )
      .clipShape(Capsule())
  }
}
