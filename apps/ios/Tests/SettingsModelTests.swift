import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import Testing
import UserNotifications

@testable import Quota

@MainActor
struct SettingsModelTests {
  @Test func thresholdChoicesAreTheDocumentedSetAndSecondSlotMayBeOff() {
    #expect(SettingsModel.thresholdChoices == [5, 10, 15, 20, 25, 30, 40, 50])
    #expect(SettingsCopy.off == "Off")
    #expect(SettingsCopy.alertAt == "Alert at")
    #expect(SettingsCopy.thenAt == "Then at")
    #expect(SettingsCopy.footer == "Quota reminds you when a refresh brings new data.")
    #expect(SettingsCopy.permissionDenied == "Allow notifications for Quota in Settings.")
    #expect(SettingsCopy.openSettings == "Open Settings")
    #expect(SettingsCopy.thresholdLabel(20) == "20%")
    #expect(SettingsModel.isValidThreshold(20))
    #expect(!SettingsModel.isValidThreshold(3))
    #expect(!SettingsModel.isValidThreshold(99))
    #expect(SettingsModel.secondThresholdChoices(first: 20) == [5, 10, 15])
    #expect(SettingsModel.secondThresholdChoices(first: 5).isEmpty)
  }

  @Test func invalidThresholdsAreIgnoredAndSecondOffStoresASingleValue() {
    let defaults = isolatedSettingsDefaults()
    defer { defaults.tearDown() }
    let model = SettingsModel(
      rulesStore: IOSAlertRulesStore(defaults: defaults.store),
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

    let reloaded = IOSAlertRulesStore(defaults: defaults.store).load()
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
      rulesStore: IOSAlertRulesStore(defaults: defaults.store),
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
    let url = QuotaWebLinks.githubStartURL(returnTo: "/my/settings?delete=account")
    #expect(
      url.absoluteString
        == "https://quota.gotry.io/api/auth/github/start?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount"
    )
    #expect(QuotaWebLinks.deleteAccountStart == url)
    #expect(QuotaWebLinks.deleteAccountReturnTo == "/my/settings?delete=account")
  }

  @Test func versionLabelIsShortVersionAndBuild() {
    #expect(SettingsCopy.versionLabel(shortVersion: "0.0.1", build: "1") == "0.0.1 (1)")
    #expect(SettingsCopy.licenses == "Licenses: MIT")
  }

  @Test func subscriptionsUseCatalogOrderMaskedLabelsAndDefaultThresholds() {
    let defaults = isolatedSettingsDefaults()
    defer { defaults.tearDown() }
    let model = SettingsModel(
      rulesStore: IOSAlertRulesStore(defaults: defaults.store),
      notificationCenter: FakeNotificationAuthorizer(),
      appearanceDefaults: defaults.store
    )
    let now = Date(timeIntervalSince1970: 1_786_723_200)
    let grok = testSubscription(
      provider: .grok,
      fingerprint: "visual_grok",
      label: nil,
      observedAt: now
    )
    let codex = testSubscription(
      provider: .codex,
      fingerprint: "visual_codex",
      label: "pe***@example.com",
      observedAt: now
    )
    let claude = testSubscription(
      provider: .claude,
      fingerprint: "visual_claude",
      label: "Team workspace",
      observedAt: now
    )

    let rows = model.notificationSubscriptions(from: [grok, claude, codex])
    #expect(rows.map(\.provider) == [.codex, .claude, .grok])
    #expect(rows.map(\.providerDisplayName) == ["Codex", "Claude Code", "Grok"])
    #expect(rows.map(\.accountLabel) == ["pe***@example.com", "Team workspace", "Account 1"])
    #expect(rows.allSatisfy { $0.firstThreshold == 20 && $0.secondThreshold == 10 })
    #expect(rows[0].selector == SettingsModel.selector(for: codex))
    #expect(!model.rules.enabled)
    #expect(model.rules.resetReminders)
  }

  @Test func denyingAuthorizationTurnsTheSwitchBackOff() async {
    let defaults = isolatedSettingsDefaults()
    defer { defaults.tearDown() }
    let center = FakeNotificationAuthorizer()
    center.requestAuthorizationGranted = false
    let model = SettingsModel(
      rulesStore: IOSAlertRulesStore(defaults: defaults.store),
      notificationCenter: center,
      appearanceDefaults: defaults.store
    )

    await model.setNotificationsEnabled(true)

    #expect(!model.rules.enabled)
    #expect(model.authorizationDenied)
    #expect(center.requestedOptions == [.alert, .sound])
  }

  @Test func grantingAuthorizationTurnsTheSwitchOn() async {
    let defaults = isolatedSettingsDefaults()
    defer { defaults.tearDown() }
    let center = FakeNotificationAuthorizer()
    center.requestAuthorizationGranted = true
    let model = SettingsModel(
      rulesStore: IOSAlertRulesStore(defaults: defaults.store),
      notificationCenter: center,
      appearanceDefaults: defaults.store
    )

    await model.setNotificationsEnabled(true)

    #expect(model.rules.enabled)
    #expect(!model.authorizationDenied)
    let reloaded = IOSAlertRulesStore(defaults: defaults.store).load()
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

private func testSubscription(
  provider: ProviderID,
  fingerprint: String,
  label: String?,
  observedAt: Date
) -> QuotaSubscription {
  let snapshot = QuotaSnapshot(
    provider: provider,
    account: QuotaAccount(
      fingerprint: fingerprint,
      label: label,
      fingerprintScope: .global
    ),
    windows: [],
    status: .available,
    observedAt: observedAt
  )
  return QuotaSubscription(
    key: "\(provider.rawValue)|\(fingerprint)|global|",
    provider: provider,
    snapshot: snapshot,
    sources: []
  )
}
