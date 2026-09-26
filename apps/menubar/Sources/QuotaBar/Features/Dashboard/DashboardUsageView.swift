import QuotaPresentation
import QuotaWire
import SwiftUI

/// Dashboard Usage, an analysis page (ADR 0064): a sentence about the reader's own model usage,
/// the period controls, the model river with its ledger, and the token mix; then the Today
/// windows table, the monthly budget, Projects on This Mac, Rhythm, and Sessions.
struct DashboardUsageView: View {
  var dashboard: DashboardModel
  let now: Date
  @State private var rangeEditor = false
  @State private var draftFrom = Date()
  @State private var draftTo = Date()
  @State private var metric: UsageMetric = .tokens
  @State private var scale: UsageRiverScale = .amount
  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback

  var body: some View {
    let state = dashboard.presentedUsage(now: now)
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
      sentenceHeader(state)

      usagePeriodTabs
      usagePeriodStepper(state)

      if rangeEditor {
        rangeEditorRow
      }

      if let refreshWarning = state.refreshWarning {
        QuotaInlineNotice(message: refreshWarning)
      }

      if let accountErrorMessage = state.accountWarning,
        accountErrorMessage != state.refreshWarning
      {
        QuotaInlineNotice(message: accountErrorMessage)
      }

      if let warning = state.statusWarning {
        QuotaInlineNotice(message: warning)
      }

      if let usage = state.usage {
        modelsCard(usage, state: state)

        if usage.totals.totalTokens > 0 {
          usageCard("Token mix") {
            UsageTokenMixView(mix: UsageTokenMix(usage.totals), cacheSaved: usage.cacheSaved)
          }
        }
      } else {
        usageCard("Usage by model") {
          QuotaSectionStateView(
            presentation: state.isPreparing
              ? .loading(title: "Preparing Usage…")
              : .empty(
                message: state.available
                  ? "No Usage is available for this period."
                  : "This period is folded from this Mac's own hours. Switch the source to this Mac to see it."
              )
          )
        }
      }

      if dashboard.showsTodayWindows {
        DashboardTodayTable(
          rows: dashboard.todayRows(now: now, resetStyle: resetCopyStyle.style)
        )
      }

      if let progress = state.budget {
        budgetBar(progress, basis: state.budgetBasis)
      }

      if let usage = state.usage {
        if state.showsProjects, let projects = usage.projects, !projects.isEmpty {
          usageCard("Projects") {
            projectUsage(projects)
          }
        }

        if let hours = usage.hoursOfDay, hours.contains(where: { $0.totalTokens > 0 }) {
          usageCard("Rhythm") {
            rhythm(hours)
          }
        }
      }

      if let sessions = state.sessions {
        sessionsSection(sessions)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  /// Eyebrow, one sentence written from the reader's numbers, and one meta line.
  private func sentenceHeader(_ state: DashboardUsagePresentation) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text("Usage · \(state.source == .account ? "Account" : "This Mac")")
        .quotaSectionHeaderStyle()
      sentence(state)
        .quotaFont(.sentence)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if let usage = state.usage, usage.totals.totalTokens > 0 {
        Text(
          UsageSentence.meta(
            totals: usage.totals,
            cost: usage.cost,
            cacheHitBasisPoints: usage.cacheHitBasisPoints,
            days: usage.days,
            previous: usage.previousTotals
          )
        )
        .quotaMetaStyle()
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func sentence(_ state: DashboardUsagePresentation) -> Text {
    guard let usage = state.usage else {
      return Text(state.isPreparing ? "Preparing Usage…" : "No Usage is available for this period.")
        .foregroundStyle(QuotaPalette.body)
    }
    return UsageSentence.runs(
      totals: usage.totals,
      ledger: usage.ledger,
      periodPhrase: state.periodPhrase
    )
    .reduce(Text("")) { text, run in
      text
        + Text(run.text)
        .foregroundStyle(run.emphasized ? QuotaPalette.ink : QuotaPalette.body)
    }
  }

  /// The metric switch carrying each metric's value for the period, the river, and the ledger.
  private func modelsCard(
    _ usage: DashboardPresentedUsage,
    state: DashboardUsagePresentation
  ) -> some View {
    let river = UsageRiver.make(
      range: usage.range,
      series: usage.modelSeries,
      days: usage.days,
      metric: metric,
      scale: scale,
      colors: state.colors,
      today: state.today
    )
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
      HStack(alignment: .bottom, spacing: QuotaDesign.Spacing.md) {
        metricSwitch(usage)
        Spacer(minLength: 0)
        if river != nil {
          Picker("Scale", selection: $scale) {
            ForEach(UsageRiverScale.allCases) { scale in
              Text(scale.title).tag(scale)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .accessibilityLabel("Scale")
        }
      }
      if let river {
        UsageRiverChart(river: river)
      }
      if usage.ledger.isEmpty {
        QuotaSectionStateView(
          presentation: .empty(message: "No model usage is available for this period.")
        )
      } else {
        UsageModelLedgerView(rows: usage.ledger, colors: state.colors, metric: metric)
      }
    }
    .padding(QuotaDesign.Layout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaCardSurface()
  }

  /// Tokens, API-equivalent cost, and Messages, each with its value for the period.
  private func metricSwitch(_ usage: DashboardPresentedUsage) -> some View {
    HStack(spacing: QuotaDesign.Spacing.lg) {
      ForEach(UsageMetric.allCases) { item in
        let selected = metric == item
        Button { metric = item } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
              .quotaFont(.meta)
              .foregroundStyle(selected ? QuotaPalette.ink : QuotaPalette.mute)
            Text(item.periodValue(usage.totals, cost: usage.cost))
              .quotaFont(.rowTitle)
              .foregroundStyle(selected ? QuotaPalette.ink : QuotaPalette.body)
              .monospacedDigit()
            Rectangle()
              .fill(selected ? QuotaPalette.ink : Color.clear)
              .frame(height: 2)
          }
          .fixedSize()
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.periodValue(usage.totals, cost: usage.cost))
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Measure")
  }

  /// The six segments a period is named by. A custom range selects none of them and says what it
  /// covers in the title row instead.
  private var usagePeriodTabs: some View {
    HStack(spacing: 0) {
      ForEach(UsagePeriodSegment.allCases.filter { $0 != .custom }) { value in
        let selected = dashboard.selectedUsagePeriodSegment == value
        Button { dashboard.selectUsagePeriod(.selection(for: value, custom: nil)) } label: {
          Text(value.title)
            .quotaFont(.listSecondary)
            .foregroundStyle(selected ? QuotaPalette.ink : QuotaPalette.body)
            .frame(
              maxWidth: .infinity,
              minHeight: QuotaDesign.Layout.minimumInteractiveDimension
            )
            .background {
              if selected {
                RoundedRectangle(
                  cornerRadius: QuotaDesign.Layout.rowCornerRadius,
                  style: .continuous
                )
                .fill(QuotaPalette.fieldFill)
                .padding(2)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.accessibilityTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .frame(maxWidth: 480)
    .background {
      RoundedRectangle(
        cornerRadius: QuotaDesign.Layout.fieldCornerRadius,
        style: .continuous
      )
      .fill(QuotaPalette.progressTrack.opacity(0.55))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Usage period")
  }

  private func usagePeriodStepper(_ state: DashboardUsagePresentation) -> some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      stepButton(
        symbol: "chevron.left",
        label: "Previous period",
        target: dashboard.usagePeriod.previous
      )
      Text(state.title)
        .quotaFont(.listSecondary)
        .foregroundStyle(QuotaPalette.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Period \(state.title)")
      stepButton(
        symbol: "chevron.right",
        label: "Next period",
        target: dashboard.usagePeriod.next
      )
      Button {
        let range = dashboard.usagePeriod.range(today: now)
        draftFrom = range.flatMap { UsageDateText.date(from: $0.from) } ?? now
        draftTo = range.flatMap { UsageDateText.date(from: $0.to) } ?? now
        rangeEditor.toggle()
      } label: {
        Image(systemName: "calendar")
          .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Custom range")
    }
    .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
  }

  private func stepButton(
    symbol: String,
    label: String,
    target: UsagePeriodSelection?
  ) -> some View {
    Button { if let target { dashboard.selectUsagePeriod(target) } } label: {
      Image(systemName: symbol)
        .foregroundStyle(target == nil ? QuotaPalette.body.opacity(0.4) : QuotaPalette.ink)
        .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
    }
    .buttonStyle(.plain)
    .disabled(target == nil)
    .accessibilityLabel(label)
  }

  private var rangeEditorRow: some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      DatePicker("From", selection: $draftFrom, displayedComponents: .date)
      DatePicker("To", selection: $draftTo, displayedComponents: .date)
      Button("Apply") {
        dashboard.selectUsagePeriod(
          .custom(
            from: UsageDateText.date(min(draftFrom, draftTo)),
            to: UsageDateText.date(max(draftFrom, draftTo))
          )
        )
        rangeEditor = false
      }
    }
    .datePickerStyle(.field)
    .quotaFont(.listSecondary)
  }

  private func budgetBar(_ progress: UsageBudgetProgress, basis: String?) -> some View {
    usageCard("Monthly budget") {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        ProgressView(value: progress.fraction)
        Text(progress.text)
          .quotaMonoListValueStyle()
        if let basis {
          Text(basis)
            .quotaFont(.meta)
            .foregroundStyle(QuotaPalette.body)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Monthly budget")
      .accessibilityValue(
        basis.map { "\(progress.accessibilityText). \($0)" } ?? progress.accessibilityText
      )
    }
  }

  private func rhythm(_ hours: [LocalUsageHourOfDay]) -> some View {
    let maximum = hours.map(\.totalTokens).max() ?? 0
    let total = hours.reduce(0) { $0 + $1.totalTokens }
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      HStack(alignment: .bottom, spacing: 2) {
        ForEach(hours, id: \.hour) { hour in
          let share = maximum > 0 ? Double(hour.totalTokens) / Double(maximum) : 0
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(QuotaPalette.ink.opacity(hour.totalTokens > 0 ? 0.55 : 0.12))
            .frame(maxWidth: .infinity)
            .frame(height: max(2, 36 * share))
            .help("\(hour.hour):00 · \(UsageValueFormatter.count(hour.totalTokens)) tokens")
        }
      }
      .frame(height: 36, alignment: .bottom)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Usage by hour of the day")

      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
          GridItem(.flexible())],
        alignment: .leading,
        spacing: QuotaDesign.Spacing.meta
      ) {
        ForEach(UsageDayPart.allCases, id: \.self) { part in
          let tokens = hours.filter { part.hours.contains($0.hour) }.reduce(0) {
            $0 + $1.totalTokens
          }
          HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.meta) {
            Text(part.title).quotaMetaStyle()
            Spacer(minLength: 2)
            Text(UsageValueFormatter.share(tokens, of: total) ?? "—")
              .quotaMonoListValueStyle()
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(part.title)
          .accessibilityValue(UsageValueFormatter.share(tokens, of: total) ?? "none")
        }
      }
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
    .padding(.vertical, QuotaDesign.Layout.groupContentInset)
  }

  private func projectUsage(_ projects: [LocalUsageProjectSummary]) -> some View {
    let ordered = projects.sorted {
      UsageValueFormatter.precedes(
        cost: $0.cost, tokens: $0.totalTokens, name: $0.projectKey,
        before: $1.cost, tokens: $1.totalTokens, name: $1.projectKey
      )
    }
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
      HStack(spacing: QuotaDesign.Spacing.xxs) {
        Text("Project")
          .quotaMetaStyle()
        Spacer(minLength: 0)
        Text("Tokens")
          .quotaMetaStyle()
          .frame(minWidth: 72, alignment: .trailing)
        Text("Cost")
          .quotaMetaStyle()
          .frame(minWidth: 72, alignment: .trailing)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .padding(.top, QuotaDesign.Spacing.sm)
      .accessibilityHidden(true)

      ForEach(ordered, id: \.projectKey) { project in
        let tokens = UsageValueFormatter.count(project.totalTokens)
        let cost = UsageValueFormatter.compactCost(project.cost)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.xxs) {
            Text(project.displayName)
              .quotaFont(.listSecondary)
              .foregroundStyle(QuotaPalette.body)
              .lineLimit(1)
            Spacer(minLength: 0)
            Text(tokens)
              .quotaMonoListValueStyle()
              .lineLimit(1)
              .frame(minWidth: 72, alignment: .trailing)
            Text(cost)
              .quotaMonoListValueStyle()
              .lineLimit(1)
              .minimumScaleFactor(0.75)
              .frame(minWidth: 72, alignment: .trailing)
          }
          Text(project.topModel)
            .quotaMetaStyle()
            .lineLimit(1)
        }
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.displayName)
        .accessibilityValue("\(tokens) tokens, \(cost), top model \(project.topModel)")
      }
    }
    .padding(.bottom, QuotaDesign.Spacing.sm)
  }

  private func sessionsSection(_ sessions: LocalUsageSessions) -> some View {
    usageCard(
      "Sessions",
      trailing: {
        Text("\(sessions.active) active · \(sessions.today) today")
          .quotaMetaStyle()
          .accessibilityLabel("\(sessions.active) active, \(sessions.today) today")
      }
    ) {
      if sessions.recent.isEmpty {
        QuotaSectionStateView(
          presentation: .empty(message: "No sessions in the last 90 days.")
        )
      } else {
        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
          ForEach(sessions.recent) { session in
            sessionRow(session, now: now)
          }
        }
      }
    }
  }

  private func sessionRow(_ session: LocalUsageSession, now: Date) -> some View {
    let summary = UsageValueFormatter.tokensAndCost(session.tokens, session.cost)
    let age = FreshnessCopy.age(since: session.lastActivityAt, now: now)
    let active = session.isActive
    return HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      ZStack(alignment: .topTrailing) {
        UsageAgentIcon(agent: session.agent, size: QuotaDesign.Layout.usageProviderIconSize)
          .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        if active {
          Circle()
            .fill(QuotaPalette.accent)
            .frame(width: 6, height: 6)
            .offset(x: 2, y: -2)
            .accessibilityHidden(true)
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(session.projectKey)
          .quotaFont(.listSecondary)
          .foregroundStyle(QuotaPalette.ink)
          .lineLimit(1)
        Text(age)
          .quotaMetaStyle()
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Text(summary)
        .quotaMonoListValueStyle()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sessionAccessibilityLabel(session, age: age, summary: summary, active: active))
  }

  private func sessionAccessibilityLabel(
    _ session: LocalUsageSession,
    age: String,
    summary: String,
    active: Bool
  ) -> String {
    var parts = [session.agent.displayName, session.projectKey, age, summary]
    if active { parts.insert("Active", at: 0) }
    return parts.joined(separator: ", ")
  }

  private func usageCard<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    usageCard(title, trailing: { EmptyView() }, content: content)
  }

  private func usageCard<Content: View, Trailing: View>(
    _ title: String,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
        Text(title)
          .quotaSectionHeaderStyle()
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        trailing()
          .layoutPriority(1)
      }
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(QuotaDesign.Layout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaCardSurface()
  }

}

private struct UsageAgentIcon: View {
  let agent: BillingAgent
  var size = QuotaDesign.Layout.settingsIconColumnWidth

  var body: some View {
    if let assetName = agent.brandAssetName {
      BrandAssetIcon(assetName: assetName, size: size)
    } else {
      Image(systemName: "questionmark.square.dashed")
        .quotaFont(.secondary)
        .foregroundStyle(QuotaPalette.body)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }
}

extension BillingAgent {
  fileprivate var brandAssetName: String? {
    switch self {
    case .codex: "openai"
    case .claudeCode: "claude"
    case .grok: "grok"
    case .opencode: "opencode"
    case .pi: "pi"
    case .cursor: "cursor"
    case .gemini: "gemini"
    case .copilot: "copilot"
    case .kilo: "kilo"
    case .antigravity: "antigravity"
    case .unknown: nil
    }
  }
}
