import Foundation
import QuotaWire
import Testing

@testable import Quota

struct UsageActivityChartTests {
  @Test
  func padsToSundayFirstWeeksAndKeepsInRangeDaysSelectable() {
    let chart = UsageActivityChart.build(
      reported: [day("2026-01-15", input: 100, output: 20)],
      range: (from: "2026-01-15", to: "2026-01-16"),
      today: "2026-01-16"
    )

    #expect(chart.days[0].date == "2026-01-11")
    #expect(UsageActivityCalendar.utc.component(.weekday, from: date("2026-01-11")) == 1)
    #expect(chart.days.last?.date == "2026-01-17")
    #expect(UsageActivityCalendar.utc.component(.weekday, from: date("2026-01-17")) == 7)
    #expect(chart.days.count % 7 == 0)
    #expect(chart.weeks[0][0].date == "2026-01-11")
    #expect(chart.days.first { $0.date == "2026-01-14" }?.outside == true)
    #expect(chart.days.first { $0.date == "2026-01-15" }?.outside == false)
    #expect(chart.days.first { $0.date == "2026-01-16" }?.today == true)
    #expect(UsageActivityCalendar.weekdayLabels == ["", "Mon", "", "Wed", "", "Fri", ""])
  }

  @Test
  func takesEachDaysTotalsCostAndScanVerdictAsRelayFoldedThem() {
    let chart = UsageActivityChart.build(
      reported: [
        day(
          "2026-03-02",
          input: 150,
          output: 50,
          cost: cost(amountMicrousd: "400000", status: .partial, unpricedRows: 1),
          partial: true
        ),
        day("2026-03-03", input: 10, output: 10),
      ],
      range: (from: "2026-03-02", to: "2026-03-03"),
      today: "2026-03-03"
    )

    let first = chart.days.first { $0.date == "2026-03-02" }
    #expect(first?.tokens == 200)
    #expect(first?.partial == true)
    #expect(first?.cost?.status == .partial)
    #expect(first?.cost?.amountMicrousd == "400000")
    #expect(first?.level == 4)
    #expect(chart.days.first { $0.date == "2026-03-03" }?.level == 1)
    #expect(chart.days.first { $0.date == "2026-03-04" }?.level == 0)
  }

  @Test
  func placesMonthLabelsOnWeekColumnsAndDropsOverlappingNeighbors() {
    let wide = UsageActivityChart.build(
      reported: [],
      range: (from: "2026-01-01", to: "2026-03-15"),
      today: "2026-03-15"
    )
    #expect(wide.monthLabels.map(\.weekIndex) == [0, 5, 9])
    #expect(wide.monthLabels.map(\.label) == ["Jan", "Feb", "Mar"])
    #expect(wide.monthLabels[0].span == 5)
    #expect(wide.monthLabels[1].span == 4)

    let tight = UsageActivityChart.build(
      reported: [],
      range: (from: "2026-01-31", to: "2026-02-02"),
      today: "2026-02-02"
    )
    #expect(tight.weeks.count == 2)
    #expect(tight.monthLabels.map(\.label) == ["Jan"])
    #expect(tight.monthLabels[0].weekIndex == 0)
    #expect(tight.monthLabels[0].span == 2)
  }

  @Test
  func anchorsAMidWeekMonthOnTheSundayFirstWeekThatContainsItsFirstVisibleDay() {
    let june = UsageActivityChart.build(
      reported: [],
      range: (from: "2026-05-01", to: "2026-06-15"),
      today: "2026-06-15"
    )
    #expect(UsageActivityCalendar.utc.component(.weekday, from: date("2026-06-01")) == 2)
    let juneWeek = june.weeks.firstIndex { week in week.contains { $0.date == "2026-06-01" } }
    #expect(juneWeek == 5)
    #expect(june.weeks[juneWeek ?? -1][0].date == "2026-05-31")
    #expect(june.monthLabels.map(\.weekIndex) == [0, 5])
    #expect(june.monthLabels.map(\.label) == ["May", "Jun"])

    let july = UsageActivityChart.build(
      reported: [],
      range: (from: "2026-06-15", to: "2026-07-10"),
      today: "2026-07-10"
    )
    #expect(UsageActivityCalendar.utc.component(.weekday, from: date("2026-07-01")) == 4)
    let julyWeek = july.weeks.firstIndex { week in week.contains { $0.date == "2026-07-01" } } ?? -1
    let julyWeekStart = july.weeks[julyWeek][0].date
    #expect(julyWeek >= 0)
    #expect(julyWeekStart < "2026-07-01")
    #expect(july.monthLabels.first { $0.label == "Jul" }?.weekIndex == julyWeek)
    #expect(july.monthLabels.first { $0.label == "Jul" }?.weekIndex != julyWeek + 1)
  }

  @Test
  func aOneWeekTrailingMonthKeepsItsFullAbbreviation() {
    // 2026-09-01 is Tuesday, so a range ending 2026-09-05 places Sep on the last week.
    let chart = UsageActivityChart.build(
      reported: [day("2026-09-05", input: 10, output: 0)],
      range: (from: "2025-09-06", to: "2026-09-05"),
      today: "2026-09-05"
    )
    #expect(chart.monthLabels.last?.label == "Sep")
    #expect(chart.monthLabels.last?.span == 1)
    #expect(chart.monthLabels.allSatisfy { $0.label.count == 3 })
    #expect(!chart.monthLabels.map(\.label).contains("…"))
  }

  @Test
  func activityWindowIs365UtcDaysEndingToday() {
    let range = UsageActivityCalendar.range(endingOn: "2026-08-14")
    #expect(range.from == "2025-08-15")
    #expect(range.to == "2026-08-14")
    #expect(UsageActivityCalendar.longDate("2026-08-14") == "August 14, 2026")
  }

  @Test
  func fiveFillLevelsAreZeroAndFourEqualBandsOfTheBusiestDay() {
    #expect(UsageActivityChart.activityLevel(0, maximum: 200) == 0)
    #expect(UsageActivityChart.activityLevel(20, maximum: 0) == 0)
    #expect(UsageActivityChart.activityLevel(20, maximum: 200) == 1)
    #expect(UsageActivityChart.activityLevel(200, maximum: 200) == 4)
  }

  @Test
  func selectedDayAccessibilityStatesDateTokensAndCost() {
    let chart = UsageActivityChart.build(
      reported: [day("2026-08-14", input: 80, output: 20, cost: cost(amountMicrousd: "1230000"))],
      range: (from: "2026-08-14", to: "2026-08-14"),
      today: "2026-08-14"
    )
    let spoken = chart.days.first { $0.date == "2026-08-14" }?.accessibilityValue
    #expect(spoken?.contains("August 14, 2026") == true)
    #expect(spoken?.contains("tokens") == true)
    #expect(spoken?.contains("complete") == true)
  }

  @Test
  func emptyActivityIsZeroReportedTokensAcrossTheRange() {
    #expect(UsageActivityChart.hasReportedActivity([]) == false)
    #expect(
      UsageActivityChart.hasReportedActivity([
        day("2026-08-14", input: 0, output: 0),
        day("2026-08-13", input: 0, output: 0),
      ]) == false
    )
    #expect(
      UsageActivityChart.hasReportedActivity([
        day("2026-08-14", input: 0, output: 0),
        day("2026-08-13", input: 1, output: 0),
      ])
    )
  }

  @Test
  func defaultSelectedDatePrefersTodayThenTheLastInRangeDay() {
    let withToday = UsageActivityChart.build(
      reported: [day("2026-01-15", input: 10, output: 0)],
      range: (from: "2026-01-15", to: "2026-01-16"),
      today: "2026-01-16"
    )
    #expect(withToday.defaultSelectedDate == "2026-01-16")

    let withoutToday = UsageActivityChart.build(
      reported: [day("2026-01-15", input: 10, output: 0)],
      range: (from: "2026-01-15", to: "2026-01-16"),
      today: "2026-01-20"
    )
    #expect(withoutToday.defaultSelectedDate == "2026-01-16")
  }

  @Test
  func adjacentSelectionStopsAtTheFirstAndLastInRangeDay() {
    let chart = UsageActivityChart.build(
      reported: [day("2026-01-15", input: 10, output: 0)],
      range: (from: "2026-01-15", to: "2026-01-16"),
      today: "2026-01-16"
    )

    #expect(chart.adjacentSelectableDay(from: "2026-01-15", increment: true)?.date == "2026-01-16")
    #expect(chart.adjacentSelectableDay(from: "2026-01-16", increment: true)?.date == "2026-01-16")
    #expect(chart.adjacentSelectableDay(from: "2026-01-16", increment: false)?.date == "2026-01-15")
    #expect(chart.adjacentSelectableDay(from: "2026-01-15", increment: false)?.date == "2026-01-15")
    #expect(chart.adjacentSelectableDay(from: "2026-01-11", increment: true)?.date == "2026-01-16")
  }

  @Test
  func spatialSelectionMapsToTheNearestInRangeDayAndIgnoresPaddingCells() {
    let chart = UsageActivityChart.build(
      reported: [day("2026-01-15", input: 10, output: 0)],
      range: (from: "2026-01-15", to: "2026-01-16"),
      today: "2026-01-16"
    )
    let cellSize = 14.0
    let cellGap = 4.0
    let stride = cellSize + cellGap

    // One Sunday-first week: in-range Thursday (index 4) and Friday (index 5).
    let thursday = chart.nearestSelectableDay(
      atX: cellSize / 2,
      atY: 4 * stride + cellSize / 2,
      cellSize: cellSize,
      cellGap: cellGap
    )
    let friday = chart.nearestSelectableDay(
      atX: cellSize / 2,
      atY: 5 * stride + cellSize / 2,
      cellSize: cellSize,
      cellGap: cellGap
    )
    let sundayPadding = chart.nearestSelectableDay(
      atX: cellSize / 2,
      atY: cellSize / 2,
      cellSize: cellSize,
      cellGap: cellGap
    )
    let betweenThuFri = chart.nearestSelectableDay(
      atX: cellSize / 2,
      atY: 4.6 * stride + cellSize / 2,
      cellSize: cellSize,
      cellGap: cellGap
    )

    #expect(thursday?.date == "2026-01-15")
    #expect(friday?.date == "2026-01-16")
    #expect(sundayPadding?.date == "2026-01-15")
    #expect(betweenThuFri?.date == "2026-01-16")
    #expect(chart.selectableDay(on: "2026-01-11") == nil)
    #expect(chart.selectableDay(on: "2026-01-15")?.outside == false)
  }
}

private func date(_ value: String) -> Date {
  UsageActivityCalendar.date(from: value)
}

private func day(
  _ date: String,
  input: Int,
  output: Int,
  cost: UsageCostOutcome? = nil,
  partial: Bool = false
) -> UsageActivityDay {
  UsageActivityDay(
    date: date,
    totals: UsageSummaryTotals(
      totalTokens: input + output,
      inputTokens: input,
      outputTokens: output,
      cacheReadInputTokens: 0,
      cacheWriteInputTokens: 0,
      reasoningTokens: 0,
      messages: 1
    ),
    cost: cost ?? completeCost(),
    partial: partial
  )
}

private func completeCost() -> UsageCostOutcome {
  cost(amountMicrousd: "1230000", status: .complete, unpricedRows: 0)
}

private func cost(
  amountMicrousd: String?,
  status: UsageCostStatus = .complete,
  unpricedRows: Int = 0
) -> UsageCostOutcome {
  UsageCostOutcome(
    mode: .auto,
    basis: amountMicrousd == nil ? .none : .calculated,
    status: status,
    amountMicrousd: amountMicrousd,
    catalogRevision: nil,
    calculatedRows: amountMicrousd == nil ? 0 : 1,
    reportedRows: 0,
    unpricedRows: unpricedRows,
    assumptions: [],
    unpriced: unpricedRows == 0
      ? []
      : [
        UsageUnpricedItem(
          billingChannel: .openaiDirect,
          model: "other",
          reason: .unknownModel,
          rows: unpricedRows
        )
      ]
  )
}
