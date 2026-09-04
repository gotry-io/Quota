import SwiftUI

struct SettingsNotificationsView: View {
  @Bindable var model: AppModel
  @Bindable var settings: SettingsModel

  var body: some View {
    Form {
      masterSection
      ForEach(notificationRows) { row in
        subscriptionSection(row)
      }
    }
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("settings.notifications.root")
    .navigationTitle(SettingsCopy.notifications)
    .task { await settings.refreshAuthorization() }
  }

  private var notificationRows: [SettingsNotificationSubscription] {
    settings.notificationSubscriptions(from: model.summary?.subscriptions ?? [])
  }

  private var masterSection: some View {
    Section {
      Toggle(
        SettingsCopy.enableNotifications,
        isOn: Binding(
          get: { settings.rules.enabled },
          set: { desired in Task { await settings.setNotificationsEnabled(desired) } }
        )
      )
      .accessibilityLabel(SettingsCopy.enableNotifications)
      .accessibilityHint("Allow Quota to send quota reminders")
      .accessibilityIdentifier("settings.notifications.enable")

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

      if notificationRows.isEmpty {
        Text(SettingsCopy.emptyAlerts)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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
