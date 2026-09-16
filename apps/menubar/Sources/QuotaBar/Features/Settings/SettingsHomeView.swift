import QuotaWire
import SwiftUI

struct SettingsHomeView: View {
  @Bindable var model: MenuBarViewModel
  let onOpenAgents: () -> Void
  let onOpenUsage: () -> Void

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
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
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
