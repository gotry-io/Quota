import QuotaWire
import SwiftUI

struct SettingsHomeView: View {
  @Bindable var model: MenuBarViewModel
  let onOpenAgents: () -> Void
  let onOpenDevices: () -> Void
  let onOpenUsage: () -> Void
  let onOpenSupport: () -> Void
  let onRequestLogout: () -> Void

  @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
  @AppStorage(MenuBarDisplayPreference.storageKey) private var menuBarDisplay =
    MenuBarDisplayPreference.fallback

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

        SettingsSection(title: "General") {
          VStack(alignment: .leading, spacing: 0) {
            menuBarDisplayRow
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
            settingsToggleRow(
              title: "Sync Usage",
              systemImage: "arrow.triangle.2.circlepath",
              isOn: Binding(
                get: { model.usageUploadEnabled },
                set: { desired in
                  Task { await model.setUsageUploadEnabled(desired) }
                }
              ),
              isEnabled: !model.isUpdatingUsageUpload,
              accessibilityLabel: "Sync Usage",
              accessibilityHint: "Upload this Mac's Usage to your Quota account"
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

        if model.accountState == .signedIn {
          logoutRow
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
          VStack(spacing: 0) {
            settingsExternalLinkRow(
              title: model.accountDisplayLabel,
              systemImage: "person.crop.circle.fill",
              url: AppMetadata.accountURL
            )
            settingsDestinationRow(
              title: "Devices",
              systemImage: "laptopcomputer.and.iphone",
              trailing: model.accountDeviceSummary,
              accessibilityLabel: "Devices",
              action: onOpenDevices
            )
          }

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

  /// The menu-bar item is the product's first sentence, so what it says is a setting rather
  /// than a fixed choice. The compact menu matches the Usage source control's treatment.
  private var menuBarDisplayRow: some View {
    SettingsListRow(title: "Menu Bar Display", systemImage: "menubar.rectangle") {
      Menu {
        Picker("Menu Bar Display", selection: $menuBarDisplay) {
          ForEach(MenuBarDisplayPreference.allCases) { option in
            Text(option.label).tag(option)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        HStack(spacing: QuotaDesign.Spacing.xxs) {
          Text(menuBarDisplay.label)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
        .quotaFont(.meta)
        .foregroundStyle(QuotaPalette.body)
        .padding(.horizontal, QuotaDesign.Spacing.xs)
        .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
        .background {
          RoundedRectangle(cornerRadius: QuotaDesign.Layout.rowCornerRadius, style: .continuous)
            .fill(QuotaPalette.fieldFill)
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Menu Bar Display")
      .accessibilityValue(menuBarDisplay.label)
    }
    .accessibilityHint("What the QuotaBar menu-bar item shows")
  }

  private var logoutRow: some View {
    Button {
      onRequestLogout()
    } label: {
      HStack(spacing: QuotaDesign.Spacing.sm) {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .quotaFont(.secondary)
          .foregroundStyle(QuotaPalette.critical)
          .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        Text(model.isLoggingOut ? "Logging Out…" : "Log Out")
          .quotaFont(.settingsLabel)
          .foregroundStyle(QuotaPalette.critical)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.settingsRowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .quotaGroupSurface()
    .disabled(model.isLoggingOut)
    .accessibilityLabel(model.isLoggingOut ? "Logging out" : "Log Out")
    .accessibilityHint("Shows a confirmation")
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
      totalTokens = model.accountSummary.map { UsageSummaryTotals($0.usage.totals).totalTokens }
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
    isEnabled: Bool = true,
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
    .disabled(!isEnabled)
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

}
