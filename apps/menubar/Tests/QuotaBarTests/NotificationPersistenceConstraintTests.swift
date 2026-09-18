import Foundation
import QuotaAlertDelivery
import Testing

@testable import QuotaBar

struct NotificationPersistenceConstraintTests {
  @Test func shippedQuotaBarReleaseUsesNotificationsPrefixAndNotificationStateFile() {
    let store = NotificationRules.store()
    #expect(store.keyPrefix == "notifications")
    #expect(store.enabledKey == "notifications.enabled")
    #expect(store.resetRemindersKey == "notifications.resetReminders")
    #expect(store.paceAlertsKey == "notifications.paceAlerts")
    #expect(store.thresholdsKey == "notifications.thresholds")
    let url = NotificationRules.stateFileURL(
      applicationSupport: URL(filePath: "/Application Support")
    )
    #expect(url.lastPathComponent == "notification-state.json")
    #expect(url.path.hasSuffix("/Application Support/QuotaBar/notification-state.json"))
  }
}
