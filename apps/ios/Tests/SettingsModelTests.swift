import Foundation
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import Testing
import UserNotifications

@testable import Quota

@MainActor
struct SettingsModelTests {
  @Test func invalidThresholdsAreIgnoredAndSecondOffStoresASingleValue() {
    let defaults = isolatedSettingsDefaults()
    defer { defaults.tearDown() }
    let model = SettingsModel(
      rulesStore: AlertCoordinator.rulesStore(defaults: defaults.store),
      notificationCenter: FakeNotificationAuthorizer(),
      appearanceDefaults: defaults.store
    )
    let selector = "codex_acct"

    #expect(model.rules.thresholds(for: selector) == [20, 10])

    model.setFirstThreshold(3, for: selector)
    #expect(model.rules.thresholds(for: selector) == [20, 10])

    model.setFirstThreshold(15, for: selector)
    #expect(model.rules.thresholds(for: selector) == [15, 10])

    model.setSecondThreshold(99, for: selector)
    #expect(model.rules.thresholds(for: selector) == [15, 10])

    model.setSecondThreshold(15, for: selector)
    #expect(model.rules.thresholds(for: selector) == [15, 10])

    model.setSecondThreshold(nil, for: selector)
    #expect(model.rules.thresholds(for: selector) == [15])

    model.setSecondThreshold(5, for: selector)
    #expect(model.rules.thresholds(for: selector) == [15, 5])

    model.setFirstThreshold(5, for: selector)
    #expect(model.rules.thresholds(for: selector) == [5])

    let reloaded = AlertCoordinator.rulesStore(defaults: defaults.store).load()
    #expect(reloaded.thresholds(for: selector) == [5])
  }

  @Test func appearancePersistsAndUnknownValuesFallBackToSystem() {
    let defaults = isolatedSettingsDefaults()
    defer { defaults.tearDown() }

    #expect(AppearancePreference.load(from: defaults.store) == .system)

    AppearancePreference.dark.save(to: defaults.store)
    #expect(AppearancePreference.load(from: defaults.store) == .dark)
    #expect(defaults.store.string(forKey: AppearancePreference.storageKey) == "dark")

    let model = SettingsModel(
      rulesStore: AlertCoordinator.rulesStore(defaults: defaults.store),
      notificationCenter: FakeNotificationAuthorizer(),
      appearanceDefaults: defaults.store
    )
    #expect(model.appearance == .dark)
    model.setAppearance(.light)
    #expect(model.appearance == .light)
    #expect(AppearancePreference.load(from: defaults.store) == .light)
    #expect(AppearancePreference.light.colorScheme == .light)
    #expect(AppearancePreference.dark.colorScheme == .dark)
    #expect(AppearancePreference.system.colorScheme == nil)

    defaults.store.set("sepia", forKey: AppearancePreference.storageKey)
    #expect(AppearancePreference.load(from: defaults.store) == .system)
  }

  @Test func deleteAccountStartEncodesReturnToSoTheQueryDoesNotSplit() {
    let url = QuotaWebLinks.signInURL(returnTo: "/my/settings?delete=account")
    // Re-authenticating goes through the page that asks which Account this is, not through one
    // channel's round trip.
    #expect(
      url.absoluteString
        == "https://quota.gotry.io/sign-in?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount"
    )
    #expect(QuotaWebLinks.deleteAccountStart == url)
    #expect(QuotaWebLinks.deleteAccountReturnTo == "/my/settings?delete=account")
  }

  /// The Enable Notifications switch is what the system answered, not what was tapped: a denial
  /// turns it back off and says so, and a grant turns it on and keeps it on across a relaunch.
  @Test func theNotificationSwitchFollowsWhatTheSystemAnswers() async {
    let defaults = isolatedSettingsDefaults()
    defer { defaults.tearDown() }
    let center = FakeNotificationAuthorizer()
    center.requestAuthorizationGranted = false
    let model = SettingsModel(
      rulesStore: AlertCoordinator.rulesStore(defaults: defaults.store),
      notificationCenter: center,
      appearanceDefaults: defaults.store
    )

    await model.setNotificationsEnabled(true)

    #expect(!model.rules.enabled)
    #expect(model.authorizationDenied)
    #expect(center.requestedOptions == [.alert, .sound])

    center.requestAuthorizationGranted = true
    await model.setNotificationsEnabled(true)

    #expect(model.rules.enabled)
    #expect(!model.authorizationDenied)
    let reloaded = AlertCoordinator.rulesStore(defaults: defaults.store).load()
    #expect(reloaded.enabled)
  }
}

@MainActor
final class FakeNotificationAuthorizer: NotificationAuthorizing, @unchecked Sendable {
  var requestAuthorizationGranted = false
  var status: UNAuthorizationStatus = .notDetermined
  var requestedOptions: UNAuthorizationOptions?

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    requestedOptions = options
    status = requestAuthorizationGranted ? .authorized : .denied
    return requestAuthorizationGranted
  }

  func authorizationStatus() async -> UNAuthorizationStatus { status }
}

private struct IsolatedSettingsDefaults {
  let name: String
  let store: UserDefaults

  func tearDown() {
    store.removePersistentDomain(forName: name)
  }
}

private func isolatedSettingsDefaults() -> IsolatedSettingsDefaults {
  let name = "QuotaTests.Settings.\(UUID().uuidString)"
  let store = UserDefaults(suiteName: name)!
  store.removePersistentDomain(forName: name)
  return IsolatedSettingsDefaults(name: name, store: store)
}
