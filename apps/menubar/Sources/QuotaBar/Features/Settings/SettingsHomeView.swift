import QuotaWire
import SwiftUI

struct SettingsHomeView: View {
  @Bindable var model: MenuBarViewModel
  let onOpenAccount: () -> Void
  let onOpenAgents: () -> Void
  let onOpenUsage: () -> Void
  let onOpenMenuBarStyle: () -> Void
  let onOpenMenuBarProvider: () -> Void
  let onOpenSupport: () -> Void

  @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
  @AppStorage(MenuBarStylePreference.storageKey) private var menuBarStyle =
    MenuBarStylePreference.fallback
  @AppStorage(MenuBarProviderPreference.storageKey) private var menuBarProvider =
    MenuBarProviderPreference.fallback

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        accountSection

        if let accountErrorMessage = model.accountErrorMessage,
          accountErrorMessage != signedOutMessage
        {
          Label(accountErrorMessage, systemImage: "exclamationmark.circle")
            .quotaMetaStyle()
            .fixedSize(horizontal: false, vertical: true)
        }

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
              trailing: agentsSummary,
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
              trailing: menuBarStyle.label,
              accessibilityLabel: MenuBarRoute.menuBarStyle.title,
              action: onOpenMenuBarStyle
            )
            settingsDestinationRow(
              title: "Provider",
              systemImage: "chart.bar.doc.horizontal",
              trailing: menuBarProvider.label,
              accessibilityLabel: MenuBarRoute.menuBarProvider.title,
              action: onOpenMenuBarProvider
            )
          }
        }

        SettingsSection(title: "General") {
          VStack(alignment: .leading, spacing: 0) {
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
            settingsDestinationRow(
              title: "Support",
              systemImage: "questionmark.circle",
              trailing: AppMetadata.versionLabel,
              accessibilityLabel: "Support",
              action: onOpenSupport
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .onAppear { launchAtLoginEnabled = LaunchAtLoginController.isEnabled }
  }

  @ViewBuilder
  private var accountSection: some View {
    SettingsSection(title: "Account") {
      VStack(alignment: .leading, spacing: 0) {
        switch model.accountState {
        case .signedIn:
          settingsDestinationRow(
            title: model.accountDisplayLabel,
            systemImage: "person.crop.circle.fill",
            accessibilityLabel: "Account, \(model.accountDisplayLabel)",
            action: onOpenAccount
          )

        case .logoutPending:
          SettingsListRow(title: "Logout Pending", systemImage: "wifi.slash") {
            Button {
              Task { await model.logout() }
            } label: {
              if model.isLoggingOut {
                ProgressView().controlSize(.small)
              } else {
                Text("Retry Logout")
                  .quotaFont(.listSecondary)
              }
            }
            .buttonStyle(.plain)
            .disabled(model.isLoggingOut)
            .accessibilityLabel(model.isLoggingOut ? "Retrying logout" : "Retry Logout")
          }
          .accessibilityHint("Logout will finish when this Mac is online")

        case .notChecked, .signedOut:
          if model.isLoggingIn {
            SettingsListRow(title: "Finish sign-in in browser", systemImage: "person.crop.circle") {
              Button("Cancel", action: model.cancelLogin)
                .quotaFont(.listSecondary)
                .buttonStyle(.plain)
            }
          } else {
            Button(action: model.startLogin) {
              SettingsListRow(
                title: "Sign In",
                systemImage: "person.crop.circle.badge.plus"
              ) {
                Image(systemName: "chevron.right")
                  .quotaChevronStyle()
              }
            }
            .buttonStyle(QuotaListRowButtonStyle())
            .accessibilityLabel("Sign In")
            .accessibilityHint(signedOutMessage)
          }
        }
      }
    }
  }

  private var signedOutMessage: String {
    switch model.accountDisconnectReason {
    case .deviceDeleted:
      "This device was removed. Sign in again to reconnect it."
    case .sessionEnded:
      "The account session ended. Sign in again to continue syncing."
    case nil:
      "Sync quota and Usage across your devices."
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

  private var agentsSummary: String {
    let visible = ProviderID.allCases.filter { ProviderVisibility.isVisible($0) }.count
    let total = ProviderID.allCases.count
    return visible == total ? "\(total)" : "\(visible)/\(total)"
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
    trailing: String = "",
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      SettingsListRow(title: title, systemImage: systemImage) {
        HStack(spacing: QuotaDesign.Spacing.xxs) {
          if !trailing.isEmpty {
            Text(trailing)
              .quotaListSecondaryStyle()
              .lineLimit(1)
          }
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }
      }
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(trailing)
  }

}
