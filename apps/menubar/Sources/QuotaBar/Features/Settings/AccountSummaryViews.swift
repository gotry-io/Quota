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

/// How recently a device spoke, from the two things Relay actually witnessed: when the device
/// last called, and when the newest reading it sent was taken. A device that is asleep or closed
/// is quiet, not broken, so nothing here claims a device is unhealthy.
enum AccountDeviceActivity: String, Equatable, Sendable {
  case active = "Active"
  case idle = "Idle"
  case notReporting = "Not reporting"

  static func status(for device: AccountDevice, now: Date) -> Self {
    guard let newest = [device.lastSeenAt, device.lastObservedAt].compactMap({ $0 }).max() else {
      return .notReporting
    }
    let age = now.timeIntervalSince(newest)
    if age < 30 * 60 { return .active }
    if age < 24 * 60 * 60 { return .idle }
    return .notReporting
  }
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
                SettingsListRow(
                  title: device.displayName,
                  subtitle: deviceSubtitle(device, now: now),
                  systemImage: device.platform == .macos ? "desktopcomputer" : "terminal",
                  height: QuotaDesign.Layout.settingsListRowHeight
                ) {
                  Text(AccountDeviceActivity.status(for: device, now: now).rawValue)
                    .quotaListSecondaryStyle()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(device.displayName)
                .accessibilityValue(
                  AccountDeviceActivity.status(for: device, now: now).rawValue
                    + ". " + deviceSubtitle(device, now: now)
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

  private func deviceSubtitle(_ device: AccountDevice, now: Date) -> String {
    let platform =
      switch device.platform {
      case .macos: "macOS"
      case .linux: "Linux"
      case .windows: "Windows"
      case .unknown: "Unknown"
      }
    var parts = [platform]
    if let lastSeenAt = device.lastSeenAt {
      parts.append("Last seen \(CompactAgeFormat.string(since: lastSeenAt, now: now)) ago")
    } else {
      parts.append("Never reported")
    }
    if let lastObservedAt = device.lastObservedAt {
      parts.append("Last reading \(CompactAgeFormat.string(since: lastObservedAt, now: now)) ago")
    }
    return parts.joined(separator: " · ")
  }

}

struct AccountUsageView: View {
  @Bindable var model: MenuBarViewModel
  @Binding var source: UsageSource
  @Binding var period: UsagePeriod

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
      isPreparing: model.isPreparingUsage(source: presentedSource)
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

        if let warning = state.statusWarning {
          QuotaInlineNotice(message: warning)
        }

        if let usage = state.usage {
          SettingsSection(title: "Summary") {
            usageSummary(usage)
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
                ForEach(providers) { provider in
                  providerUsage(provider)
                }
              }
              .padding(.vertical, QuotaDesign.Spacing.sm)
            }
          }

        } else {
          SettingsSection(title: "Summary") {
            QuotaSectionStateView(
              presentation: state.isPreparing
                ? .loading(title: "Preparing Usage…")
                : .empty(message: "No Usage is available for this period.")
            )
          }
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

  private var usagePeriodTabs: some View {
    HStack(spacing: 0) {
      ForEach(UsagePeriod.allCases) { value in
        Button { period = value } label: {
          Text(value.label)
            .quotaFont(.listSecondary)
            .foregroundStyle(value == period ? QuotaPalette.ink : QuotaPalette.body)
            .frame(
              maxWidth: .infinity,
              minHeight: QuotaDesign.Layout.minimumInteractiveDimension
            )
            .background {
              if value == period {
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
        .accessibilityLabel(value.label)
        .accessibilityAddTraits(value == period ? .isSelected : [])
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

  private func usageStatusWarning(source: UsageSource) -> String? {
    guard let detail = model.usageDetail(source: source, period: period) else { return nil }
    guard detail.incomplete || detail.detailsTruncated else { return nil }
    return source == .local
      ? "Some local Usage may be incomplete."
      : "Some account Usage may be incomplete."
  }

  private func presentedUsage(source: UsageSource) -> PresentedUsage? {
    guard let detail = model.usageDetail(source: source, period: period) else { return nil }
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
      models: localModels
    )
  }

  private func usageSummary(_ usage: PresentedUsage) -> some View {
    let tokens = UsageValueFormatter.count(usage.totals.totalTokens)
    let cost = UsageValueFormatter.compactCost(usage.cost)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.md) {
        summaryMetric("Tokens", tokens)
        summaryMetric("Cost", cost)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
      .padding(.top, QuotaDesign.Layout.groupContentInset)
      .padding(.bottom, QuotaDesign.Spacing.sm)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Usage summary")
      .accessibilityValue("\(tokens) tokens, \(cost)")

      Divider()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)

      tokenMetrics(usage.totals)
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
        .padding(.vertical, QuotaDesign.Layout.groupContentInset)
    }
  }

  private func summaryMetric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .quotaMetaStyle()
      Text(value)
        .quotaFont(.rowTitle)
        .monospacedDigit()
        .foregroundStyle(QuotaPalette.ink)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func providerUsage(_ provider: PresentedUsageProvider) -> some View {
    let models = Array(sortedModels(provider.models).prefix(5))
    let duplicateNames = Set(
      Dictionary(grouping: provider.models, by: \.model)
        .filter { $0.value.count > 1 }
        .keys
    )
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
      providerHeading(provider.provider)
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        ForEach(models, id: \.id) { model in
          let title =
            if duplicateNames.contains(model.model), let agent = model.agent {
              "\(model.model) · \(UsageValueFormatter.agent(agent))"
          } else {
            model.model
          }
          modelUsageRow(model, title: title)
        }
      }
    }
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

  private func modelUsageRow(
    _ model: PresentedUsageModel,
    title: String
  ) -> some View {
    let summary = UsageValueFormatter.tokensAndCost(model.totals.totalTokens, model.cost)
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

  private func sortedModels(_ models: [PresentedUsageModel]) -> [PresentedUsageModel] {
    models.sorted {
      UsageValueFormatter.precedes(
        cost: $0.cost, tokens: $0.totals.totalTokens, name: $0.model,
        before: $1.cost, tokens: $1.totals.totalTokens, name: $1.model
      )
    }
  }
}

extension UsagePeriod {
  fileprivate var label: String {
    switch self {
    case .today: "Today"
    case .last7Days: "7 Days"
    case .last30Days: "30 Days"
    case .all: "All"
    }
  }
}

private struct AccountUsagePageState: Equatable {
  let refreshWarning: String?
  let accountWarning: String?
  let statusWarning: String?
  let usage: PresentedUsage?
  let isPreparing: Bool
}

private struct PresentedUsage: Equatable {
  let totals: PresentedUsageTotals
  let cost: UsageCostOutcome
  let models: [PresentedUsageModel]
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

extension InferenceProvider {
  fileprivate var brandAssetName: String? {
    switch self {
    case .openai: "openai"
    case .azureOpenAI: "azureai"
    case .anthropic: "claude"
    case .awsBedrock: "bedrock"
    case .googleVertex: "vertexai"
    case .openrouter: "openrouter"
    case .xai: "grok"
    case .moonshot: "kimi"
    case .deepseek: "deepseek"
    case .unknown: nil
    }
  }

}
