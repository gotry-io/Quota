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

  private var chart: some View {
    GeometryReader { proxy in
      let maximum = rows.map(value(of:)).max() ?? 0
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
    let scale = maximum > 0 ? CGFloat(value(of: row)) / CGFloat(maximum) : 0
    let barHeight = max(2, height * scale)
    if mode == .tokens, row.totals.totalTokens > 0 {
      VStack(spacing: 0) {
        segment(row.outputTokens, of: row.totals.totalTokens, height: barHeight, opacity: 0.9)
        segment(row.freshInputTokens, of: row.totals.totalTokens, height: barHeight, opacity: 0.55)
        segment(row.cachedInputTokens, of: row.totals.totalTokens, height: barHeight, opacity: 0.25)
      }
      .frame(height: barHeight)
      .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(Color.primary.opacity(value(of: row) > 0 ? 0.55 : 0.12))
        .frame(height: barHeight)
    }
  }

  private func segment(_ part: Int, of whole: Int, height: CGFloat, opacity: Double) -> some View {
    Rectangle()
      .fill(Color.primary.opacity(opacity))
      .frame(height: whole > 0 ? height * CGFloat(part) / CGFloat(whole) : 0)
  }

  private func value(of row: UsageDailyFold.Row) -> Int {
    mode == .tokens ? row.totals.totalTokens : Int(row.cost.amountMicrousd ?? "0") ?? 0
  }

  private var legendCopy: String {
    mode == .tokens ? "Bars stack cached input, fresh input, and output." : "Bars are cost."
  }

  private var chartAccessibilityValue: String {
    let total = rows.reduce(0) { $0 + $1.totals.totalTokens }
    return "\(rows.count) days, \(QuotaFormat.accessibleCount(total)) tokens in total"
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
    .accessibilityValue(
      "\(QuotaFormat.accessibleCount(row.totals.totalTokens)) tokens, \(QuotaFormat.costAccessibility(row.cost)). \(detailLine(row))"
    )
    .accessibilityIdentifier("usage.daily.row")
  }

  private func detailLine(_ row: UsageDailyFold.Row) -> String {
    let totals = row.totals
    return
      "\(QuotaFormat.compactCount(totals.inputTokens)) in · \(QuotaFormat.compactCount(totals.outputTokens)) out · \(QuotaFormat.compactCount(totals.cacheReadInputTokens)) cached · \(QuotaFormat.compactCount(totals.reasoningTokens)) reasoning · \(QuotaFormat.compactCount(totals.messages)) messages"
  }
}
