import Charts
import QuotaPresentation
import QuotaWire
import SwiftUI

/// The model river in Swift Charts: one `AreaMark` band per model per local day, stacked from the
/// bottom in legend order, coloured by the surface's one model-colour assignment. The current day
/// is hatched as in progress; an empty day is a baseline tick, and in Cost mode a day nothing
/// could price is an outlined tick rather than a zero.
struct UsageRiverChart: View {
  let river: UsageRiver
  @State private var selectedDate: Date?

  var body: some View {
    Chart {
      ForEach(river.bands) { band in
        AreaMark(
          x: .value("Day", band.date),
          yStart: .value(valueLabel, band.low),
          yEnd: .value(valueLabel, band.high)
        )
        .foregroundStyle(by: .value("Series", band.segmentKey))
        .interpolationMethod(.monotone)
      }
      if let selectedDate {
        RuleMark(x: .value("Day", nearestDay(selectedDate)))
          .foregroundStyle(QuotaPalette.mute)
          .lineStyle(StrokeStyle(lineWidth: 1))
          .annotation(
            position: .top,
            spacing: 4,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            selectionDetail(selectedDate)
          }
      }
    }
    .chartForegroundStyleScale(
      domain: river.segmentKeys.map(\.key),
      range: river.segmentKeys.map { entry in
        QuotaPalette.model(river.series.first { $0.name == entry.series }?.swatch)
      }
    )
    .chartLegend(.hidden)
    .chartYScale(domain: .automatic(includesZero: true))
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(axisLabel(amount))
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
      }
    }
    .chartXSelection(value: $selectedDate)
    .chartOverlay { proxy in
      GeometryReader { geometry in
        if let plotFrame = proxy.plotFrame {
          let frame = geometry[plotFrame]
          Canvas { context, _ in
            drawInProgress(context: context, proxy: proxy, frame: frame)
            drawTicks(context: context, proxy: proxy, frame: frame)
          }
          .allowsHitTesting(false)
        }
      }
    }
    .frame(height: 200)
    .accessibilityChartDescriptor(UsageRiverDescriptor(river: river))
    .accessibilityIdentifier("usage.river")
  }

  private var valueLabel: String {
    river.scale == .share ? "Share" : river.metric.title
  }

  private func axisLabel(_ amount: Double) -> String {
    if river.scale == .share { return "\(Int((amount * 100).rounded()))%" }
    return UsageRiverFormat.value(amount, metric: river.metric)
  }

  /// The plotted day nearest the pointer.
  private func nearestDay(_ date: Date) -> Date {
    river.dates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) } ?? date
  }

  private func selectionDetail(_ date: Date) -> some View {
    let day = nearestDay(date)
    let top = river.bands
      .filter { $0.date == day && $0.high > $0.low }
      .sorted { ($0.high - $0.low) > ($1.high - $1.low) }
      .prefix(3)
    return VStack(alignment: .leading, spacing: 2) {
      Text(day.formatted(.dateTime.month(.abbreviated).day()))
        .quotaFont(.meta)
        .foregroundStyle(QuotaPalette.body)
      Text(UsageRiverFormat.value(river.dayTotals[day] ?? 0, metric: river.metric))
        .quotaFont(.settingsLabel)
        .foregroundStyle(QuotaPalette.ink)
        .monospacedDigit()
      if river.scale == .amount {
        ForEach(Array(top), id: \.id) { band in
          Text("\(band.series) · \(UsageRiverFormat.value(band.high - band.low, metric: river.metric))")
            .quotaFont(.meta)
            .foregroundStyle(QuotaPalette.body)
            .lineLimit(1)
        }
      }
    }
    .padding(QuotaDesign.Spacing.xs)
    .background {
      RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
        .fill(QuotaPalette.cardFill)
        .overlay {
          RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
            .strokeBorder(QuotaPalette.cardHairline, lineWidth: 1)
        }
    }
  }

  /// Hatches the span from the day before today to today: that day is still being written.
  private func drawInProgress(context: GraphicsContext, proxy: ChartProxy, frame: CGRect) {
    guard let today = river.inProgress, let todayX = proxy.position(forX: today),
      let index = river.dates.firstIndex(of: today), index > 0,
      let startX = proxy.position(forX: river.dates[index - 1])
    else { return }
    let rect = CGRect(
      x: frame.minX + startX, y: frame.minY, width: max(todayX - startX, 0), height: frame.height)
    var hatch = Path()
    var x = rect.minX - rect.height
    while x < rect.maxX {
      hatch.move(to: CGPoint(x: x, y: rect.maxY))
      hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
      x += 5
    }
    var clipped = context
    clipped.clip(to: Path(rect))
    clipped.stroke(hatch, with: .color(QuotaPalette.cardFill.opacity(0.75)), lineWidth: 1.5)
  }

  private func drawTicks(context: GraphicsContext, proxy: ChartProxy, frame: CGRect) {
    for (date, tick) in river.ticks {
      guard let x = proxy.position(forX: date) else { continue }
      let rect = CGRect(x: frame.minX + x - 4, y: frame.maxY - 2, width: 8, height: 2)
      switch tick {
      case .empty:
        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(QuotaPalette.soft))
      case .unpriced:
        context.stroke(
          Path(roundedRect: rect, cornerRadius: 1),
          with: .color(QuotaPalette.mute),
          style: StrokeStyle(lineWidth: 1, dash: [1.5, 1])
        )
      }
    }
  }
}

enum UsageRiverFormat {
  static func value(_ amount: Double, metric: UsageMetric) -> String {
    switch metric {
    case .tokens, .messages: UsageValueFormatter.count(Int(amount.rounded()))
    case .cost: UsageBudgetProgress.usd(Decimal(amount))
    }
  }
}

/// VoiceOver's chart: one series per model, the day as the x axis, spoken in the metric the
/// river is measuring.
private struct UsageRiverDescriptor: AXChartDescriptorRepresentable {
  let river: UsageRiver

  func makeChartDescriptor() -> AXChartDescriptor {
    let lastIndex = Double(max(river.dates.count - 1, 0))
    let maximum = max(river.dayTotals.values.max() ?? 0, river.scale == .share ? 1 : 0)
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Day",
      range: 0...max(lastIndex, 1),
      gridlinePositions: []
    ) { value in
      let index = Int(value.rounded())
      guard river.dates.indices.contains(index) else { return "" }
      return river.dates[index].formatted(.dateTime.month(.abbreviated).day())
    }
    let yAxis = AXNumericDataAxisDescriptor(
      title: river.scale == .share ? "Share" : river.metric.title,
      range: 0...max(maximum, 1),
      gridlinePositions: []
    ) { value in
      river.scale == .share
        ? "\(Int((value * 100).rounded()))%"
        : UsageRiverFormat.value(value, metric: river.metric)
    }
    let series = river.series.map { entry in
      AXDataSeriesDescriptor(
        name: entry.name,
        isContinuous: true,
        dataPoints: river.dates.enumerated().compactMap { index, date in
          guard let band = river.bands.first(where: { $0.series == entry.name && $0.date == date })
          else { return nil }
          return AXDataPoint(x: Double(index), y: band.high - band.low)
        }
      )
    }
    let unpriced = river.ticks.values.filter { $0 == .unpriced }.count
    var summary = "\(river.metric.title) by model over \(river.dates.count) days"
    if unpriced > 0 { summary += ", \(unpriced) unpriced" }
    return AXChartDescriptor(
      title: "Usage by model",
      summary: summary,
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: series
    )
  }
}
