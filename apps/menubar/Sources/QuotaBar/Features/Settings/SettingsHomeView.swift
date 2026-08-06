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
        .controlSize(.mini)
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
            .quotaMetaStyle()
            .lineLimit(1)
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(trailing)
  }

  private func settingsValueRow(title: String, systemImage: String, value: String) -> some View {
    SettingsListRow(title: title, systemImage: systemImage) {
      Text(value)
        .quotaMonoMetaStyle()
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
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint("Opens in browser")
  }
}

/// Status copy for Agents list detail lines and the provider-detail visibility toggle hint.
/// Visibility is controlled only on the provider detail page.
struct AgentStatusPresentation: Equatable {
  /// Optional secondary line. Nil for healthy signed-in agents.
  let detail: String?
  /// Hint for the **Show in Overview** toggle on provider detail.
  let accessibilityHint: String

  static func resolve(result: QuotaCollectionResult?) -> AgentStatusPresentation {
    guard let result else {
      return AgentStatusPresentation(
        detail: "Refresh to check access.",
        accessibilityHint: "Not checked yet. Toggle visibility anytime; refresh to update status."
      )
    }

    switch result.outcome {
    case .success:
      return AgentStatusPresentation(
        detail: nil,
        accessibilityHint: "Toggle to show or hide in Overview."
      )
    case .authRequired, .unavailable, .unsupported, .error:
      guard let status = ProviderStatusCopy.from(result: result) else {
        return AgentStatusPresentation(
          detail: "Unavailable",
          accessibilityHint: "Provider unavailable. Toggle to show or hide in Overview."
        )
      }
      return AgentStatusPresentation(
        detail: status.detail ?? status.title,
        accessibilityHint: "\(status.accessibilityLabel) Toggle to show or hide in Overview."
      )
    }
  }
}
