import QuotaPresentation
import QuotaWire
import SwiftUI

/// Main window → Settings → Notifications: remaining-quota rules this Mac evaluates. Policy
/// follows the Account when signed in; delivery and the master switch stay on this Mac.
struct NotificationsSettingsView: View {
  @Bindable var model: MenuBarViewModel
  /// The amount as it is being typed, which is only a budget once it parses.
  @State private var budgetDraft = ""

  var body: some View {
    Form {
      Section {
        Toggle(
          "Notifications",
          isOn: Binding(
            get: { model.notificationRules.enabled },
            set: { desired in Task { await model.setNotificationsEnabled(desired) } }
          )
        )
        .accessibilityLabel("Notifications")
        .accessibilityHint("Allow QuotaBar to send quota reminders")

        Toggle(
          "Reset reminders",
          isOn: Binding(
            get: { model.notificationRules.resetReminders },
            set: { model.setResetReminders($0) }
          )
        )
        .accessibilityLabel("Reset reminders")
        .accessibilityHint("Notify when a quota window refills")

        Toggle(
          "Pace warnings",
          isOn: Binding(
            get: { model.notificationRules.paceAlerts },
            set: { model.setPaceAlerts($0) }
          )
        )
        .accessibilityLabel("Pace warnings")
        .accessibilityHint("Notify when a window stops lasting to its reset")

        if model.notificationAuthorizationDenied {
          Text(NotificationsSettingsCopy.permissionDenied)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(NotificationsSettingsCopy.openSystemSettings) {
            model.openNotificationSystemSettings()
          }
          .accessibilityLabel(NotificationsSettingsCopy.openSystemSettings)
        }
      }

      budgetSection

      ForEach(model.notificationSubscriptions()) { subscription in
        subscriptionSection(subscription)
      }

      Section {
        EmptyView()
      } footer: {
        Text(NotificationsSettingsCopy.footer)
      }
    }
    .formStyle(.grouped)
    .quotaSettingsColumn()
    .task { await model.refreshNotificationAuthorization() }
    .onAppear { budgetDraft = model.usage.budget.amountUSD.map(UsageBudgetProgress.plain) ?? "" }
  }

  /// The monthly spend budget. Signed in it follows the Account; signed out it stays on this Mac.
  private var budgetSection: some View {
    SwiftUI.Section {
      TextField("Amount (USD)", text: $budgetDraft, prompt: Text("No budget"))
        .onSubmit(applyBudgetAmount)
        .accessibilityLabel("Monthly budget amount in US dollars")
      Button("Save", action: applyBudgetAmount)
      Toggle(
        "Budget alerts",
        isOn: Binding(
          get: { model.usage.budget.alerts },
          set: {
            model.usage.setBudget(UsageBudget(amountUSD: model.usage.budget.amountUSD, alerts: $0))
          }
        )
      )
      .accessibilityLabel("Budget alerts")
      .accessibilityHint("Notify at 80% and 100% of the monthly budget")
    } header: {
      Text("Monthly budget")
    } footer: {
      Text(NotificationsSettingsCopy.budgetFooter(signedIn: model.accountFlow.hasAccountSession))
    }
  }

  /// An amount that is not a positive number under the maximum clears the budget rather than
  /// setting one of zero, and the field is rewritten to say so.
  private func applyBudgetAmount() {
    let amount = UsageBudget.normalized(
      Decimal(string: budgetDraft.trimmingCharacters(in: .whitespaces), locale: .current)
    )
    model.usage.setBudget(UsageBudget(amountUSD: amount, alerts: model.usage.budget.alerts))
    budgetDraft = amount.map(UsageBudgetProgress.plain) ?? ""
  }

  private func subscriptionSection(_ subscription: NotificationSettingsSubscription) -> some View {
    Section {
      LabeledContent {
        EmptyView()
      } label: {
        Label {
          Text(subscription.accountLabel)
        } icon: {
          ProviderBrandIcon(
            provider: subscription.provider,
            size: QuotaDesign.Layout.settingsIconColumnWidth
          )
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "\(subscription.providerDisplayName), \(subscription.accountLabel)"
      )

      Picker(
        NotificationsSettingsCopy.alertAt,
        selection: Binding(
          get: { subscription.firstThreshold },
          set: { model.setNotificationFirstThreshold($0, for: subscription.selector) }
        )
      ) {
        ForEach(NotificationRules.thresholdChoices, id: \.self) { value in
          Text(NotificationsSettingsCopy.thresholdLabel(value)).tag(value)
        }
      }
      .accessibilityLabel(NotificationsSettingsCopy.alertAt)

      Picker(
        NotificationsSettingsCopy.thenAt,
        selection: Binding(
          get: { subscription.secondThreshold.map(String.init) ?? "off" },
          set: { pin in applySecondThreshold(pin, selector: subscription.selector) }
        )
      ) {
        Text(NotificationsSettingsCopy.off).tag("off")
        ForEach(
          NotificationRules.thresholdChoices.filter { $0 < subscription.firstThreshold },
          id: \.self
        ) { value in
          Text(NotificationsSettingsCopy.thresholdLabel(value)).tag(String(value))
        }
      }
      .accessibilityLabel(NotificationsSettingsCopy.thenAt)
    } header: {
      Text(subscription.providerDisplayName)
    }
  }

  private func applySecondThreshold(_ pin: String, selector: String) {
    if pin == "off" {
      model.setNotificationSecondThreshold(nil, for: selector)
    } else if let value = Int(pin) {
      model.setNotificationSecondThreshold(value, for: selector)
    }
  }
}
