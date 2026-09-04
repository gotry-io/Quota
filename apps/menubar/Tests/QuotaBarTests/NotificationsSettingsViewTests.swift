import Foundation
import QuotaWire
import Testing
import UserNotifications

@testable import QuotaBar

struct NotificationsSettingsViewTests {
  @Test func thresholdChoicesMatchTheDocumentedSetAndSecondSlotMayBeOff() {
    #expect(NotificationRules.thresholdChoices == [5, 10, 15, 20, 25, 30, 40, 50])
    #expect(NotificationsSettingsCopy.off == "Off")
    #expect(NotificationsSettingsCopy.alertAt == "Alert at")
    #expect(NotificationsSettingsCopy.thenAt == "Then at")
    #expect(NotificationsSettingsCopy.footer == "Quota reminds you when a refresh brings new data.")
    #expect(
      NotificationsSettingsCopy.permissionDenied
        == "Allow notifications for QuotaBar in System Settings."
    )
    #expect(NotificationsSettingsCopy.openSystemSettings == "Open System Settings")
    #expect(
      NotificationsSettingsCopy.systemSettingsURL.absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )
    #expect(NotificationsSettingsCopy.homeTrailing(enabled: true) == "On")
    #expect(NotificationsSettingsCopy.homeTrailing(enabled: false) == "Off")
    #expect(NotificationsSettingsCopy.thresholdLabel(20) == "20%")
  }

  @Test @MainActor
  func pageListsOverviewSubscriptionsWithDefaultThresholds() {
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let now = Date(timeIntervalSince1970: 1_786_300_000)
    let model = MenuBarViewModel(
      client: StubLocalService(state: loggingInState()),
      notificationDefaults: defaults.store
    )
    model.apply(overviewOnlyState(overview: [codexOverviewItem(remainingPercent: 80, now: now)]))

    let rows = model.notificationSubscriptions()
    #expect(rows.count == 1)
    #expect(rows[0].providerDisplayName == "Codex")
    #expect(rows[0].accountLabel == "Account 1")
    #expect(rows[0].firstThreshold == 20)
    #expect(rows[0].secondThreshold == 10)
    #expect(!model.notificationRules.enabled)
    #expect(model.notificationRules.resetReminders)
  }

  @Test @MainActor
  func secondThresholdOffStoresASingleThreshold() {
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let now = Date(timeIntervalSince1970: 1_786_300_000)
    let item = codexOverviewItem(remainingPercent: 80, now: now)
    let model = MenuBarViewModel(
      client: StubLocalService(state: loggingInState()),
      notificationDefaults: defaults.store
    )
    model.apply(overviewOnlyState(overview: [item]))
    let selector = NotificationOverview.selector(for: item)

    model.setNotificationSecondThreshold(nil, for: selector)
    #expect(model.notificationRules.thresholds(for: selector) == [20])
    #expect(model.notificationSubscriptions()[0].secondThreshold == nil)

    model.setNotificationFirstThreshold(15, for: selector)
    model.setNotificationSecondThreshold(5, for: selector)
    #expect(model.notificationRules.thresholds(for: selector) == [15, 5])
    #expect(model.notificationSubscriptions()[0].firstThreshold == 15)
    #expect(model.notificationSubscriptions()[0].secondThreshold == 5)
  }

  @Test @MainActor
  func denyingAuthorizationTurnsTheSwitchBackOffAndShowsTheSystemSettingsRow() async {
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let center = FakeNotificationCenter()
    center.requestAuthorizationGranted = false
    let model = MenuBarViewModel(
      client: StubLocalService(state: loggingInState()),
      notificationCenter: center,
      notificationDefaults: defaults.store
    )

    await model.setNotificationsEnabled(true)

    #expect(!model.notificationRules.enabled)
    #expect(model.notificationAuthorizationDenied)
    #expect(center.requestedOptions == [.alert, .sound])
    #expect(NotificationsSettingsCopy.homeTrailing(enabled: model.notificationRules.enabled) == "Off")
  }

  @Test @MainActor
  func grantingAuthorizationTurnsTheSwitchOn() async {
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let center = FakeNotificationCenter()
    center.requestAuthorizationGranted = true
    let model = MenuBarViewModel(
      client: StubLocalService(state: loggingInState()),
      notificationCenter: center,
      notificationDefaults: defaults.store
    )

    await model.setNotificationsEnabled(true)

    #expect(model.notificationRules.enabled)
    #expect(!model.notificationAuthorizationDenied)
    #expect(NotificationsSettingsCopy.homeTrailing(enabled: true) == "On")
  }
}
