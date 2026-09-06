import Foundation
import QuotaPresentation
import Testing

struct RemainingCopyConformanceTests {
  @Test func remainingCopyMatchesTheSharedFixture() throws {
    let fixture = try RemainingCopyFixture.load()
    #expect(
      RemainingQuotaFormat.amountOfLimitPercentTolerance == fixture.tolerance
    )
    let cases = fixture.cases
    #expect(cases.count > 1)
    for testCase in cases {
      let remainingPercent = RemainingQuotaFormat.remainingPercent(
        usedPercent: testCase.window.usedPercent)
      let unit = testCase.window.unit
      let hasLimit = testCase.window.limitValue != nil
      let observed = RemainingQuotaFormat.remaining(
        remainingPercent: remainingPercent,
        remainingValue: testCase.window.remainingValue,
        limitValue: testCase.window.limitValue,
        hasLimit: hasLimit,
        unit: unit
      )
      let meter = RemainingQuotaFormat.showsPercentMeter(
        remainingPercent: remainingPercent,
        remainingValue: testCase.window.remainingValue,
        limitValue: testCase.window.limitValue,
        hasLimit: hasLimit,
        unit: unit
      )
      let balance = RemainingQuotaFormat.isBalanceOnly(
        remainingValue: testCase.window.remainingValue,
        hasLimit: hasLimit
      )
      let amount = RemainingQuotaFormat.isAmountOfLimit(
        remainingPercent: remainingPercent,
        remainingValue: testCase.window.remainingValue,
        limitValue: testCase.window.limitValue,
        unit: unit
      )
      #expect(observed == testCase.expected, "\(testCase.name) copy")
      #expect(meter == testCase.showsPercentMeter, "\(testCase.name) meter")
      #expect(balance == testCase.isBalanceOnly, "\(testCase.name) balance")
      #expect(amount == testCase.isAmountOfLimit, "\(testCase.name) amount")
    }
  }
}

enum RemainingCopyFixture {
  struct Window {
    var usedPercent: Double
    var remainingValue: Double?
    var limitValue: Double?
    var unit: RemainingQuotaUnit?
  }

  struct Case {
    let name: String
    let window: Window
    let expected: String
    let showsPercentMeter: Bool
    let isBalanceOnly: Bool
    let isAmountOfLimit: Bool
  }

  static func load() throws -> (tolerance: Double, cases: [Case]) {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
    let tolerance = (root["amount_of_limit_percent_tolerance"] as! NSNumber).doubleValue
    let entries = root["cases"] as! [[String: Any]]
    let cases = entries.map { entry in
      let window = entry["window"] as! [String: Any]
      return Case(
        name: entry["name"] as! String,
        window: Window(
          usedPercent: (window["used_percent"] as! NSNumber).doubleValue,
          remainingValue: (window["remaining_value"] as? NSNumber)?.doubleValue,
          limitValue: (window["limit_value"] as? NSNumber)?.doubleValue,
          unit: remainingUnit(window["value_unit"] as? String)
        ),
        expected: entry["expected"] as! String,
        showsPercentMeter: entry["shows_percent_meter"] as! Bool,
        isBalanceOnly: entry["is_balance_only"] as! Bool,
        isAmountOfLimit: entry["is_amount_of_limit"] as! Bool
      )
    }
    return (tolerance, cases)
  }

  private static func remainingUnit(_ value: String?) -> RemainingQuotaUnit? {
    switch value {
    case "usd": .usd
    case "credits": .credits
    case "count": .count
    default: nil
    }
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/remaining-copy-conformance.json")
}
