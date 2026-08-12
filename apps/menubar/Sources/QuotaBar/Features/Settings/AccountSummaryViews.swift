import Foundation
import SwiftUI

struct AccountDevicesView: View {
  @Bindable var model: MenuBarViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        if let accountErrorMessage = model.accountErrorMessage {
          accountIssue(accountErrorMessage)
        }

        if let summary = model.accountSummary {
          SettingsSection(title: "Account Devices") {
            if summary.devices.isEmpty {
              settingsEmptyCopy("No devices have signed in yet.")
            } else {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(summary.devices) { device in
                  SettingsListRow(
                    title: device.displayName,
                    subtitle: deviceSubtitle(device),
                    systemImage: device.platform == .macos ? "desktopcomputer" : "terminal",
                    height: QuotaDesign.Layout.settingsListRowHeight
                  ) {
                    Text(statusLabel(device.status))
                      .quotaListSecondaryStyle()
                  }
                  .accessibilityElement(children: .ignore)
                  .accessibilityLabel(device.displayName)
                  .accessibilityValue("\(statusLabel(device.status)). \(deviceSubtitle(device))")
                }
              }
            }
          }
        } else {
          accountUnavailableCopy
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var accountUnavailableCopy: some View {
    settingsEmptyCopy(
      model.accountState == .logoutPending
        ? "Logout is pending. QuotaBar will finish when this Mac is online."
        : "Sign in from Settings to view account devices."
    )
  }

  private func deviceSubtitle(_ device: AccountDevice) -> String {
    let platform =
      switch device.platform {
      case .macos: "macOS"
      case .linux: "Linux"
      case .windows: "Windows"
      }
    guard let activity = device.lastSeenAt ?? device.signedOutAt else { return platform }
    return "\(platform) · Seen \(CompactAgeFormatter.string(since: activity, now: Date())) ago"
  }

  private func statusLabel(_ status: AccountDeviceStatus) -> String {
    switch status {
    case .active: "Active"
    case .offline: "Offline"
    case .signedOut: "Signed out"
    }
  }
}

struct AccountUsageView: View {
  @Bindable var model: MenuBarViewModel
  @Binding var source: UsageSource
  @Binding var period: UsagePeriod

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        if effectiveSource == .account, let accountErrorMessage = model.accountErrorMessage {
          accountIssue(accountErrorMessage)
        }

        usagePeriodTabs

        if let warning = usageStatusWarning {
          accountIssue(warning)
        }

        if let usage = presentedUsage {
          SettingsSection(title: "Summary") {
            usageSummary(usage)
          }

          SettingsSection(title: "Models") {
            let providers = presentedProviders(usage.models)
            if providers.isEmpty {
              settingsEmptyCopy("No model usage is available for this period.")
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
          settingsEmptyCopy("No Usage is available for this period.")
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var effectiveSource: UsageSource {
    !model.usageUploadEnabled || model.accountSummary == nil ? .local : source
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

  private var usageStatusWarning: String? {
    guard let detail = model.usageDetail(source: effectiveSource, period: period) else { return nil }
    guard detail.incomplete || detail.detailsTruncated else { return nil }
    return effectiveSource == .local
      ? "Some local Usage may be incomplete."
      : "Some account Usage may be incomplete."
  }

  private var presentedUsage: PresentedUsage? {
    guard let detail = model.usageDetail(source: effectiveSource, period: period) else { return nil }
    let usage = detail.usage
    let localModels = usage.clients.flatMap { client in
      client.providers.flatMap { provider in
        provider.models.map {
          PresentedUsageModel($0, provider: provider.provider, client: client.client)
        }
      }
    }
    return PresentedUsage(
      totals: PresentedUsageTotals(usage.totals),
      cost: usage.cost,
      models: localModels.isEmpty
        ? detail.fallbackModels.map(PresentedUsageModel.init)
        : localModels
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
            if duplicateNames.contains(model.model), let client = model.client {
              "\(model.model) · \(UsageValueFormatter.agent(client))"
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

private struct PresentedUsage {
  let totals: PresentedUsageTotals
  let cost: UsageCostOutcome
  let models: [PresentedUsageModel]
}

private struct PresentedUsageProvider: Identifiable {
  let provider: InferenceProvider?
  let models: [PresentedUsageModel]

  var id: String { provider?.rawValue ?? "unknown" }
}

private struct PresentedUsageTotals {
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

  init(_ totals: UsageTokenTotals) {
    totalTokens = totals.inputTokens + totals.outputTokens
    inputTokens = totals.inputTokens
    outputTokens = totals.outputTokens
    cacheReadInputTokens = totals.cacheReadTokens
    cacheWriteInputTokens =
      totals.cacheWrite5mTokens + totals.cacheWrite1hTokens + totals.cacheWriteInferredTokens
    reasoningTokens = totals.reasoningTokens
    messages = totals.requests
  }
}

private struct PresentedUsageModel {
  let provider: InferenceProvider?
  let client: BillingAgent?
  let model: String
  let totals: PresentedUsageTotals
  let cost: UsageCostOutcome

  var id: String {
    "\(client?.rawValue ?? "account"):\(provider?.rawValue ?? "unknown"):\(model)"
  }

  init(
    _ model: LocalUsageModelSummary,
    provider: InferenceProvider,
    client: BillingAgent
  ) {
    self.provider = provider
    self.client = client
    self.model = model.model
    totals = PresentedUsageTotals(model.totals)
    cost = model.cost
  }

  init(_ model: LocalUsageModelSummary) {
    provider = nil
    client = nil
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
    case .unknown: nil
    }
  }

}

@ViewBuilder
@MainActor
private func accountIssue(_ message: String) -> some View {
  Label(message, systemImage: "exclamationmark.circle")
    .quotaSecondaryStyle()
    .fixedSize(horizontal: false, vertical: true)
}

@ViewBuilder
@MainActor
private func settingsEmptyCopy(_ message: String) -> some View {
  Text(message)
    .quotaSecondaryStyle()
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Layout.settingsRowVerticalPadding)
    .frame(
      maxWidth: .infinity, minHeight: QuotaDesign.Layout.settingsRowHeight, alignment: .leading)
}

enum UsageValueFormatter {
  static func count(_ value: Int) -> String {
    value.formatted(
      .number
        .notation(.compactName)
        .precision(.significantDigits(1...3))
    )
    .replacingOccurrences(of: "K", with: "k")
  }

  static func accessibleCount(_ value: Int) -> String {
    value.formatted(.number)
  }

  static func compactCost(_ outcome: UsageCostOutcome) -> String {
    let amount = outcome.amountMicrousd.flatMap { usd($0, maximumFractionDigits: 2) } ?? "$0.00"
    return switch outcome.status {
    case .complete: amount
    case .partial: "≥ \(amount)"
    case .unavailable: "— unpriced"
    }
  }

  static func tokensAndCost(_ tokens: Int, _ cost: UsageCostOutcome) -> String {
    let tokens = count(tokens)
    guard cost.status != .unavailable, cost.amountMicrousd != nil else { return tokens }
    return "\(tokens) · \(compactCost(cost))"
  }

  static func precedes(
    cost leftCost: UsageCostOutcome,
    tokens leftTokens: Int,
    name leftName: String,
    before rightCost: UsageCostOutcome,
    tokens rightTokens: Int,
    name rightName: String
  ) -> Bool {
    let left = normalizedMicrousd(leftCost.amountMicrousd)
    let right = normalizedMicrousd(rightCost.amountMicrousd)
    if (left != nil) != (right != nil) { return left != nil }
    if let left, let right, left != right {
      return left.count == right.count ? left > right : left.count > right.count
    }
    if leftTokens != rightTokens { return leftTokens > rightTokens }
    return leftName.localizedStandardCompare(rightName) == .orderedAscending
  }

  static func agent(_ agent: BillingAgent) -> String {
    switch agent {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .grok: "Grok"
    case .opencode: "OpenCode"
    case .pi: "Pi"
    }
  }

  private static func usd(_ microusd: String, maximumFractionDigits: Int) -> String? {
    guard let decimal = Decimal(string: microusd, locale: Locale(identifier: "en_US_POSIX")) else {
      return nil
    }
    let dollars = decimal / 1_000_000
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = .current
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = maximumFractionDigits
    return formatter.string(from: NSDecimalNumber(decimal: dollars))
  }

  private static func normalizedMicrousd(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.drop(while: { $0 == "0" })
    return normalized.isEmpty ? "0" : String(normalized)
  }
}
