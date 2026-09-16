import Charts
import QuotaPresentation
import QuotaWire
import SwiftUI

/// Cost per local day from ADR 0036's already-folded `days[]`. The view does not fold again.
struct DashboardUsageChart: View {
  let days: [LocalUsageDay]

  var body: some View {
    Chart {
      ForEach(days, id: \.date) { day in
        BarMark(
          x: .value("Day", day.date),
          y: .value("Cost", costUSD(day))
        )
        .foregroundStyle(QuotaPalette.ink.opacity(hasCost(day) ? 0.55 : 0.12))
        .accessibilityLabel(day.date)
        .accessibilityValue(UsageValueFormatter.tokensAndCost(day.totals.totalTokens, day.cost))
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

  private func hasCost(_ day: LocalUsageDay) -> Bool {
    costUSD(day) > 0
  }

  private func costUSD(_ day: LocalUsageDay) -> Double {
    dashboardUsageCostUSD(day.cost)
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
    let amounts = days.map { dashboardUsageCostUSD($0.cost) }
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
      dataPoints: amounts.enumerated().map { index, amount in
        AXDataPoint(x: Double(index), y: amount)
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
    let priced = days.filter { dashboardUsageCostUSD($0.cost) > 0 }.count
    return "\(days.count) days, \(priced) with cost"
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
