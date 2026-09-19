import QuotaWire
import SwiftUI

/// One bar per UTC day of the selected period, and the numbers behind them.
struct UsageDailySection: View {
  let rows: [UsageDailyFold.Row]
  @State private var mode: Mode = .tokens
  @State private var tableOpen = false

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

      legend
        .accessibilityHidden(true)

      chart
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage by day")
        .accessibilityValue(chartAccessibilityValue)
        .accessibilityIdentifier("usage.daily.chart")

      DisclosureGroup(isExpanded: $tableOpen) {
        ForEach(rows.reversed()) { row in
          tableRow(row)
        }
      } label: {
        Text("Daily breakdown")
          .font(.body)
      }
      .tint(.primary)
      .accessibilityIdentifier("usage.daily.table")
    } header: {
      Text("Daily")
        .accessibilityIdentifier("section.header.daily")
    } footer: {
      Text("UTC days. \(legendCopy)")
        .accessibilityIdentifier("section.footer.daily")
    }
  }

  private var legend: some View {
    HStack(spacing: 12) {
      legendItem(QuotaTheme.emerald.opacity(0.35), "Cached")
      legendItem(QuotaTheme.emerald, "Fresh")
      legendItem(Color.primary.opacity(0.85), "Output")
    }
    .font(.caption)
    .foregroundStyle(.primary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func legendItem(_ color: Color, _ label: String) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(color)
        .frame(width: 8, height: 8)
      Text(label)
    }
  }

  private var chart: some View {
    GeometryReader { proxy in
      let maximum = UsageDailyFold.quantitativeMaximum(rows, metric: metric)
      let spacing: CGFloat = 2
      let width = max(
        2,
        (proxy.size.width - spacing * CGFloat(max(0, rows.count - 1))) / CGFloat(max(1, rows.count))
      )
      HStack(alignment: .bottom, spacing: spacing) {
        ForEach(rows) { row in
          bar(row, maximum: maximum, height: proxy.size.height)
            .frame(width: width)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
  }

  @ViewBuilder
  private func bar(_ row: UsageDailyFold.Row, maximum: Int, height: CGFloat) -> some View {
    switch UsageDailyFold.barKind(row, metric: metric) {
    case .amount(let amount):
      quantitativeBar(row, amount: amount, maximum: maximum, height: height)
    case .empty:
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(Color(uiColor: .tertiarySystemFill))
        .frame(height: 2)
    case .unpriced:
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .strokeBorder(
          Color(uiColor: .tertiaryLabel),
          style: StrokeStyle(lineWidth: 1, dash: [1.5, 1])
        )
        .frame(height: 2)
    }
  }

  @ViewBuilder
  private func quantitativeBar(
    _ row: UsageDailyFold.Row,
    amount: Int,
    maximum: Int,
    height: CGFloat
  ) -> some View {
    let scale = maximum > 0 ? CGFloat(amount) / CGFloat(maximum) : 0
    if metric == .tokens, row.totals.totalTokens > 0 {
      let barHeight = max(2, height * scale)
      VStack(spacing: 0) {
        segment(
          row.outputTokens,
          of: row.totals.totalTokens,
          height: barHeight,
          fill: Color.primary.opacity(0.85)
        )
        segment(
          row.freshInputTokens,
          of: row.totals.totalTokens,
          height: barHeight,
          fill: QuotaTheme.emerald
        )
        segment(
          row.cachedInputTokens,
          of: row.totals.totalTokens,
          height: barHeight,
          fill: QuotaTheme.emerald.opacity(0.35)
        )
      }
      .frame(height: barHeight)
      .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(QuotaTheme.emerald)
        .frame(height: max(2, height * scale))
    }
  }

  private func segment(_ part: Int, of whole: Int, height: CGFloat, fill: Color) -> some View {
    Rectangle()
      .fill(fill)
      .frame(height: whole > 0 ? height * CGFloat(part) / CGFloat(whole) : 0)
  }

  private var metric: UsageDailyMetric { mode == .tokens ? .tokens : .cost }

  private var legendCopy: String {
    mode == .tokens ? "Bars stack cached input, fresh input, and output." : "Bars are cost."
  }

  private var chartAccessibilityValue: String {
    UsageDailyFold.chartAccessibilityValue(rows, metric: metric)
  }

  private func tableRow(_ row: UsageDailyFold.Row) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.date)
          .font(.subheadline)
        Spacer(minLength: 8)
        Text("\(QuotaFormat.compactCount(row.totals.totalTokens)) · \(QuotaFormat.cost(row.cost))")
          .font(.subheadline.monospacedDigit())
      }
      Text(detailLine(row))
        .font(.caption.monospacedDigit())
        .foregroundStyle(Color.primary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(QuotaFormat.utcLongDate(row.date))
    .accessibilityValue(tableAccessibilityValue(row))
    .accessibilityIdentifier("usage.daily.row")
  }

  private func tableAccessibilityValue(_ row: UsageDailyFold.Row) -> String {
    switch UsageDailyFold.barKind(row, metric: metric) {
    case .unpriced:
      return
        "\(QuotaFormat.accessibleCount(row.totals.totalTokens)) tokens, unpriced. \(detailLine(row))"
    default:
      return
        "\(QuotaFormat.accessibleCount(row.totals.totalTokens)) tokens, \(QuotaFormat.costAccessibility(row.cost)). \(detailLine(row))"
    }
  }

  private func detailLine(_ row: UsageDailyFold.Row) -> String {
    let totals = row.totals
    return
      "\(QuotaFormat.compactCount(totals.inputTokens)) in · \(QuotaFormat.compactCount(totals.outputTokens)) out · \(QuotaFormat.compactCount(totals.cacheReadInputTokens)) cached · \(QuotaFormat.compactCount(totals.reasoningTokens)) reasoning · \(QuotaFormat.compactCount(totals.messages)) messages"
  }
}
