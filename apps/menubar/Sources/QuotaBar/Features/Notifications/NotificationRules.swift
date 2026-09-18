import Foundation
import QuotaAlertDelivery

/// Remaining-percent choices the Notifications page offers, and this Mac's `AlertRulesStore`.
///
/// The second slot may be Off. Persistence is the shared store under the shipped
/// `notifications.*` prefix; the state file is `QuotaBar/notification-state.json`.
enum NotificationRules {
  static let thresholdChoices = [5, 10, 15, 20, 25, 30, 40, 50]

  static func store(defaults: UserDefaults = .standard) -> AlertRulesStore {
    AlertRulesStore(defaults: defaults, keyPrefix: "notifications")
  }

  static func stateFileURL(applicationSupport: URL) -> URL {
    applicationSupport
      .appendingPathComponent("QuotaBar", isDirectory: true)
      .appendingPathComponent("notification-state.json", isDirectory: false)
  }
}
