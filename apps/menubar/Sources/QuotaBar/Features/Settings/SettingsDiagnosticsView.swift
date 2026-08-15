import AppKit
import QuotaPresentation
import SwiftUI

/// Pure labels and feedback timing for Diagnostics header actions.
enum DiagnosticsHeaderAction {
  static let recheckLabel = "Recheck diagnostics"
  static let checkingLabel = "Checking diagnostics"
  static let copyFeedbackDuration: Duration = .seconds(2)

  static func recheckAccessibilityLabel(isChecking: Bool) -> String {
    isChecking ? checkingLabel : recheckLabel
  }

  static func copyAccessibilityLabel(didCopy: Bool) -> String {
    didCopy ? "Diagnostics copied" : "Copy diagnostics"
  }
}

/// Turns the bounded wire report into concise, user-facing Diagnostics copy.
enum DiagnosticsPresentation {
  struct SurfaceSummary: Equatable {
    let title: String
    let detail: String
  }

  struct FindingSummary: Equatable {
    let title: String
    let solution: String
  }

  static func surfaceSummary(_ surface: LocalServiceDiagnosticSurface) -> SurfaceSummary {
    let metrics = surface.metrics
    switch surface.name {
    case "quota_overview":
      let items = metrics["items", default: 0]
      let local = metrics["this_device_sources", default: 0]
      let account = metrics["account_sources", default: 0]
      let detail = items == 0
        ? "No quota data yet"
        : "\(count(items, singular: "quota")) · \(local.formatted()) this Mac · \(account.formatted()) Account"
      return SurfaceSummary(title: "Quota Overview", detail: detail)
    case "usage_this_device":
      let records = metrics["records", default: 0]
      let partial = metrics["partial_hours", default: 0]
      let detail = records == 0
        ? "No local Usage records yet"
        : "\(count(records, singular: "record"))\(partial > 0 ? " · \(count(partial, singular: "partial hour"))" : "")"
      return SurfaceSummary(title: "This Mac Usage", detail: detail)
    case "usage_account":
      let enabled = metrics["enabled", default: 0] == 1
      let periods = metrics["periods", default: 0]
      return SurfaceSummary(
        title: "Account Usage",
        detail: enabled ? (periods > 0 ? "\(count(periods, singular: "period")) available" : "No Account Usage yet") : "Usage sync is off"
      )
    case "account":
      let signedIn = metrics["signed_in", default: 0] == 1
      let devices = metrics["devices", default: 0]
      let detail = if signedIn, devices > 0 {
        "Signed in · \(count(devices, singular: "device"))"
      } else if signedIn {
        "Signed in"
      } else {
        "Not signed in"
      }
      return SurfaceSummary(title: "Account", detail: detail)
    default:
      return SurfaceSummary(title: surface.name.capitalized, detail: dataLabel(surface.data))
    }
  }

  static func findingSummary(_ finding: LocalServiceDiagnosticFinding) -> FindingSummary {
    let subject = finding.subject?.split(separator: ":", maxSplits: 1).last.map(String.init)
    let label = subject.map { " (\($0.replacingOccurrences(of: "_", with: " ").capitalized))" } ?? ""
    let title: String = switch finding.code {
    case "auth_required", "authentication_required": "Sign-in needed\(label)"
    case "config_unreadable": "Provider settings can’t be read"
    case "permission_denied": "Usage access was denied\(label)"
    case "source_unreadable": "Usage source can’t be read\(label)"
    case "truncated_tail", "source_changed", "scan_cancelled": "Usage source is still changing\(label)"
    case "malformed_json", "unknown_record", "invalid_timestamp", "invalid_model", "invalid_usage": "Some Usage records are invalid\(label)"
    case "invalid_catalog": "Pricing data is invalid"
    case "client_upgrade_required": "QuotaBar needs an update"
    case "invalid_state": "Local state needs repair"
    case "unrepresentable_hour", "invalid_usage_batch", "sync_failed": "Usage upload failed"
    default: "\(componentTitle(finding.component)) needs attention\(label)"
    }
    return FindingSummary(
      title: title,
      solution: recoverySolution(finding.recovery, source: finding.source)
    )
  }

  static func findingAccessibilityLabel(
    _ finding: LocalServiceDiagnosticFinding,
    summary: FindingSummary
  ) -> String {
    "\(severityLabel(finding.severity)): \(summary.title), \(finding.count) occurrence"
      + "\(finding.count == 1 ? "" : "s"). \(summary.solution)"
  }

  static func prioritizedFindings(
    _ findings: [LocalServiceDiagnosticFinding]
  ) -> [LocalServiceDiagnosticFinding] {
    findings.enumerated().sorted { left, right in
      let leftPriority = severityPriority(left.element.severity)
      let rightPriority = severityPriority(right.element.severity)
      return leftPriority == rightPriority
        ? left.offset < right.offset
        : leftPriority < rightPriority
    }.map(\.element)
  }

  static func componentTitle(_ name: String) -> String {
    switch name {
    case "quota_collection": "Quota collection"
    case "usage_scan": "Usage scan"
    case "usage_upload": "Usage upload"
    case "pricing_catalog": "Pricing"
    case "provider_configuration": "Provider settings"
    case "account": "Account"
    default: name.capitalized
    }
  }

  static func operationLabel(_ operation: LocalServiceDiagnosticOperation) -> String {
    switch operation {
    case .healthy: "Working"
    case .degraded: "Needs attention"
    case .blocked: "Unavailable"
    }
  }

  static func dataLabel(_ data: LocalServiceDiagnosticDataState) -> String {
    switch data {
    case .current: "Current data"
    case .stale: "Saved data is stale"
    case .partial: "Some data is incomplete"
    case .empty: "No data yet"
    case .unknown: "Data has not been checked"
    }
  }

  private static func recoverySolution(
    _ recovery: LocalServiceDiagnosticRecovery,
    source: LocalServiceDiagnosticSource
  ) -> String {
    switch recovery {
    case .none: "No action is needed."
    case .automatic: "QuotaBar will retry this during the next refresh."
    case .retry: "Recheck in a moment. If this continues, copy the report and send Feedback."
    case .login where source == .account: "Reconnect Account in Settings, then recheck."
    case .login: "Sign in only if you want this Mac to collect this source; Account data remains usable."
    case .configureProvider: "Open Agents and repair the saved provider setup, then recheck."
    case .updateSource: "Update the app or CLI that produced this Usage data, then recheck."
    case .checkAccess: "Check that QuotaBar can access this agent’s Usage data, then recheck."
    case .upgrade: "Open Support, check for updates, then recheck."
    case .reinstall: "Reinstall QuotaBar to repair local state, then recheck."
    case .feedback: "Copy the report, then send Feedback from Support."
    }
  }

  private static func count(_ value: Int, singular: String) -> String {
    "\(value.formatted()) \(singular)\(value == 1 ? "" : "s")"
  }

  private static func severityPriority(_ severity: LocalServiceDiagnosticSeverity) -> Int {
    switch severity {
    case .error: 0
    case .warning: 1
    case .info: 2
    }
  }

  private static func severityLabel(_ severity: LocalServiceDiagnosticSeverity) -> String {
    switch severity {
    case .error: "Error"
    case .warning: "Warning"
    case .info: "Info"
    }
  }

}

/// Owns Diagnostics page state so MenuBarContentView can drive header actions.
enum DiagnosticsPageState: Equatable {
  case loading
  case error(String)
  case report(
    LocalServiceDiagnosticReport,
    isRechecking: Bool,
    refreshWarning: String?
  )
}

@MainActor
@Observable
final class DiagnosticsPageModel {
  private(set) var report: LocalServiceDiagnosticReport?
  private(set) var errorMessage: String?
  private(set) var isLoading = false
  private(set) var didCopy = false

  private var copyFeedbackTask: Task<Void, Never>?
  /// Bumped on entry reset so an abandoned in-flight check cannot publish stale results.
  private var loadGeneration = 0

  init(
    report: LocalServiceDiagnosticReport? = nil,
    errorMessage: String? = nil,
    isLoading: Bool = false
  ) {
    self.report = report
    self.errorMessage = errorMessage
    self.isLoading = isLoading
  }

  var pageState: DiagnosticsPageState {
    if let report {
      return .report(report, isRechecking: isLoading, refreshWarning: errorMessage)
    }
    if isLoading || errorMessage == nil { return .loading }
    return .error(errorMessage ?? "Could not collect diagnostics.")
  }

  var showsHeaderActions: Bool { report != nil }
  var canCopy: Bool { report != nil }
  var canRecheck: Bool { report != nil && !isLoading }

  func prepareForEntry() {
    loadGeneration += 1
    copyFeedbackTask?.cancel()
    copyFeedbackTask = nil
    report = nil
    errorMessage = nil
    isLoading = false
    didCopy = false
  }

  /// Runs a fresh `diagnose` check. Ignores overlapping calls while loading.
  func runCheck(diagnose: () async throws -> LocalServiceDiagnosticReport) async {
    guard !isLoading else { return }
    let generation = loadGeneration
    isLoading = true
    errorMessage = nil
    defer {
      if generation == loadGeneration {
        isLoading = false
      }
    }
    do {
      let next = try await diagnose()
      guard generation == loadGeneration else { return }
      report = next
      errorMessage = nil
    } catch {
      guard generation == loadGeneration else { return }
      errorMessage =
        (error as? LocalizedError)?.errorDescription ?? "Could not collect diagnostics."
    }
  }

  func copyTextReport() {
    guard let text = report?.textReport else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    didCopy = true
    copyFeedbackTask?.cancel()
    copyFeedbackTask = Task { @MainActor in
      try? await Task.sleep(for: DiagnosticsHeaderAction.copyFeedbackDuration)
      guard !Task.isCancelled else { return }
      didCopy = false
    }
  }
}

struct SettingsDiagnosticsView: View {
  let state: DiagnosticsPageState
  let onRetry: () -> Void
  @State private var recentActivityExpanded = false

  var body: some View {
    QuotaNavigationStableContent(state: state) { presentedState in
      content(presentedState)
    }
  }

  @ViewBuilder
  private func content(_ state: DiagnosticsPageState) -> some View {
    switch state {
    case .loading:
      QuotaPageStateView(loadingTitle: "Checking diagnostics…")
    case .error(let errorMessage):
      QuotaPageStateView(
        errorTitle: "Diagnostics Unavailable",
        message: errorMessage,
        retry: onRetry
      )
    case .report(let report, _, let refreshWarning):
      VStack(spacing: 0) {
        if let refreshWarning {
          QuotaInlineNotice(message: refreshWarning)
            .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
            .padding(.top, QuotaDesign.Spacing.sm)
        }

        ScrollView {
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
            statusView(report)
            findingsView(report)
            surfacesView(report)
            recentActivityView(report)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
          .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
        }
      }
    }
  }

  private func recentActivityView(_ report: LocalServiceDiagnosticReport) -> some View {
    SettingsSection(title: "Support") {
      DisclosureGroup(isExpanded: $recentActivityExpanded) {
        VStack(alignment: .leading, spacing: 0) {
          if report.recentActivity.attempts.isEmpty {
            Text("No recent activity")
              .quotaListSecondaryStyle()
              .padding(QuotaDesign.Spacing.sm)
          } else {
            ForEach(Array(report.recentActivity.attempts.suffix(20).reversed().enumerated()), id: \.offset) { _, attempt in
              SettingsListRow(
                title: attempt.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                subtitle: "\(attempt.trigger.rawValue.replacingOccurrences(of: "_", with: " ")) · \(CompactAgeFormat.string(since: attempt.startedAt, now: Date())) ago",
                systemImage: attempt.outcome == .running ? "arrow.triangle.2.circlepath" : "clock.arrow.circlepath"
              ) {
                Text(attempt.outcome.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                  .quotaListSecondaryStyle()
              }
              .accessibilityElement(children: .combine)
            }
          }
          if report.recentActivity.historyTruncated {
            Text("Older activity was trimmed by the bounded support history.")
              .quotaMetaStyle()
              .padding(QuotaDesign.Spacing.sm)
          }
        }
      } label: {
        Text("Recent Activity")
          .quotaSettingsLabelStyle()
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .padding(.vertical, QuotaDesign.Spacing.sm)
      .accessibilityHint("Shows structured local operations included in copied diagnostics.")
    }
  }

  private func statusView(_ report: LocalServiceDiagnosticReport) -> some View {
    let checked = LastCheckedLabel.checkedStatusString(from: report.refresh.asOf)
    let presentation = reportStatusPresentation(report.summary)
    return HStack(spacing: QuotaDesign.Spacing.sm) {
      Image(systemName: presentation.symbol)
        .foregroundStyle(operationColor(presentation.tone))
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        Text(presentation.label)
          .quotaFont(.rowTitle)
        Text(checked)
          .quotaMetaStyle()
        if report.refresh.phase == .running {
          Text("Refresh still running · showing the last completed check")
            .quotaMetaStyle()
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Diagnostics status: \(presentation.label). \(checked)")
  }

  private func surfacesView(_ report: LocalServiceDiagnosticReport) -> some View {
    SettingsSection(title: "Data") {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(report.surfaces, id: \.name) { surface in
          let summary = DiagnosticsPresentation.surfaceSummary(surface)
          SettingsListRow(
            title: summary.title,
            subtitle: summary.detail,
            systemImage: symbol(for: surface.name)
          ) {
            Image(systemName: operationSymbol(surface.operation, data: surface.data))
              .quotaFont(.secondary)
              .foregroundStyle(operationColor(surface.operation, data: surface.data))
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(summary.title), \(DiagnosticsPresentation.operationLabel(surface.operation)), \(DiagnosticsPresentation.dataLabel(surface.data)). \(summary.detail)"
          )
        }
      }
    }
  }

  @ViewBuilder
  private func findingsView(_ report: LocalServiceDiagnosticReport) -> some View {
    if !report.findings.isEmpty {
      SettingsSection(title: "Findings") {
        let findings = DiagnosticsPresentation.prioritizedFindings(report.findings)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
            let summary = DiagnosticsPresentation.findingSummary(finding)
            HStack(alignment: .top, spacing: QuotaDesign.Spacing.sm) {
              Image(systemName: findingSymbol(finding.severity))
                .quotaFont(.secondary)
                .foregroundStyle(findingColor(finding.severity))
                .frame(
                  width: QuotaDesign.Layout.settingsIconColumnWidth,
                  height: QuotaDesign.Layout.settingsIconColumnWidth
                )

              VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.xs) {
                  Text(summary.title)
                    .quotaSettingsLabelStyle()
                    .fixedSize(horizontal: false, vertical: true)
                  Spacer(minLength: QuotaDesign.Spacing.xs)
                  if finding.count > 1 {
                    Text("×\(finding.count.formatted())")
                      .quotaMonoListValueStyle()
                  }
                }
                Text(summary.solution)
                  .quotaListSecondaryStyle()
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
            .padding(.vertical, QuotaDesign.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(DiagnosticsPresentation.findingAccessibilityLabel(finding, summary: summary))
          }
        }
      }
    }
  }

  private func symbol(for name: String) -> String {
    switch name {
    case "quota_overview": "gauge.with.dots.needle.67percent"
    case "usage_this_device": "laptopcomputer"
    case "usage_account": "cloud"
    case "account": "person.crop.circle"
    default: "questionmark.circle"
    }
  }

  private func operationSymbol(
    _ operation: LocalServiceDiagnosticOperation,
    data: LocalServiceDiagnosticDataState
  ) -> String {
    if data == .partial || data == .stale { return "exclamationmark.triangle.fill" }
    return switch operation {
    case .healthy: "checkmark.circle.fill"
    case .degraded: "exclamationmark.triangle.fill"
    case .blocked: "xmark.octagon.fill"
    }
  }

  private func operationColor(
    _ operation: LocalServiceDiagnosticOperation,
    data: LocalServiceDiagnosticDataState = .current
  ) -> Color {
    if data == .partial || data == .stale { return QuotaPalette.warning }
    return switch operation {
    case .healthy: QuotaPalette.accent
    case .degraded: QuotaPalette.warning
    case .blocked: QuotaPalette.critical
    }
  }

  private func findingSymbol(_ severity: LocalServiceDiagnosticSeverity) -> String {
    switch severity {
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }

  private func findingColor(_ severity: LocalServiceDiagnosticSeverity) -> Color {
    switch severity {
    case .info: QuotaPalette.body
    case .warning: QuotaPalette.warning
    case .error: QuotaPalette.critical
    }
  }

  private func reportStatusPresentation(
    _ summary: LocalServiceDiagnosticSummary
  ) -> (label: String, symbol: String, tone: LocalServiceDiagnosticOperation) {
    if summary.operation == .blocked {
      return ("Action needed", "xmark.octagon.fill", .blocked)
    }
    if summary.operation == .degraded || summary.data == .partial || summary.data == .stale
      || summary.attention == .required
    {
      return ("Some checks need attention", "exclamationmark.triangle.fill", .degraded)
    }
    return ("All systems working", "checkmark.circle.fill", .healthy)
  }
}
