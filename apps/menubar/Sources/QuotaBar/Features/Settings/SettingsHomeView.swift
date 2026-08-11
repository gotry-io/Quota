import AppKit
import SwiftUI

struct SettingsHomeView: View {
  @Bindable var model: MenuBarViewModel
  let onOpenAgents: () -> Void
  let onOpenDevices: () -> Void
  let onOpenUsage: () -> Void

  @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
  @State private var isLogoutConfirmationPresented = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        accountSection

        SettingsSection(title: "Usage") {
          settingsDestinationRow(
            title: "This Mac",
            systemImage: "chart.bar.xaxis",
            trailing: usageSummary,
            accessibilityLabel: "Usage",
            action: onOpenUsage
          )
        }

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

        SettingsSection(title: "Account Data") {
          settingsDestinationRow(
            title: "Devices",
            systemImage: "laptopcomputer.and.iphone",
            trailing: model.accountDeviceSummary,
            accessibilityLabel: "Devices",
            action: onOpenDevices
          )
        }

        SettingsSection(title: "Local Providers") {
          settingsDestinationRow(
            title: "Agents",
            systemImage: "cpu",
            trailing: agentsSummary,
            accessibilityLabel: "Agents",
            action: onOpenAgents
          )
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
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .onAppear { launchAtLoginEnabled = LaunchAtLoginController.isEnabled }
    .alert("Log Out?", isPresented: $isLogoutConfirmationPresented) {
      Button("Cancel", role: .cancel) {}
      Button("Log Out", role: .destructive) {
        Task { await model.logout() }
      }
    } message: {
      Text(
        "This signs QuotaBar out on this Mac. Your device and synced data stay in your Quota account."
      )
    }
  }

  @ViewBuilder
  private var accountSection: some View {
    SettingsSection(title: "Account") {
      VStack(alignment: .leading, spacing: 0) {
        switch model.accountState {
        case .signedIn:
          SettingsListRow(
            title: model.accountDisplayLabel,
            systemImage: "person.crop.circle.fill",
            height: QuotaDesign.Layout.settingsRowHeight
          ) {
            Button {
              isLogoutConfirmationPresented = true
            } label: {
              Group {
                if model.isLoggingOut {
                  ProgressView().controlSize(.small)
                } else {
                  Text("Log Out")
                }
              }
              .quotaFont(.listSecondary)
              .foregroundStyle(QuotaPalette.critical)
              .frame(
                minWidth: QuotaDesign.Layout.minimumInteractiveDimension,
                minHeight: QuotaDesign.Layout.minimumInteractiveDimension
              )
            }
            .buttonStyle(.plain)
            .disabled(model.isLoggingOut)
            .accessibilityLabel(model.isLoggingOut ? "Logging out" : "Log Out")
          }

        case .logoutPending:
          accountAction(
            message: "Logout is pending and will finish when this Mac is online.",
            title: model.isLoggingOut ? "Retrying…" : "Retry Logout",
            isEnabled: !model.isLoggingOut,
            isCompact: true
          ) {
            Task { await model.logout() }
          }

        case .notChecked, .signedOut:
          if model.isLoggingIn {
            accountAction(
              message: "Finish signing in with GitHub in your browser.",
              title: "Cancel",
              action: model.cancelLogin
            )
          } else {
            accountAction(
              message: signedOutMessage,
              title: "Continue with GitHub",
              isCompact: true,
              action: model.startLogin
            )
          }
        }

        settingsLinkRow(
          title: "Manage account",
          systemImage: "globe",
          url: AppMetadata.accountURL
        )

        if let accountErrorMessage = model.accountErrorMessage {
          Label(accountErrorMessage, systemImage: "exclamationmark.circle")
            .quotaMetaStyle()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
            .padding(.bottom, QuotaDesign.Layout.groupContentInset)
        }
      }
    }
  }

  private var signedOutMessage: String {
    "Sync quota and Usage across your devices."
  }

  private var usageSummary: String {
    guard let report = model.localUsage, report.status != .unavailable,
      let totals = report.totals
    else { return "Unavailable" }
    return "\(UsageValueFormatter.count(totals.inputTokens + totals.outputTokens)) tokens"
  }

  private var agentsSummary: String {
    let visible = ProviderID.allCases.filter { ProviderVisibility.isVisible($0) }.count
    let total = ProviderID.allCases.count
    return visible == total ? "\(total)" : "\(visible)/\(total)"
  }

  private func accountAction(
    message: String,
    title: String,
    isEnabled: Bool = true,
    isCompact: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Text(message)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)

      Button(title, action: action)
        .buttonStyle(QuotaPrimaryButtonStyle(isCompact: isCompact))
        .disabled(!isEnabled)
    }
    .padding(QuotaDesign.Layout.groupContentInset)
    .frame(maxWidth: .infinity, alignment: .leading)
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
