import QuotaPresentation
import QuotaWire
import SwiftUI

/// The model ledger (`docs/design.md` Model ledger): the river's legend as a table. Six rows,
/// then **N more models** with their total, which opens the rest in place.
struct UsageModelLedgerView: View {
  let rows: [ModelLedgerRow<BillingAgent>]
  let colors: ModelColorAssignment
  let metric: UsageMetric
  @State private var showsAll = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  static let visibleRows = 6

  private var shown: [ModelLedgerRow<BillingAgent>] {
    showsAll ? rows : Array(rows.prefix(Self.visibleRows))
  }

  private var stacks: Bool { dynamicTypeSize.isAccessibilitySize }

  private var largest: Double {
    rows.map { value(of: $0) }.max() ?? 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !stacks {
        header
      }
      ForEach(shown, id: \.key) { row in
        ledgerRow(row)
        Rectangle()
          .fill(QuotaPalette.hairline)
          .frame(height: 0.5)
      }
      if rows.count > Self.visibleRows {
        moreRow
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Models")
  }

  private var header: some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      Text("MODEL")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10 + QuotaDesign.Spacing.sm)
      Text("TOKENS").frame(width: Column.tokens, alignment: .trailing)
      Text("SHARE").frame(width: Column.share, alignment: .trailing)
      Text("CHANGE").frame(width: Column.change, alignment: .trailing)
      Text("FROM CACHE").frame(width: Column.cache, alignment: .trailing)
      Text("COST").frame(width: Column.cost, alignment: .trailing)
    }
    .quotaFont(.meta)
    .foregroundStyle(QuotaPalette.mute)
    .padding(.vertical, QuotaDesign.Spacing.xs)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func ledgerRow(_ row: ModelLedgerRow<BillingAgent>) -> some View {
    let swatch = colors.swatch(for: row.key)
    let cells = Cells(row)
    Group {
      if stacks {
        VStack(alignment: .leading, spacing: 2) {
          identity(row, swatch: swatch)
          Text(
            [cells.tokens, cells.share, cells.change, cells.cache, cells.cost]
              .joined(separator: " · ")
          )
          .quotaMonoListValueStyle()
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: QuotaDesign.Spacing.sm) {
          identity(row, swatch: swatch)
            .frame(maxWidth: .infinity, alignment: .leading)
          value(cells.tokens, width: Column.tokens, strong: true)
          value(cells.share, width: Column.share)
          value(cells.change, width: Column.change)
          value(cells.cache, width: Column.cache)
          value(cells.cost, width: Column.cost)
        }
      }
    }
    .padding(.vertical, QuotaDesign.Spacing.xs)
    .background(alignment: .leading) {
      GeometryReader { geometry in
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(QuotaPalette.model(swatch).opacity(0.16))
          .frame(width: geometry.size.width * tint(of: row))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.key.model)
    .accessibilityValue(
      "\(cells.tokens) tokens, \(cells.share) of the period, change \(cells.change), \(cells.cache) from cache, \(cells.cost)"
    )
  }

  private func identity(_ row: ModelLedgerRow<BillingAgent>, swatch: ModelSwatch) -> some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(QuotaPalette.model(swatch))
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.key.model)
          .quotaFont(.listSecondary)
          .foregroundStyle(QuotaPalette.ink)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(row.agents.map(\.displayName).joined(separator: ", "))
          .quotaMetaStyle()
          .lineLimit(1)
      }
    }
  }

  private func value(_ text: String, width: CGFloat, strong: Bool = false) -> some View {
    Text(text)
      .quotaFont(.monoMeta)
      .foregroundStyle(strong ? QuotaPalette.ink : QuotaPalette.body)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(width: width, alignment: .trailing)
  }

  private var moreRow: some View {
    let rest = rows.dropFirst(Self.visibleRows)
    let tokens = rest.reduce(0) { $0 + $1.totals.totalTokens }
    let title =
      showsAll
      ? "Show fewer models"
      : "\(rest.count) more \(rest.count == 1 ? "model" : "models") · \(UsageValueFormatter.count(tokens)) tokens"
    return Button {
      showsAll.toggle()
    } label: {
      HStack(spacing: QuotaDesign.Spacing.xs) {
        Text(title)
          .quotaFont(.listSecondary)
          .foregroundStyle(QuotaPalette.body)
        Image(systemName: showsAll ? "chevron.up" : "chevron.down")
          .quotaAffordanceStyle()
        Spacer(minLength: 0)
      }
      .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func value(of row: ModelLedgerRow<BillingAgent>) -> Double {
    switch metric {
    case .tokens: Double(row.totals.totalTokens)
    case .messages: Double(row.totals.messages)
    case .cost: row.cost.amountMicrousd.flatMap(Double.init) ?? 0
    }
  }

  private func tint(of row: ModelLedgerRow<BillingAgent>) -> Double {
    largest > 0 ? min(value(of: row) / largest, 1) : 0
  }

  private enum Column {
    static let tokens: CGFloat = 64
    static let share: CGFloat = 44
    static let change: CGFloat = 56
    static let cache: CGFloat = 72
    static let cost: CGFloat = 72
  }

  /// One row's cells as printed.
  private struct Cells {
    let tokens: String
    let share: String
    let change: String
    let cache: String
    let cost: String

    init(_ row: ModelLedgerRow<BillingAgent>) {
      tokens = UsageValueFormatter.count(row.totals.totalTokens)
      share = "\(Int((row.share * 100).rounded()))%"
      change = UsageShareChangeCopy.text(row.shareChange)
      cache = UsageMetrics.cacheHitPercentLabel(basisPoints: row.cacheHitBasisPoints) ?? "—"
      cost = UsageCostFormat.compact(
        status: row.cost.coverage,
        amountMicrousd: row.cost.amountMicrousd
      )
    }
  }
}

/// The token mix (`docs/design.md` Token mix): one bar in the chart roles, then each part's
/// share, reasoning named inside output, and what cache saved against list price.
struct UsageTokenMixView: View {
  let mix: UsageTokenMix
  let cacheSaved: UsageCacheSaved

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      GeometryReader { geometry in
        HStack(spacing: 1) {
          ForEach(mix.parts) { part in
            Rectangle()
              .fill(color(part))
              .frame(width: max(geometry.size.width * mix.fraction(part) - 1, 0))
          }
        }
        .clipShape(Capsule())
      }
      .frame(height: 10)
      .background(Capsule().fill(QuotaPalette.progressTrack))
      .accessibilityHidden(true)

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.md) {
          legends
          Spacer(minLength: 0)
        }
        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
          legends
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Token mix")
  }

  @ViewBuilder
  private var legends: some View {
    ForEach(mix.parts) { part in
      legend(part)
    }
    if let saved = UsageValueFormatter.cacheSaved(cacheSaved) {
      Text("Cache \(saved)")
        .quotaMetaStyle()
    }
  }

  private func legend(_ part: UsageTokenMix.Part) -> some View {
    let percent = "\(Int((mix.fraction(part) * 100).rounded()))%"
    let reasoning =
      part == .output && mix.reasoningTokens > 0
      ? " · reasoning \(UsageValueFormatter.count(mix.reasoningTokens))" : ""
    return HStack(spacing: QuotaDesign.Spacing.xxs) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(color(part))
        .frame(width: 8, height: 8)
      Text("\(part.title) \(percent)\(reasoning)")
        .quotaFont(.meta)
        .foregroundStyle(QuotaPalette.body)
        .monospacedDigit()
    }
  }

  private func color(_ part: UsageTokenMix.Part) -> Color {
    switch part {
    case .cacheRead: QuotaPalette.chartCache
    case .cacheWrite: QuotaPalette.chartCacheWrite
    case .freshInput: QuotaPalette.chartInput
    case .output: QuotaPalette.chartOutput
    }
  }
}
