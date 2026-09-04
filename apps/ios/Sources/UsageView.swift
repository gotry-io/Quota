import QuotaWire
import SwiftUI

struct UsageView: View {
  @Bindable var model: AppModel
  @State private var expandedProviderIDs: Set<String> = []

  var body: some View {
    VStack(spacing: 12) {
      periodPicker
        .padding(.horizontal, QuotaTheme.contentGutter)
        .padding(.top, 8)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if let usage = model.summary?.usage {
            let period = model.selectedUsagePeriod.period(in: usage)
            let sections = UsageBreakdown.sections(in: period)
            if sections.isEmpty {
              emptyCard
            } else {
              UsageHeadlineCard(period: period)
            }
            UsageActivityCard(model: model)
            ForEach(sections) { section in
              UsageAgentCard(
                section: section,
                expandedProviderIDs: $expandedProviderIDs
              )
            }
          } else {
            emptyCard
            UsageActivityCard(model: model)
          }
        }
        .frame(maxWidth: QuotaTheme.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, QuotaTheme.contentGutter)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
      }
    }
    .task(id: model.selectedTab) {
      guard model.selectedTab == .usage else { return }
      await model.loadActivity()
    }
    .sheet(item: $model.activityDaySheet) { _ in
      UsageDayDetailSheet(model: model)
    }
    .accessibilityIdentifier("usage.root")
    .navigationTitle("Usage")
    .navigationBarTitleDisplayMode(.large)
  }

  private var periodPicker: some View {
    Picker("Usage period", selection: $model.selectedUsagePeriod) {
      ForEach(SelectedUsagePeriod.allCases) { period in
        Text(period.segmentTitle)
          .tag(period)
          .accessibilityLabel(period.accessibilityTitle)
      }
    }
    .pickerStyle(.segmented)
    .frame(minHeight: QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("usage.period")
  }

  private var emptyCard: some View {
    Text("No Usage in this period.")
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("usage.empty")
  }
}

struct UsageHeadlineCard: View {
  let totals: UsageSummaryTotals
  let cost: UsageCostOutcome
  let partial: Bool
  var partialCopy: String = "Some hours in this period were scanned incompletely."
  var basisCopy: String? = nil
  var identifier: String = "usage.headline"

  init(period: UsagePeriod) {
    totals = period.totals
    cost = period.cost
    partial = period.partial
  }

  init(
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    partial: Bool,
    partialCopy: String = "Some hours in this period were scanned incompletely.",
    basisCopy: String? = nil,
    identifier: String = "usage.headline"
  ) {
    self.totals = totals
    self.cost = cost
    self.partial = partial
    self.partialCopy = partialCopy
    self.basisCopy = basisCopy
    self.identifier = identifier
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      tokensMetric
      metric(
        label: "API-equivalent cost",
        value: QuotaFormat.cost(cost),
        accessibility: "API-equivalent cost, \(QuotaFormat.costAccessibility(cost))"
      )
      if let basisCopy {
        Text(basisCopy)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Cost basis, \(basisCopy)")
      }
      if partial {
        Text(partialCopy)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(identifier)
  }

  private var tokensMetric: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("Tokens")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .layoutPriority(0)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 12)
        Text(QuotaFormat.compactCount(totals.totalTokens))
          .font(.body.monospacedDigit().weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
      }
      Text(
        "\(QuotaFormat.compactCount(totals.inputTokens)) in · \(QuotaFormat.compactCount(totals.outputTokens)) out"
      )
      .font(.footnote.monospacedDigit())
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(QuotaFormat.accessibleCount(totals.totalTokens)) tokens, \(QuotaFormat.accessibleCount(totals.inputTokens)) in, \(QuotaFormat.accessibleCount(totals.outputTokens)) out"
    )
  }

  private func metric(label: String, value: String, accessibility: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .layoutPriority(0)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 12)
      Text(value)
        .font(.body.monospacedDigit().weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibility)
  }
}

struct UsageAgentCard: View {
  let section: UsageBreakdown.AgentSection
  @Binding var expandedProviderIDs: Set<String>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(section.displayName)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      ForEach(Array(section.providers.enumerated()), id: \.element.id) { index, provider in
        if index > 0 { Divider() }
        providerBlock(provider)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func providerBlock(_ provider: UsageBreakdown.ProviderSection) -> some View {
    let key = provider.expansionKey(agentID: section.id)
    let expanded = expandedProviderIDs.contains(key)
    let visible = provider.visibleModels(expanded: expanded)
    let hidden = provider.hiddenCount(expanded: expanded)
    return VStack(alignment: .leading, spacing: 8) {
      Text(provider.displayName)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      ForEach(visible) { row in
        modelRow(row)
      }

      if hidden > 0 {
        Button {
          expandedProviderIDs.insert(key)
        } label: {
          Text("Show \(hidden) more")
            .font(.subheadline.weight(.medium))
            .frame(
              maxWidth: .infinity,
              minHeight: QuotaTheme.minimumTouchTarget,
              alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(QuotaTheme.emerald)
        .accessibilityLabel("Show \(hidden) more \(provider.displayName) models")
        .accessibilityIdentifier("usage.show-more")
      }
    }
  }

  private func modelRow(_ row: UsageBreakdown.ModelRow) -> some View {
    let tokens = QuotaFormat.compactCount(row.totals.totalTokens)
    let cost = QuotaFormat.cost(row.cost)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(row.displayName)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Text("\(tokens) · \(cost)")
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(row.displayName), \(QuotaFormat.accessibleCount(row.totals.totalTokens)) tokens, \(QuotaFormat.costAccessibility(row.cost))"
    )
    .accessibilityIdentifier("usage.model")
  }
}
