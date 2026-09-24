import Foundation
import QuotaWire
import Testing
import UserNotifications

@testable import QuotaBar

struct NotificationsSettingsViewTests {
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
  func theSwitchIsOnOnlyWhenTheSystemGrantsNotifications() async {
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let denying = FakeNotificationCenter()
    denying.requestAuthorizationGranted = false
    let denied = MenuBarViewModel(
      client: StubLocalService(state: loggingInState()),
      notificationCenter: denying,
      notificationDefaults: defaults.store
    )

    await denied.setNotificationsEnabled(true)

    #expect(!denied.notificationRules.enabled)
    #expect(denied.notificationAuthorizationDenied)
    #expect(denying.requestedOptions == [.alert, .sound])

    let grantedDefaults = notificationDefaultsSuite()
    defer { grantedDefaults.tearDown() }
    let granting = FakeNotificationCenter()
    granting.requestAuthorizationGranted = true
    let granted = MenuBarViewModel(
      client: StubLocalService(state: loggingInState()),
      notificationCenter: granting,
      notificationDefaults: grantedDefaults.store
    )

    await granted.setNotificationsEnabled(true)

    #expect(granted.notificationRules.enabled)
    #expect(!granted.notificationAuthorizationDenied)
  }
}
