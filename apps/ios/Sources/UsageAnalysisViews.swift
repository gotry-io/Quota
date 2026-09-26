import Charts
import QuotaPresentation
import QuotaWire
import SwiftUI

// The Usage tab as an analysis surface (ADR 0064, docs/design.md components): a sentence about
// the reader's own model usage, metric tabs that carry their values, the model river, the model
// ledger, and the token mix. Views only: the folds are `UsageModelRiver`, `ModelLedger`, and
// `UsageLedgerFold`, and the colours are the one `ModelColorAssignment` the Usage model holds.

/// One sentence written from the period's numbers, numbers in ink and the rest in the support
/// colour. It never ranks the reader against anyone.
struct UsageSentence: View {
  let totals: UsageSummaryTotals
  let rows: [ModelLedgerRow<BillingAgent>]
  /// The period is the day the reader is in, which is still being counted.
  let isToday: Bool

  var body: some View {
    sentence
      .font(.title3)
      .foregroundStyle(QuotaTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("usage.sentence")
  }

  private var sentence: Text {
    let tokens = ink("\(QuotaFormat.compactCount(totals.totalTokens)) tokens")
    let opening = isToday ? "So far today you ran" : "You ran"
    guard let top = rows.first else {
      return Text("\(opening) \(tokens).")
    }
    guard rows.count > 1 else {
      return Text("\(opening) \(tokens), all through \(ink(ModelDisplay.name(top.key.model))).")
    }
    let models = ink("\(rows.count) models")
    let share = ink(QuotaFormat.share(top.totals.totalTokens, of: totals.totalTokens) ?? "—")
    return Text(
      "\(opening) \(tokens) through \(models). \(ink(ModelDisplay.name(top.key.model))) carried \(share) of it."
    )
  }

  private func ink(_ value: String) -> Text {
    Text(value).fontWeight(.semibold).foregroundStyle(Color.primary)
  }
}

/// The facts under the sentence: cache share of input, active days, messages, and how the cost
/// was arrived at, plus the two coverage warnings the period read can carry.
struct UsageHeaderMeta: View {
  let period: UsagePeriod
  /// Days in the asked range with Usage, and the range's length. Nil for All, which names no
  /// first day.
  let activeDays: (active: Int, of: Int)?
  var truncatedByRetention = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(facts.joined(separator: " · "))
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Text("\(QuotaFormat.costBasis(period.cost)) · \(QuotaFormat.costPriced(period.cost))")
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      if period.partial {
        Label("Some hours in this period were scanned incompletely.", systemImage: "exclamationmark.triangle")
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(QuotaTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      if truncatedByRetention {
        Label("This range goes past what Quota still keeps.", systemImage: "exclamationmark.triangle")
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(QuotaTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityIdentifier("usage.header.meta")
  }

  private var spoken: String {
    var lines = [
      facts.joined(separator: ", "),
      "Cost basis, \(QuotaFormat.costBasis(period.cost)). \(QuotaFormat.costPriced(period.cost))",
    ]
    if period.partial { lines.append("Some hours in this period were scanned incompletely.") }
    if truncatedByRetention { lines.append("This range goes past what Quota still keeps.") }
    return lines.joined(separator: ". ")
  }

  private var facts: [String] {
    var parts: [String] = []
    if let cache = UsageMetrics.cacheHitPercentLabel(basisPoints: period.cacheHitBasisPoints) {
      parts.append("\(cache) of input from cache")
    }
    if let activeDays, activeDays.of > 1 {
      parts.append("\(activeDays.active) of \(activeDays.of) days active")
    }
    let messages = period.totals.messages
    parts.append("\(QuotaFormat.compactCount(messages)) \(messages == 1 ? "message" : "messages")")
    return parts
  }
}

/// Tokens and API-equivalent cost as tabs that carry their values; the selected one is what the
/// river measures. They sit side by side, and stack at accessibility sizes.
struct UsageMetricTabs: View {
  @Binding var metric: UsageMetric
  let totals: UsageSummaryTotals
  let cost: UsageCostOutcome
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    layout {
      tab(.tokens)
      tab(.cost)
    }
  }

  private func tab(_ value: UsageMetric) -> some View {
    let selected = metric == value
    return VStack(alignment: .leading, spacing: 4) {
      Text(title(value))
        .font(QuotaDesign.Typography.support)
        .foregroundStyle(selected ? Color.primary : QuotaTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("usage.metric.\(value.rawValue).title")
      Text(amount(value))
        .font(QuotaDesign.Typography.remainingValue)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("usage.metric.\(value.rawValue).value")
      Capsule()
        .fill(selected ? Color.primary : Color.clear)
        .frame(height: 2)
    }
    .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture { metric = value }
    // One element, the way a stat tile is: named by the tab and its value. Double-tap is its
    // default action. It carries no button trait, because the iOS 26.3 auditor then reports the
    // inner text of any combined button as partial Dynamic Type.
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel(value))
    .accessibilityAction { metric = value }
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint("Shows it by model in the chart.")
    .accessibilityIdentifier("usage.metric.\(value.rawValue)")
  }

  private func title(_ value: UsageMetric) -> String {
    switch value {
    case .tokens: "Tokens"
    case .cost: "API-equivalent"
    }
  }

  private func amount(_ value: UsageMetric) -> String {
    switch value {
    case .tokens: QuotaFormat.compactCount(totals.totalTokens)
    case .cost: QuotaFormat.cost(cost)
    }
  }

  private func accessibilityLabel(_ value: UsageMetric) -> String {
    switch value {
    case .tokens: "Tokens, \(QuotaFormat.accessibleCount(totals.totalTokens)) tokens"
    case .cost: "API-equivalent cost, \(QuotaFormat.costAccessibility(cost))"
    }
  }
}

/// The model river: a stacked area per model per local day, the largest model at the bottom.
/// An empty day is a baseline tick, today is veiled as still being counted, and a tap opens
/// that day. The ledger under it is the legend.
struct UsageModelRiverChart: View {
  let river: UsageModelRiver.River
  let metric: UsageMetric
  var onSelectDay: (String) -> Void = { _ in }

  @State private var selectedDate: String?

  var body: some View {
    chart
      .frame(height: 188)
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(metric == .tokens ? "Tokens by model" : "API-equivalent cost by model")
      .accessibilityValue(accessibilityValue)
      .accessibilityHint("Shows usage for the selected day.")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(named: "View day") { openSelectedDay() }
      .accessibilityIdentifier("usage.river")
  }

  private var chart: some View {
    Chart {
      ForEach(river.points) { point in
        if river.days.count > 1 {
          AreaMark(
            x: .value("Day", point.date),
            y: .value("Amount", point.value),
            stacking: .standard
          )
          .foregroundStyle(by: .value("Model", point.seriesID))
        } else {
          BarMark(
            x: .value("Day", point.date),
            y: .value("Amount", point.value),
            width: .ratio(0.4)
          )
          .foregroundStyle(by: .value("Model", point.seriesID))
        }
      }
      ForEach(river.days) { day in
        dayMarks(day)
      }
      if let selectedDate {
        RuleMark(x: .value("Day", selectedDate))
          .foregroundStyle(Color.primary.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartForegroundStyleScale(
      domain: river.series.map(\.id),
      range: river.series.map { QuotaTheme.modelFill($0.swatch) }
    )
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
      AxisMarks(values: xTicks) { value in
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
          .onTapGesture { location in
            guard let plotFrame = proxy.plotFrame else { return }
            let x = location.x - geometry[plotFrame].origin.x
            if let date: String = proxy.value(atX: x), river.days.contains(where: { $0.date == date }) {
              selectedDate = date
              onSelectDay(date)
            }
          }
      }
    }
  }

  @ChartContentBuilder
  private func dayMarks(_ day: UsageModelRiver.Day) -> some ChartContent {
    switch day.kind {
    case .amount:
      if day.isToday, river.days.count > 1 {
        RectangleMark(
          x: .value("Day", day.date),
          yStart: .value("Amount", 0),
          yEnd: .value("Amount", yTop)
        )
        .foregroundStyle(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.55))
      }
    case .empty:
      BarMark(x: .value("Day", day.date), y: .value("Amount", 0))
        .foregroundStyle(.clear)
        .annotation(position: .overlay, alignment: .bottom) {
          Capsule()
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: 10, height: 2)
        }
    case .unpriced:
      BarMark(x: .value("Day", day.date), y: .value("Amount", 0))
        .foregroundStyle(.clear)
        .annotation(position: .overlay, alignment: .bottom) {
          Capsule()
            .strokeBorder(
              Color(uiColor: .tertiaryLabel),
              style: StrokeStyle(lineWidth: 1, dash: [1.5, 1])
            )
            .frame(width: 10, height: 2)
        }
    }
  }

  private var yTicks: [Double] { UsageDailyAxis.valueTicks(maximum: river.maximum) }
  private var yTop: Double { yTicks.last ?? 1 }
  private var xTicks: [String] { UsageDailyAxis.dateTicks(dates: river.days.map(\.date)) }

  private func xLabelAnchor(_ value: AxisValue) -> UnitPoint {
    guard let text = value.as(String.self), let index = xTicks.firstIndex(of: text) else {
      return .top
    }
    switch UsageDailyAxis.dateTickAnchor(index: index, count: xTicks.count) {
    case .leading: return .topLeading
    case .center: return .top
    case .trailing: return .topTrailing
    }
  }

  private func yLabel(_ amount: Double) -> String {
    metric == .cost
      ? UsageBudgetProgress.usd(Decimal(amount))
      : CompactCountFormat.compact(Int(amount.rounded()))
  }

  private var accessibilityValue: String {
    let total = river.points.reduce(0) { $0 + $1.value }
    let amount =
      metric == .cost
      ? UsageBudgetProgress.usd(Decimal(total))
      : "\(CompactCountFormat.accessible(Int(total.rounded()))) tokens"
    var parts = ["\(river.days.count) days", "\(amount) in total"]
    if let largest = river.series.first {
      parts.append("largest \(largest.name)")
    }
    let unpriced = river.days.filter { $0.unpricedCells > 0 }.count
    if metric == .cost, unpriced > 0 {
      parts.append("\(unpriced) \(unpriced == 1 ? "day" : "days") partly unpriced")
    }
    if river.days.last?.isToday == true {
      parts.append("today so far")
    }
    return parts.joined(separator: ", ")
  }

  private func openSelectedDay() {
    let fallback = river.days.last { $0.kind != .empty }?.date ?? river.days.last?.date
    if let date = selectedDate ?? fallback {
      onSelectDay(date)
    }
  }
}

/// A model's colour chip beside its name. It grows with the text, capped so it stays a chip.
struct ModelSwatchChip: View {
  let swatch: ModelSwatch
  @ScaledMetric(relativeTo: .subheadline) private var size: Double = 10

  var body: some View {
    RoundedRectangle(cornerRadius: 2, style: .continuous)
      .fill(QuotaTheme.modelFill(swatch))
      .frame(width: min(size, 18), height: min(size, 18))
      .accessibilityHidden(true)
  }
}

/// The model ledger: the legend is the table. One row per model, names merged across agents,
/// largest first, each with a bar of its tokens in its own colour. The Usage page lists six and
/// then how many more; All models lists every row with the agents that sent it.
struct UsageModelLedgerSection: View {
  let rows: [ModelLedgerRow<BillingAgent>]
  let colors: ModelColorAssignment
  /// Nil lists every row.
  var visible: Int? = UsageLedgerFold.visibleRows
  var showsAgents = false

  var body: some View {
    let split = UsageLedgerFold.split(rows, visible: visible ?? rows.count)
    let largest = rows.first?.totals.totalTokens ?? 0
    Section {
      ForEach(split.visible, id: \.key) { row in
        ledgerRow(row, largest: largest)
      }
      if let rest = split.rest {
        NavigationLink(value: UsageDestination.breakdown) {
          restRow(rest)
        }
        .accessibilityIdentifier("usage.ledger.more")
      }
    } header: {
      Text("Models")
        .accessibilityIdentifier("section.header.models")
    }
  }

  private func ledgerRow(_ row: ModelLedgerRow<BillingAgent>, largest: Int) -> some View {
    let swatch = colors.swatch(for: row.key)
    let name = ModelDisplay.name(row.key.model)
    let tokens = QuotaFormat.compactCount(row.totals.totalTokens)
    return VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          ModelSwatchChip(swatch: swatch)
          modelName(name)
          Spacer(minLength: 8)
          tokenText(tokens)
        }
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            ModelSwatchChip(swatch: swatch)
            modelName(name)
          }
          tokenText(tokens)
        }
      }
      Text(meta(row).joined(separator: " · "))
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      ModelShareBar(
        fraction: largest > 0 ? Double(row.totals.totalTokens) / Double(largest) : 0,
        fill: QuotaTheme.modelFill(swatch)
      )
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(name)
    .accessibilityValue(
      ([QuotaFormat.accessibleCount(row.totals.totalTokens) + " tokens"] + meta(row, spoken: true))
        .joined(separator: ", ")
    )
    .accessibilityIdentifier("usage.ledger.row")
  }

  private func restRow(_ rest: UsageLedgerFold.Rest) -> some View {
    let share = "\(Int((rest.share * 100).rounded()))%"
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        ModelSwatchChip(swatch: .other)
        Text("\(rest.count) more \(rest.count == 1 ? "model" : "models")")
          .font(.subheadline)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("\(QuotaFormat.compactCount(rest.tokens)) tokens · \(share)")
        .font(QuotaDesign.Typography.meta.monospacedDigit())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(rest.count) more \(rest.count == 1 ? "model" : "models")")
    .accessibilityValue("\(QuotaFormat.accessibleCount(rest.tokens)) tokens, \(share) of tokens")
    .accessibilityHint("Opens All models")
  }

  private func modelName(_ name: String) -> some View {
    Text(name)
      .font(.subheadline.weight(.medium))
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func tokenText(_ tokens: String) -> some View {
    Text(tokens)
      .font(.subheadline.monospacedDigit())
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// Share, from cache, change against the previous period when there is one, cost, and on All
  /// models the agents that sent it.
  private func meta(_ row: ModelLedgerRow<BillingAgent>, spoken: Bool = false) -> [String] {
    var parts = ["\(String(format: "%.1f", row.share * 100))%" + (spoken ? " of tokens" : "")]
    if let cache = UsageMetrics.cacheHitPercentLabel(basisPoints: row.cacheHitBasisPoints) {
      parts.append("\(cache) from cache")
    }
    switch row.shareChange {
    case .points(let points)?:
      parts.append(
        points == 0 ? "no change" : "\(points > 0 ? "↑" : "↓") \(abs(points)) pts")
    case .new?:
      parts.append("New")
    case nil:
      break
    }
    let status = row.cost.coverage
    parts.append(
      spoken
        ? UsageCostFormat.accessible(status: status, amountMicrousd: row.cost.amountMicrousd)
        : UsageCostFormat.compact(status: status, amountMicrousd: row.cost.amountMicrousd))
    if showsAgents, !row.agents.isEmpty {
      parts.append(row.agents.map(\.displayName).joined(separator: ", "))
    }
    return parts
  }
}

/// A value against the largest of its kind, drawn once under a name in the caller's colour.
struct ModelShareBar: View {
  let fraction: Double
  let fill: Color

  var body: some View {
    Canvas { context, size in
      let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
      context.fill(track, with: .color(QuotaTheme.meterTrack))
      let width = size.width * min(max(fraction, 0), 1)
      guard width > 0 else { return }
      let bar = Path(
        roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height),
        cornerRadius: size.height / 2)
      context.fill(bar, with: .color(fill))
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}

/// One bar of cache read, cache write, fresh input, and output that adds up to the period's
/// tokens, with percentages, reasoning named inside output, and what cache saved.
struct UsageTokenMixSection: View {
  let totals: UsageSummaryTotals
  let cacheSaved: UsageCacheSaved?
  @ScaledMetric(relativeTo: .caption) private var swatchSize: Double = 8

  private struct Part: Identifiable {
    let name: String
    let tokens: Int
    let fill: Color
    var id: String { name }
  }

  private var parts: [Part] {
    let fresh = max(totals.inputTokens - totals.cacheReadInputTokens - totals.cacheWriteInputTokens, 0)
    return [
      Part(name: "Cache read", tokens: totals.cacheReadInputTokens, fill: QuotaTheme.cachedFill),
      Part(name: "Cache write", tokens: totals.cacheWriteInputTokens, fill: QuotaTheme.cacheWriteFill),
      Part(name: "Fresh input", tokens: fresh, fill: QuotaTheme.freshInputFill),
      Part(name: "Output", tokens: totals.outputTokens, fill: QuotaTheme.outputFill),
    ].filter { $0.tokens > 0 }
  }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        bar
        VStack(alignment: .leading, spacing: 6) {
          ForEach(parts) { part in
            legendRow(part)
          }
          if let saved = cacheSaved.flatMap(QuotaFormat.cacheSaved) {
            Text("Cache \(saved) against list price")
              .font(QuotaDesign.Typography.meta)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.vertical, 4)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Token mix")
      .accessibilityValue(accessibilityValue)
      .accessibilityIdentifier("usage.token-mix")
    } header: {
      Text("Token mix")
        .accessibilityIdentifier("section.header.token-mix")
    }
  }

  private var bar: some View {
    let parts = self.parts
    let total = max(totals.totalTokens, 1)
    return Canvas { context, size in
      let gaps = CGFloat(max(parts.count - 1, 0)) * 2
      let width = max(size.width - gaps, 0)
      context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4))
      var x: CGFloat = 0
      for part in parts {
        let segment = width * CGFloat(part.tokens) / CGFloat(total)
        context.fill(
          Path(CGRect(x: x, y: 0, width: segment, height: size.height)), with: .color(part.fill))
        x += segment + 2
      }
    }
    .frame(height: 12)
    .accessibilityHidden(true)
  }

  private func legendRow(_ part: Part) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(part.fill)
        .frame(width: min(swatchSize, 14), height: min(swatchSize, 14))
      VStack(alignment: .leading, spacing: 2) {
        Text(part.name)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if part.name == "Output", let reasoning = reasoningLine {
          Text(reasoning)
            .font(QuotaDesign.Typography.meta)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Text(QuotaFormat.share(part.tokens, of: totals.totalTokens) ?? "—")
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.primary)
    }
  }

  private var reasoningLine: String? {
    guard totals.reasoningTokens > 0,
      let share = QuotaFormat.share(totals.reasoningTokens, of: totals.outputTokens)
    else { return nil }
    return "\(share) of it reasoning"
  }

  private var accessibilityValue: String {
    var spoken = parts.map { part in
      "\(part.name) \(QuotaFormat.share(part.tokens, of: totals.totalTokens) ?? "none")"
    }
    if let reasoningLine { spoken.append("output \(reasoningLine)") }
    if let saved = cacheSaved.flatMap(QuotaFormat.cacheSaved) {
      spoken.append("cache \(saved) against list price")
    }
    return spoken.joined(separator: ", ")
  }
}
