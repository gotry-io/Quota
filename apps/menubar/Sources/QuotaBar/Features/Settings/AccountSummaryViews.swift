import Foundation
import QuotaPresentation
import QuotaWire
import SwiftUI

private enum AccountDevicesPageState: Equatable {
  case loading
  case empty(message: String)
  case error(message: String)
  case content(summary: AccountSummary, refreshWarning: String?)
}

struct AccountDevicesView: View {
  @Bindable var model: MenuBarViewModel

  var body: some View {
    QuotaNavigationStableContent(state: pageState) { state in
      content(state)
    }
  }

  private var pageState: AccountDevicesPageState {
    if let summary = model.accountSummary {
      return .content(
        summary: summary,
        refreshWarning: model.accountErrorMessage ?? model.errorMessage
      )
    } else if model.accountRefreshing {
      return .loading
    } else if model.accountState == .signedOut || model.accountState == .logoutPending {
      return .empty(message: accountUnavailableMessage)
    } else if let pageErrorMessage = model.accountErrorMessage ?? model.errorMessage {
      return .error(message: pageErrorMessage)
    } else {
      return .empty(message: accountUnavailableMessage)
    }
  }

  @ViewBuilder
  private func content(_ state: AccountDevicesPageState) -> some View {
    switch state {
    case .loading:
      QuotaPageStateView(loadingTitle: "Loading devices…")
    case .empty(let message):
      QuotaPageStateView(
        emptySystemImage: "desktopcomputer",
        title: "No Account Devices",
        message: message
      )
    case .error(let message):
      QuotaPageStateView(
        errorTitle: "Devices Unavailable",
        message: message,
        retry: { Task { await model.refresh() } }
      )
    case .content(let summary, let refreshWarning):
      loadedDevices(summary, refreshWarning: refreshWarning)
    }
  }

  private func loadedDevices(_ summary: AccountSummary, refreshWarning: String?) -> some View {
    let now = Date()
    return ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        if let refreshWarning {
          QuotaInlineNotice(message: refreshWarning)
        }

        SettingsSection(title: "Account Devices") {
          if summary.devices.isEmpty {
            QuotaSectionStateView(
              presentation: .empty(message: "No devices have signed in yet.")
            )
          } else {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(summary.devices) { device in
                let activity = device.activity(now: now)
                SettingsListRow(
                  title: device.displayName,
                  subtitle: deviceSubtitle(device, activity: activity, now: now),
                  systemImage: platformSymbol(device.platform),
                  height: QuotaDesign.Layout.settingsListRowHeight
                ) {
                  Text(activity.label)
                    .quotaListSecondaryStyle()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(device.displayName)
                .accessibilityValue(
                  activity.label + ". " + deviceSubtitle(device, activity: activity, now: now)
                )
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var accountUnavailableMessage: String {
    model.accountState == .logoutPending
      ? "Logout is pending. QuotaBar will finish when this Mac is online."
      : "Sign in from Settings to view account devices."
  }

  private func deviceSubtitle(
    _ device: AccountDevice,
    activity: DeviceActivity,
    now: Date
  ) -> String {
    let platform =
      switch device.platform {
      case .macos: "macOS"
      case .ios: "iOS"
      case .unknown: "Unknown"
      }
    return "\(platform) · \(FreshnessCopy.lastReading(since: activity.since, now: now))"
  }

  /// The glyph a Device is listed under. A phone is a Device here like any other
  /// ([ADR 0041](../../../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
  private func platformSymbol(_ platform: AccountDevicePlatform) -> String {
    switch platform {
    case .macos: "desktopcomputer"
    case .ios: "iphone"
    case .unknown: "terminal"
    }
  }

}

struct AccountUsageView: View {
  @Bindable var model: MenuBarViewModel
  @Binding var source: UsageSource
  let now: Date
  @State private var rangeEditor = false
  @State private var draftFrom = Date()
  @State private var draftTo = Date()

  var body: some View {
    QuotaNavigationStableContent(state: pageState) { state in
      content(state)
    }
  }

  private var pageState: AccountUsagePageState {
    let presentedSource = effectiveSource
    return AccountUsagePageState(
      refreshWarning: model.errorMessage,
      accountWarning: presentedSource == .account ? model.accountErrorMessage : nil,
      statusWarning: usageStatusWarning(source: presentedSource),
      usage: presentedUsage(source: presentedSource),
      sessions: model.localUsage?.sessions,
      isPreparing: model.isPreparingUsage(source: presentedSource) || model.customUsageLoading,
      title: model.usagePeriodTitle(),
      available: model.usagePeriodIsAvailable(
        source: presentedSource, selection: model.usagePeriod),
      budget: model.budgetProgress
    )
  }

  private func content(_ state: AccountUsagePageState) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
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
          SettingsSection(title: "Summary") {
            usageSummary(usage)
          }

          if let days = usage.days, days.contains(where: { $0.totals.totalTokens > 0 }) {
            SettingsSection(title: "Daily") {
              dailyUsage(days)
            }
          }

          SettingsSection(title: "Models") {
            let providers = presentedProviders(usage.models)
            if providers.isEmpty {
              QuotaSectionStateView(
                presentation: .empty(message: "No model usage is available for this period.")
              )
            } else {
              VStack(
                alignment: .leading,
                spacing: QuotaDesign.Spacing.sm
              ) {
                topModels(usage)
                ForEach(providers) { provider in
                  providerUsage(provider, of: usage.totals.totalTokens)
                }
              }
              .padding(.vertical, QuotaDesign.Spacing.sm)
            }
          }

          if let projects = usage.projects, !projects.isEmpty {
            SettingsSection(title: "Projects") {
              projectUsage(projects)
            }
          }

          if let hours = usage.hoursOfDay, hours.contains(where: { $0.totalTokens > 0 }) {
            SettingsSection(title: "Rhythm") {
              rhythm(hours)
            }
          }

        } else {
          SettingsSection(title: "Summary") {
            QuotaSectionStateView(
              presentation: state.isPreparing
                ? .loading(title: "Preparing Usage…")
                : .empty(message: state.available
                  ? "No Usage is available for this period."
                  : "This period is folded from this Mac's own hours. Switch the source to this Mac to see it.")
            )
          }
        }

        if let sessions = state.sessions {
          sessionsSection(sessions)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var effectiveSource: UsageSource {
    model.effectiveUsageSource(source)
  }

  /// The six segments a period is named by. A custom range selects none of them and says what it
  /// covers in the title row instead.
  private var usagePeriodTabs: some View {
    HStack(spacing: 0) {
      ForEach(UsagePeriodSegment.allCases.filter { $0 != .custom }) { value in
        let selected = model.usagePeriod.segment == value
        Button { model.selectUsagePeriod(.selection(for: value, custom: nil)) } label: {
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

  private func usagePeriodStepper(_ state: AccountUsagePageState) -> some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      stepButton(
        symbol: "chevron.left", label: "Previous period", target: model.usagePeriod.previous)
      Text(state.title)
        .quotaFont(.listSecondary)
        .foregroundStyle(QuotaPalette.body)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Period \(state.title)")
      stepButton(symbol: "chevron.right", label: "Next period", target: model.usagePeriod.next)
      Button {
        let range = model.usagePeriod.range(today: Date())
        draftFrom = range.flatMap { UsageDateText.date(from: $0.from) } ?? Date()
        draftTo = range.flatMap { UsageDateText.date(from: $0.to) } ?? Date()
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
    Button { if let target { model.selectUsagePeriod(target) } } label: {
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
        model.selectUsagePeriod(
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

  /// This month's spend against the budget this Mac keeps, which is never uploaded.
  private func budgetBar(_ progress: UsageBudgetProgress) -> some View {
    SettingsSection(title: "Monthly budget") {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        ProgressView(value: progress.fraction)
        Text(progress.text)
          .quotaMonoListValueStyle()
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
      .padding(.vertical, QuotaDesign.Layout.groupContentInset)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Monthly budget")
      .accessibilityValue(progress.accessibilityText)
    }
  }

  private func usageStatusWarning(source: UsageSource) -> String? {
    guard let detail = model.usageDetail(source: source, selection: model.usagePeriod) else {
      return nil
    }
    guard detail.incomplete || detail.detailsTruncated else { return nil }
    return source == .local
      ? "Some local Usage may be incomplete."
      : "Some account Usage may be incomplete."
  }

  private func presentedUsage(source: UsageSource) -> PresentedUsage? {
    guard let detail = model.usageDetail(source: source, selection: model.usagePeriod) else {
      return nil
    }
    let usage = detail.usage
    let localModels = usage.agents.flatMap { agent in
      agent.providers.flatMap { provider in
        provider.models.map {
          PresentedUsageModel($0, provider: provider.provider, agent: agent.agent)
        }
      }
    }
    return PresentedUsage(
      totals: PresentedUsageTotals(usage.totals),
      cost: usage.cost,
      cacheSaved: usage.cacheSaved,
      cacheHitBasisPoints: usage.cacheHitBasisPoints,
      days: usage.days,
      hoursOfDay: usage.hoursOfDay,
      models: localModels,
      projects: source == .local && model.groupUsageByProject ? usage.projects : nil
    )
  }

  private func usageSummary(_ usage: PresentedUsage) -> some View {
    let tokens = UsageValueFormatter.count(usage.totals.totalTokens)
    let cost = UsageValueFormatter.compactCost(usage.cost)
    let hit = UsageMetrics.cacheHitPercentLabel(basisPoints: usage.cacheHitBasisPoints) ?? "—"
    let saved = UsageValueFormatter.cacheSaved(usage.cacheSaved)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.md) {
        summaryMetric("Tokens", tokens)
        summaryMetric("Cost", cost)
        summaryMetric("Cache hit", hit, detail: saved)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
      .padding(.top, QuotaDesign.Layout.groupContentInset)
      .padding(.bottom, QuotaDesign.Spacing.sm)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Usage summary")
      .accessibilityValue(
        "\(tokens) tokens, \(cost), cache hit \(hit)" + (saved.map { ", \($0)" } ?? "")
      )

      Divider()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)

      tokenMetrics(usage.totals)
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
        .padding(.vertical, QuotaDesign.Layout.groupContentInset)
    }
  }

  private func summaryMetric(_ label: String, _ value: String, detail: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .quotaMetaStyle()
      Text(value)
        .quotaFont(.rowTitle)
        .monospacedDigit()
        .foregroundStyle(QuotaPalette.ink)
        .lineLimit(1)
      if let detail {
        Text(detail)
          .quotaMetaStyle()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func providerUsage(_ provider: PresentedUsageProvider, of total: Int) -> some View {
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
              "\(model.model) · \(UsageValueFormatter.agent(agent))"
          } else {
            model.model
          }
          modelUsageRow(model, title: title, of: total)
        }
      }
    }
  }

  /// A provider's share of the period, drawn once under its name.
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

  /// The three models this period was mostly spent on, above the tree that holds all of them.
  @ViewBuilder
  private func topModels(_ usage: PresentedUsage) -> some View {
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

  /// One bar per local day, and the numbers behind them.
  private func dailyUsage(_ days: [LocalUsageDay]) -> some View {
    let maximum = days.map(\.totals.totalTokens).max() ?? 0
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      HStack(alignment: .bottom, spacing: 2) {
        ForEach(days, id: \.date) { day in
          let share = maximum > 0 ? Double(day.totals.totalTokens) / Double(maximum) : 0
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(QuotaPalette.ink.opacity(day.totals.totalTokens > 0 ? 0.55 : 0.12))
            .frame(maxWidth: .infinity)
            .frame(height: max(2, 44 * share))
            .help("\(day.date) · \(UsageValueFormatter.tokensAndCost(day.totals.totalTokens, day.cost))")
        }
      }
      .frame(height: 44, alignment: .bottom)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Usage by day")
      .accessibilityValue(
        "\(days.count) days, most in a day \(UsageValueFormatter.accessibleCount(maximum)) tokens"
      )

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
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
    .padding(.vertical, QuotaDesign.Layout.groupContentInset)
  }

  /// The hours of the local clock this Mac works in, and the four stretches they fall into.
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
        columns: [GridItem(.flexible()), GridItem(.flexible())],
        alignment: .leading,
        spacing: QuotaDesign.Spacing.meta
      ) {
        ForEach(UsageDayPart.allCases, id: \.self) { part in
          let tokens = hours.filter { part.hours.contains($0.hour) }.reduce(0) { $0 + $1.totalTokens }
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
          .frame(minWidth: 52, alignment: .trailing)
        Text("Cost")
          .quotaMetaStyle()
          .frame(minWidth: 52, alignment: .trailing)
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
              .frame(minWidth: 52, alignment: .trailing)
            Text(cost)
              .quotaMonoListValueStyle()
              .lineLimit(1)
              .minimumScaleFactor(0.75)
              .frame(minWidth: 52, alignment: .trailing)
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
    _ model: PresentedUsageModel,
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

  private func tokenMetrics(_ totals: PresentedUsageTotals) -> some View {
    LazyVGrid(
      columns: [GridItem(.flexible()), GridItem(.flexible())],
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
    SettingsSection(
      title: "Sessions",
      trailing: {
        Text("\(sessions.active) active · \(sessions.today) today")
          .quotaMetaStyle()
          .accessibilityLabel("\(sessions.active) active, \(sessions.today) today")
      },
      content: {
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
          .padding(.vertical, QuotaDesign.Spacing.sm)
        }
      }
    )
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
    var parts = [UsageValueFormatter.agent(session.agent), session.projectKey, age, summary]
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

  private func presentedProviders(
    _ models: [PresentedUsageModel]
  ) -> [PresentedUsageProvider] {
    Dictionary(grouping: models, by: \.provider)
      .map { PresentedUsageProvider(provider: $0.key, models: $0.value) }
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

  private func sortedByTokens(_ models: [PresentedUsageModel]) -> [PresentedUsageModel] {
    models.sorted {
      $0.totals.totalTokens != $1.totals.totalTokens
        ? $0.totals.totalTokens > $1.totals.totalTokens
        : $0.model < $1.model
    }
  }

  private func sortedModels(_ models: [PresentedUsageModel]) -> [PresentedUsageModel] {
    models.sorted {
      UsageValueFormatter.precedes(
        cost: $0.cost, tokens: $0.totals.totalTokens, name: $0.model,
        before: $1.cost, tokens: $1.totals.totalTokens, name: $1.model
      )
    }
  }
}

private struct AccountUsagePageState: Equatable {
  let refreshWarning: String?
  let accountWarning: String?
  let statusWarning: String?
  let usage: PresentedUsage?
  let sessions: LocalUsageSessions?
  let isPreparing: Bool
  /// The range the period covers, which is what the title row reads.
  let title: String
  /// Whether this source can answer this period at all.
  let available: Bool
  let budget: UsageBudgetProgress?
}

private struct PresentedUsage: Equatable {
  let totals: PresentedUsageTotals
  let cost: UsageCostOutcome
  let cacheSaved: UsageCacheSaved
  let cacheHitBasisPoints: Int?
  /// Present for a period bounded by two local midnights, and absent for every retained day.
  let days: [LocalUsageDay]?
  let hoursOfDay: [LocalUsageHourOfDay]?
  let models: [PresentedUsageModel]
  /// This Mac's attribution, when the source is this Mac and grouping is on; the Account
  /// source has none.
  let projects: [LocalUsageProjectSummary]?
}

private struct PresentedUsageProvider: Identifiable {
  let provider: InferenceProvider?
  let models: [PresentedUsageModel]

  var id: String { provider?.rawValue ?? "unknown" }
}

private struct PresentedUsageTotals: Equatable {
  let totalTokens: Int
  let inputTokens: Int
  let outputTokens: Int
  let cacheReadInputTokens: Int
  let cacheWriteInputTokens: Int
  let reasoningTokens: Int
  let messages: Int

  init(_ totals: UsageSummaryTotals) {
    totalTokens = totals.totalTokens
    inputTokens = totals.inputTokens
    outputTokens = totals.outputTokens
    cacheReadInputTokens = totals.cacheReadInputTokens
    cacheWriteInputTokens = totals.cacheWriteInputTokens
    reasoningTokens = totals.reasoningTokens
    messages = totals.messages
  }

}

private struct PresentedUsageModel: Equatable {
  let provider: InferenceProvider?
  let agent: BillingAgent?
  let model: String
  let totals: PresentedUsageTotals
  let cost: UsageCostOutcome

  var id: String {
    "\(agent?.rawValue ?? "account"):\(provider?.rawValue ?? "unknown"):\(model)"
  }

  init(
    _ model: LocalUsageModelSummary,
    provider: InferenceProvider,
    agent: BillingAgent
  ) {
    self.provider = provider
    self.agent = agent
    self.model = model.model
    totals = PresentedUsageTotals(model.totals)
    cost = model.cost
  }

  init(_ model: LocalUsageModelSummary) {
    provider = nil
    agent = nil
    self.model = model.model
    totals = PresentedUsageTotals(model.totals)
    cost = model.cost
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
      BrandAssetIcon(
        assetName: assetName,
        size: size
      )
    } else {
      Image(systemName: "questionmark.square.dashed")
        .quotaFont(.secondary)
        .foregroundStyle(QuotaPalette.body)
        .frame(
          width: size,
          height: size
        )
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
  /// No owned Google mark yet, so Google takes the semantic symbol rather than a borrowed logo.
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
