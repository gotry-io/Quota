import QuotaAlerts
import Testing

struct AlertRulesTests {
  @Test func missingSelectorUsesTheDocumentedDefaultPair() {
    let rules = AlertRules()
    #expect(rules.enabled == false)
    #expect(rules.resetReminders == true)
    #expect(rules.thresholds(for: "codex_acct") == [20, 10])
  }

  @Test func thresholdsAreKeptDescendingAndUniqueInsideOneToNinetyNine() {
    #expect(AlertRules.normalized([10, 20, 20, 5]) == [20, 10, 5])
    #expect(AlertRules.normalized([1, 99]) == [99, 1])
    #expect(AlertRules.normalized([0, 100, -1, 20]) == [20])
    #expect(AlertRules.normalized([0, 100]) == [20, 10])
    #expect(AlertRules.normalized([]) == [20, 10])
  }

  @Test func setThresholdsStoresTheNormalizedPairForThatSelector() {
    var rules = AlertRules()
    rules.setThresholds([10, 30, 30, 0], for: "codex_acct")
    #expect(rules.thresholds(for: "codex_acct") == [30, 10])
    #expect(rules.thresholds(for: "unedited") == [20, 10])
  }
}
