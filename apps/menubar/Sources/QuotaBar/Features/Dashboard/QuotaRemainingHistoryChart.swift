import Charts
import QuotaPresentation
import SwiftUI

/// Labelled remaining 0–100 over calendar time for one window.
///
/// Solid segments are observations; a reset starts a new segment; a dashed segment is the
/// ADR 0035 estimate at reset, the same projection the pace headline uses. See ADR 0042.
struct QuotaRemainingHistoryChart: View {
  let history: QuotaRemainingHistory
  var tint: Color = QuotaPalette.accent
  var windowTitle: String = ""
  var historySource: QuotaHistorySource = .thisDevice

  @State private var observedListOpen = false

  /// Tall enough for 0 / 50 / 100 % labels and time ticks.
  static let height: CGFloat = 168

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      chart
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(DashboardQuotaCopy.remainingHistory)
        .accessibilityValue(summary)
        .accessibilityChartDescriptor(descriptor)
        .accessibilityIdentifier("quota.history")

      legend
        .accessibilityHidden(true)

      DisclosureGroup(isExpanded: $observedListOpen) {
        ForEach(dataList, id: \.id) { row in
          HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.sm) {
            Text(row.label)
              .quotaSecondaryStyle()
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: QuotaDesign.Spacing.sm)
            Text(row.value)
              .quotaMetaStyle()
              .monospacedDigit()
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(row.label)
          .accessibilityValue(row.value)
        }
      } label: {
        Text("Observed remaining, \(history.spanDescription)")
          .quotaSecondaryStyle()
          .accessibilityIdentifier("quota.history.observed")
      }
    }
  }

  private var chart: some View {
    Chart {
      ForEach(history.segments, id: \.resetsAt) { segment in
        ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
          LineMark(
            x: .value("Time", point.date),
            y: .value("Remaining", point.remainingPercent),
            series: .value("Window", segmentName(segment))
          )
          .foregroundStyle(tint)
          .interpolationMethod(.linear)
          .lineStyle(StrokeStyle(lineWidth: 2))
        }
        if segment.points.count == 1, let point = segment.points.first {
          PointMark(
            x: .value("Time", point.date),
            y: .value("Remaining", point.remainingPercent)
          )
          .foregroundStyle(tint)
          .symbolSize(24)
        }
      }
      if let last = history.observedPoints.last, let estimate = history.estimate {
        LineMark(
          x: .value("Time", last.date),
          y: .value("Remaining", last.remainingPercent),
          series: .value("Window", "Estimate")
        )
        .foregroundStyle(tint.opacity(0.65))
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        LineMark(
          x: .value("Time", estimate.date),
          y: .value("Remaining", estimate.remainingPercent),
          series: .value("Window", "Estimate")
        )
        .foregroundStyle(tint.opacity(0.65))
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        PointMark(
          x: .value("Time", estimate.date),
          y: .value("Remaining", estimate.remainingPercent)
        )
        .foregroundStyle(tint.opacity(0.65))
        .symbolSize(24)
      }
    }
    .chartYScale(domain: 0...100)
    .chartXScale(domain: xDomain)
    .chartLegend(.hidden)
    .chartYAxis {
      AxisMarks(values: [0, 50, 100]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text("\(Int(amount))%")
              .foregroundStyle(QuotaPalette.body)
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine()
        AxisTick()
        AxisValueLabel()
          .foregroundStyle(QuotaPalette.body)
      }
    }
  }

  private var legend: some View {
    HStack(spacing: QuotaDesign.Spacing.md) {
      legendItem(label: "Observed", dashed: false)
      if history.estimate != nil {
        legendItem(label: "Estimate", dashed: true)
      }
    }
    .quotaMetaStyle()
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func legendItem(label: String, dashed: Bool) -> some View {
    HStack(spacing: QuotaDesign.Spacing.xs) {
      if dashed {
        Capsule()
          .stroke(
            tint.opacity(0.65),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3])
          )
          .frame(width: 16, height: 2)
      } else {
        Capsule()
          .fill(tint)
          .frame(width: 16, height: 2)
      }
      Text(label)
    }
  }

  private var xDomain: ClosedRange<Date> {
    history.chartDomain
  }

  private var summary: String {
    var parts: [String] = []
    if historySource == .yourDevices {
      if windowTitle.isEmpty {
        parts.append("Remaining history from your devices, \(history.spanDescription)")
      } else {
        parts.append(
          "Remaining history from your devices for \(windowTitle), \(history.spanDescription)"
        )
      }
    } else if windowTitle.isEmpty {
      parts.append("Remaining history on this Mac, \(history.spanDescription)")
    } else {
      parts.append(
        "Remaining history on this Mac for \(windowTitle), \(history.spanDescription)"
      )
    }
    if let first = history.observedPoints.first, let last = history.observedPoints.last {
      if first.date == last.date {
        parts.append("last observed remaining \(percent(last.remainingPercent))")
      } else {
        let from = percent(first.remainingPercent)
        let to = percent(last.remainingPercent)
        parts.append("observed remaining from \(from) to \(to)")
      }
    }
    if let estimate = history.estimate {
      parts.append("estimate \(percent(estimate.remainingPercent)) at reset")
    }
    return parts.joined(separator: ". ") + "."
  }

  private var dataList: [DataRow] {
    var rows: [DataRow] = []
    for (index, point) in history.observedPoints.enumerated() {
      rows.append(
        DataRow(
          id: "observed-\(index)",
          label: timestamp.string(from: point.date),
          value: percent(point.remainingPercent)
        )
      )
    }
    if let estimate = history.estimate {
      rows.append(
        DataRow(
          id: "estimate",
          label: "Estimate at reset",
          value: percent(estimate.remainingPercent)
        )
      )
    }
    return rows
  }

  private var descriptor: QuotaRemainingHistoryChartDescriptor {
    QuotaRemainingHistoryChartDescriptor(
      history: history,
      windowTitle: windowTitle,
      summary: summary
    )
  }

  private func segmentName(_ segment: QuotaRemainingHistorySegment) -> String {
    "\(segment.resetsAt.timeIntervalSince1970)"
  }

  private func percent(_ value: Double) -> String {
    RemainingQuotaFormat.percent(value)
  }

  private var timestamp: DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("Mdjm")
    return formatter
  }

  private struct DataRow: Equatable {
    var id: String
    var label: String
    var value: String
  }
}

private struct QuotaRemainingHistoryChartDescriptor: AXChartDescriptorRepresentable {
  let history: QuotaRemainingHistory
  let windowTitle: String
  let summary: String

  func makeChartDescriptor() -> AXChartDescriptor {
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Time",
      range: xRange,
      gridlinePositions: []
    ) { value in
      Self.timestamp.string(from: Date(timeIntervalSince1970: value))
    }
    let yAxis = AXNumericDataAxisDescriptor(
      title: "Remaining percent",
      range: 0...100,
      gridlinePositions: [0, 50, 100]
    ) { value in
      RemainingQuotaFormat.percent(value)
    }
    var series = history.segments.enumerated().map { index, segment in
      AXDataSeriesDescriptor(
        name: history.segments.count == 1 ? "Observed" : "Window \(index + 1)",
        isContinuous: true,
        dataPoints: segment.points.map { point in
          AXDataPoint(x: point.date.timeIntervalSince1970, y: point.remainingPercent)
        }
      )
    }
    if let last = history.observedPoints.last, let estimate = history.estimate {
      series.append(
        AXDataSeriesDescriptor(
          name: "Estimate",
          isContinuous: true,
          dataPoints: [
            AXDataPoint(x: last.date.timeIntervalSince1970, y: last.remainingPercent),
            AXDataPoint(x: estimate.date.timeIntervalSince1970, y: estimate.remainingPercent),
          ]
        )
      )
    }
    let title =
      windowTitle.isEmpty
      ? DashboardQuotaCopy.remainingHistory
      : "\(DashboardQuotaCopy.remainingHistory), \(windowTitle)"
    return AXChartDescriptor(
      title: title,
      summary: summary,
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: series
    )
  }

  private var xRange: ClosedRange<Double> {
    let domain = history.chartDomain
    return domain.lowerBound.timeIntervalSince1970...domain.upperBound.timeIntervalSince1970
  }

  private static let timestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()
}
