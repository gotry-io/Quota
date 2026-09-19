import QuotaPresentation
import QuotaWire
import SwiftUI

struct UsageView: View {
  @Bindable var model: AppModel
  @State private var expandedProviderIDs: Set<String> = []
  @State private var rangeEditor = false
  @State private var budgetEditor = false

  var body: some View {
    @Bindable var usage = model.usage
    List {
      // Usage is the Account's fold across every device. This phone measures none of it, so
      // without an account there is nothing to pick a period of.
      if !model.hasAccountSession {
        signedOutInvitation
      } else {
        Section {
          QuotaCard {
            periodPicker
            periodStepper
          }
          .quotaCardRow()
        }

        if let period = usage.usagePeriodValue {
          Section {
            UsageTotalsSection(period: period)
              .quotaCardRow()
          }
        }

        Section {
          UsageBudgetSection(model: model, editing: $budgetEditor)
            .quotaCardRow()
        }

        signedInContent
      }
    }
    .listStyle(.insetGrouped)
    .task(id: model.selectedTab) {
      guard model.selectedTab == .usage else { return }
      await usage.loadActivity()
    }
    .task(id: "\(model.selectedTab)-\(usage.usagePeriodTitle)") {
      guard model.selectedTab == .usage else { return }
      await usage.loadRhythm()
    }
    .sheet(item: $usage.activityDaySheet) { _ in
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

  /// The days the Daily section draws, which the Activity read has already fetched.
  ///
  /// The table covers the period's own days, bounded by the activity days this phone holds.
  private var dailyRows: [UsageDailyFold.Row] {
    guard let days = model.usage.activityChart.days, let range = model.usage.usagePeriodRange else {
      return []
    }
    let available = UsageActivityCalendar.range(endingOn: model.usage.activityToday)
    return UsageDailyFold.rows(
      reported: days,
      from: max(range.from, available.from),
      to: min(range.to, available.to)
    )
  }

  private var signedOutInvitation: some View {
    ContentUnavailableView {
      Label(UsageCopy.signedOutTitle, systemImage: "chart.bar")
    } description: {
      Text(UsageCopy.signedOutDetail)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    } actions: {
      Button(UsageCopy.signIn) { model.showSignIn() }
        .frame(minHeight: QuotaTheme.minimumTouchTarget)
        .accessibilityIdentifier("usage.signin")
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, minHeight: 220)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  @ViewBuilder
  private var signedInContent: some View {
    if let period = model.usage.usagePeriodValue {
      let sections = model.usage.usagePeriodIsFolded ? [] : UsageBreakdown.sections(in: period)
      if model.usage.usagePeriodIsFolded {
        foldedPeriod
      } else if sections.isEmpty {
        emptyPeriod
      }
      if model.selectedTab == .usage {
        if UsageDailyFold.hasUsage(dailyRows) {
          UsageDailySection(rows: dailyRows)
        }
        if let hours = model.usage.activityRhythm.hours {
          UsageRhythmSection(hoursOfDay: hours.hoursOfDay, weekdayHours: hours.weekdayHours)
        }
        UsageActivitySection(model: model)
        UsageTopModelsSection(sections: sections, periodTokens: period.totals.totalTokens)
        UsageAgentListSections(
          sections: sections,
          periodTokens: period.totals.totalTokens,
          expandedProviderIDs: $expandedProviderIDs
        )
      }
    } else if model.selectedTab == .usage {
      emptyPeriod
      UsageActivitySection(model: model)
    }
  }

  private enum UsageCopy {
    static let signedOutTitle = "Sign in to see your usage"
    static let signedOutDetail =
      "Usage is what QuotaBar reports from your Macs. This iPhone reads quota here, and measures "
      + "no usage of its own."
    static let signIn = "Sign in to Quota"
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
    .frame(minHeight: QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("usage.period")
  }

  private var periodStepper: some View {
    HStack(spacing: 12) {
      Button {
        if let previous = model.usage.usagePeriod.previous {
          model.usage.selectUsagePeriod(previous)
        }
      } label: {
        Image(systemName: "chevron.left")
          .frame(
            minWidth: QuotaTheme.minimumTouchTarget,
            minHeight: QuotaTheme.minimumTouchTarget
          )
          .contentShape(Rectangle())
      }
      .disabled(model.usage.usagePeriod.previous == nil)
      .accessibilityLabel("Previous period")
      .accessibilityIdentifier("usage.period.previous")

      Text(model.usage.usagePeriodTitle)
        .font(QuotaDesign.Typography.support)
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("usage.period.title")

      Button {
        if let next = model.usage.usagePeriod.next { model.usage.selectUsagePeriod(next) }
      } label: {
        Image(systemName: "chevron.right")
          .frame(
            minWidth: QuotaTheme.minimumTouchTarget,
            minHeight: QuotaTheme.minimumTouchTarget
          )
          .contentShape(Rectangle())
      }
      .disabled(model.usage.usagePeriod.next == nil)
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
      get: {
        model.usage.usagePeriod.segment == .custom ? nil : model.usage.usagePeriod.segment
      },
      set: { segment in
        guard let segment else { return }
        model.usage.selectUsagePeriod(.selection(for: segment, custom: nil))
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
      // The row takes the view's ideal height, so the wrapped description is never cut by a
      // row sized before the text wrapped.
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("usage.empty")
  }
}

struct UsageTotalsSection: View {
  let totals: UsageSummaryTotals
  let cost: UsageCostOutcome
  /// Absent for one day of the activity chart, which is priced but carries no saving of its own.
  let cacheSaved: UsageCacheSaved?
  let partial: Bool
  var partialCopy: String = "Some hours in this period were scanned incompletely."
  var identifier: String = "usage.headline"

  init(period: UsagePeriod, identifier: String = "usage.headline") {
    totals = period.totals
    cost = period.cost
    cacheSaved = period.cacheSaved
    partial = period.partial
    self.identifier = identifier
  }

  init(
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    cacheSaved: UsageCacheSaved? = nil,
    partial: Bool,
    partialCopy: String = "Some hours in this period were scanned incompletely.",
    identifier: String = "usage.headline"
  ) {
    self.totals = totals
    self.cost = cost
    self.cacheSaved = cacheSaved
    self.partial = partial
    self.partialCopy = partialCopy
    self.identifier = identifier
  }

  private var cacheHitLabel: String {
    UsageMetrics.cacheHitPercentLabel(
      basisPoints: UsageMetrics.cacheHitBasisPoints(
        cacheReadInputTokens: totals.cacheReadInputTokens,
        inputTokens: totals.inputTokens
      )
    ) ?? "—"
  }

  var body: some View {
    QuotaCard {
      QuotaStatGrid {
        costTile
        tokensTile
        cacheHitTile
        reasoningTile
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(
          "\(QuotaFormat.compactCount(totals.inputTokens)) in · \(QuotaFormat.compactCount(totals.outputTokens)) out"
        )
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("section.footer.\(identifier)")
        Text("\(QuotaFormat.costBasis(cost)) · \(QuotaFormat.costPriced(cost))")
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("\(identifier).priced")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(footerAccessibilityLabel)

      if partial {
        Label(partialCopy, systemImage: "exclamationmark.triangle")
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(QuotaTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var costTile: some View {
    QuotaStatTile(
      label: "Cost",
      value: QuotaFormat.cost(cost),
      valueIdentifier: "\(identifier).cost"
    )
    .accessibilityLabel("Cost, \(QuotaFormat.costAccessibility(cost))")
    .accessibilityIdentifier(identifier)
  }

  private var tokensTile: some View {
    QuotaStatTile(
      label: "Tokens",
      value: QuotaFormat.compactCount(totals.totalTokens),
      valueFont: QuotaDesign.Typography.remainingValue
    )
    .accessibilityLabel(
      "\(QuotaFormat.accessibleCount(totals.totalTokens)) tokens, \(QuotaFormat.accessibleCount(totals.inputTokens)) in, \(QuotaFormat.accessibleCount(totals.outputTokens)) out"
    )
    .accessibilityIdentifier("\(identifier).tokens")
  }

  private var cacheHitTile: some View {
    QuotaStatTile(
      label: "Cache hit",
      value: cacheHitLabel,
      caption: cacheSaved.flatMap(QuotaFormat.cacheSaved),
      valueFont: QuotaDesign.Typography.remainingValue
    )
    .accessibilityLabel("Cache hit")
    .accessibilityValue(cacheHitAccessibilityValue)
    .accessibilityIdentifier("\(identifier).cache-hit")
  }

  private var reasoningTile: some View {
    QuotaStatTile(
      label: "Reasoning",
      value: QuotaFormat.compactCount(totals.reasoningTokens),
      valueFont: QuotaDesign.Typography.remainingValue
    )
    .accessibilityLabel("Reasoning")
    .accessibilityValue("\(QuotaFormat.accessibleCount(totals.reasoningTokens)) tokens of output")
    .accessibilityIdentifier("\(identifier).reasoning")
  }

  private var cacheHitAccessibilityValue: String {
    let saved = cacheSaved.flatMap(QuotaFormat.cacheSaved)
    return cacheHitLabel + (saved.map { ", \($0)" } ?? "")
  }

  private var footerAccessibilityLabel: String {
    "\(QuotaFormat.accessibleCount(totals.inputTokens)) in · \(QuotaFormat.accessibleCount(totals.outputTokens)) out. Cost basis, \(QuotaFormat.costBasis(cost)). \(QuotaFormat.costPriced(cost))"
      + (partial ? ". \(partialCopy)" : "")
  }
}

/// The three models this period was mostly spent on, above the tree that holds all of them.
struct UsageTopModelsSection: View {
  let sections: [UsageBreakdown.AgentSection]
  let periodTokens: Int

  var body: some View {
    let ranked = Array(UsageBreakdown.rankedModels(in: sections).prefix(3))
    if ranked.count > 1 {
      let topTokens = ranked[0].totals.totalTokens
      Section {
        ForEach(Array(ranked.enumerated()), id: \.element.id) { index, row in
          let share = QuotaFormat.share(row.totals.totalTokens, of: periodTokens) ?? "—"
          let fraction = topTokens > 0 ? Double(row.totals.totalTokens) / Double(topTokens) : 0
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(QuotaTheme.secondary)
              Text(row.displayName)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
              Spacer(minLength: 8)
              Text("\(share) · \(QuotaFormat.compactCount(row.totals.totalTokens))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
            }
            QuotaShareBar(share: fraction)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(row.displayName)
          .accessibilityValue(
            "\(QuotaFormat.share(row.totals.totalTokens, of: periodTokens) ?? "no share"), \(QuotaFormat.accessibleCount(row.totals.totalTokens)) tokens"
          )
          .accessibilityIdentifier("usage.top-model")
        }
      } header: {
        Text("Top models")
          .accessibilityIdentifier("section.header.top-models")
      }
    }
  }
}

struct UsageAgentListSections: View {
  let sections: [UsageBreakdown.AgentSection]
  var periodTokens: Int = 0
  @Binding var expandedProviderIDs: Set<String>
  var modelIdentifier: String = "usage.model"
  var showMoreIdentifier: String = "usage.show-more"
  var showFewerIdentifier: String = "usage.show-fewer"

  var body: some View {
    ForEach(sections) { section in
      Section {
        QuotaCard(
          title: section.displayName,
          systemImage: section.agent.systemImage,
          titleIdentifier: "section.header.\(section.id)"
        ) {
          ForEach(section.providers) { provider in
            providerBlock(provider, agentID: section.id)
          }
        }
        .quotaCardRow()
      }
    }
  }

  @ViewBuilder
  private func providerBlock(
    _ provider: UsageBreakdown.ProviderSection,
    agentID: String
  ) -> some View {
    let key = provider.expansionKey(agentID: agentID)
    let expanded = expandedProviderIDs.contains(key)
    let visible = provider.visibleModels(expanded: expanded)
    let hidden = provider.hiddenCount(expanded: expanded)
    let providerTokens = UsageBreakdown.providerTokens(provider)

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(provider.displayName)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Text(QuotaFormat.share(providerTokens, of: periodTokens) ?? "—")
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.primary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(provider.displayName)
      .accessibilityValue(
        "\(QuotaFormat.share(providerTokens, of: periodTokens) ?? "no share") of this period"
      )
      .accessibilityIdentifier("usage.provider.\(provider.id)")

      QuotaShareBar(share: shareFraction(providerTokens, of: periodTokens))

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
        .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
        .accessibilityLabel(
          expanded
            ? "Show fewer \(provider.displayName) models"
            : "Show \(hidden) more \(provider.displayName) models"
        )
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(expanded ? showFewerIdentifier : showMoreIdentifier)
      }
    }
  }

  private func shareFraction(_ part: Int, of whole: Int) -> Double {
    guard whole > 0 else { return 0 }
    return min(1, Double(part) / Double(whole))
  }

  private func modelRow(_ row: UsageBreakdown.ModelRow) -> some View {
    let tokens = QuotaFormat.compactCount(row.totals.totalTokens)
    let cost = QuotaFormat.cost(row.cost)
    let share = QuotaFormat.share(row.totals.totalTokens, of: periodTokens)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(row.displayName)
        .font(.subheadline)
        .foregroundStyle(Color.primary)
      Spacer(minLength: 8)
      Text("\(tokens) · \(cost)" + (share.map { " · \($0)" } ?? ""))
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

/// A share of a whole, drawn once under a name. Fill is emerald.
struct QuotaShareBar: View {
  let share: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(QuotaTheme.meterTrack)
        Capsule()
          .fill(QuotaTheme.emerald)
          .frame(width: proxy.size.width * share)
      }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}
