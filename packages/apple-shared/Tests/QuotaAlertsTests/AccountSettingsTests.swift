import Foundation
import QuotaAlerts
import QuotaPresentation
import Testing

struct AccountSettingsTests {
  @Test func theBudgetAmountRoundTripsThroughTheWireAsCents() throws {
    let cents = try AccountSettingsSample.document(amount: "\"250.00\"")
    #expect(cents.budget.amountUSD == Decimal(250))
    #expect(try AccountSettingsSample.wireAmount(cents) == "250.00")

    let tenths = try AccountSettingsSample.document(amount: "\"0.5\"")
    #expect(tenths.budget.amountUSD == Decimal(string: "0.5"))
    // A `Decimal` keeps no trailing zero of its own, so the wire form is always cents.
    #expect(try AccountSettingsSample.wireAmount(tenths) == "0.50")

    let cap = try AccountSettingsSample.document(amount: "\"1000000\"")
    #expect(cap.budget.amountUSD == UsageBudget.maximumAmountUSD)
    #expect(try AccountSettingsSample.wireAmount(cap) == "1000000.00")

    let none = try AccountSettingsSample.document(amount: "null")
    #expect(none.budget.amountUSD == nil)
    #expect(try AccountSettingsSample.wireAmount(none) == nil)
    let written = try #require(String(data: try none.updateRequestJSON(), encoding: .utf8))
    #expect(written.contains("\"amount_usd\":null"))
  }

  @Test func aDocumentDecodesPastKeysThisBuildDoesNotName() throws {
    let document = try AccountSettingsDocument.decode(
      Data(
        """
        {
          "protocol_version": 2,
          "revision": 7,
          "updated_at": "2026-09-21T10:00:00.000Z",
          "alerts": {
            "reset_reminders": false,
            "pace_alerts": true,
            "thresholds": { "a1b2c3d4e5f6": [20, 10] },
            "quiet_hours": { "from": "22:00" }
          },
          "budget": { "amount_usd": "250.00", "alerts": true, "currency": "USD" },
          "experiment": true
        }
        """.utf8
      )
    )
    #expect(document.revision == 7)
    #expect(document.updatedAt == ISO8601DateFormatter().date(from: "2026-09-21T10:00:00Z"))
    #expect(document.alerts.resetReminders == false)
    #expect(document.alerts.thresholds == ["a1b2c3d4e5f6": [20, 10]])
    #expect(document.budget.amountUSD == Decimal(250))
    // What a write states is the document and nothing else, so none of that comes back out.
    let rewritten = try AccountSettingsDocument.decode(try document.updateRequestJSON())
    #expect(rewritten.alerts == document.alerts)
    #expect(rewritten.budget == document.budget)
    #expect(rewritten.history.sync == false)
    #expect(rewritten.revision == 0)
    #expect(rewritten.updatedAt == nil)
  }

  @Test func aDocumentWithoutHistoryDecodesAsSyncOffAndAWriteOmitsIt() throws {
    let document = try AccountSettingsDocument.decode(
      Data(
        """
        {
          "protocol_version": 2,
          "revision": 1,
          "updated_at": "2026-09-21T10:00:00Z",
          "alerts": { "reset_reminders": true, "pace_alerts": true, "thresholds": {} },
          "budget": { "amount_usd": null, "alerts": true }
        }
        """.utf8
      )
    )
    #expect(document.history.sync == false)
    let object = try JSONSerialization.jsonObject(with: try document.updateRequestJSON())
    let fields = try #require(object as? [String: Any])
    #expect(fields["history"] == nil)
    #expect(fields.keys.sorted() == ["alerts", "budget", "protocol_version"])
  }

  @Test func anExplicitHistorySwitchIsStoredAndAWriteThatNamesItSendsIt() throws {
    let document = try AccountSettingsDocument.decode(
      Data(
        """
        {
          "alerts": { "reset_reminders": true, "pace_alerts": true, "thresholds": {} },
          "budget": { "amount_usd": null, "alerts": true },
          "history": { "sync": true }
        }
        """.utf8
      )
    )
    #expect(document.history.sync)
    #expect(document.writesHistory == false)
    var named = document
    named.writesHistory = true
    let object = try JSONSerialization.jsonObject(with: try named.updateRequestJSON())
    let fields = try #require(object as? [String: Any])
    let history = try #require(fields["history"] as? [String: Any])
    #expect(history["sync"] as? Bool == true)
  }

  /// The strict check is over the stored shape, so `revision`, `updated_at`, and the
  /// `protocol_version` a request adds around it are not part of it either.
  @Test func normalizeRefusesAKeyTheDocumentDoesNotDefine() {
    let alerts = #"{"reset_reminders":true,"pace_alerts":true,"thresholds":{}}"#
    let budget = #"{"amount_usd":null,"alerts":true}"#
    let documents = [
      #"{"alerts":\#(alerts),"budget":\#(budget),"enabled":false}"#,
      #"{"revision":3,"alerts":\#(alerts),"budget":\#(budget)}"#,
      #"{"protocol_version":2,"alerts":\#(alerts),"budget":\#(budget)}"#,
      #"{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{},"enabled":false},"#
        + #""budget":\#(budget)}"#,
      #"{"alerts":\#(alerts),"budget":{"amount_usd":null,"alerts":true,"currency":"USD"}}"#,
    ]
    for document in documents {
      #expect(AccountSettings.normalize(Data(document.utf8)) == .refused, "\(document)")
    }
  }

  @Test func anUpdateRequestStatesOnlyWhatAClientMayWrite() throws {
    let document = AccountSettingsDocument(
      revision: 7,
      updatedAt: Date(timeIntervalSince1970: 0),
      alerts: AccountSettingsDocument.Alerts(
        resetReminders: true,
        paceAlerts: false,
        thresholds: ["a1b2c3d4e5f6": [20, 10]]
      ),
      budget: AccountSettingsDocument.Budget(amountUSD: Decimal(250), alerts: true)
    )
    let object = try JSONSerialization.jsonObject(with: try document.updateRequestJSON())
    let fields = try #require(object as? [String: Any])
    #expect(fields.keys.sorted() == ["alerts", "budget", "protocol_version"])
    #expect(fields["protocol_version"] as? Int == QuotaProtocol.control)
  }

  @Test func theMasterSwitchSurvivesAnAdoptedPolicy() {
    let policy = AccountSettingsPolicy(
      resetReminders: false,
      paceAlerts: false,
      thresholds: ["a1b2c3d4e5f6": [40, 20]],
      budgetAmountUSD: Decimal(250),
      budgetAlerts: false
    )
    let allowed = AlertRules(enabled: true, resetReminders: true, paceAlerts: true).applying(policy)
    #expect(allowed.enabled)
    #expect(allowed.resetReminders == false)
    #expect(allowed.paceAlerts == false)
    #expect(allowed.thresholds == ["a1b2c3d4e5f6": [40, 20]])
    #expect(AlertRules(enabled: false).applying(policy).enabled == false)

    let budget = UsageBudget(policy: policy)
    #expect(budget.amountUSD == Decimal(250))
    #expect(budget.alerts == false)

    // The switch is not a policy field, so a device's own value never travels either way.
    #expect(AccountSettingsPolicy(rules: allowed, budget: budget) == policy)
  }

  @Test func theWireCarriesTheLargestTwoThresholdsOfALocalList() {
    let rules = AlertRules(thresholds: ["a1b2c3d4e5f6": [10, 30, 20]])
    let policy = AccountSettingsPolicy(rules: rules, budget: UsageBudget.none)
    #expect(policy.thresholds == ["a1b2c3d4e5f6": [30, 20]])
  }

  @Test func selectorsThisDeviceDoesNotKnowSurviveAReapply() throws {
    let fresh = try AccountSettingsDocument.decode(
      Data(
        """
        {
          "revision": 4,
          "alerts": {
            "reset_reminders": true,
            "pace_alerts": true,
            "thresholds": { "112233445566": [15], "deadbeef0001": [5] }
          },
          "budget": { "amount_usd": "100.00", "alerts": true }
        }
        """.utf8
      )
    )
    let added = AccountSettings.reapply(
      edit: .setThresholds(selector: "a1b2c3d4e5f6", [30, 5]),
      onto: fresh
    )
    #expect(
      added.alerts.thresholds == [
        "112233445566": [15], "deadbeef0001": [5], "a1b2c3d4e5f6": [30, 5],
      ]
    )
    #expect(added.revision == 4)
    #expect(added.budget.amountUSD == Decimal(100))

    let switched = AccountSettings.reapply(edit: .setPaceAlerts(false), onto: fresh)
    #expect(switched.alerts.thresholds == fresh.alerts.thresholds)
    #expect(switched.alerts.paceAlerts == false)
    #expect(switched.alerts.resetReminders)
  }

  @Test func reapplyOfHistorySyncNamesHistoryOnlyOnThatWrite() throws {
    let fresh = try AccountSettingsDocument.decode(
      Data(
        """
        {
          "revision": 3,
          "alerts": {
            "reset_reminders": true,
            "pace_alerts": true,
            "thresholds": { "112233445566": [15] }
          },
          "budget": { "amount_usd": "50.00", "alerts": true },
          "history": { "sync": false }
        }
        """.utf8
      )
    )
    let enabled = AccountSettings.reapply(edit: .setHistorySync(true), onto: fresh)
    #expect(enabled.history.sync)
    #expect(enabled.writesHistory)
    #expect(enabled.alerts.thresholds == fresh.alerts.thresholds)
    #expect(enabled.revision == 3)
    let enabledBody = try #require(
      JSONSerialization.jsonObject(with: try enabled.updateRequestJSON()) as? [String: Any]
    )
    let history = try #require(enabledBody["history"] as? [String: Any])
    #expect(history["sync"] as? Bool == true)

    let other = AccountSettings.reapply(edit: .setPaceAlerts(false), onto: fresh)
    #expect(other.history.sync == false)
    #expect(other.writesHistory == false)
    let otherBody = try #require(
      JSONSerialization.jsonObject(with: try other.updateRequestJSON()) as? [String: Any]
    )
    #expect(otherBody["history"] == nil)

    let disabled = AccountSettings.reapply(edit: .setHistorySync(false), onto: enabled)
    #expect(disabled.history.sync == false)
    #expect(disabled.writesHistory)
    let disabledBody = try #require(
      JSONSerialization.jsonObject(with: try disabled.updateRequestJSON()) as? [String: Any]
    )
    let disabledHistory = try #require(disabledBody["history"] as? [String: Any])
    #expect(disabledHistory["sync"] as? Bool == false)
  }

  @Test func aDeviceThatEditedNothingAdoptsWithoutAWrite() throws {
    let defaults = AccountSettingsPolicy(rules: AlertRules(), budget: UsageBudget.none)
    #expect(defaults.isDefault)
    let empty = AccountSettingsDocument(
      alerts: AccountSettingsDocument.Alerts(
        resetReminders: true,
        paceAlerts: true,
        thresholds: [:]
      ),
      budget: AccountSettingsDocument.Budget(amountUSD: nil, alerts: true)
    )
    #expect(
      AccountSettings.planFirstSync(local: defaults, account: empty) == .adopt(policy: defaults)
    )

    // A selector edited to the default pair is still an edit, so it seeds the Account.
    let chosen = AccountSettingsPolicy(
      rules: AlertRules(thresholds: ["a1b2c3d4e5f6": AlertRules.defaultThresholds]),
      budget: UsageBudget.none
    )
    #expect(chosen.isDefault == false)
    let write = try #require(AccountSettings.planFirstSync(local: chosen, account: empty).write)
    #expect(write.revision == 0)
    #expect(write.alerts.thresholds == ["a1b2c3d4e5f6": [20, 10]])
  }

  @Test func normalizeTakesTheDocumentAtItsLimits() throws {
    let selectors = (0..<AccountSettings.maximumSelectors).map { String(format: "%012x", $0) }
    let full = AccountSettingsSample.thresholds(selectors: selectors, values: "[99, 1]")
    guard case .ok(let document) = AccountSettings.normalize(full) else {
      Issue.record("\(AccountSettings.maximumSelectors) selectors are still the document")
      return
    }
    #expect(document.alerts.thresholds.count == AccountSettings.maximumSelectors)
    #expect(document.revision == 0)

    let single = AccountSettingsSample.thresholds(selectors: ["112233445566"], values: "[15]")
    #expect(AccountSettings.normalize(single) != .refused)
  }

  @Test func normalizeRefusesWhatTheDocumentDoesNotDefine() {
    let overCap = (0...AccountSettings.maximumSelectors).map { String(format: "%012x", $0) }
    #expect(
      AccountSettings.normalize(
        AccountSettingsSample.thresholds(selectors: overCap, values: "[20, 10]")
      ) == .refused
    )
    for values in ["[]", "[20, 20]", "[10, 20]", "[30, 20, 10]", "[0]", "[100]", "[20.5]"] {
      #expect(
        AccountSettings.normalize(
          AccountSettingsSample.thresholds(selectors: ["a1b2c3d4e5f6"], values: values)
        ) == .refused,
        "\(values)"
      )
    }
    for selector in ["A1B2C3D4E5F6", "a1b2c3d4e5f", "a1b2c3d4e5f6a", "budget"] {
      #expect(
        AccountSettings.normalize(
          AccountSettingsSample.thresholds(selectors: [selector], values: "[20, 10]")
        ) == .refused,
        "\(selector)"
      )
    }
    for amount in ["\"0\"", "\"1000000.01\"", "\"1.234\"", "\"250 \"", "\"-5\"", "\"\"", "250.00"] {
      #expect(
        AccountSettings.normalize(AccountSettingsSample.json(amount: amount)) == .refused,
        "\(amount)"
      )
    }
    #expect(AccountSettings.normalize(Data("{}".utf8)) == .refused)
    #expect(
      AccountSettings.normalize(
        Data(#"{"alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}}}"#.utf8)
      ) == .refused
    )
  }
}

private enum AccountSettingsSample {
  /// A document with no thresholds and the given `amount_usd` literal, as JSON bytes.
  static func json(amount: String) -> Data {
    Data(
      """
      {
        "alerts": { "reset_reminders": true, "pace_alerts": true, "thresholds": {} },
        "budget": { "amount_usd": \(amount), "alerts": true }
      }
      """.utf8
    )
  }

  static func document(amount: String) throws -> AccountSettingsDocument {
    try AccountSettingsDocument.decode(json(amount: amount))
  }

  /// A document giving every selector the same threshold list.
  static func thresholds(selectors: [String], values: String) -> Data {
    let entries = selectors.map { "\"\($0)\": \(values)" }.joined(separator: ", ")
    return Data(
      """
      {
        "alerts": {
          "reset_reminders": true,
          "pace_alerts": true,
          "thresholds": { \(entries) }
        },
        "budget": { "amount_usd": null, "alerts": true }
      }
      """.utf8
    )
  }

  /// The `amount_usd` a write states, or nil when the write states no budget.
  static func wireAmount(_ document: AccountSettingsDocument) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: try document.updateRequestJSON())
    let fields = try #require(object as? [String: Any])
    let budget = try #require(fields["budget"] as? [String: Any])
    return budget["amount_usd"] as? String
  }
}
