import SwiftUI

/// Settings → Agents → <Provider>: visibility + optional API-key configuration.
struct ProviderSettingsView: View {
  let model: MenuBarViewModel
  let provider: ProviderID

  @State private var isVisible: Bool

  init(model: MenuBarViewModel, provider: ProviderID) {
    self.model = model
    self.provider = provider
    _isVisible = State(initialValue: ProviderVisibility.isVisible(provider))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Overview") {
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
            SettingsListRow(
              title: provider.displayName,
              height: QuotaDesign.Layout.settingsListRowHeight,
              leading: {
                ProviderBrandIcon(provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
              },
              trailing: {
                Toggle("Show in Overview", isOn: visibilityBinding)
                  .labelsHidden()
                  .controlSize(.mini)
                  .accessibilityLabel("Show \(provider.displayName) in Overview")
                  .accessibilityHint(agentStatus.accessibilityHint)
              }
            )

            // Recovery/status stays multi-line under the row (not a clipped list subtitle).
            if let detail = agentStatus.detail {
              Text(detail)
                .quotaMetaStyle()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, QuotaDesign.Layout.settingsIconColumnWidth + QuotaDesign.Spacing.sm)
            }
          }
        }

        if provider.isConfigurable {
          SettingsSection(title: "API key") {
            ApiKeyProviderSettingsForm(provider: provider, isVisible: visibilityBinding)
              .padding(.vertical, QuotaDesign.Layout.settingsRowVerticalPadding)
          }
        } else {
          SettingsSection(title: "Sign-in") {
            Text("Uses local \(provider.displayName) session credentials. Recovery: \(provider.loginCommand)")
              .quotaMetaStyle()
              .fixedSize(horizontal: false, vertical: true)
              .padding(.vertical, QuotaDesign.Layout.settingsRowVerticalPadding)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var agentStatus: AgentStatusPresentation {
    AgentStatusPresentation.resolve(result: model.result(for: provider))
  }

  private var visibilityBinding: Binding<Bool> {
    Binding(
      get: { isVisible },
      set: { newValue in
        ProviderVisibility.setVisible(provider, newValue)
        isVisible = newValue
      }
    )
  }
}
