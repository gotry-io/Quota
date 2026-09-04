import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import SwiftUI
import UIKit
import UserNotifications

/// The slice of `UNUserNotificationCenter` Settings uses to ask for alerts.
protocol NotificationAuthorizing: AnyObject, Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func authorizationStatus() async -> UNAuthorizationStatus
}

/// Production `UNUserNotificationCenter.current()`.
final class SystemNotificationAuthorizer: NotificationAuthorizing, @unchecked Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: options)
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }
}

enum SettingsCopy {
  static let notifications = "Notifications"
  static let resetReminders = "Reset reminders"
  static let footer = "Quota reminds you when a refresh brings new data."
  static let permissionDenied = "Allow notifications for Quota in Settings."
  static let openSettings = "Open Settings"
  static let openSettingsURL = URL(string: UIApplication.openSettingsURLString)!
  static let alertAt = "Alert at"
  static let thenAt = "Then at"
  static let off = "Off"
  static let appearance = "Appearance"
  static let about = "About"
  static let privacyAndSupport = "Privacy & Support"
  static let account = "Account"
  static let manageDevices = "Manage devices on the web"
  static let deleteAccount = "Delete Account…"
  static let deleteAccountExplanation =
    "Deletion happens on the website after you sign in again with GitHub."
  static let deleteAccountFollowUp = "If you deleted the Account, sign out here too."
  static let logOut = "Log Out"
  static let licenses = "Licenses: MIT"
  static let website = "quota.gotry.io"
  static let github = "GitHub"
  static let privacy = "Privacy"
  static let support = "Support"
  static let version = "Version"

  static func thresholdLabel(_ value: Int) -> String {
    RemainingQuotaFormat.percent(Double(value))
  }

  static func versionLabel(shortVersion: String?, build: String?) -> String {
    "\(shortVersion ?? "") (\(build ?? ""))"
  }

  static func bundleVersionLabel(
    bundle: Bundle = .main
  ) -> String {
    versionLabel(
      shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
  }
}

enum QuotaWebLinks {
  static let origin = "https://quota.gotry.io"
  static let website = URL(string: origin)!
  static let githubRepository = URL(string: "https://github.com/gotry-io/Quota")!
  static let privacy = URL(string: "\(origin)/privacy")!
  static let support = URL(string: "\(origin)/support")!
  static let manageDevices = URL(string: "\(origin)/my/devices")!
  static let deleteAccountReturnTo = "/my/settings?delete=account"

  static var deleteAccountStart: URL {
    githubStartURL(returnTo: deleteAccountReturnTo)
  }

  /// `return_to` is encoded so `/`, `?`, and `=` cannot split the query.
  static func githubStartURL(returnTo: String) -> URL {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let encoded = returnTo.addingPercentEncoding(withAllowedCharacters: allowed)!
    return URL(string: "\(origin)/api/auth/github/start?return_to=\(encoded)")!
  }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "appearance"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  static func load(from defaults: UserDefaults) -> AppearancePreference {
    guard let raw = defaults.string(forKey: storageKey),
      let value = AppearancePreference(rawValue: raw)
    else {
      return .system
    }
    return value
  }

  func save(to defaults: UserDefaults) {
    defaults.set(rawValue, forKey: Self.storageKey)
  }
}

/// One Overview-visible subscription as the Notifications page lists it.
struct SettingsNotificationSubscription: Equatable, Identifiable, Sendable {
  var selector: String
  var provider: ProviderID
  var providerDisplayName: String
  var accountLabel: String
  var firstThreshold: Int
  var secondThreshold: Int?

  var id: String { selector }
}

/// Settings rules, appearance, and notification permission.
@MainActor
@Observable
final class SettingsModel {
  /// Remaining-percent choices the Notifications page offers. The second slot may be Off.
  static let thresholdChoices = [5, 10, 15, 20, 25, 30, 40, 50]

  private let rulesStore: IOSAlertRulesStore
  private let notificationCenter: any NotificationAuthorizing
  private let appearanceDefaults: UserDefaults

  var rules: AlertRules
  var appearance: AppearancePreference
  var authorizationDenied = false

  init(
    rulesStore: IOSAlertRulesStore = IOSAlertRulesStore(),
    notificationCenter: any NotificationAuthorizing = SystemNotificationAuthorizer(),
    appearanceDefaults: UserDefaults = .standard
  ) {
    self.rulesStore = rulesStore
    self.notificationCenter = notificationCenter
    self.appearanceDefaults = appearanceDefaults
    self.rules = rulesStore.load()
    self.appearance = AppearancePreference.load(from: appearanceDefaults)
  }

  static func isValidThreshold(_ value: Int) -> Bool {
    thresholdChoices.contains(value)
  }

  static func secondThresholdChoices(first: Int) -> [Int] {
    thresholdChoices.filter { $0 < first }
  }

  static func selector(for subscription: QuotaSubscription) -> String {
    SubscriptionSelector.make(
      provider: subscription.provider.rawValue,
      fingerprint: subscription.snapshot.account.fingerprint,
      fingerprintScope: subscription.snapshot.account.fingerprintScope.rawValue,
      sourceID: AlertCoordinator.sourceID(fromKey: subscription.key)
    )
  }

  func notificationSubscriptions(
    from subscriptions: [QuotaSubscription]
  ) -> [SettingsNotificationSubscription] {
    let grouped = Dictionary(grouping: subscriptions, by: \.provider)
    var result: [SettingsNotificationSubscription] = []
    for provider in ProviderID.allCases {
      guard let items = grouped[provider], !items.isEmpty else { continue }
      for (index, subscription) in items.enumerated() {
        let selector = Self.selector(for: subscription)
        let values = rules.thresholds(for: selector)
        let label =
          PlanDisplay.accountLabel(subscription.snapshot.account.label)
          ?? "Account \(index + 1)"
        result.append(
          SettingsNotificationSubscription(
            selector: selector,
            provider: provider,
            providerDisplayName: provider.displayName,
            accountLabel: label,
            firstThreshold: values[0],
            secondThreshold: values.count > 1 ? values[1] : nil
          )
        )
      }
    }
    return result
  }

  func setNotificationsEnabled(_ enabled: Bool) async {
    if enabled {
      let granted: Bool
      do {
        granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
      } catch {
        granted = false
      }
      if granted {
        authorizationDenied = false
        persist { $0.enabled = true }
      } else {
        authorizationDenied = true
        persist { $0.enabled = false }
      }
    } else {
      persist { $0.enabled = false }
    }
  }

  func setResetReminders(_ enabled: Bool) {
    persist { $0.resetReminders = enabled }
  }

  func setFirstThreshold(_ value: Int, for selector: String) {
    guard Self.isValidThreshold(value) else { return }
    let current = rules.thresholds(for: selector)
    var next = [value]
    if current.count > 1, current[1] < value, Self.isValidThreshold(current[1]) {
      next.append(current[1])
    }
    persist { $0.setThresholds(next, for: selector) }
  }

  func setSecondThreshold(_ value: Int?, for selector: String) {
    let first = rules.thresholds(for: selector)[0]
    if let value {
      guard Self.isValidThreshold(value), value < first else { return }
      persist { $0.setThresholds([first, value], for: selector) }
    } else {
      persist { $0.setThresholds([first], for: selector) }
    }
  }

  func setAppearance(_ value: AppearancePreference) {
    appearance = value
    appearance.save(to: appearanceDefaults)
  }

  func refreshAuthorization() async {
    let status = await notificationCenter.authorizationStatus()
    switch status {
    case .denied:
      authorizationDenied = true
      if rules.enabled {
        persist { $0.enabled = false }
      }
    case .authorized, .provisional, .ephemeral, .notDetermined:
      authorizationDenied = false
    default:
      break
    }
  }

  private func persist(_ update: (inout AlertRules) -> Void) {
    var next = rules
    update(&next)
    guard next != rules else { return }
    rulesStore.save(next)
    rules = next
  }
}
