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
    static let headerControlWidth: CGFloat = minimumInteractiveDimension
    /// Compact visible hover/pressed surface inside the unchanged header target.
    static let headerControlSurfaceSize: CGFloat = 24
    /// Settings overflow list, trailing-aligned to the panel content guide.
    static let headerMenuWidth: CGFloat = 220
    /// Nominal optical box for header action symbols.
    static let headerGlyphWidth: CGFloat = 16
    /// Root brand mark aligns directly with the shell's leading content edge.
    static let headerBrandSize: CGFloat = 18
    /// Navigation/action slot. Grouped content uses its own inset grid.
    static let headerAccessoryWidth: CGFloat = headerControlWidth
    static let providerRowVerticalPadding: CGFloat = 8
    /// Vertical padding inside multi-line settings content and command rows.
    static let settingsRowVerticalPadding: CGFloat = 8
    /// Single-line Settings rows (home General / Sources / About).
    static let settingsRowHeight: CGFloat = 38
    /// Stacked list rows (Agents, Devices) — title-only still uses this height and centers.
    static let settingsListRowHeight: CGFloat = 46
    /// Leading mark column (SF Symbol or brand icon).
    static let settingsIconColumnWidth: CGFloat = 16
    static let usageProviderIconSize: CGFloat = 14
    static let progressHeight: CGFloat = 6
    /// Primary filled pill (empty-state Retry, etc.).
    static let controlMinHeight: CGFloat = 36
    /// Compact single-line fields.
    static let fieldMinHeight: CGFloat = 32
    /// Fields nest slightly inside group chrome.
    static let fieldCornerRadius: CGFloat = 7
    /// Settings groups and read-only modules.
    static let groupCornerRadius: CGFloat = 10
    /// Content inset inside a Settings group.
    static let groupContentInset: CGFloat = 8
    /// Equal inset between a group and its row interaction surface.
    static let groupSurfaceInset: CGFloat = 4
    /// Hover/pressed surface nested inside a settings group.
    static let rowCornerRadius: CGFloat = 6
    /// Transient menus sit above the panel and use a slightly fuller silhouette than groups.
    static let floatingMenuCornerRadius: CGFloat = 12
    /// Keeps menu-row hover geometry concentric with the 4pt surface inset.
    static let floatingMenuRowCornerRadius: CGFloat =
      floatingMenuCornerRadius - groupSurfaceInset
    static let floatingMenuShadowRadius: CGFloat = 12
    static let floatingMenuShadowY: CGFloat = 5

    static let headerBackIconPointSize: CGFloat = 11
    static let headerActionIconPointSize: CGFloat = 13
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
  /// panelTitle ≥ emptyTitle > rowTitle > settingsLabel > sectionHeader > listSecondary > meta
  enum Typography {
    enum Role {
      case panelTitle
      case emptyTitle
      case rowTitle
      /// Compact Settings body labels (menu-style, smaller than Overview row titles).
      case settingsLabel
      case sectionHeader
      /// Supporting copy inside list rows; more readable than tertiary metadata.
      case listSecondary
      case secondary
      case meta
      case mono
      case monoMeta
      case quotaLabel
      case remainingValue

      fileprivate var baseSize: CGFloat {
        switch self {
        case .panelTitle, .emptyTitle, .rowTitle: 13
        case .settingsLabel, .remainingValue: 12
        case .sectionHeader, .secondary, .mono, .quotaLabel: 11
        case .listSecondary: 10.5
        case .meta, .monoMeta: 10
        }
      }

      fileprivate var weight: Font.Weight {
        switch self {
        case .panelTitle, .sectionHeader: .semibold
        case .emptyTitle, .rowTitle, .settingsLabel, .quotaLabel, .remainingValue: .medium
        case .listSecondary, .secondary, .meta, .mono, .monoMeta: .regular
        }
      }

      fileprivate var design: Font.Design {
        switch self {
        case .emptyTitle: .rounded
        case .mono, .monoMeta: .monospaced
        default: .default
        }
      }
    }

    static let chevron = Font.system(size: 11, weight: .semibold)
    static let affordance = Font.system(size: 10, weight: .medium)
    static let headerBackIcon = Font.system(
      size: Layout.headerBackIconPointSize,
      weight: .semibold
    )
    static let headerActionIcon = Font.system(
      size: Layout.headerActionIconPointSize,
      weight: .medium
    )
    static let emptyIcon = Font.system(size: Layout.emptyIconPointSize, weight: .regular)
  }
}

// MARK: - Semantic text styles (one helper per font+color pair)

extension View {
  func quotaFont(_ role: QuotaDesign.Typography.Role) -> some View {
    modifier(QuotaScaledFontModifier(role: role))
  }

  func quotaSectionHeaderStyle() -> some View {
    quotaFont(.sectionHeader)
      .foregroundStyle(QuotaPalette.body)
  }

  func quotaRowTitleStyle() -> some View {
    quotaFont(.rowTitle)
      .foregroundStyle(QuotaPalette.ink)
  }

  /// Settings body labels — 12pt medium, denser than Overview provider titles.
  func quotaSettingsLabelStyle() -> some View {
    quotaFont(.settingsLabel)
      .foregroundStyle(QuotaPalette.ink)
  }

  func quotaSecondaryStyle() -> some View {
    quotaFont(.secondary)
      .foregroundStyle(QuotaPalette.body)
  }

  /// One-line supporting copy inside a list row; quieter than its title but not tertiary metadata.
  func quotaListSecondaryStyle() -> some View {
    quotaFont(.listSecondary)
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

  /// Compact technical value inside a Settings row (for example the app version).
  func quotaMonoListValueStyle() -> some View {
    quotaFont(.monoMeta)
      .foregroundStyle(QuotaPalette.body)
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

extension DynamicTypeSize {
  fileprivate var quotaScale: CGFloat {
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

struct QuotaPrimaryButtonStyle: ButtonStyle {
  var isCompact = false

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .quotaFont(.rowTitle)
      .foregroundStyle(isEnabled ? QuotaPalette.onAccent : QuotaPalette.body)
      .padding(.horizontal, isCompact ? 14 : 18)
      .frame(
        minHeight: isCompact
          ? QuotaDesign.Layout.fieldMinHeight
          : QuotaDesign.Layout.controlMinHeight
      )
      .background(
        isEnabled ? QuotaPalette.accent : QuotaPalette.soft
      )
      .clipShape(Capsule())
      .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.98 : 1)
  }
}
