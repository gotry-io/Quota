import AppKit
import SwiftUI

struct SettingsHomeView: View {
  let model: MenuBarViewModel
  let onOpenAgents: () -> Void
  let onOpenRemoteDevices: () -> Void
  var deleteAllErrorMessage: String? = nil

  @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "General") {
          settingsToggleRow(
            title: "Launch at Login",
            systemImage: "power",
            isOn: Binding(
              get: { launchAtLoginEnabled },
              set: { desired in
                _ = LaunchAtLoginController.apply(enabled: desired)
                launchAtLoginEnabled = LaunchAtLoginController.isEnabled
              }
            ),
            accessibilityLabel: "Launch at Login",
            accessibilityHint: "Start QuotaBar when you log in"
          )
        }

        SettingsSection(title: "Sources") {
          VStack(alignment: .leading, spacing: 0) {
            settingsDestinationRow(
              title: "Agents",
              systemImage: "cpu",
              trailing: agentsSummary,
              accessibilityLabel: "Agents",
              action: onOpenAgents
            )
            settingsDestinationRow(
              title: "Devices",
              systemImage: "laptopcomputer.and.iphone",
              trailing: deviceSummary,
              accessibilityLabel: "Remote Devices",
              action: onOpenRemoteDevices
            )
          }
        }

        SettingsSection(title: "About") {
          VStack(alignment: .leading, spacing: 0) {
            settingsValueRow(
              title: "Version",
              systemImage: "info.circle",
              value: AppMetadata.versionLabel
            )
            settingsLinkRow(
              title: "Website",
              systemImage: "globe",
              url: AppMetadata.websiteURL
            )
            settingsLinkRow(
              title: "Feedback",
              systemImage: "envelope",
              url: AppMetadata.feedbackURL
            )
          }

          if let deleteAllErrorMessage {
            Label(deleteAllErrorMessage, systemImage: "exclamationmark.circle")
              .quotaMetaStyle()
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, QuotaDesign.Spacing.xs)
              .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
              .padding(.bottom, QuotaDesign.Layout.groupContentInset)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .onAppear {
      launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    }
  }

  private var deviceSummary: String {
    model.relayStateModel.remoteDeviceSummary
  }

  private var agentsSummary: String {
    let visible = ProviderID.allCases.filter { ProviderVisibility.isVisible($0) }.count
    let total = ProviderID.allCases.count
    if visible == total {
      return "\(total)"
    }
    return "\(visible)/\(total)"
  }

  private func settingsToggleRow(
    title: String,
    systemImage: String,
    isOn: Binding<Bool>,
    accessibilityLabel: String,
    accessibilityHint: String
  ) -> some View {
    SettingsListRow(title: title, systemImage: systemImage) {
      Toggle(accessibilityLabel, isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(QuotaPalette.accent)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(accessibilityHint)
  }

  private func settingsDestinationRow(
    title: String,
    systemImage: String,
    trailing: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      SettingsListRow(title: title, systemImage: systemImage) {
        HStack(spacing: QuotaDesign.Spacing.xxs) {
          Text(trailing)
            .quotaListSecondaryStyle()
            .lineLimit(1)
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }
      }
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(trailing)
  }

  private func settingsValueRow(title: String, systemImage: String, value: String) -> some View {
    SettingsListRow(title: title, systemImage: systemImage) {
      Text(value)
        .quotaMonoListValueStyle()
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title) \(value)")
  }

  private func settingsLinkRow(title: String, systemImage: String, url: URL) -> some View {
    Button {
      NSWorkspace.shared.open(url)
    } label: {
      SettingsListRow(title: title, systemImage: systemImage) {
        Image(systemName: "arrow.up.right")
          .quotaAffordanceStyle()
      }
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel(title)
    .accessibilityHint("Opens in browser")
  }
}
