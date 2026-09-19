import Charts
import QuotaPresentation
import QuotaWire
import SwiftUI

/// How one local day is drawn on the Usage cost chart.
enum DashboardUsageDayKind: Equatable {
  case cost(Double)
  case empty
  case unpriced
}

func dashboardUsageDayKind(_ day: LocalUsageDay) -> DashboardUsageDayKind {
  if day.totals.totalTokens == 0 { return .empty }
  if day.cost.status == .unavailable { return .unpriced }
  let usd = dashboardUsageCostUSD(day.cost)
  return usd > 0 ? .cost(usd) : .empty
}

/// Cost per local day from ADR 0036's already-folded `days[]`. The view does not fold again.
struct DashboardUsageChart: View {
  let days: [LocalUsageDay]

  var body: some View {
    Chart {
      ForEach(days, id: \.date) { day in
        switch dashboardUsageDayKind(day) {
        case .cost(let usd):
          BarMark(
            x: .value("Day", day.date),
            y: .value("Cost", usd)
          )
          .foregroundStyle(QuotaPalette.ink.opacity(0.55))
          .accessibilityLabel(day.date)
          .accessibilityValue(UsageBudgetProgress.usd(Decimal(usd)))
        case .empty:
          BarMark(
            x: .value("Day", day.date),
            y: .value("Cost", 0)
          )
          .foregroundStyle(.clear)
          .annotation(position: .overlay, alignment: .bottom) {
            Capsule()
              .fill(Color(nsColor: .tertiarySystemFill))
              .frame(height: 2)
          }
          .accessibilityLabel(day.date)
          .accessibilityValue("no usage")
        case .unpriced:
          BarMark(
            x: .value("Day", day.date),
            y: .value("Cost", 0)
          )
          .foregroundStyle(.clear)
          .annotation(position: .overlay, alignment: .bottom) {
            Capsule()
              .strokeBorder(
                Color(nsColor: .tertiaryLabelColor),
                style: StrokeStyle(lineWidth: 1, dash: [1.5, 1])
              )
              .frame(height: 2)
          }
          .accessibilityLabel(day.date)
          .accessibilityValue("unpriced")
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(usdLabel(amount))
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks { value in
        AxisValueLabel {
          if let date = value.as(String.self) {
            Text(shortDate(date))
          }
        }
      }
    }
    .frame(minHeight: 120)
    .accessibilityChartDescriptor(DashboardUsageChartDescriptor(days: days))
  }

  private func shortDate(_ date: String) -> String {
    String(date.suffix(5))
  }

  private func usdLabel(_ amount: Double) -> String {
    UsageBudgetProgress.usd(Decimal(amount))
  }
}

private struct DashboardUsageChartDescriptor: AXChartDescriptorRepresentable {
  let days: [LocalUsageDay]

  func makeChartDescriptor() -> AXChartDescriptor {
    let amounts = days.map { day -> Double in
      if case .cost(let usd) = dashboardUsageDayKind(day) { return usd }
      return 0
    }
    let maxAmount = max(amounts.max() ?? 0, 1)
    let lastIndex = Double(max(days.count - 1, 0))
    let yAxis = AXNumericDataAxisDescriptor(
      title: "Cost",
      range: 0...maxAmount,
      gridlinePositions: []
    ) { value in
      UsageBudgetProgress.usd(Decimal(value))
    }
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Day",
      range: 0...lastIndex,
      gridlinePositions: []
    ) { value in
      let index = Int(value.rounded())
      guard days.indices.contains(index) else { return "" }
      return days[index].date
    }
    let series = AXDataSeriesDescriptor(
      name: "Cost by day",
      isContinuous: false,
      dataPoints: days.enumerated().map { index, day in
        switch dashboardUsageDayKind(day) {
        case .cost(let usd):
          return AXDataPoint(x: Double(index), y: usd)
        case .empty:
          var point = AXDataPoint(x: Double(index), y: 0)
          point.label = "no usage"
          return point
        case .unpriced:
          var point = AXDataPoint(x: Double(index), y: 0)
          point.label = "unpriced"
          return point
        }
      }
    )
    return AXChartDescriptor(
      title: "Usage cost by day",
      summary: summary,
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: [series]
    )
  }

  private var summary: String {
    let priced = days.filter {
      if case .cost = dashboardUsageDayKind($0) { return true }
      return false
    }.count
    let unpriced = days.filter { dashboardUsageDayKind($0) == .unpriced }.count
    if unpriced == 0 {
      return "\(days.count) days, \(priced) with cost"
    }
    return "\(days.count) days, \(priced) with cost, \(unpriced) unpriced"
  }
}

/// Dollars from an already-folded day's cost. Isolated from the view so VoiceOver can read it.
private func dashboardUsageCostUSD(_ cost: UsageCostOutcome) -> Double {
  guard cost.status != .unavailable, let microusd = cost.amountMicrousd,
    let decimal = Decimal(string: microusd, locale: Locale(identifier: "en_US_POSIX"))
  else {
    return 0
  }
  return NSDecimalNumber(decimal: decimal / 1_000_000).doubleValue
}
