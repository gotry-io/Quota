import SwiftUI

/// Settings → Agents → <Provider>: visibility, reporting provenance, and local setup.
struct ProviderSettingsView: View {
  let provider: ProviderID
  let reportingSources: [ProviderReportingSourcePresentation]
  let now: Date
  @State private var isVisible: Bool

  init(
    provider: ProviderID,
    reportingSources: [ProviderReportingSourcePresentation] = [],
    now: Date
  ) {
    self.provider = provider
    self.reportingSources = reportingSources
    self.now = now
    _isVisible = State(initialValue: ProviderVisibility.isVisible(provider))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Overview") {
          SettingsListRow(
            title: "Show in Overview",
            subtitle: "Applies to local and account device reports",
            height: QuotaDesign.Layout.settingsListRowHeight,
            leading: {
              ProviderBrandIcon(
                provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
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

        SettingsSection(
          title: provider.isConfigurable ? "This Mac Configuration" : "This Mac Sign-in"
        ) {
          QuotaCommandRow(
            command: provider.loginCommand,
            copyLabel: provider.isConfigurable
              ? "Copy configuration command"
              : "Copy sign-in command"
          )
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
