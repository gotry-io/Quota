import SwiftUI

/// Settings → Agents → <Provider>: visibility, reporting provenance, and This Mac configuration.
struct ProviderSettingsView: View {
  let provider: ProviderID
  let reportingSources: [ProviderReportingSourcePresentation]
  let now: Date
  var saveRequest: Int = 0
  var onIssue: (String?) -> Void = { _ in }

  @State private var isVisible: Bool

  init(
    provider: ProviderID,
    reportingSources: [ProviderReportingSourcePresentation] = [],
    now: Date,
    saveRequest: Int = 0,
    onIssue: @escaping (String?) -> Void = { _ in }
  ) {
    self.provider = provider
    self.reportingSources = reportingSources
    self.now = now
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
            subtitle: "Applies to This Mac and Relay sources",
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

        SettingsSection(title: "Reporting From") {
          if reportingSources.isEmpty {
            Text("No reports yet")
              .quotaSecondaryStyle()
              .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
              .frame(
                maxWidth: .infinity,
                minHeight: QuotaDesign.Layout.settingsRowHeight,
                alignment: .leading
              )
          } else {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(reportingSources) { source in
                SettingsListRow(
                  title: source.displayName,
                  systemImage: source.symbolName
                ) {
                  Text(source.detailLabel(now: now))
                    .quotaListSecondaryStyle()
                    .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(source.displayName)
                .accessibilityValue(source.detailLabel(now: now))
              }
            }
          }
        }

        if provider.isConfigurable {
          SettingsSection(title: "This Mac API Key") {
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
          SettingsSection(title: "This Mac Sign-in") {
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
