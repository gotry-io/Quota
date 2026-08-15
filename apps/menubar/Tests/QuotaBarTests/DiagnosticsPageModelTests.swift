import Foundation
import Testing
@testable import QuotaBar

@MainActor
@Suite
struct DiagnosticsPageModelTests {
  @Test func initialCheckPublishesV2ReportAndCopyText() async {
    let model = DiagnosticsPageModel()
    let report = sampleReport()

    await model.runCheck { report }

    #expect(model.report == report)
    #expect(model.canCopy)
    #expect(!model.isLoading)
    #expect(report.textReport.contains("Diagnostics: healthy"))
    #expect(report.textReport.contains("provider:codex"))
    #expect(report.jsonReport.contains("\"schema_version\":2"))
  }

  @Test func recheckKeepsLastCompletedReportWhenRefreshFails() async {
    let original = sampleReport()
    let model = DiagnosticsPageModel(report: original)

    await model.runCheck { throw TestDiagnosticError.failed }

    #expect(model.report == original)
    #expect(model.errorMessage != nil)
    #expect(model.canCopy)
  }

  @Test func resetDropsAbandonedResult() async {
    let model = DiagnosticsPageModel()
    let task = Task { @MainActor in
      await model.runCheck {
        try await Task.sleep(for: .milliseconds(50))
        return sampleReport()
      }
    }
    await Task.yield()
    model.prepareForEntry()
    await task.value
    #expect(model.report == nil)
  }

  @Test func presentationUsesTypedRecoveryAndSafeSubject() {
    let finding = LocalServiceDiagnosticFinding(
      component: "usage_scan",
      source: .thisDevice,
      subject: "agent:cursor",
      code: "malformed_json",
      severity: .warning,
      impact: .surface,
      recovery: .updateSource,
      count: 4,
      observedAt: .init(timeIntervalSince1970: 0),
      message: "Invalid Usage input was isolated while valid records were retained."
    )

    let summary = DiagnosticsPresentation.findingSummary(finding)

    #expect(summary.title.contains("Cursor"))
    #expect(summary.solution.contains("Update"))
    #expect(
      DiagnosticsPresentation.findingAccessibilityLabel(finding, summary: summary)
        .contains("4 occurrences")
    )
  }

  @Test func findingsSortBySeverityWithoutChangingPeerOrder() {
    let values = [
      finding(code: "info", severity: .info),
      finding(code: "warning_a", severity: .warning),
      finding(code: "error", severity: .error),
      finding(code: "warning_b", severity: .warning),
    ]
    #expect(
      DiagnosticsPresentation.prioritizedFindings(values).map(\.code)
        == ["error", "warning_a", "warning_b", "info"]
    )
  }

  @Test func accountAndLocalLoginRecoveriesStaySourceSpecific() {
    let local = DiagnosticsPresentation.findingSummary(
      loginFinding(source: .thisDevice)
    )
    let account = DiagnosticsPresentation.findingSummary(
      loginFinding(source: .account)
    )

    #expect(local.solution.contains("this Mac"))
    #expect(account.solution.contains("Reconnect Account"))
  }
}

private enum TestDiagnosticError: Error { case failed }

private func finding(
  code: String,
  severity: LocalServiceDiagnosticSeverity
) -> LocalServiceDiagnosticFinding {
  LocalServiceDiagnosticFinding(
    component: "usage_scan",
    source: .thisDevice,
    subject: "agent:codex",
    code: code,
    severity: severity,
    impact: .source,
    recovery: .retry,
    count: 1,
    observedAt: .init(timeIntervalSince1970: 0),
    message: "Safe finding message."
  )
}

private func loginFinding(
  source: LocalServiceDiagnosticSource
) -> LocalServiceDiagnosticFinding {
  LocalServiceDiagnosticFinding(
    component: source == .account ? "account" : "quota_collection",
    source: source,
    subject: source == .account ? nil : "provider:codex",
    code: "auth_required",
    severity: .warning,
    impact: .source,
    recovery: .login,
    count: 1,
    observedAt: .init(timeIntervalSince1970: 0),
    message: "Authentication is required."
  )
}

private func sampleReport() -> LocalServiceDiagnosticReport {
  let date = Date(timeIntervalSince1970: 0)
  return LocalServiceDiagnosticReport(
    schemaVersion: 2,
    summary: LocalServiceDiagnosticSummary(
      operation: .healthy, data: .current, attention: .optional),
    refresh: LocalServiceDiagnosticRefresh(
      phase: .idle, asOf: date, startedAt: nil, nextDueAt: date.addingTimeInterval(300)),
    generatedAt: date,
    client: LocalServiceDiagnosticClient(name: "test", version: "1"),
    surfaces: [
      LocalServiceDiagnosticSurface(
        name: "quota_overview", operation: .healthy, data: .current, source: nil,
        metrics: ["items": 1, "account_sources": 1]),
      LocalServiceDiagnosticSurface(
        name: "usage_this_device", operation: .healthy, data: .empty, source: .thisDevice,
        metrics: ["records": 0]),
      LocalServiceDiagnosticSurface(
        name: "usage_account", operation: .healthy, data: .empty, source: .account,
        metrics: ["enabled": 1, "periods": 0]),
      LocalServiceDiagnosticSurface(
        name: "account", operation: .healthy, data: .current, source: .account,
        metrics: ["signed_in": 1]),
    ],
    checks: [
      LocalServiceDiagnosticCheck(
        name: "quota_collection", source: .account, subject: "provider:codex",
        mode: .required, operation: .healthy, data: .current, lastAttemptAt: date,
        lastSuccessAt: date, metrics: ["sources": 1]),
    ],
    findings: []
  )
}
