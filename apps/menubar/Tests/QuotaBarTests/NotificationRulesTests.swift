import Foundation
import QuotaAlerts
import Testing

@testable import QuotaBar

struct NotificationRulesTests {
  @Test func thresholdChoicesAreTheDocumentedSet() {
    #expect(NotificationRules.thresholdChoices == [5, 10, 15, 20, 25, 30, 40, 50])
  }

  @Test func missingKeysUseTheDocumentedDefaults() {
    let defaults = isolatedDefaults()
    defer { defaults.tearDown() }
    let rules = NotificationRules.load(from: defaults.store)
    #expect(rules.enabled == false)
    #expect(rules.resetReminders == true)
    #expect(rules.thresholds(for: "codex_acct") == [20, 10])
  }

  @Test func roundTripPersistsEnabledResetRemindersAndPerSelectorThresholds() {
    let defaults = isolatedDefaults()
    defer { defaults.tearDown() }
    let written = AlertRules(
      enabled: true,
      resetReminders: false,
      thresholds: ["codex_acct": [10, 30, 30, 0]]
    )
    NotificationRules.save(written, to: defaults.store)
    let read = NotificationRules.load(from: defaults.store)
    #expect(read.enabled)
    #expect(!read.resetReminders)
    #expect(read.thresholds(for: "codex_acct") == [30, 10])
    #expect(read.thresholds(for: "unedited") == [20, 10])
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
  let name = "QuotaBarTests.NotificationRules.\(UUID().uuidString)"
  let store = UserDefaults(suiteName: name)!
  store.removePersistentDomain(forName: name)
  return IsolatedDefaults(name: name, store: store)
}
