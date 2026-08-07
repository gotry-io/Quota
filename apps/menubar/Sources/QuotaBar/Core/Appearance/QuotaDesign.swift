import SwiftUI

enum QuotaDesign {
  enum Layout {
    static let panelWidth: CGFloat = 320
    /// Fixed panel height for every page. MenuBarExtra first-open ignores flexible heights.
    static let panelMaxHeight: CGFloat = 480

    /// Single horizontal gutter for header, page body, and footer.
    static let panelHorizontalPadding: CGFloat = 16
    /// Usable width inside the page gutter.
    static var panelContentWidth: CGFloat { panelWidth - (panelHorizontalPadding * 2) }

    static let pageVerticalPadding: CGFloat = 16
    static let emptyStateVerticalPadding: CGFloat = 24

    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
    /// Apple HIG's recommended minimum pointer target on macOS.
    static let minimumInteractiveDimension: CGFloat = 28
    /// Visual footprint between the back glyph's content edge and the title.
    /// The button itself remains `headerControlWidth` wide and overlaps this slot inward.
    static let backTitleOffset: CGFloat = 20
    static let headerControlWidth: CGFloat = minimumInteractiveDimension
    static let providerRowVerticalPadding: CGFloat = 10
    /// Vertical padding inside multi-line settings forms (API key, sign-in copy).
    static let settingsRowVerticalPadding: CGFloat = 8
    /// Single-line Settings rows (home General / Sources / About).
    static let settingsRowHeight: CGFloat = 36
    /// Stacked list rows (Agents, Devices) — title-only still uses this height and centers.
    static let settingsListRowHeight: CGFloat = 44
    /// Leading mark column (SF Symbol or brand icon).
    static let settingsIconColumnWidth: CGFloat = 16
    static let progressHeight: CGFloat = 8
    static let tagCornerRadius: CGFloat = 3
    /// Primary filled pill (empty-state Retry, etc.).
    static let controlMinHeight: CGFloat = 36
    /// Compact single-line fields.
    static let fieldMinHeight: CGFloat = 30
    /// Fields nest slightly inside group chrome.
    static let fieldCornerRadius: CGFloat = 6
    /// Settings groups, command chips, pairing cells.
    static let groupCornerRadius: CGFloat = 8
    /// Product toggle track (visual); hit target remains ≥ minimumInteractiveDimension.
    static let toggleTrackWidth: CGFloat = 26
    static let toggleTrackHeight: CGFloat = 15
    static let toggleThumbSize: CGFloat = 13

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
    /// Dense stacks inside a settings/task section (About rows, device metadata).
    static let sectionRows: CGFloat = sm
    static let meta: CGFloat = xxs
    static let inline: CGFloat = sm
    static let iconLabel: CGFloat = xs
  }

  /// Semantic type roles. Prefer these over bare `.caption` / `.subheadline`.
  ///
  /// Hierarchy (strong → quiet):
  /// panelTitle ≥ emptyTitle > rowTitle > settingsLabel ≥ sectionHeader > secondary > meta
  enum Typography {
    enum Role {
      case panelTitle
      case emptyTitle
      case rowTitle
      /// Compact Settings body labels (menu-style, smaller than Overview row titles).
      case settingsLabel
      case sectionHeader
      case secondary
      case meta
      case metaMedium
      case mono
      case monoMeta
      case quotaLabel
      case remainingValue

      fileprivate var baseSize: CGFloat {
        switch self {
        case .panelTitle, .emptyTitle, .rowTitle, .remainingValue: 13
        case .settingsLabel, .sectionHeader, .secondary, .mono, .quotaLabel: 11
        case .meta, .metaMedium, .monoMeta: 10
        }
      }

      fileprivate var weight: Font.Weight {
        switch self {
        case .panelTitle, .sectionHeader, .remainingValue: .semibold
        case .emptyTitle, .rowTitle, .settingsLabel, .metaMedium, .quotaLabel: .medium
        case .secondary, .meta, .mono, .monoMeta: .regular
        }
      }

      fileprivate var design: Font.Design {
        switch self {
        case .panelTitle, .emptyTitle: .rounded
        case .mono, .monoMeta: .monospaced
        default: .default
        }
      }
    }

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
  func quotaFont(_ role: QuotaDesign.Typography.Role) -> some View {
    modifier(QuotaScaledFontModifier(role: role))
  }

  func quotaSectionHeaderStyle() -> some View {
    quotaFont(.sectionHeader)
      .foregroundStyle(QuotaPalette.mute)
  }

  func quotaRowTitleStyle() -> some View {
    quotaFont(.rowTitle)
      .foregroundStyle(QuotaPalette.ink)
  }

  /// Settings body labels — 11pt medium, denser than Overview provider titles.
  func quotaSettingsLabelStyle() -> some View {
    quotaFont(.settingsLabel)
      .foregroundStyle(QuotaPalette.ink)
  }

  func quotaSecondaryStyle() -> some View {
    quotaFont(.secondary)
      .foregroundStyle(QuotaPalette.body)
  }

  func quotaMetaStyle() -> some View {
    quotaFont(.meta)
      .foregroundStyle(QuotaPalette.mute)
  }

  /// Technical mono string (URL, command, id) — never stronger than body.
  func quotaMonoStyle() -> some View {
    quotaFont(.mono)
      .foregroundStyle(QuotaPalette.body)
  }

  func quotaMonoMetaStyle() -> some View {
    quotaFont(.monoMeta)
      .foregroundStyle(QuotaPalette.mute)
  }

  func quotaEmptyTitleStyle() -> some View {
    quotaFont(.emptyTitle)
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

private struct QuotaScaledFontModifier: ViewModifier {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let role: QuotaDesign.Typography.Role

  func body(content: Content) -> some View {
    content.font(
      .system(
        size: role.baseSize * dynamicTypeSize.quotaScale,
        weight: role.weight,
        design: role.design
      )
    )
  }
}

private extension DynamicTypeSize {
  var quotaScale: CGFloat {
    switch self {
    case .xSmall, .small, .medium, .large: 1
    case .xLarge: 1.08
    case .xxLarge: 1.16
    case .xxxLarge: 1.24
    case .accessibility1: 1.32
    case .accessibility2: 1.4
    case .accessibility3: 1.48
    case .accessibility4: 1.56
    case .accessibility5: 1.64
    @unknown default: 1
    }
  }
}

// MARK: - Shared chrome

/// Compact mute status chip reserved for stale quota data.
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
    .quotaFont(.meta)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .quotaFont(.rowTitle)
      .foregroundStyle(isEnabled ? QuotaPalette.onAccent : QuotaPalette.body)
      .padding(.horizontal, 18)
      .frame(minHeight: QuotaDesign.Layout.controlMinHeight)
      .background(
        isEnabled ? QuotaPalette.accent : QuotaPalette.soft
      )
      .clipShape(Capsule())
      .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.98 : 1)
  }
}
