import SwiftUI

/// Settings → Agents → <Provider>: visibility + optional API-key configuration.
struct ProviderSettingsView: View {
  let provider: ProviderID
  var saveRequest: Int = 0
  var onIssue: (String?) -> Void = { _ in }

  @State private var isVisible: Bool

  init(
    provider: ProviderID,
    saveRequest: Int = 0,
    onIssue: @escaping (String?) -> Void = { _ in }
  ) {
    self.provider = provider
    self.saveRequest = saveRequest
    self.onIssue = onIssue
    _isVisible = State(initialValue: ProviderVisibility.isVisible(provider))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Overview") {
          SettingsListRow(
            title: "Show in Overview",
            height: QuotaDesign.Layout.settingsListRowHeight,
            leading: {
              ProviderBrandIcon(provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
            },
            trailing: {
              Toggle("Show in Overview", isOn: visibilityBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(QuotaPalette.accent)
                .accessibilityLabel("Show \(provider.displayName) in Overview")
                .accessibilityHint("Show or hide this agent in Overview")
            }
          )
        }

        if provider.isConfigurable {
          SettingsSection(title: "API key") {
            ApiKeyProviderSettingsForm(
              provider: provider,
              isVisible: visibilityBinding,
              saveRequest: saveRequest,
              onIssue: onIssue
            )
            .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
            .padding(.vertical, QuotaDesign.Layout.settingsRowVerticalPadding)
          }
        } else {
          SettingsSection(title: "Sign-in") {
            QuotaCommandRow(
              command: provider.loginCommand,
              copyLabel: "Copy sign-in command"
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
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
