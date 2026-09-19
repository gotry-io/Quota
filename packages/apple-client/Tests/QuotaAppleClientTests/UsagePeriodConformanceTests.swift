import Foundation
import QuotaWire
import Testing

/// Consumer of `usage-period-conformance.json`: fixture-shaped bodies decode, and totals,
/// cost, and coverage are what the Usage page draws.
@Suite
struct UsagePeriodConformanceTests {
  @Test func fixtureBodiesDecodeAndExposeTotalsCostAndCoverage() throws {
    let data = try Fixtures.accountUsagePeriodJSON(
      from: "2026-08-26",
      to: "2026-08-28",
      timezone: "Asia/Singapore",
      totals: Fixtures.summaryTotals(input: 2_000, output: 400, cacheRead: 200),
      cost: Fixtures.completeCost(amount: "1230000"),
      days: [
        Fixtures.usagePeriodDayBucket(date: "2026-08-26"),
        Fixtures.usagePeriodDayBucket(date: "2026-08-28"),
      ],
      coverage: Fixtures.usagePeriodCoverage(
        partial: true,
        truncatedByRetention: true
      )
    )
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    root["extra"] = true
    let decoded = try WireCodec.decode(
      AccountUsagePeriodResponse.self,
      from: try JSONSerialization.data(withJSONObject: root)
    )
    #expect(decoded.request.from == "2026-08-26")
    #expect(decoded.request.to == "2026-08-28")
    #expect(decoded.request.timezone == "Asia/Singapore")
    #expect(decoded.days.map(\.date) == ["2026-08-26", "2026-08-28"])
    #expect(decoded.totals.totalTokens == 2_400)
    #expect(decoded.cost.amountMicrousd == "1230000")
    #expect(decoded.coverage.partial)
    #expect(decoded.coverage.truncatedByRetention)
    #expect(decoded.usagePeriod.totals.totalTokens == 2_400)
    #expect(decoded.usagePeriod.cost.amountMicrousd == "1230000")
    #expect(decoded.usagePeriod.partial)
    #expect(decoded.usagePeriod.agents.isEmpty)
  }

  @Test func missingDaysStayGapsAndUnpricedCostIsNotZero() throws {
    let unpriced: [String: Any] = [
      "mode": "calculate",
      "basis": "none",
      "status": "unavailable",
      "amount_microusd": NSNull(),
      "catalog_revision": NSNull(),
      "calculated_rows": 0,
      "reported_rows": 0,
      "unpriced_rows": 1,
      "assumptions": [],
      "unpriced": [
        [
          "billing_channel": "openai_direct",
          "model": "a-model-no-catalog-names",
          "reason": "unknown_model",
          "rows": 1,
        ]
      ],
    ]
    let priced = Fixtures.completeCost(amount: "1000")
    let data = try Fixtures.accountUsagePeriodJSON(
      from: "2026-08-26",
      to: "2026-08-28",
      timezone: "Asia/Singapore",
      totals: Fixtures.summaryTotals(input: 2_000, output: 400),
      cost: [
        "mode": "calculate",
        "basis": "calculated",
        "status": "partial",
        "amount_microusd": "1000",
        "catalog_revision": "pricing_1",
        "calculated_rows": 1,
        "reported_rows": 0,
        "unpriced_rows": 1,
        "assumptions": ["agent_default_channel"],
        "unpriced": unpriced["unpriced"] as Any,
      ],
      days: [
        Fixtures.usagePeriodDayBucket(
          date: "2026-08-26",
          cost: unpriced
        ),
        Fixtures.usagePeriodDayBucket(date: "2026-08-28", cost: priced),
      ]
    )
    let decoded = try WireCodec.decode(AccountUsagePeriodResponse.self, from: data)
    #expect(decoded.days.map(\.date) == ["2026-08-26", "2026-08-28"])
    #expect(!decoded.days.map(\.date).contains("2026-08-27"))
    #expect(decoded.days[0].cost.status == .unavailable)
    #expect(decoded.days[0].cost.amountMicrousd == nil)
    #expect(decoded.cost.status == .partial)
    #expect(decoded.cost.amountMicrousd != "0")
  }
}
