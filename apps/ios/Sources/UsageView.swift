import QuotaPresentation
import QuotaWire
import SwiftUI

struct UsageView: View {
  @Bindable var model: AppModel
  @State private var expandedProviderIDs: Set<String> = []
  @State private var rangeEditor = false
  @State private var budgetEditor = false

  var body: some View {
    List {
      Section {
        periodPicker
        periodStepper
      }

      UsageBudgetSection(model: model, editing: $budgetEditor)

      if let period = model.usagePeriodValue {
        let sections = model.usagePeriodIsFolded ? [] : UsageBreakdown.sections(in: period)
        UsageTotalsSection(period: period)
        if model.usagePeriodIsFolded {
          foldedPeriod
        } else if sections.isEmpty {
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
    .task(id: model.selectedTab) {
      guard model.selectedTab == .usage else { return }
      await model.loadActivity()
    }
    .sheet(item: $model.activityDaySheet) { _ in
      UsageDayDetailSheet(model: model)
    }
    .sheet(isPresented: $rangeEditor) {
      UsageRangeEditor(model: model)
    }
    .sheet(isPresented: $budgetEditor) {
      UsageBudgetEditor(model: model)
    }
    .accessibilityIdentifier("usage.root")
    .navigationTitle("Usage")
    .navigationBarTitleDisplayMode(.large)
  }

  /// The six periods a segment names. A custom range selects none of them and says so in the
  /// title row instead.
  private var periodPicker: some View {
    Picker("Usage period", selection: segmentBinding) {
      ForEach(UsagePeriodSegment.allCases.filter { $0 != .custom }) { segment in
        Text(segment.title)
          .tag(Optional(segment))
          .accessibilityLabel(segment.accessibilityTitle)
      }
    }
    .pickerStyle(.segmented)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .frame(minHeight: QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("usage.period")
  }

  private var periodStepper: some View {
    HStack(spacing: 12) {
      Button {
        if let previous = model.usagePeriod.previous { model.selectUsagePeriod(previous) }
      } label: {
        Image(systemName: "chevron.left")
          .frame(
            minWidth: QuotaTheme.minimumTouchTarget,
            minHeight: QuotaTheme.minimumTouchTarget
          )
          .contentShape(Rectangle())
      }
      .disabled(model.usagePeriod.previous == nil)
      .accessibilityLabel("Previous period")
      .accessibilityIdentifier("usage.period.previous")

      Text(model.usagePeriodTitle)
        .font(.subheadline)
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("usage.period.title")

      Button {
        if let next = model.usagePeriod.next { model.selectUsagePeriod(next) }
      } label: {
        Image(systemName: "chevron.right")
          .frame(
            minWidth: QuotaTheme.minimumTouchTarget,
            minHeight: QuotaTheme.minimumTouchTarget
          )
          .contentShape(Rectangle())
      }
      .disabled(model.usagePeriod.next == nil)
      .accessibilityLabel("Next period")
      .accessibilityIdentifier("usage.period.next")

      Button {
        rangeEditor = true
      } label: {
        Image(systemName: "calendar")
          .frame(
            minWidth: QuotaTheme.minimumTouchTarget,
            minHeight: QuotaTheme.minimumTouchTarget
          )
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Custom range")
      .accessibilityIdentifier("usage.period.custom")
    }
    .buttonStyle(.plain)
    .tint(.primary)
    .frame(minHeight: QuotaTheme.minimumTouchTarget)
  }

  private var segmentBinding: Binding<UsagePeriodSegment?> {
    Binding(
      get: { model.usagePeriod.segment == .custom ? nil : model.usagePeriod.segment },
      set: { segment in
        guard let segment else { return }
        model.selectUsagePeriod(.selection(for: segment, custom: nil))
      }
    )
  }

  private var foldedPeriod: some View {
    Section {
      Text(
        "This range was added up on this iPhone, so it carries totals only. The model breakdown is on Today, Last 7 days, Last 30 days, and All."
      )
      .font(.body)
      .foregroundStyle(Color.primary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("usage.folded")
  }

  private var emptyPeriod: some View {
    Section {
      ContentUnavailableView {
        Label("No usage", systemImage: "chart.bar")
      } description: {
        Text("No usage was reported for this period.")
      }
      .foregroundStyle(Color.primary)
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
      LabeledContent("Tokens") {
        Text(QuotaFormat.compactCount(totals.totalTokens))
          .font(.body.monospacedDigit().weight(.medium))
          .foregroundStyle(Color.primary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(QuotaFormat.accessibleCount(totals.totalTokens)) tokens, \(QuotaFormat.accessibleCount(totals.inputTokens)) in, \(QuotaFormat.accessibleCount(totals.outputTokens)) out"
      )
      .accessibilityIdentifier(identifier)

      LabeledContent("API-equivalent cost") {
        Text(QuotaFormat.cost(cost))
          .font(.body.monospacedDigit().weight(.medium))
          .foregroundStyle(Color.primary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "API-equivalent cost, \(QuotaFormat.costAccessibility(cost))"
      )
      .accessibilityIdentifier("\(identifier).cost")

      VStack(alignment: .leading, spacing: 4) {
        Text(
          "\(QuotaFormat.compactCount(totals.inputTokens)) in · \(QuotaFormat.compactCount(totals.outputTokens)) out"
        )
        .font(.body)
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("section.footer.\(identifier)")
        Text(QuotaFormat.costBasis(cost))
          .font(.body)
          .foregroundStyle(Color.primary)
        if partial {
          Text(partialCopy)
            .font(.body)
            .foregroundStyle(Color.primary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(footerAccessibilityLabel)
    }
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
        ForEach(section.providers) { provider in
          providerRows(provider, agentID: section.id)
        }
      } header: {
        Text(section.displayName)
          .accessibilityIdentifier("section.header.\(section.id)")
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

    Text(provider.displayName)
      .font(.subheadline)
      .foregroundStyle(Color.primary)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("usage.provider.\(provider.id)")

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
      Text(row.displayName)
        .font(.subheadline)
        .foregroundStyle(Color.primary)
      Spacer(minLength: 8)
      Text("\(tokens) · \(cost)")
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(Color.primary)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(row.displayName), \(QuotaFormat.accessibleCount(row.totals.totalTokens)) tokens, \(QuotaFormat.costAccessibility(row.cost))"
    )
    .accessibilityIdentifier(modelIdentifier)
  }
}
