import AppKit
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
  struct ComponentSummary: Equatable {
    let title: String
    let detail: String
  }

  struct IssueSummary: Equatable {
    let title: String
    let solution: String
  }

  static func componentSummary(
    _ component: LocalServiceDiagnosticComponent
  ) -> ComponentSummary {
    let metrics = component.metrics
    switch component.name {
    case "providers":
      let configured = metrics["configured", default: 0]
      let discovered = metrics["discovered", default: 0]
      let detail = if configured == 0, discovered == 0 {
        "No providers available"
      } else if configured > 0, discovered > 0 {
        "\(count(discovered, singular: "provider")) available · \(count(configured, singular: "setup")) saved"
      } else if discovered > 0 {
        "\(count(discovered, singular: "provider")) available"
      } else {
        "\(count(configured, singular: "provider setup")) saved"
      }
      return ComponentSummary(title: "Providers", detail: detail)

    case "quota":
      let results = metrics["results", default: 0]
      let success = metrics["success", default: 0]
      let detail = if results == 0 {
        "No provider checks yet"
      } else if results == success {
        "All \(count(results, singular: "provider check")) passed"
      } else {
        "\(success.formatted()) of \(count(results, singular: "provider check")) passed"
      }
      return ComponentSummary(title: "Quota", detail: detail)

    case "usage":
      let records = metrics["records", default: 0]
      let files = metrics["files", default: 0]
      let detail = if records == 0 {
        "No Usage records yet"
      } else if files > 0 {
        "\(count(records, singular: "record")) from \(count(files, singular: "file"))"
      } else {
        count(records, singular: "Usage record")
      }
      return ComponentSummary(title: "Usage", detail: detail)

    case "pricing":
      let entries = metrics["entries", default: 0]
      let isPresent = metrics["catalog_present", default: 0] == 1
      let isValid = metrics["catalog_valid", default: 0] == 1
      let detail = if entries > 0 {
        "\(count(entries, singular: "model price")) available"
      } else if isPresent, isValid {
        "Pricing data is available"
      } else if isPresent {
        "Pricing data needs attention"
      } else {
        "No pricing data yet"
      }
      return ComponentSummary(title: "Pricing", detail: detail)

    case "account":
      let signedIn = metrics["signed_in", default: 0] == 1
      let logoutPending = metrics["session_logout_pending", default: 0] == 1
      let devices = metrics["devices", default: 0]
      let detail = if logoutPending {
        "Sign-out is waiting to finish"
      } else if signedIn, devices > 0 {
        "Signed in · \(count(devices, singular: "device"))"
      } else if signedIn {
        "Signed in"
      } else {
        "Not signed in"
      }
      return ComponentSummary(title: "Account", detail: detail)

    case "sync":
      let isEnabled = metrics["usage_upload_enabled", default: 0] == 1
      let pending = metrics["uploadable_dirty_ranges", default: 0]
        + metrics["outbox", default: 0]
      let failed = metrics["last_upload_failed", default: 0]
        + metrics["last_upload_degraded", default: 0]
        + metrics["last_upload_blocked", default: 0]
      let lastSucceeded = metrics["last_upload_success", default: 0] == 1
      let detail = if !isEnabled {
        "Usage sync is off"
      } else if pending > 0 {
        "\(count(pending, singular: "upload")) pending"
      } else if failed > 0 {
        "Last sync did not finish"
      } else if lastSucceeded {
        "Up to date"
      } else {
        "Waiting for the first sync"
      }
      return ComponentSummary(title: "Sync", detail: detail)

    default:
      return ComponentSummary(title: component.name.capitalized, detail: "See Issues for details")
    }
  }

  static func issueSummary(
    _ issue: LocalServiceDiagnosticIssue,
    component: LocalServiceDiagnosticComponent?
  ) -> IssueSummary {
    let hasCachedAccountData = hasCachedAccountData(issue: issue, component: component)
    return IssueSummary(
      title: issueTitle(issue, hasCachedAccountData: hasCachedAccountData),
      solution: recoverySolution(issue, hasCachedAccountData: hasCachedAccountData)
    )
  }

  static func issueAccessibilityLabel(
    _ issue: LocalServiceDiagnosticIssue,
    summary: IssueSummary
  ) -> String {
    "\(severityLabel(issue.severity)): \(summary.title), \(issue.count) occurrence"
      + "\(issue.count == 1 ? "" : "s"). \(summary.solution)"
  }

  static func prioritizedIssues(
    _ issues: [LocalServiceDiagnosticIssue]
  ) -> [LocalServiceDiagnosticIssue] {
    issues.enumerated().sorted { left, right in
      let leftPriority = severityPriority(left.element.severity)
      let rightPriority = severityPriority(right.element.severity)
      return leftPriority == rightPriority
        ? left.offset < right.offset
        : leftPriority < rightPriority
    }.map(\.element)
  }

  static func componentTitle(_ name: String) -> String {
    switch name {
    case "providers": "Providers"
    case "quota": "Quota"
    case "usage": "Usage"
    case "pricing": "Pricing"
    case "account": "Account"
    case "sync": "Sync"
    default: name.capitalized
    }
  }

  static func statusLabel(_ status: LocalServiceDiagnosticComponentStatus) -> String {
    switch status {
    case .ready: "Working"
    case .degraded: "Needs attention"
    case .blocked: "Unavailable"
    }
  }

  private static func issueTitle(
    _ issue: LocalServiceDiagnosticIssue,
    hasCachedAccountData: Bool
  ) -> String {
    let component = componentTitle(issue.component)
    return switch issue.code {
    case "network_error":
      issue.component == "account"
        ? (hasCachedAccountData ? "Account data couldn’t be updated" : "Account is unavailable")
        : "\(component) update failed"
    case "authentication_required", "auth_required": "\(component) needs sign-in"
    case "device_deleted": "This device was removed"
    case "stale_generation": "The account session expired"
    case "config_unreadable": "Provider settings can’t be read"
    case "not_configured": "No providers configured"
    case "client_upgrade_required": "QuotaBar needs an update"
    case "unsupported_operation": "\(component) operation isn’t supported"
    case "pending_upload": "Usage is waiting to sync"
    case "state_unavailable": "\(component) data can’t be read"
    case "invalid_catalog": "Pricing data is invalid"
    case "invalid_model_catalog": "Model data is invalid"
    case "unavailable": "\(component) is unavailable"
    case "provider_error": "A provider check failed"
    case "invalid_response": "\(component) returned invalid data"
    case "scan_blocked": "Usage scan couldn’t finish"
    case "scan_partial", "partial_sources": "Some Usage data is incomplete"
    case "permission_denied": "Usage data access was denied"
    case "source_unreadable": "Usage data can’t be read"
    case "source_changed": "Usage data changed during the scan"
    case "scan_cancelled": "Usage scan was interrupted"
    case "discovery_limit": "Too many Usage files were found"
    case "record_limit": "A Usage file is too large"
    case "line_too_large": "A Usage record is too large"
    case "truncated_tail": "A Usage file is incomplete"
    case "malformed_json", "unknown_record", "invalid_timestamp", "invalid_model", "invalid_usage":
      "Some Usage records couldn’t be read"
    case "unrepresentable_hour", "invalid_usage_batch", "sync_failed": "Usage couldn’t sync"
    case "busy": "\(component) is busy"
    case "cancelled": "\(component) check was cancelled"
    default: "\(component) needs attention"
    }
  }

  private static func recoverySolution(
    _ issue: LocalServiceDiagnosticIssue,
    hasCachedAccountData: Bool
  ) -> String {
    let recovery = switch issue.message {
    case "recovery_retry": Recovery.retry
    case "recovery_login": Recovery.login
    case "recovery_configure_provider": Recovery.configureProvider
    case "recovery_upgrade": Recovery.upgrade
    case "recovery_reinstall": Recovery.reinstall
    case "recovery_none": Recovery.feedback
    default: recovery(for: issue.code)
    }

    switch recovery {
    case .retry:
      if issue.code == "network_error", issue.component == "account" {
        let availability = hasCachedAccountData
          ? "Your saved account data is still available. "
          : "Account data is currently unavailable. "
        return availability
          + "Refresh QuotaBar using the control at the bottom, then recheck in a moment. If this "
          + "keeps happening, copy the report and send Feedback."
      }
      return "Refresh QuotaBar using the control at the bottom, then recheck. If this continues, "
        + "copy the report and send Feedback."
    case .login:
      if issue.component == "quota" || issue.component == "providers" {
        return "Open Agents in Settings, sign in to the affected provider, then recheck."
      }
      return "Open Account in Settings, sign in again, then recheck."
    case .configureProvider:
      return "Open Agents in Settings, check the provider sign-in or API key, then recheck."
    case .upgrade:
      return "Open Support in Settings, check for updates, then recheck."
    case .reinstall:
      return "Reinstall QuotaBar, then recheck."
    case .feedback:
      return "Copy the report, then send Feedback from Support."
    case .dataAccess:
      return "Check that QuotaBar can access your agent’s Usage data, then refresh and recheck. "
        + "If this continues, copy the report and send Feedback."
    case .updateUsageSource:
      return "Update the app or CLI that produced this Usage data, refresh QuotaBar, then recheck. "
        + "If this continues, copy the report and send Feedback."
    }
  }

  private static func recovery(for code: String) -> Recovery {
    switch code {
    case "authentication_required", "auth_required", "device_deleted", "stale_generation":
      .login
    case "config_unreadable":
      .configureProvider
    case "client_upgrade_required":
      .upgrade
    case "permission_denied", "source_unreadable":
      .dataAccess
    case "discovery_limit", "record_limit", "line_too_large", "truncated_tail",
      "malformed_json", "unknown_record", "invalid_timestamp", "invalid_model", "invalid_usage":
      .updateUsageSource
    case "network_error", "unavailable", "provider_error", "busy", "cancelled",
      "pending_upload", "scan_blocked", "scan_partial", "partial_sources", "source_changed",
      "scan_cancelled":
      .retry
    default:
      .feedback
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

  private static func hasCachedAccountData(
    issue: LocalServiceDiagnosticIssue,
    component: LocalServiceDiagnosticComponent?
  ) -> Bool {
    guard issue.component == "account", issue.severity == .warning,
          let component, component.name == "account", component.status == .degraded
    else { return false }
    return component.metrics["signed_in", default: 0] == 1
      || component.metrics["devices", default: 0] > 0
      || component.metrics["observations", default: 0] > 0
  }

  private enum Recovery {
    case retry
    case login
    case configureProvider
    case upgrade
    case reinstall
    case feedback
    case dataAccess
    case updateUsageSource
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
            issuesView(report)
            componentsView(report)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
          .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
        }
      }
    }
  }

  private func statusView(_ report: LocalServiceDiagnosticReport) -> some View {
    let checked = LastCheckedLabel.checkedStatusString(from: report.generatedAt)
    let presentation = reportStatusPresentation(report.status)
    return HStack(spacing: QuotaDesign.Spacing.sm) {
      Image(systemName: presentation.symbol)
        .foregroundStyle(statusColor(presentation.tone))
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        Text(presentation.label)
          .quotaFont(.rowTitle)
        Text(checked)
          .quotaMetaStyle()
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Diagnostics status: \(presentation.label). \(checked)")
  }

  private func componentsView(_ report: LocalServiceDiagnosticReport) -> some View {
    SettingsSection(title: "Components") {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(report.components, id: \.name) { component in
          let summary = DiagnosticsPresentation.componentSummary(component)
          SettingsListRow(
            title: summary.title,
            subtitle: summary.detail,
            systemImage: symbol(for: component.name)
          ) {
            Image(systemName: statusSymbol(component.status))
              .quotaFont(.secondary)
              .foregroundStyle(statusColor(component.status))
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(summary.title), \(DiagnosticsPresentation.statusLabel(component.status)). \(summary.detail)"
          )
        }
      }
    }
  }

  @ViewBuilder
  private func issuesView(_ report: LocalServiceDiagnosticReport) -> some View {
    if !report.issues.isEmpty {
      SettingsSection(title: "Issues") {
        let issues = DiagnosticsPresentation.prioritizedIssues(report.issues)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            let component = report.components.first { $0.name == issue.component }
            let summary = DiagnosticsPresentation.issueSummary(issue, component: component)
            HStack(alignment: .top, spacing: QuotaDesign.Spacing.sm) {
              Image(systemName: issueSymbol(issue.severity))
                .quotaFont(.secondary)
                .foregroundStyle(issueColor(issue.severity))
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
                  if issue.count > 1 {
                    Text("×\(issue.count.formatted())")
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
            .accessibilityLabel(DiagnosticsPresentation.issueAccessibilityLabel(issue, summary: summary))
          }
        }
      }
    }
  }

  private func symbol(for name: String) -> String {
    switch name {
    case "providers": "square.grid.2x2"
    case "quota": "gauge.with.dots.needle.67percent"
    case "usage": "chart.bar.xaxis"
    case "pricing": "tag"
    case "account": "person.crop.circle"
    case "sync": "arrow.triangle.2.circlepath"
    default: "questionmark.circle"
    }
  }

  private func statusSymbol(_ status: LocalServiceDiagnosticComponentStatus) -> String {
    switch status {
    case .ready: "checkmark.circle.fill"
    case .degraded: "exclamationmark.triangle.fill"
    case .blocked: "xmark.octagon.fill"
    }
  }

  private func statusColor(_ status: LocalServiceDiagnosticComponentStatus) -> Color {
    switch status {
    case .ready: QuotaPalette.accent
    case .degraded: QuotaPalette.warning
    case .blocked: QuotaPalette.critical
    }
  }

  private func issueSymbol(_ severity: LocalServiceDiagnosticSeverity) -> String {
    switch severity {
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }

  private func issueColor(_ severity: LocalServiceDiagnosticSeverity) -> Color {
    switch severity {
    case .info: QuotaPalette.body
    case .warning: QuotaPalette.warning
    case .error: QuotaPalette.critical
    }
  }

  private func reportStatusPresentation(
    _ status: LocalServiceDiagnosticStatus
  ) -> (label: String, symbol: String, tone: LocalServiceDiagnosticComponentStatus) {
    switch status {
    case .healthy: ("All systems working", "checkmark.circle.fill", .ready)
    case .degraded: ("Some checks need attention", "exclamationmark.triangle.fill", .degraded)
    case .blocked: ("Action needed", "xmark.octagon.fill", .blocked)
    }
  }
}
