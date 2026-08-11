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
        : "Continue with GitHub in Settings to view account devices."
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
  @State private var scope: UsageDisplayScope = .local

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        if effectiveScope == .account, let accountErrorMessage = model.accountErrorMessage {
          accountIssue(accountErrorMessage)
        }

        SettingsSection(title: "Source") {
          if model.accountSummary != nil {
            Picker("Usage source", selection: $scope) {
              ForEach(UsageDisplayScope.allCases) { value in
                Text(value.label).tag(value)
              }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("Usage source")
            .padding(QuotaDesign.Layout.groupContentInset)
          } else {
            usageValueRow(title: "Scope", systemImage: "laptopcomputer", value: "This Mac")
          }
        }

        if let usage = presentedUsage {
          SettingsSection(title: "Period") {
            usageValueRow(
              title: "Range",
              systemImage: "calendar",
              value: "\(usage.range.from) – \(usage.range.to)"
            )
          }

          SettingsSection(title: "Tokens") {
            VStack(alignment: .leading, spacing: 0) {
              usageValueRow(
                title: "Input",
                systemImage: "arrow.down.left",
                value: UsageValueFormatter.count(usage.totals.inputTokens)
              )
              usageValueRow(
                title: "Cached input",
                systemImage: "bolt.horizontal.circle",
                value: UsageValueFormatter.count(usage.totals.cachedInputTokens)
              )
              usageValueRow(
                title: "Output",
                systemImage: "arrow.up.right",
                value: UsageValueFormatter.count(usage.totals.outputTokens)
              )
              usageValueRow(
                title: "Reasoning",
                systemImage: "brain.head.profile",
                value: UsageValueFormatter.count(usage.totals.reasoningTokens)
              )
              usageValueRow(
                title: "Requests",
                systemImage: "number",
                value: UsageValueFormatter.count(usage.totals.requests)
              )
            }
          }

          SettingsSection(title: "Models") {
            let modelBreakdowns = usage.breakdowns
              .filter { $0.dimension == .model }
              .sorted {
                let lhsTokens = $0.totals.inputTokens + $0.totals.outputTokens
                let rhsTokens = $1.totals.inputTokens + $1.totals.outputTokens
                return lhsTokens == rhsTokens
                  ? $0.key.localizedStandardCompare($1.key) == .orderedAscending
                  : lhsTokens > rhsTokens
              }

            if modelBreakdowns.isEmpty {
              settingsEmptyCopy("No model usage is available for this period.")
            } else {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(modelBreakdowns.enumerated()), id: \.offset) { _, breakdown in
                  modelUsageRow(breakdown)
                }
              }
            }
          }

          SettingsSection(title: "Cost") {
            VStack(alignment: .leading, spacing: 0) {
              usageValueRow(
                title: "Estimated cost",
                systemImage: "dollarsign.circle",
                value: UsageValueFormatter.cost(usage.cost)
              )
              usageValueRow(
                title: "Basis",
                systemImage: "function",
                value: UsageValueFormatter.basis(usage.cost.basis)
              )
              if let revision = usage.cost.catalogRevision {
                usageValueRow(
                  title: "Pricing catalog",
                  systemImage: "tag",
                  value: revision
                )
              }
              if usage.cost.unpricedRows > 0 {
                usageValueRow(
                  title: "Unpriced rows",
                  systemImage: "exclamationmark.triangle",
                  value: UsageValueFormatter.count(usage.cost.unpricedRows)
                )
              }
            }
          }

          SettingsSection(title: "Coverage") {
            if usage.coverage.isEmpty {
              settingsEmptyCopy("No Usage coverage is available for this period.")
            } else {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(BillingAgent.allCasesForPresentation, id: \.rawValue) { agent in
                  let items = usage.coverage.filter { $0.agent == agent }
                  if !items.isEmpty {
                    usageValueRow(
                      title: UsageValueFormatter.agent(agent),
                      systemImage: "checkmark.shield",
                      value: UsageValueFormatter.coverage(items)
                    )
                  }
                }
              }
            }
          }
        } else {
          settingsEmptyCopy(
            effectiveScope == .account
              ? "Account Usage is unavailable. Local Usage remains available."
              : "Local Usage could not be read. Check agent log access and refresh."
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var effectiveScope: UsageDisplayScope {
    model.accountSummary == nil ? .local : scope
  }

  private var presentedUsage: PresentedUsage? {
    switch effectiveScope {
    case .local:
      guard let report = model.localUsage,
        report.status != .unavailable,
        let totals = report.totals,
        let cost = report.cost
      else { return nil }
      return PresentedUsage(
        range: report.range,
        totals: totals,
        cost: cost,
        coverage: report.coverage,
        breakdowns: report.breakdowns
      )
    case .account:
      guard let usage = model.accountSummary?.usage else { return nil }
      return PresentedUsage(
        range: usage.range,
        totals: usage.totals,
        cost: usage.cost,
        coverage: usage.coverage.map {
          UsageCoverage(
            agent: $0.agent,
            startAt: $0.startAt,
            endAt: $0.endAt,
            status: $0.status
          )
        },
        breakdowns: usage.breakdowns
      )
    }
  }

  private func usageValueRow(title: String, systemImage: String, value: String) -> some View {
    SettingsListRow(title: title, systemImage: systemImage) {
      Text(value)
        .quotaMonoListValueStyle()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }

  private func modelUsageRow(_ breakdown: UsageBreakdown) -> some View {
    let tokens = breakdown.totals.inputTokens + breakdown.totals.outputTokens
    let detail =
      "\(UsageValueFormatter.count(tokens)) tokens · "
      + "\(UsageValueFormatter.count(breakdown.totals.requests)) requests"
    return SettingsListRow(
      title: breakdown.key,
      subtitle: detail,
      systemImage: "cube",
      height: QuotaDesign.Layout.settingsListRowHeight
    ) {
      Text(UsageValueFormatter.cost(breakdown.cost))
        .quotaMonoListValueStyle()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(breakdown.key)
    .accessibilityValue("\(detail). \(UsageValueFormatter.cost(breakdown.cost))")
  }
}

private enum UsageDisplayScope: String, CaseIterable, Identifiable {
  case local
  case account

  var id: Self { self }
  var label: String { self == .local ? "This Mac" : "Account" }
}

private struct PresentedUsage {
  let range: UsageDateRange
  let totals: UsageTokenTotals
  let cost: UsageCostOutcome
  let coverage: [UsageCoverage]
  let breakdowns: [UsageBreakdown]
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

  static func cost(_ outcome: UsageCostOutcome) -> String {
    let amount = outcome.amountMicrousd.flatMap(usd) ?? "$0.00"
    return switch outcome.status {
    case .complete: "\(amount) estimated"
    case .partial: "≥ \(amount) partial"
    case .unavailable: "— unpriced"
    }
  }

  static func basis(_ basis: UsageCostBasis) -> String {
    switch basis {
    case .calculated: "Calculated"
    case .reported: "Reported"
    case .mixed: "Mixed"
    case .none: "None"
    }
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

  static func coverage(_ items: [UsageCoverage]) -> String {
    let complete = items.filter { $0.status == .complete }.count
    let partial = items.count - complete
    if partial == 0 { return "\(complete) complete" }
    if complete == 0 { return "\(partial) partial" }
    return "\(complete) complete · \(partial) partial"
  }

  private static func usd(_ microusd: String) -> String? {
    guard let decimal = Decimal(string: microusd, locale: Locale(identifier: "en_US_POSIX")) else {
      return nil
    }
    let dollars = decimal / 1_000_000
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = .current
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 6
    return formatter.string(from: NSDecimalNumber(decimal: dollars))
  }
}

extension BillingAgent {
  fileprivate static let allCasesForPresentation: [BillingAgent] = [
    .codex, .claudeCode, .grok, .opencode, .pi,
  ]
}
