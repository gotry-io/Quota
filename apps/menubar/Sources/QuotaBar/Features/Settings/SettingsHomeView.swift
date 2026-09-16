import QuotaWire
import SwiftUI

struct SettingsHomeView: View {
  @Bindable var model: MenuBarViewModel
  let onOpenAgents: () -> Void
  let onOpenUsage: () -> Void
  let onOpenMenuBarStyle: () -> Void
  let onOpenMenuBarProvider: () -> Void
  let onOpenResetCopy: () -> Void

  @AppStorage(MenuBarStylePreference.storageKey) private var menuBarStyle =
    MenuBarStylePreference.fallback
  @AppStorage(MenuBarProviderPreference.storageKey) private var menuBarProvider =
    MenuBarProviderPreference.fallback
  @AppStorage(MenuBarArrangementPreference.storageKey) private var menuBarArrangement =
    MenuBarArrangementPreference.fallback
  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback
  @AppStorage(PaceLinePreference.storageKey) private var showsPaceLines =
    PaceLinePreference.fallback

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Quota") {
          VStack(alignment: .leading, spacing: 0) {
            settingsDestinationRow(
              title: "Usage",
              systemImage: "chart.bar.xaxis",
              trailing: usageSummary,
              accessibilityLabel: "Usage",
              action: onOpenUsage
            )
            settingsDestinationRow(
              title: "Agents",
              systemImage: "cpu",
              accessibilityLabel: "Agents",
              action: onOpenAgents
            )
          }
        }

        SettingsSection(title: "Menu Bar") {
          VStack(alignment: .leading, spacing: 0) {
            settingsDestinationRow(
              title: "Style",
              systemImage: "menubar.rectangle",
              trailing: currentLayout.effectiveStyle(menuBarStyle).label,
              accessibilityLabel: MenuBarRoute.menuBarStyle.title,
              action: onOpenMenuBarStyle
            )
            settingsDestinationRow(
              title: "Provider",
              systemImage: "chart.bar.doc.horizontal",
              trailing: currentLayout.settingsSummary,
              accessibilityLabel: MenuBarRoute.menuBarProvider.title,
              action: onOpenMenuBarProvider
            )
            settingsDestinationRow(
              title: "Reset time",
              systemImage: "clock.arrow.circlepath",
              trailing: resetCopyStyle.label,
              accessibilityLabel: MenuBarRoute.resetCopy.title,
              action: onOpenResetCopy
            )
            settingsToggleRow(
              title: "Show pace lines",
              systemImage: "chart.xyaxis.line",
              isOn: $showsPaceLines,
              accessibilityLabel: "Show pace lines",
              accessibilityHint: "Draw each window's usage curve and where it lands at reset"
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var currentLayout: MenuBarLayout {
    MenuBarLayout.resolve(
      selection: menuBarProvider,
      arrangement: menuBarArrangement,
      visibleProviders: ProviderDisplayOrder.enabledProviders()
    )
  }

  private var usageSummary: String {
    let totalTokens: Int?
    if model.accountState == .signedIn, model.usageUploadEnabled {
      totalTokens = model.accountSummary?.usage.all.totals.totalTokens
    } else if model.localUsage?.status != .unavailable {
      totalTokens = model.usageDetail(source: .local, period: .all)?.usage.totals.totalTokens
    } else {
      totalTokens = nil
    }
    guard let totalTokens else { return "Unavailable" }
    return "\(UsageValueFormatter.count(totalTokens)) tokens"
  }

}
