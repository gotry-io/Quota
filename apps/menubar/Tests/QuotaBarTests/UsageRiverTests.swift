import Foundation
import QuotaPresentation
import QuotaWire
import Testing

@testable import QuotaBar

struct UsageRiverTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
  }()

  private let series = UsageModelSeries(
    models: [UsageModelSeriesEntry(model: "gpt-5", provider: .openai)],
    days: [
      day("2026-08-01", tokens: 10, cost: "2000000"),
      // 2026-08-02 reported nothing.
      day("2026-08-03", tokens: 40, cost: nil),
      day("2026-08-04", tokens: 20, cost: "1000000"),
    ]
  )

  /// An empty day keeps its place with a baseline tick. In Amount the stack meets the baseline
  /// there; in Share the area breaks rather than dipping to 0 %; in Cost a day nothing could
  /// price is its own tick, never $0.
  @Test
  func anEmptyDayIsATickThatBreaksShareAndAnUnpricedDayIsNotZero() throws {
    let range = UsageDateRange(from: "2026-08-01", to: "2026-08-04")
    let amount = try #require(river(range, metric: .tokens, scale: .amount))
    let empty = try #require(UsageDateText.date(from: "2026-08-02", calendar))
    #expect(amount.dates.count == 4)
    #expect(amount.ticks == [empty: .empty])
    #expect(amount.bands.first { $0.date == empty }?.high == 0)

    let share = try #require(river(range, metric: .tokens, scale: .share))
    #expect(!share.bands.contains { $0.date == empty })
    #expect(Set(share.bands.map(\.segmentKey)).count == 2)

    let cost = try #require(river(range, metric: .cost, scale: .amount))
    let unpriced = try #require(UsageDateText.date(from: "2026-08-03", calendar))
    #expect(cost.ticks[unpriced] == .unpriced)
    #expect(cost.ticks[empty] == .empty)

    #expect(river(UsageDateRange(from: "2026-08-04", to: "2026-08-04"), metric: .tokens, scale: .amount) == nil)
  }

  /// A fixed window is compared with the same number of days just before it; a stepping
  /// period with the unit before it; `all` with nothing.
  @Test
  func thePreviousPeriodIsTheSameLengthJustBefore() throws {
    let today = try #require(UsageDateText.date(from: "2026-08-03", calendar))
    let week = UsageModel.previousRange(of: .last7Days, today: today, calendar: calendar)
    #expect(week?.from == "2026-07-21" && week?.to == "2026-07-27")
    let month = UsageModel.previousRange(of: .thisMonth, today: today, calendar: calendar)
    #expect(month?.from == "2026-07-01" && month?.to == "2026-07-31")
    #expect(UsageModel.previousRange(of: .all, today: today, calendar: calendar) == nil)
  }

  private func river(
    _ range: UsageDateRange, metric: UsageMetric, scale: UsageRiverScale
  ) -> UsageRiver? {
    UsageRiver.make(
      range: range,
      series: series,
      days: nil,
      metric: metric,
      scale: scale,
      colors: .empty,
      today: "2026-08-04",
      calendar: calendar
    )
  }
}

private func day(_ date: String, tokens: Int, cost: String?) -> UsageModelSeriesDay {
  UsageModelSeriesDay(
    date: date,
    partial: false,
    models: [
      UsageModelSeriesCell(
        model: "gpt-5",
        totalTokens: tokens,
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadInputTokens: 0,
        cacheWriteInputTokens: 0,
        costMicrousd: cost
      )
    ]
  )
}
