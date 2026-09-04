import QuotaWire
import SwiftUI

/// Settings → Quota → Notifications: local remaining-quota rules this Mac evaluates itself.
struct NotificationsSettingsView: View {
  @Bindable var model: MenuBarViewModel
  @State private var expandedMenu: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Notifications") {
          VStack(alignment: .leading, spacing: 0) {
            settingsToggleRow(
              title: "Notifications",
              systemImage: "bell",
              isOn: Binding(
                get: { model.notificationRules.enabled },
                set: { desired in Task { await model.setNotificationsEnabled(desired) } }
              ),
              accessibilityLabel: "Notifications",
              accessibilityHint: "Allow QuotaBar to send quota reminders"
            )
            settingsToggleRow(
              title: "Reset reminders",
              systemImage: "arrow.counterclockwise",
              isOn: Binding(
                get: { model.notificationRules.resetReminders },
                set: { model.setResetReminders($0) }
              ),
              accessibilityLabel: "Reset reminders",
              accessibilityHint: "Notify when a quota window refills"
            )
            if model.notificationAuthorizationDenied {
              permissionDeniedRows
            }
          }
        }

        ForEach(model.notificationSubscriptions()) { subscription in
          subscriptionGroup(subscription)
        }

        Text(NotificationsSettingsCopy.footer)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .task { await model.refreshNotificationAuthorization() }
  }

  private var permissionDeniedRows: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text(NotificationsSettingsCopy.permissionDenied)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
      Button(NotificationsSettingsCopy.openSystemSettings) {
        model.openNotificationSystemSettings()
      }
      .buttonStyle(QuotaSecondaryButtonStyle())
      .accessibilityLabel(NotificationsSettingsCopy.openSystemSettings)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func subscriptionGroup(_ subscription: NotificationSettingsSubscription) -> some View {
    SettingsSection(title: subscription.providerDisplayName) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsListRow(
          title: subscription.accountLabel,
          leading: {
            ProviderBrandIcon(
              provider: subscription.provider,
              size: QuotaDesign.Layout.settingsIconColumnWidth
            )
          },
          trailing: { EmptyView() }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(subscription.providerDisplayName), \(subscription.accountLabel)"
        )

        thresholdRow(
          title: NotificationsSettingsCopy.alertAt,
          subscription: subscription,
          slot: .first
        )
        thresholdRow(
          title: NotificationsSettingsCopy.thenAt,
          subscription: subscription,
          slot: .second
        )
      }
    }
  }

  private enum ThresholdSlot {
    case first
    case second
  }

  private func thresholdRow(
    title: String,
    subscription: NotificationSettingsSubscription,
    slot: ThresholdSlot
  ) -> some View {
    let menuID = "\(subscription.selector).\(slot == .first ? "first" : "second")"
    let selected: Int? = slot == .first ? subscription.firstThreshold : subscription.secondThreshold
    let valueTitle =
      selected.map(NotificationsSettingsCopy.thresholdLabel) ?? NotificationsSettingsCopy.off
    return SettingsListRow(title: title, systemImage: "percent") {
      QuotaChoiceMenu(
        valueTitle: valueTitle,
        options: thresholdOptions(slot: slot, first: subscription.firstThreshold),
        selectedPin: selected.map(String.init) ?? "off",
        isExpanded: expandedBinding(menuID),
        onSelect: { pin in
          applyThreshold(pin, slot: slot, selector: subscription.selector)
        },
        accessibilityTitle: title,
        accessibilityHint: valueTitle
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  private func thresholdOptions(
    slot: ThresholdSlot,
    first: Int
  ) -> [QuotaChoiceMenuOption] {
    var options: [QuotaChoiceMenuOption] = []
    if slot == .second {
      options.append(QuotaChoiceMenuOption(pin: "off", title: NotificationsSettingsCopy.off))
    }
    for value in NotificationRules.thresholdChoices {
      if slot == .second, value >= first { continue }
      options.append(
        QuotaChoiceMenuOption(
          pin: String(value),
          title: NotificationsSettingsCopy.thresholdLabel(value)
        )
      )
    }
    return options
  }

  private func applyThreshold(_ pin: String?, slot: ThresholdSlot, selector: String) {
    switch slot {
    case .first:
      guard let pin, let value = Int(pin) else { return }
      model.setNotificationFirstThreshold(value, for: selector)
    case .second:
      if pin == nil || pin == "off" {
        model.setNotificationSecondThreshold(nil, for: selector)
      } else if let pin, let value = Int(pin) {
        model.setNotificationSecondThreshold(value, for: selector)
      }
    }
  }

  private func expandedBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { expandedMenu == id },
      set: { expandedMenu = $0 ? id : (expandedMenu == id ? nil : expandedMenu) }
    )
  }
}
