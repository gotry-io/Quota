import Foundation
import QuotaWire
import Testing

@testable import QuotaBar

struct UsageExportTests {
  @Test func answersEveryCsvCellCaseInTheSharedFixture() throws {
    let fixture = try loadFixture()
    let cells = try #require(fixture["csv_cell_cases"] as? [[String: Any]])
    for cell in cells {
      let name = try #require(cell["name"] as? String)
      let input = try #require(cell["input"] as? String)
      let kind = try #require(cell["kind"] as? String)
      let expected = try #require(cell["expected"] as? String)
      let actual = UsageExport.csvCell(
        input, kind: kind == "number" ? .number : .text)
      #expect(actual == expected, "\(name)")
    }
  }

  @Test func answersEveryPeriodCaseInTheSharedFixture() throws {
    let fixture = try loadFixture()
    let cases = try #require(fixture["cases"] as? [[String: Any]])
    #expect(cases.map { $0["name"] as? String } == [
      "missing_and_unpriced", "partial_cost_and_this_mac",
    ])
    for testCase in cases {
      let name = try #require(testCase["name"] as? String)
      let inputObject = try #require(testCase["input"] as? [String: Any])
      let expectedCsv = try #require(testCase["expected_csv"] as? String)
      let expectedJson = try #require(testCase["expected_json"] as? [String: Any])
      let input = try exportInput(from: inputObject)
      #expect(UsageExport.csv(from: input) == expectedCsv, "\(name) csv")
      let actualJson = UsageExport.jsonObject(from: input)
      #expect(try canonicalJSON(actualJson) == canonicalJSON(expectedJson), "\(name) json")
    }
  }

  @Test func namesTheFileFromTheAskedLocalDates() {
    #expect(
      UsageExport.filename(from: "2026-08-10", to: "2026-08-12", format: .csv)
        == "quota-usage-2026-08-10-2026-08-12.csv"
    )
    #expect(
      UsageExport.filename(from: "2026-08-10", to: "2026-08-12", format: .json)
        == "quota-usage-2026-08-10-2026-08-12.json"
    )
  }

  @Test func mapsTheOnScreenDetailAndOmitsAPeriodWithoutDays() throws {
    let day = LocalUsageDay(
      date: "2026-08-26",
      totals: UsageSummaryTotals(
        totalTokens: 12,
        inputTokens: 10,
        outputTokens: 2,
        cacheReadInputTokens: 0,
        cacheWriteInputTokens: 0,
        reasoningTokens: 0,
        messages: 1
      ),
      cost: UsageCostOutcome(
        mode: .calculate,
        basis: .calculated,
        status: .complete,
        amountMicrousd: "3138",
        catalogRevision: "pricing_1",
        calculatedRows: 1,
        reportedRows: 0,
        unpricedRows: 0,
        assumptions: [],
        unpriced: []
      )
    )
    let withDays = LocalServiceUsageDetail(
      range: UsageDateRange(from: "2026-08-26", to: "2026-08-26"),
      usage: LocalUsagePeriodSummary(
        totals: day.totals,
        cost: day.cost,
        cacheSaved: UsageCacheSaved(amountMicrousd: "0", status: .complete, unpricedRows: 0),
        agents: [],
        days: [day]
      ),
      incomplete: false,
      detailsTruncated: false,
      timezone: "Asia/Singapore"
    )
    let input = try #require(
      UsageExport.input(
        detail: withDays,
        scope: "This Mac",
        range: (from: "2026-08-26", to: "2026-08-26"),
        timezone: "Asia/Singapore",
        exportedAt: "2026-09-20T12:00:00Z",
        appVersion: "0.2.6"
      )
    )
    #expect(input.days.count == 1)
    #expect(UsageExport.csv(from: input).contains("0.003138"))
    let withoutDays = LocalServiceUsageDetail(
      range: UsageDateRange(from: "2026-08-26", to: "2026-08-26"),
      usage: LocalUsagePeriodSummary(
        totals: day.totals,
        cost: day.cost,
        cacheSaved: UsageCacheSaved(amountMicrousd: "0", status: .complete, unpricedRows: 0),
        agents: []
      ),
      incomplete: false,
      detailsTruncated: false
    )
    #expect(
      UsageExport.input(
        detail: withoutDays,
        scope: "This Mac",
        range: (from: "2026-08-26", to: "2026-08-26"),
        timezone: "Asia/Singapore",
        exportedAt: "2026-09-20T12:00:00Z",
        appVersion: "0.2.6"
      ) == nil
    )
  }
}

private func loadFixture() throws -> [String: Any] {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("packages/protocol/fixtures/usage-export-conformance.json")
  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
  return try #require(object as? [String: Any])
}

private func exportInput(from object: [String: Any]) throws -> UsageExport.Input {
  let rawDays = try #require(object["days"] as? [[String: Any]])
  let days = try rawDays.map { day in
    let totals = try #require(day["totals"] as? [String: Any])
    let cost = try #require(day["cost"] as? [String: Any])
    return UsageExport.DayInput(
      date: try #require(day["date"] as? String),
      totalTokens: intValue(totals["total_tokens"]),
      inputTokens: intValue(totals["input_tokens"]),
      outputTokens: intValue(totals["output_tokens"]),
      cacheReadTokens: intValue(totals["cache_read_input_tokens"]),
      cacheWriteTokens: intValue(totals["cache_write_input_tokens"]),
      reasoningTokens: intValue(totals["reasoning_tokens"]),
      messages: intValue(totals["messages"]),
      amountMicrousd: cost["amount_microusd"] as? String,
      costStatus: try #require(cost["status"] as? String)
    )
  }
  let coverage = try #require(object["coverage"] as? [String: Any])
  let boundsObject = object["bounds"] as? [String: Any]
  let revisionObject = object["revision"] as? [String: Any]
  return UsageExport.Input(
    scope: try #require(object["scope"] as? String),
    from: try #require(object["from"] as? String),
    to: try #require(object["to"] as? String),
    timezone: try #require(object["timezone"] as? String),
    bounds: boundsObject.map {
      UsageExport.Bounds(
        start: $0["start"] as? String ?? "",
        end: $0["end"] as? String ?? "",
        grid: $0["grid"] as? String ?? ""
      )
    },
    coverage: UsageExport.Coverage(
      partial: coverage["partial"] as? Bool ?? false,
      truncatedByRetention: coverage["truncated_by_retention"] as? Bool ?? false
    ),
    revision: revisionObject.map {
      UsageExport.Revision(
        usageRevision: intValue($0["usage_revision"]),
        deviceGeneration: intValue($0["device_generation"]),
        accountUpdatedAt: $0["account_updated_at"] as? String,
        pricingRevision: $0["pricing_revision"] as? String ?? "",
        modelCatalogRevision: $0["model_catalog_revision"] as? String ?? "",
        foldVersion: intValue($0["fold_version"])
      )
    },
    exportedAt: try #require(object["exported_at"] as? String),
    appVersion: try #require(object["app_version"] as? String),
    days: days
  )
}

private func intValue(_ value: Any?) -> Int {
  (value as? NSNumber)?.intValue ?? 0
}

private func canonicalJSON(_ object: Any) throws -> String {
  let data = try JSONSerialization.data(
    withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
  return String(decoding: data, as: UTF8.self)
}
