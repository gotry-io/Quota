import QuotaPresentation
import QuotaWire
import SwiftUI

/// Dashboard Usage: the panel Usage page at width. Period stepping, custom range, totals,
/// a cost-per-day chart, Projects on This Mac, and the monthly budget keep their existing
/// behaviour and copy.
struct DashboardUsageView: View {
  var dashboard: DashboardModel
  let now: Date
  @State private var rangeEditor = false
  @State private var draftFrom = Date()
  @State private var draftTo = Date()

  var body: some View {
    let state = dashboard.presentedUsage(now: now)
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
      Text("Usage")
        .quotaSectionHeaderStyle()

      if let refreshWarning = state.refreshWarning {
        QuotaInlineNotice(message: refreshWarning)
      }

      if let accountErrorMessage = state.accountWarning,
        accountErrorMessage != state.refreshWarning
      {
        QuotaInlineNotice(message: accountErrorMessage)
      }

      usagePeriodTabs
      usagePeriodStepper(state)

      if rangeEditor {
        rangeEditorRow
      }

      if let progress = state.budget {
        budgetBar(progress)
      }

      if let warning = state.statusWarning {
        QuotaInlineNotice(message: warning)
      }

      if let usage = state.usage {
        usageSummary(usage)

        if let days = usage.days, days.contains(where: { $0.totals.totalTokens > 0 }) {
          usageCard("Daily") {
            dailyUsage(days)
          }
        }

        usageCard("Models") {
          let providers = presentedProviders(usage.models)
          if providers.isEmpty {
            QuotaSectionStateView(
              presentation: .empty(message: "No model usage is available for this period.")
            )
          } else {
            VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
              topModels(usage)
              ForEach(providers) { provider in
                providerUsage(provider, of: usage.totals.totalTokens)
              }
            }
          }
        }

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
      } else {
        usageCard("Summary") {
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

      if let sessions = state.sessions {
        sessionsSection(sessions)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
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

  private func budgetBar(_ progress: UsageBudgetProgress) -> some View {
    usageCard("Monthly budget") {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        ProgressView(value: progress.fraction)
        Text(progress.text)
          .quotaMonoListValueStyle()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Monthly budget")
      .accessibilityValue(progress.accessibilityText)
    }
  }

  private func usageSummary(_ usage: DashboardPresentedUsage) -> some View {
    let tokens = UsageValueFormatter.count(usage.totals.totalTokens)
    let cost = UsageValueFormatter.compactCost(usage.cost)
    let hit = UsageMetrics.cacheHitPercentLabel(basisPoints: usage.cacheHitBasisPoints) ?? "—"
    let saved = UsageValueFormatter.cacheSaved(usage.cacheSaved)
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
      HStack(alignment: .top, spacing: QuotaDesign.Spacing.section) {
        QuotaStatTile(label: "Tokens", value: tokens)
        QuotaStatTile(label: "Cost", value: cost)
        QuotaStatTile(label: "Cache hit", value: hit, caption: saved)
      }
      usageCard("Summary") {
        tokenMetrics(usage.totals)
      }
    }
  }

  private func dailyUsage(_ days: [LocalUsageDay]) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      DashboardUsageChart(days: days)
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        ForEach(days.reversed().prefix(7), id: \.date) { day in
          HStack(spacing: QuotaDesign.Spacing.xxs) {
            Text(day.date)
              .quotaFont(.listSecondary)
              .foregroundStyle(QuotaPalette.body)
            Spacer(minLength: 0)
            Text(UsageValueFormatter.tokensAndCost(day.totals.totalTokens, day.cost))
              .quotaMonoListValueStyle()
              .lineLimit(1)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Layout.groupContentInset)
  }

  private func providerUsage(
    _ provider: DashboardPresentedUsageProvider,
    of total: Int
  ) -> some View {
    let models = Array(sortedModels(provider.models).prefix(5))
    let duplicateNames = Set(
      Dictionary(grouping: provider.models, by: \.model)
        .filter { $0.value.count > 1 }
        .keys
    )
    let providerTokens = provider.models.reduce(0) { $0 + $1.totals.totalTokens }
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
      providerHeading(provider.provider)
      shareBar(providerTokens, of: total)
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        ForEach(models, id: \.id) { model in
          let title =
            if duplicateNames.contains(model.model), let agent = model.agent {
              "\(model.model) · \(agent.displayName)"
            } else {
              model.model
            }
          modelUsageRow(model, title: title, of: total)
        }
      }
    }
  }

  private func shareBar(_ tokens: Int, of total: Int) -> some View {
    let share = total > 0 ? min(1, Double(tokens) / Double(total)) : 0
    return HStack(spacing: QuotaDesign.Spacing.sm) {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(QuotaPalette.progressTrack)
          Capsule()
            .fill(QuotaPalette.ink.opacity(0.55))
            .frame(width: proxy.size.width * share)
        }
      }
      .frame(height: 4)
      Text(UsageValueFormatter.share(tokens, of: total) ?? "—")
        .quotaMetaStyle()
        .monospacedDigit()
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(
      .leading,
      QuotaDesign.Layout.settingsIconColumnWidth + QuotaDesign.Spacing.sm
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Share of period")
    .accessibilityValue(UsageValueFormatter.share(tokens, of: total) ?? "none")
  }

  @ViewBuilder
  private func topModels(_ usage: DashboardPresentedUsage) -> some View {
    let ranked = Array(sortedByTokens(usage.models).prefix(3))
    if ranked.count > 1 {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        Text("Top models")
          .quotaMetaStyle()
        ForEach(ranked, id: \.id) { model in
          HStack(spacing: QuotaDesign.Spacing.xxs) {
            Text(model.model)
              .quotaFont(.listSecondary)
              .foregroundStyle(QuotaPalette.ink)
              .lineLimit(1)
            Spacer(minLength: 0)
            Text(
              "\(UsageValueFormatter.share(model.totals.totalTokens, of: usage.totals.totalTokens) ?? "—") · \(UsageValueFormatter.count(model.totals.totalTokens))"
            )
            .quotaMonoListValueStyle()
            .lineLimit(1)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .padding(.bottom, QuotaDesign.Spacing.sm)
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

  private func providerHeading(_ provider: InferenceProvider?) -> some View {
    let title = provider?.displayName ?? "Unknown Provider"
    return HStack(spacing: QuotaDesign.Spacing.sm) {
      UsageProviderIcon(
        provider: provider,
        size: QuotaDesign.Layout.usageProviderIconSize
      )
      .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
      Text(title)
        .quotaFont(.quotaLabel)
        .foregroundStyle(QuotaPalette.ink)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Provider \(title)")
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

  private func modelUsageRow(
    _ model: DashboardPresentedUsageModel,
    title: String,
    of total: Int
  ) -> some View {
    let share = UsageValueFormatter.share(model.totals.totalTokens, of: total)
    let summary =
      UsageValueFormatter.tokensAndCost(model.totals.totalTokens, model.cost)
      + (share.map { " · \($0)" } ?? "")
    return HStack(spacing: QuotaDesign.Spacing.xxs) {
      Text(title)
        .quotaFont(.listSecondary)
        .foregroundStyle(QuotaPalette.body)
        .lineLimit(1)
      Spacer(minLength: 0)
      Text(summary)
        .quotaMonoListValueStyle()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(
      .leading,
      QuotaDesign.Layout.settingsIconColumnWidth + QuotaDesign.Spacing.sm
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.model)
    .accessibilityValue(summary)
  }

  private func tokenMetrics(_ totals: DashboardPresentedUsageTotals) -> some View {
    LazyVGrid(
      columns: [
        GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
      ],
      alignment: .leading,
      spacing: QuotaDesign.Spacing.meta
    ) {
      modelMetric("Input", totals.inputTokens)
      modelMetric("Output", totals.outputTokens)
      modelMetric("Cache read", totals.cacheReadInputTokens)
      modelMetric("Cache write", totals.cacheWriteInputTokens)
      modelMetric("Reasoning", totals.reasoningTokens)
      modelMetric("Messages", totals.messages)
    }
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

  private func modelMetric(_ label: String, _ value: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.meta) {
      Text(label).quotaMetaStyle()
      Spacer(minLength: 2)
      Text(UsageValueFormatter.count(value)).quotaMonoListValueStyle()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(UsageValueFormatter.accessibleCount(value))
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

  private func presentedProviders(
    _ models: [DashboardPresentedUsageModel]
  ) -> [DashboardPresentedUsageProvider] {
    Dictionary(grouping: models, by: \.provider)
      .map { DashboardPresentedUsageProvider(provider: $0.key, models: $0.value) }
      .sorted {
        let left = sortedModels($0.models).first
        let right = sortedModels($1.models).first
        guard let left, let right else { return left != nil }
        return UsageValueFormatter.precedes(
          cost: left.cost,
          tokens: $0.models.reduce(0) { $0 + $1.totals.totalTokens },
          name: $0.provider?.rawValue ?? "unknown",
          before: right.cost,
          tokens: $1.models.reduce(0) { $0 + $1.totals.totalTokens },
          name: $1.provider?.rawValue ?? "unknown"
        )
      }
  }

  private func sortedByTokens(_ models: [DashboardPresentedUsageModel])
    -> [DashboardPresentedUsageModel]
  {
    models.sorted {
      $0.totals.totalTokens != $1.totals.totalTokens
        ? $0.totals.totalTokens > $1.totals.totalTokens
        : $0.model < $1.model
    }
  }

  private func sortedModels(_ models: [DashboardPresentedUsageModel])
    -> [DashboardPresentedUsageModel]
  {
    models.sorted {
      UsageValueFormatter.precedes(
        cost: $0.cost, tokens: $0.totals.totalTokens, name: $0.model,
        before: $1.cost, tokens: $1.totals.totalTokens, name: $1.model
      )
    }
  }
}

private struct QuotaStatTile: View {
  let label: String
  let value: String
  var caption: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
      Text(label)
        .quotaMetaStyle()
      Text(value)
        .font(QuotaDesign.Typography.statValue)
        .foregroundStyle(QuotaPalette.ink)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      if let caption {
        Text(caption)
          .quotaMetaStyle()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(QuotaDesign.Layout.cardPadding)
    .quotaCardSurface()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(value + (caption.map { ", \($0)" } ?? ""))
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

private struct UsageProviderIcon: View {
  let provider: InferenceProvider?
  var size = QuotaDesign.Layout.settingsIconColumnWidth

  var body: some View {
    if let assetName = provider?.brandAssetName {
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

extension InferenceProvider {
  fileprivate var brandAssetName: String? {
    switch self {
    case .openai: "openai"
    case .anthropic: "claude"
    case .xai: "grok"
    case .moonshot: "kimi"
    case .deepseek: "deepseek"
    case .cursor: "cursor"
    case .google: "gemini"
    case .unknown: nil
    }
  }
}
