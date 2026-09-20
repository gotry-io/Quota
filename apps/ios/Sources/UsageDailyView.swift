import Charts
import QuotaPresentation
import QuotaWire
import SwiftUI

/// One bar per day of the selected period, with axes, a Tokens/Cost switch, and day selection.
struct UsageDailySection: View {
  let rows: [UsageDailyFold.Row]
  var onSelectDay: (String) -> Void = { _ in }

  @State private var mode: Mode = .tokens
  /// The swatch grows with the caption beside it, capped so it stays a swatch (#247's rule).
  @ScaledMetric(relativeTo: .caption) private var swatchSize: Double = 8
  @State private var selectedDate: String?

  enum Mode: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: Self { self }
    var title: String { self == .tokens ? "Tokens" : "Cost" }
  }

  var body: some View {
    Section {
      Picker("Daily bars measure", selection: $mode) {
        ForEach(Mode.allCases) { value in
          Text(value.title).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .frame(minHeight: QuotaTheme.minimumTouchTarget)
      .accessibilityIdentifier("usage.daily.mode")

      chart
        .frame(height: 168)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage by day")
        .accessibilityValue(chartAccessibilityValue)
        .accessibilityHint("Shows usage for the selected day.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "View day") {
          openSelectedDay()
        }
        .accessibilityIdentifier("usage.daily.chart")

      if metric == .tokens {
        legend
          .accessibilityHidden(true)
      }
    } footer: {
      Text(legendCopy)
        .accessibilityIdentifier("section.footer.daily")
    }
    .onAppear {
      if selectedDate == nil {
        selectedDate = defaultSelectedDate
      }
    }
  }

  private var legend: some View {
    // Three swatches on one line stop fitting as the caption grows, and the auditor reads a
    // legend that cannot grow as Dynamic Type partially unsupported. Reflow into a column
    // rather than clip, the same rule the provider rows follow.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        legendItems
      }
      VStack(alignment: .leading, spacing: 4) {
        legendItems
      }
    }
    .font(.caption)
    .foregroundStyle(.primary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var legendItems: some View {
    legendItem(QuotaTheme.cachedFill, "Cached")
    legendItem(QuotaTheme.emerald, "Fresh")
    legendItem(Color.primary.opacity(0.85), "Output")
  }

  private func legendItem(_ color: Color, _ label: String) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(color)
        .frame(width: swatch, height: swatch)
      Text(label)
    }
  }

  private var swatch: Double { min(swatchSize, 8 * 1.75) }

  private var chart: some View {
    Chart {
      ForEach(rows) { row in
        marks(for: row)
      }
    }
    .chartLegend(.hidden)
    .chartYScale(domain: 0...yTop)
    .chartYAxis {
      AxisMarks(position: .leading, values: yTicks) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(yLabel(amount))
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: xTickTexts) { value in
        AxisValueLabel(anchor: xLabelAnchor(value)) {
          if let text = value.as(String.self) {
            Text(UsageDailyAxis.dateLabel(text))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
          }
        }
      }
    }
    .chartXSelection(value: $selectedDate)
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle()
          .fill(.clear)
          .contentShape(Rectangle())
          .onTapGesture(count: 1, coordinateSpace: .local) { location in
            select(at: location, proxy: proxy, geometry: geometry)
            openSelectedDay()
          }
      }
    }
  }

  @ChartContentBuilder
  private func marks(for row: UsageDailyFold.Row) -> some ChartContent {
    let dimmed = selectedDate.map { $0 != row.date } ?? false
    let opacity = dimmed ? 0.45 : 1
    switch UsageDailyFold.barKind(row, metric: metric) {
    case .amount:
      if metric == .tokens {
        BarMark(
          x: .value("Day", row.date),
          y: .value("Tokens", Double(row.cachedInputTokens))
        )
        .foregroundStyle(QuotaTheme.cachedFill)
        .opacity(opacity)
        BarMark(
          x: .value("Day", row.date),
          y: .value("Tokens", Double(row.freshInputTokens))
        )
        .foregroundStyle(QuotaTheme.emerald)
        .opacity(opacity)
        BarMark(
          x: .value("Day", row.date),
          y: .value("Tokens", Double(row.outputTokens))
        )
        .foregroundStyle(Color.primary.opacity(0.85))
        .opacity(opacity)
      } else {
        BarMark(
          x: .value("Day", row.date),
          y: .value("Cost", UsageDailyFold.plotValue(row, metric: .cost))
        )
        .foregroundStyle(QuotaTheme.emerald)
        .opacity(opacity)
      }
    case .empty:
      BarMark(
        x: .value("Day", row.date),
        y: .value("Value", 0)
      )
      .foregroundStyle(.clear)
      .annotation(position: .overlay, alignment: .bottom) {
        Capsule()
          .fill(Color(uiColor: .tertiarySystemFill))
          .frame(height: 2)
      }
    case .unpriced:
      BarMark(
        x: .value("Day", row.date),
        y: .value("Value", 0)
      )
      .foregroundStyle(.clear)
      .annotation(position: .overlay, alignment: .bottom) {
        Capsule()
          .strokeBorder(
            Color(uiColor: .tertiaryLabel),
            style: StrokeStyle(lineWidth: 1, dash: [1.5, 1])
          )
          .frame(height: 2)
      }
    }
  }

  private var metric: UsageDailyMetric { mode == .tokens ? .tokens : .cost }

  private var yTicks: [Double] {
    UsageDailyAxis.valueTicks(
      maximum: Double(UsageDailyFold.quantitativeMaximum(rows, metric: metric))
        / (metric == .cost ? 1_000_000 : 1)
    )
  }

  private var yTop: Double { yTicks.last ?? 1 }

  private var xTickTexts: [String] {
    UsageDailyAxis.dateTicks(dates: rows.map(\.date))
  }

  private func xLabelAnchor(_ value: AxisValue) -> UnitPoint {
    guard let text = value.as(String.self),
      let index = xTickTexts.firstIndex(of: text)
    else { return .top }
    switch UsageDailyAxis.dateTickAnchor(index: index, count: xTickTexts.count) {
    case .leading: return .topLeading
    case .center: return .top
    case .trailing: return .topTrailing
    }
  }

  private var legendCopy: String {
    mode == .tokens
      ? "Bars stack cached input, fresh input, and output."
      : "Bars are cost."
  }

  private var chartAccessibilityValue: String {
    UsageDailyFold.chartAccessibilityValue(rows, metric: metric)
  }

  private var defaultSelectedDate: String? {
    rows.last { $0.totals.totalTokens > 0 }?.date ?? rows.last?.date
  }

  private func yLabel(_ amount: Double) -> String {
    if metric == .cost {
      return UsageBudgetProgress.usd(Decimal(amount))
    }
    return CompactCountFormat.compact(Int(amount.rounded()))
  }

  private func select(
    at location: CGPoint,
    proxy: ChartProxy,
    geometry: GeometryProxy
  ) {
    guard let plotFrame = proxy.plotFrame else { return }
    let frame = geometry[plotFrame]
    let x = location.x - frame.origin.x
    guard let text: String = proxy.value(atX: x) else { return }
    if rows.contains(where: { $0.date == text }) {
      selectedDate = text
    }
  }

  private func openSelectedDay() {
    if let date = selectedDate ?? defaultSelectedDate {
      onSelectDay(date)
    }
  }
}
