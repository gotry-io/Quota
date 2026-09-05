import QuotaWire
import SwiftUI

struct UsageView: View {
  @Bindable var model: AppModel
  @State private var expandedProviderIDs: Set<String> = []

  var body: some View {
    List {
      Section {
        periodPicker
      }

      if let usage = model.summary?.usage {
        let period = model.selectedUsagePeriod.period(in: usage)
        let sections = UsageBreakdown.sections(in: period)
        UsageTotalsSection(period: period)
        if sections.isEmpty {
          emptyPeriod
        }
        if model.selectedTab == .usage {
          UsageActivitySection(model: model)
          UsageAgentListSections(
            sections: sections,
            expandedProviderIDs: $expandedProviderIDs
          )
        }
      } else if model.selectedTab == .usage {
        emptyPeriod
        UsageActivitySection(model: model)
      }
    }
    .listStyle(.insetGrouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .quotaTabBarClearance()
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
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .frame(minHeight: QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("usage.period")
  }

  private var emptyPeriod: some View {
    Section {
      ContentUnavailableView {
        Label("No usage", systemImage: "chart.bar")
      } description: {
        Text("No usage was reported for this period.")
      }
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("usage.empty")
  }
}

struct UsageTotalsSection: View {
  let totals: UsageSummaryTotals
  let cost: UsageCostOutcome
  let partial: Bool
  var partialCopy: String = "Some hours in this period were scanned incompletely."
  var identifier: String = "usage.headline"

  init(period: UsagePeriod, identifier: String = "usage.headline") {
    totals = period.totals
    cost = period.cost
    partial = period.partial
    self.identifier = identifier
  }

  init(
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    partial: Bool,
    partialCopy: String = "Some hours in this period were scanned incompletely.",
    identifier: String = "usage.headline"
  ) {
    self.totals = totals
    self.cost = cost
    self.partial = partial
    self.partialCopy = partialCopy
    self.identifier = identifier
  }

  var body: some View {
    Section {
      metricRow(
        label: "Tokens",
        value: QuotaFormat.compactCount(totals.totalTokens),
        accessibility:
          "\(QuotaFormat.accessibleCount(totals.totalTokens)) tokens, \(QuotaFormat.accessibleCount(totals.inputTokens)) in, \(QuotaFormat.accessibleCount(totals.outputTokens)) out"
      )
      .accessibilityIdentifier(identifier)

      metricRow(
        label: "API-equivalent cost",
        value: QuotaFormat.cost(cost),
        accessibility: "API-equivalent cost, \(QuotaFormat.costAccessibility(cost))"
      )

      VStack(alignment: .leading, spacing: 4) {
        Text(
          "\(QuotaFormat.compactCount(totals.inputTokens)) in · \(QuotaFormat.compactCount(totals.outputTokens)) out"
        )
        .font(.footnote)
        Text(QuotaFormat.costBasis(cost))
          .font(.footnote)
        if partial {
          Text(partialCopy)
            .font(.footnote)
        }
      }
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(footerAccessibilityLabel)
    }
  }

  private func metricRow(label: String, value: String, accessibility: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      BodyLabel(text: label)
      Spacer(minLength: 8)
      BodyLabel(text: value, weight: .medium, monospacedDigit: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibility)
  }

  private var footerAccessibilityLabel: String {
    "\(QuotaFormat.accessibleCount(totals.inputTokens)) in · \(QuotaFormat.accessibleCount(totals.outputTokens)) out. Cost basis, \(QuotaFormat.costBasis(cost))"
      + (partial ? ". \(partialCopy)" : "")
  }
}

struct UsageAgentListSections: View {
  let sections: [UsageBreakdown.AgentSection]
  @Binding var expandedProviderIDs: Set<String>
  var modelIdentifier: String = "usage.model"
  var showMoreIdentifier: String = "usage.show-more"
  var showFewerIdentifier: String = "usage.show-fewer"

  var body: some View {
    ForEach(sections) { section in
      Section {
        Text(section.displayName)
          .font(.headline)
          .foregroundStyle(Color(uiColor: .label))
          .accessibilityAddTraits(.isHeader)
        ForEach(section.providers) { provider in
          providerRows(provider, agentID: section.id)
        }
      }
    }
  }

  @ViewBuilder
  private func providerRows(
    _ provider: UsageBreakdown.ProviderSection,
    agentID: String
  ) -> some View {
    let key = provider.expansionKey(agentID: agentID)
    let expanded = expandedProviderIDs.contains(key)
    let visible = provider.visibleModels(expanded: expanded)
    let hidden = provider.hiddenCount(expanded: expanded)

    HStack {
      BodyLabel(text: provider.displayName)
      Spacer(minLength: 0)
    }

    ForEach(visible) { row in
      modelRow(row)
    }

    if provider.foldsModels {
      Button(expanded ? "Show fewer" : "Show \(hidden) more") {
        if expanded {
          expandedProviderIDs.remove(key)
        } else {
          expandedProviderIDs.insert(key)
        }
      }
      .tint(.primary)
      .accessibilityLabel(
        expanded
          ? "Show fewer \(provider.displayName) models"
          : "Show \(hidden) more \(provider.displayName) models"
      )
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier(expanded ? showFewerIdentifier : showMoreIdentifier)
    }
  }

  private func modelRow(_ row: UsageBreakdown.ModelRow) -> some View {
    let tokens = QuotaFormat.compactCount(row.totals.totalTokens)
    let cost = QuotaFormat.cost(row.cost)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      BodyLabel(text: row.displayName, style: .subheadline)
      Spacer(minLength: 8)
      BodyLabel(
        text: "\(tokens) · \(cost)",
        style: .subheadline,
        monospacedDigit: true
      )
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(row.displayName), \(QuotaFormat.accessibleCount(row.totals.totalTokens)) tokens, \(QuotaFormat.costAccessibility(row.cost))"
    )
    .accessibilityIdentifier(modelIdentifier)
  }
}
