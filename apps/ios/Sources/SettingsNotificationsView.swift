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
    .quotaTabBarClearance()
    .contentMargins(.bottom, QuotaTheme.tabBarClearance + 120, for: .scrollContent)
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
      Text(SettingsCopy.footer)
        .font(.body)
        .foregroundStyle(Color(uiColor: .label))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func subscriptionSection(_ row: SettingsNotificationSubscription) -> some View {
    Section {
      BodyLabel(text: row.providerDisplayName, style: .subheadline, weight: .semibold)
        .accessibilityAddTraits(.isHeader)
      BodyLabel(text: row.accountLabel, style: .body)
        .accessibilityLabel("\(row.providerDisplayName), \(row.accountLabel)")

      HStack {
        BodyLabel(text: SettingsCopy.alertAt)
        Spacer(minLength: 8)
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
        .labelsHidden()
        .accessibilityLabel(SettingsCopy.alertAt)
      }

      HStack {
        BodyLabel(text: SettingsCopy.thenAt)
        Spacer(minLength: 8)
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
        .labelsHidden()
        .accessibilityLabel(SettingsCopy.thenAt)
      }
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
