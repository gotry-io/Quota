import QuotaAlerts
import Testing

struct AlertRulesTests {
  /// A selector's thresholds are kept descending and unique inside 1…99, an edit that leaves
  /// none falls back to the default pair, and an edit to one selector leaves the others alone.
  @Test func thresholdsAreKeptDescendingAndUniqueInsideOneToNinetyNine() {
    #expect(AlertRules.normalized([10, 20, 20, 5]) == [20, 10, 5])
    #expect(AlertRules.normalized([1, 99]) == [99, 1])
    #expect(AlertRules.normalized([0, 100, -1, 20]) == [20])
    #expect(AlertRules.normalized([0, 100]) == [20, 10])
    #expect(AlertRules.normalized([]) == [20, 10])
    var rules = AlertRules()
    rules.setThresholds([10, 30, 30, 0], for: "codex_acct")
    #expect(rules.thresholds(for: "codex_acct") == [30, 10])
    #expect(rules.thresholds(for: "unedited") == [20, 10])
  }
}
