import Foundation
import QuotaAlerts
import QuotaPresentation
import Testing

/// TypeScript, Swift, and Rust answer `account-settings-conformance.json`. A case one runtime
/// changes cannot quietly drift from the others.
struct AccountSettingsConformanceTests {
  @Test func everyNormalizeCaseMatchesTheSharedFixture() throws {
    let cases = try AccountSettingsFixture.section("normalize")
    #expect(cases.count >= 8)
    for testCase in cases {
      let name = try AccountSettingsFixture.name(testCase)
      let expected = try #require(testCase["expected"] as? [String: Any], "\(name)")
      let input = try AccountSettingsFixture.json(testCase["input"])
      switch AccountSettings.normalize(input) {
      case .ok(let document):
        let ok = try #require(expected["ok"] as? [String: Any], "\(name)")
        let stored = try AccountSettingsFixture.stored(document)
        #expect(stored == ok as NSDictionary, "\(name)")
        #expect(document.revision == 0, "\(name)")
        #expect(document.updatedAt == nil, "\(name)")
      case .refused:
        #expect(expected["refused"] as? Bool == true, "\(name)")
      }
    }
  }

  @Test func everyFirstSyncCaseMatchesTheSharedFixture() throws {
    let cases = try AccountSettingsFixture.section("first_sync")
    #expect(cases.count >= 4)
    for testCase in cases {
      let name = try AccountSettingsFixture.name(testCase)
      let local = try AccountSettingsFixture.document(testCase["local"]).policy
      let account = try AccountSettingsFixture.document(testCase["account"])
      let expected = try #require(testCase["expected"] as? [String: Any], "\(name)")
      let plan = AccountSettings.planFirstSync(local: local, account: account)
      #expect(AccountSettingsFixture.action(plan) == expected["action"] as? String, "\(name)")
      let adopted = try AccountSettingsFixture.document(expected["local"]).policy
      #expect(plan.policy == adopted, "\(name)")
      guard let write = expected["write"] as? [String: Any] else {
        #expect(plan.write == nil, "\(name)")
        continue
      }
      let written = try #require(plan.write, "\(name)")
      let body = try AccountSettingsFixture.writeBody(written)
      #expect(body == write as NSDictionary, "\(name)")
      // The revision a seed or a merge states in `If-Match` is the one the Account answered.
      #expect(written.revision == account.revision, "\(name)")
    }
  }

  @Test func everyReapplyCaseMatchesTheSharedFixture() throws {
    let cases = try AccountSettingsFixture.section("reapply")
    #expect(cases.count >= 3)
    for testCase in cases {
      let name = try AccountSettingsFixture.name(testCase)
      let fresh = try AccountSettingsFixture.document(testCase["fresh"])
      let edit = try #require(AccountSettingsFixture.edit(testCase["edit"], onto: fresh), "\(name)")
      let expected = try #require(testCase["expected"] as? [String: Any], "\(name)")
      let result = AccountSettings.reapply(edit: edit, onto: fresh)
      #expect(try AccountSettingsFixture.stored(result) == expected as NSDictionary, "\(name)")
    }
  }
}

private enum AccountSettingsFixture {
  static func section(_ name: String) throws -> [[String: Any]] {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require((root as? [String: Any])?[name] as? [[String: Any]])
  }

  static func name(_ testCase: [String: Any]) throws -> String {
    try #require(testCase["name"] as? String)
  }

  static func json(_ value: Any?) throws -> Data {
    try JSONSerialization.data(withJSONObject: try #require(value))
  }

  static func document(_ value: Any?) throws -> AccountSettingsDocument {
    try AccountSettingsDocument.decode(try json(value))
  }

  /// The stored policy as the fixture spells it: `alerts`, `budget`, and `history`.
  static func stored(_ document: AccountSettingsDocument) throws -> NSDictionary {
    let object = try JSONSerialization.jsonObject(with: try document.storedJSON())
    return try #require(object as? [String: Any]) as NSDictionary
  }

  /// The PUT body, less `protocol_version`. `history` is present only when this write names it.
  static func writeBody(_ document: AccountSettingsDocument) throws -> NSDictionary {
    let object = try JSONSerialization.jsonObject(with: try document.updateRequestJSON())
    var fields = try #require(object as? [String: Any])
    fields.removeValue(forKey: "protocol_version")
    return fields as NSDictionary
  }

  static func action(_ plan: AccountSettingsFirstSync) -> String {
    switch plan {
    case .seed: "seed"
    case .adopt: "adopt"
    case .adoptAndMerge: "adopt_and_merge"
    }
  }

  /// The fixture's edit as Swift holds one. A Swift budget editor writes the amount and its switch
  /// as one `UsageBudget`, so an amount-only case keeps the fresh document's switch and an
  /// alerts-only case keeps its amount.
  static func edit(_ value: Any?, onto fresh: AccountSettingsDocument) -> AccountSettingsEdit? {
    guard let fields = value as? [String: Any], let kind = fields["kind"] as? String else {
      return nil
    }
    switch kind {
    case "set_reset_reminders":
      guard let value = fields["value"] as? Bool else { return nil }
      return .setResetReminders(value)
    case "set_pace_alerts":
      guard let value = fields["value"] as? Bool else { return nil }
      return .setPaceAlerts(value)
    case "set_thresholds":
      guard let selector = fields["selector"] as? String,
        let thresholds = fields["thresholds"] as? [Int]
      else { return nil }
      return .setThresholds(selector: selector, thresholds)
    case "set_budget_amount":
      guard let raw = fields["value"] else { return nil }
      if raw is NSNull { return .setBudget(amount: nil, alerts: fresh.budget.alerts) }
      guard let text = raw as? String,
        let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
      else { return nil }
      return .setBudget(amount: amount, alerts: fresh.budget.alerts)
    case "set_budget_alerts":
      guard let value = fields["value"] as? Bool else { return nil }
      return .setBudget(amount: fresh.budget.amountUSD, alerts: value)
    case "set_history_sync":
      guard let value = fields["value"] as? Bool else { return nil }
      return .setHistorySync(value)
    default:
      return nil
    }
  }

  private static let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/account-settings-conformance.json")
}
