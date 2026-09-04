import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var settings = SettingsModel()
  @State private var confirmLogout = false
  @State private var promptSignOutAfterDelete = false

  var body: some View {
    Form {
      notificationsSection
      ForEach(notificationRows) { row in
        subscriptionSection(row)
      }
      appearanceSection
      aboutSection
      privacySection
      accountSection
    }
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("settings.root")
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.large)
    .task { await settings.refreshAuthorization() }
    .confirmationDialog(
      "Log out of Quota on this device?",
      isPresented: $confirmLogout,
      titleVisibility: .visible
    ) {
      Button("Log Out", role: .destructive) {
        Task { await model.logout() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The remote Account stays signed in on the website. This device forgets the session and saved overview."
      )
    }
    .alert(SettingsCopy.deleteAccountFollowUp, isPresented: $promptSignOutAfterDelete) {
      Button("OK", role: .cancel) {}
    }
  }

  private var notificationRows: [SettingsNotificationSubscription] {
    settings.notificationSubscriptions(from: model.summary?.subscriptions ?? [])
  }

  private var notificationsSection: some View {
    Section {
      Toggle(
        SettingsCopy.notifications,
        isOn: Binding(
          get: { settings.rules.enabled },
          set: { desired in Task { await settings.setNotificationsEnabled(desired) } }
        )
      )
      .accessibilityLabel(SettingsCopy.notifications)
      .accessibilityHint("Allow Quota to send quota reminders")
      .accessibilityIdentifier("settings.notifications")

      Toggle(
        SettingsCopy.resetReminders,
        isOn: Binding(
          get: { settings.rules.resetReminders },
          set: { settings.setResetReminders($0) }
        )
      )
      .accessibilityLabel(SettingsCopy.resetReminders)
      .accessibilityHint("Notify when a quota window refills")

      if settings.authorizationDenied {
        Text(SettingsCopy.permissionDenied)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Link(SettingsCopy.openSettings, destination: SettingsCopy.openSettingsURL)
          .accessibilityLabel(SettingsCopy.openSettings)
      }
    } footer: {
      Text(SettingsCopy.footer)
    }
  }

  private func subscriptionSection(_ row: SettingsNotificationSubscription) -> some View {
    Section {
      Text(row.accountLabel)
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(row.providerDisplayName), \(row.accountLabel)")

      Picker(
        SettingsCopy.alertAt,
        selection: Binding(
          get: { row.firstThreshold },
          set: { settings.setFirstThreshold($0, for: row.selector) }
        )
      ) {
        ForEach(SettingsModel.thresholdChoices, id: \.self) { value in
          Text(SettingsCopy.thresholdLabel(value)).tag(value)
        }
      }
      .accessibilityLabel(SettingsCopy.alertAt)

      Picker(
        SettingsCopy.thenAt,
        selection: Binding(
          get: { ThenThresholdChoice(row.secondThreshold) },
          set: { choice in
            settings.setSecondThreshold(choice.value, for: row.selector)
          }
        )
      ) {
        Text(SettingsCopy.off).tag(ThenThresholdChoice.off)
        ForEach(SettingsModel.secondThresholdChoices(first: row.firstThreshold), id: \.self) {
          value in
          Text(SettingsCopy.thresholdLabel(value)).tag(ThenThresholdChoice.value(value))
        }
      }
      .accessibilityLabel(SettingsCopy.thenAt)
    } header: {
      Text(row.providerDisplayName)
    }
  }

  private var appearanceSection: some View {
    Section(SettingsCopy.appearance) {
      Picker(
        SettingsCopy.appearance,
        selection: Binding(
          get: { settings.appearance },
          set: { settings.setAppearance($0) }
        )
      ) {
        ForEach(AppearancePreference.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel(SettingsCopy.appearance)
    }
  }

  private var aboutSection: some View {
    Section(SettingsCopy.about) {
      LabeledContent(SettingsCopy.version, value: SettingsCopy.bundleVersionLabel())
      Link(SettingsCopy.website, destination: QuotaWebLinks.website)
      Link(SettingsCopy.github, destination: QuotaWebLinks.githubRepository)
      Text(SettingsCopy.licenses)
    }
  }

  private var privacySection: some View {
    Section(SettingsCopy.privacyAndSupport) {
      Link(SettingsCopy.privacy, destination: QuotaWebLinks.privacy)
      Link(SettingsCopy.support, destination: QuotaWebLinks.support)
    }
  }

  private var accountSection: some View {
    Section {
      Link(SettingsCopy.manageDevices, destination: QuotaWebLinks.manageDevices)
      Button(SettingsCopy.deleteAccount, role: .destructive) {
        Task {
          await model.presentDeleteAccount()
          promptSignOutAfterDelete = true
        }
      }
      .accessibilityLabel(SettingsCopy.deleteAccount)
      Button(SettingsCopy.logOut, role: .destructive) {
        confirmLogout = true
      }
      .accessibilityLabel(SettingsCopy.logOut)
      .accessibilityIdentifier("settings.logout")
    } header: {
      Text(SettingsCopy.account)
    } footer: {
      Text(SettingsCopy.deleteAccountExplanation)
    }
  }
}

private enum ThenThresholdChoice: Hashable {
  case off
  case value(Int)

  init(_ value: Int?) {
    if let value {
      self = .value(value)
    } else {
      self = .off
    }
  }

  var value: Int? {
    switch self {
    case .off: nil
    case .value(let value): value
    }
  }
}
