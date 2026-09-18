import Foundation
import QuotaAlertDelivery
import Testing

@testable import Quota

struct AlertPersistenceConstraintTests {
  @Test func shippedIosReleaseUsesAlertsPrefixAndAlertStateFile() {
    let store = AlertCoordinator.rulesStore()
    #expect(store.keyPrefix == "alerts")
    #expect(store.enabledKey == "alerts.enabled")
    #expect(store.resetRemindersKey == "alerts.resetReminders")
    #expect(store.paceAlertsKey == "alerts.paceAlerts")
    #expect(store.thresholdsKey == "alerts.thresholds")
    let url = AlertCoordinator.stateFileURL(
      applicationSupport: URL(filePath: "/Application Support")
    )
    #expect(url.lastPathComponent == "alert-state.json")
    #expect(url.path.hasSuffix("/Application Support/alert-state.json"))
  }
}
