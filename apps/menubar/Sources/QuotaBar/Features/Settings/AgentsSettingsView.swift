import SwiftUI

/// Settings → Agents: catalog providers with drill-in to visibility and configuration.
struct AgentsSettingsView: View {
  let model: MenuBarViewModel
  let onOpenProvider: (ProviderID) -> Void

  var body: some View {
    // One config-file read for all API-key hints (not per-row).
    let apiKeyStatuses = ProviderConfigStore().statuses(for: ProviderID.configurableCases)

    return ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        Text("Open a provider to show or hide it in Overview and manage API keys.")
          .quotaMetaStyle()
          .fixedSize(horizontal: false, vertical: true)

        SettingsSection(title: "Agents") {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(ProviderID.allCases) { provider in
              providerRow(provider, apiKeyStatus: apiKeyStatuses[provider])
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private func providerRow(_ provider: ProviderID, apiKeyStatus: ProviderApiKeyStatus?) -> some View {
    let status = AgentStatusPresentation.resolve(result: model.result(for: provider))
    let subtitle = rowSubtitle(provider: provider, status: status, apiKeyStatus: apiKeyStatus)

    return Button {
      onOpenProvider(provider)
    } label: {
      SettingsListRow(
        title: provider.displayName,
        subtitle: subtitle,
        height: QuotaDesign.Layout.settingsListRowHeight,
        leading: {
          ProviderBrandIcon(provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
        },
        trailing: {
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(provider.displayName)
    .accessibilityHint(
      subtitle.isEmpty
        ? "Opens \(provider.displayName) settings"
        : "\(subtitle). Opens \(provider.displayName) settings"
    )
  }

  private func rowSubtitle(
    provider: ProviderID,
    status: AgentStatusPresentation,
    apiKeyStatus: ProviderApiKeyStatus?
  ) -> String {
    if let detail = status.detail {
      return detail
    }
    guard provider.isConfigurable else { return "" }
    switch apiKeyStatus ?? .missing {
    case .configured(let mask):
      return mask
    case .missing:
      return "API key"
    case .unreadable:
      return "Config unreadable"
    }
  }
}
