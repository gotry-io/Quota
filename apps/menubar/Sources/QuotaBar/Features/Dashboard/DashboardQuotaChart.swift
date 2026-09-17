import Charts
import QuotaPresentation
import SwiftUI

/// One provider's windows as used percent over time.
///
/// Colour is the remaining-quota tone of each window; rank is opacity so two windows of the
/// same provider stay distinguishable without a second palette.
struct DashboardQuotaChart: View {
  let series: [DashboardQuotaSeries]
  let now: Date

  var body: some View {
    Chart {
      ForEach(series) { item in
        ForEach(item.points) { point in
          LineMark(
            x: .value("Time", point.date),
            y: .value("Used", point.usedPercent),
            series: .value("Window", instanceSeriesName(item.title, point))
          )
          .foregroundStyle(lineColor(item))
          .interpolationMethod(.linear)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        if let last = item.points.last, let projection = item.projection {
          LineMark(
            x: .value("Time", last.date),
            y: .value("Used", last.usedPercent),
            series: .value("Window", projectionSeriesName(item.title))
          )
          .foregroundStyle(lineColor(item).opacity(0.65))
          .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
          LineMark(
            x: .value("Time", projection.date),
            y: .value("Used", projection.usedPercent),
            series: .value("Window", projectionSeriesName(item.title))
          )
          .foregroundStyle(lineColor(item).opacity(0.65))
          .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        if let resetAt = item.resetAt {
          RuleMark(x: .value("Reset", resetAt))
            .foregroundStyle(QuotaPalette.mute)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            .accessibilityLabel("Reset \(item.title)")
        }
      }
    }
    .chartYScale(domain: 0...100)
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 5)) { _ in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
          .foregroundStyle(QuotaPalette.mute)
      }
    }
    .chartYAxis {
      AxisMarks(values: [0, 25, 50, 75, 100]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text("\(Int(amount))%")
              .foregroundStyle(QuotaPalette.mute)
          }
        }
      }
    }
    .chartLegend(position: .bottom, alignment: .leading)
    .frame(height: QuotaDesign.Layout.quotaChartHeight)
    .accessibilityChartDescriptor(DashboardQuotaChartDescriptor(series: series, now: now))
  }

  private func lineColor(_ item: DashboardQuotaSeries) -> Color {
    let tone = QuotaPalette.usageColor(remainingPercent: item.remainingPercent)
    switch item.rank {
    case 0: return tone
    case 1: return tone.opacity(0.72)
    default: return tone.opacity(0.48)
    }
  }

  private func projectionSeriesName(_ title: String) -> String {
    "\(title) projection"
  }

  /// One line per window instance: a reset drops to zero on a new line, not down the old one.
  private func instanceSeriesName(_ title: String, _ point: DashboardQuotaPoint) -> String {
    guard let resetsAt = point.resetsAt else { return title }
    return "\(title) \(resetsAt.timeIntervalSince1970)"
  }
}

/// Names each window, its start, now, and the projected end.
private struct DashboardQuotaChartDescriptor: AXChartDescriptorRepresentable {
  let series: [DashboardQuotaSeries]
  let now: Date

  func makeChartDescriptor() -> AXChartDescriptor {
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Time",
      range: xRange,
      gridlinePositions: []
    ) { value in
      Self.timestamp.string(from: Date(timeIntervalSince1970: value))
    }
    let yAxis = AXNumericDataAxisDescriptor(
      title: "Used percent",
      range: 0...100,
      gridlinePositions: [0, 25, 50, 75, 100]
    ) { value in
      "\(Int(value.rounded()))%"
    }
    let dataSeries = series.map { item in
      AXDataSeriesDescriptor(
        name: item.title,
        isContinuous: true,
        dataPoints: item.points.map { point in
          AXDataPoint(x: point.date.timeIntervalSince1970, y: point.usedPercent)
        }
      )
    }
    return AXChartDescriptor(
      title: "Quota used",
      summary: summary,
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: dataSeries
    )
  }

  private var xRange: ClosedRange<Double> {
    var values: [Double] = [now.timeIntervalSince1970]
    for item in series {
      if let start = item.startedAt {
        values.append(start.timeIntervalSince1970)
      }
      if let reset = item.resetAt {
        values.append(reset.timeIntervalSince1970)
      }
      values.append(contentsOf: item.points.map { $0.date.timeIntervalSince1970 })
    }
    let minValue = values.min() ?? now.timeIntervalSince1970
    let maxValue = values.max() ?? now.timeIntervalSince1970
    return min(minValue, maxValue)...max(minValue, maxValue)
  }

  private var summary: String {
    series.map(windowSummary).joined(separator: ". ")
  }

  private func windowSummary(_ item: DashboardQuotaSeries) -> String {
    let start = item.startedAt ?? item.points.first?.date
    let end = item.projection?.date ?? item.resetAt
    var parts = [item.title]
    if let start {
      parts.append("start \(Self.timestamp.string(from: start))")
    }
    parts.append("now \(Self.timestamp.string(from: now))")
    if let end {
      parts.append("projected end \(Self.timestamp.string(from: end))")
    }
    return parts.joined(separator: ", ")
  }

  private static let timestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()
}
