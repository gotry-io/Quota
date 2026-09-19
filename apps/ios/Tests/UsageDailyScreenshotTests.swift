import QuotaWire
import SwiftUI
import Testing
import UIKit

@testable import Quota

@MainActor
struct UsageDailyScreenshotTests {
  @Test
  func renderEmptyAndUnpricedDaysToPNG() throws {
    let directory = screenshotDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let rows = UsageDailyFold.rows(
      reported: [
        UsageActivityDay(
          date: "2026-08-10",
          totals: totals(120, cache: 40, output: 30),
          cost: priced("1800000"),
          partial: false,
          agents: nil
        ),
        UsageActivityDay(
          date: "2026-08-12",
          totals: totals(40, cache: 0, output: 10),
          cost: unpricedCost(),
          partial: false,
          agents: nil
        ),
      ],
      from: "2026-08-08",
      to: "2026-08-14"
    )
    let view = UsageDailySection(rows: rows)
      .frame(width: 390)
      .padding(16)
      .background(Color(uiColor: .systemGroupedBackground))
      .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 3
    renderer.proposedSize = ProposedViewSize(width: 422, height: 420)
    guard let data = renderer.uiImage?.pngData() else {
      throw ScreenshotError.unrenderable
    }
    #expect(data.count > 100)
    try data.write(to: directory.appendingPathComponent("usage-daily-empty-days.png"))
  }
}

private enum ScreenshotError: Error {
  case unrenderable
}

private func screenshotDirectory() -> URL {
  if let override = ProcessInfo.processInfo.environment["QUOTA_USAGE_CHART_SCREENSHOT_DIR"],
    !override.isEmpty
  {
    return URL(fileURLWithPath: override, isDirectory: true)
  }
  return FileManager.default.temporaryDirectory
    .appendingPathComponent("quota-usage-daily-screenshots", isDirectory: true)
}

private func totals(_ input: Int, cache: Int, output: Int) -> UsageSummaryTotals {
  UsageSummaryTotals(
    totalTokens: input + output,
    inputTokens: input,
    outputTokens: output,
    cacheReadInputTokens: cache,
    cacheWriteInputTokens: 0,
    reasoningTokens: 0,
    messages: 2
  )
}

private func priced(_ amountMicrousd: String) -> UsageCostOutcome {
  UsageCostOutcome(
    mode: .calculate,
    basis: .calculated,
    status: .complete,
    amountMicrousd: amountMicrousd,
    catalogRevision: "pricing_1",
    calculatedRows: 1,
    reportedRows: 0,
    unpricedRows: 0,
    assumptions: [],
    unpriced: []
  )
}

private func unpricedCost() -> UsageCostOutcome {
  UsageCostOutcome(
    mode: .calculate,
    basis: .none,
    status: .unavailable,
    amountMicrousd: nil,
    catalogRevision: nil,
    calculatedRows: 0,
    reportedRows: 0,
    unpricedRows: 1,
    assumptions: [],
    unpriced: [
      UsageUnpricedItem(
        billingChannel: .openaiDirect,
        model: "other",
        reason: .unknownModel,
        rows: 1
      )
    ]
  )
}
