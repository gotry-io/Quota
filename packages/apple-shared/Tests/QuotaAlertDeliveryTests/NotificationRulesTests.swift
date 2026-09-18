import Foundation
import QuotaAlerts
import Testing

@testable import QuotaAlertDelivery

struct NotificationRulesTests {
  @Test func keyNamesAreThePrefixDotFieldForEachShippedPrefix() {
    for prefix in ["alerts", "notifications"] {
      let store = AlertRulesStore(keyPrefix: prefix)
      #expect(store.enabledKey == "\(prefix).enabled")
      #expect(store.resetRemindersKey == "\(prefix).resetReminders")
      #expect(store.paceAlertsKey == "\(prefix).paceAlerts")
      #expect(store.thresholdsKey == "\(prefix).thresholds")
    }
  }

  @Test func missingKeysUseTheDocumentedDefaultsForEachShippedPrefix() {
    for prefix in ["alerts", "notifications"] {
      let defaults = isolatedDefaults()
      defer { defaults.tearDown() }
      let store = AlertRulesStore(defaults: defaults.store, keyPrefix: prefix)
      let rules = store.load()
      #expect(rules.enabled == false)
      #expect(rules.resetReminders == true)
      #expect(rules.thresholds(for: "codex_acct") == [20, 10])
    }
  }

  @Test func roundTripPersistsEnabledResetRemindersAndPerSelectorThresholds() {
    for prefix in ["alerts", "notifications"] {
      let defaults = isolatedDefaults()
      defer { defaults.tearDown() }
      let store = AlertRulesStore(defaults: defaults.store, keyPrefix: prefix)
      let written = AlertRules(
        enabled: true,
        resetReminders: false,
        thresholds: ["codex_acct": [10, 30, 30, 0]]
      )
      store.save(written)
      #expect(defaults.store.object(forKey: "\(prefix).enabled") as? Bool == true)
      #expect(defaults.store.object(forKey: "\(prefix).resetReminders") as? Bool == false)
      let read = store.load()
      #expect(read.enabled)
      #expect(!read.resetReminders)
      #expect(read.thresholds(for: "codex_acct") == [30, 10])
      #expect(read.thresholds(for: "unedited") == [20, 10])
    }
  }
}

private struct IsolatedDefaults {
  let name: String
  let store: UserDefaults

  func tearDown() {
    store.removePersistentDomain(forName: name)
  }
}

private func isolatedDefaults() -> IsolatedDefaults {
  let name = "QuotaAlertDeliveryTests.AlertRules.\(UUID().uuidString)"
  let store = UserDefaults(suiteName: name)!
  store.removePersistentDomain(forName: name)
  return IsolatedDefaults(name: name, store: store)
}
