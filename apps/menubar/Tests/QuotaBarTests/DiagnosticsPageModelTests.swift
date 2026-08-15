import Foundation
import Testing

@testable import QuotaBar

@MainActor
struct DiagnosticsPageModelTests {
  @Test
  func prepareForEntryClearsPriorReport() async throws {
    let model = DiagnosticsPageModel()
    await model.runCheck { sampleReport(status: .healthy) }
    #expect(model.report != nil)
    #expect(model.canCopy)

    model.prepareForEntry()
    #expect(model.report == nil)
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
    #expect(!model.didCopy)
    #expect(!model.canCopy)
    #expect(!model.canRecheck)
    #expect(!model.showsHeaderActions)
    #expect(pageStateSummary(model.pageState) == .loading)
  }

  @Test
  func failedRecheckPreservesLastGoodReportAndShowsInlineWarning() async {
    let model = DiagnosticsPageModel()
    await model.runCheck { sampleReport(status: .degraded) }
    #expect(model.report?.status == .degraded)
    #expect(model.errorMessage == nil)
    #expect(model.canCopy)
    #expect(model.canRecheck)
    #expect(model.showsHeaderActions)
    #expect(
      pageStateSummary(model.pageState)
        == .report(status: .degraded, isRechecking: false, refreshWarning: nil)
    )

    await model.runCheck {
      throw TestDiagnosticError.failed
    }
    #expect(model.report?.status == .degraded)
    #expect(model.errorMessage == TestDiagnosticError.failed.errorDescription)
    #expect(model.canCopy)
    #expect(model.canRecheck)
    #expect(model.showsHeaderActions)
    #expect(
      pageStateSummary(model.pageState)
        == .report(
          status: .degraded,
          isRechecking: false,
          refreshWarning: TestDiagnosticError.failed.errorDescription
        )
    )
  }

  @Test
  func initialCheckUsesCenteredLoadingThenFullPageErrorWithoutHeaderActions() async {
    let model = DiagnosticsPageModel()
    let gate = AsyncGate()

    async let check: Void = model.runCheck {
      await gate.wait()
      throw TestDiagnosticError.failed
    }
    while !model.isLoading {
      await Task.yield()
    }

    #expect(pageStateSummary(model.pageState) == .loading)
    #expect(!model.showsHeaderActions)
    #expect(!model.canRecheck)
    #expect(!model.canCopy)

    await gate.open()
    await check
    #expect(
      pageStateSummary(model.pageState)
        == .error(TestDiagnosticError.failed.errorDescription ?? "")
    )
    #expect(!model.showsHeaderActions)
    #expect(!model.canRecheck)
    #expect(!model.canCopy)
  }

  @Test
  func recheckKeepsReportAndOnlyDisablesRecheckAction() async {
    let model = DiagnosticsPageModel()
    await model.runCheck { sampleReport(status: .healthy) }
    let gate = AsyncGate()

    async let recheck: Void = model.runCheck {
      await gate.wait()
      return sampleReport(status: .degraded)
    }
    while !model.isLoading {
      await Task.yield()
    }

    #expect(model.report?.status == .healthy)
    #expect(
      pageStateSummary(model.pageState)
        == .report(status: .healthy, isRechecking: true, refreshWarning: nil)
    )
    #expect(model.showsHeaderActions)
    #expect(!model.canRecheck)
    #expect(model.canCopy)

    await gate.open()
    await recheck
    #expect(model.report?.status == .degraded)
    #expect(
      pageStateSummary(model.pageState)
        == .report(status: .degraded, isRechecking: false, refreshWarning: nil)
    )
    #expect(model.canRecheck)
  }

  @Test
  func runCheckIgnoresOverlappingCalls() async {
    let model = DiagnosticsPageModel()
    let gate = AsyncGate()
    let counter = CallCounter()

    async let first: Void = model.runCheck {
      await counter.incrementStarted()
      await gate.wait()
      await counter.incrementFinished()
      return sampleReport(status: .healthy)
    }

    // Let the first check mark itself loading before the second call.
    while !model.isLoading {
      await Task.yield()
    }
    await model.runCheck {
      await counter.incrementStarted()
      return sampleReport(status: .blocked)
    }
    #expect(await counter.started == 1)
    #expect(model.isLoading)

    await gate.open()
    await first
    #expect(await counter.finished == 1)
    #expect(model.report?.status == .healthy)
    #expect(!model.isLoading)
  }

  @Test
  func prepareForEntryDropsStaleInFlightResults() async {
    let model = DiagnosticsPageModel()
    let gate = AsyncGate()

    async let abandoned: Void = model.runCheck {
      await gate.wait()
      return sampleReport(status: .blocked)
    }
    while !model.isLoading {
      await Task.yield()
    }

    model.prepareForEntry()
    #expect(!model.isLoading)
    #expect(model.report == nil)

    await model.runCheck { sampleReport(status: .healthy) }
    #expect(model.report?.status == .healthy)

    await gate.open()
    await abandoned
    #expect(model.report?.status == .healthy)
    #expect(model.errorMessage == nil)
  }

  @Test
  func componentSummariesCoverAllSixComponentsWithoutWireKeys() {
    let components = [
      diagnosticComponent(
        name: "providers", metrics: ["configured": 2, "discovered": 3]
      ),
      diagnosticComponent(
        name: "quota",
        status: .degraded,
        metrics: ["results": 5, "success": 4, "auth_required": 1, "snapshots": 4]
      ),
      diagnosticComponent(name: "usage", metrics: ["records": 10, "files": 2]),
      diagnosticComponent(
        name: "pricing", metrics: ["entries": 100, "catalog_present": 1, "catalog_valid": 1]
      ),
      diagnosticComponent(name: "account", metrics: ["signed_in": 1, "devices": 2]),
      diagnosticComponent(
        name: "sync",
        metrics: [
          "usage_upload_enabled": 1,
          "dirty_ranges": 1,
          "uploadable_dirty_ranges": 0,
          "outbox": 0,
          "last_upload_success": 1,
        ]
      ),
    ]
    let summaries = components.map(DiagnosticsPresentation.componentSummary)

    #expect(summaries.map(\.title) == ["Providers", "Quota", "Usage", "Pricing", "Account", "Sync"])
    #expect(summaries[0].detail == "3 providers available · 2 setups saved")
    #expect(summaries[1].detail == "4 of 5 provider checks passed")
    #expect(summaries[2].detail == "10 records from 2 files")
    #expect(summaries[3].detail == "100 model prices available")
    #expect(summaries[4].detail == "Signed in · 2 devices")
    #expect(summaries[5].detail == "Up to date")
    #expect(summaries.allSatisfy { !$0.detail.contains("=") })
    #expect(summaries.allSatisfy { !$0.detail.contains("auth_required") })
  }

  @Test
  func issueRecoveryUsesReportGuidanceBeforeErrorCode() {
    let issue = LocalServiceDiagnosticIssue(
      component: "account",
      code: "network_error",
      severity: .warning,
      count: 1,
      message: "recovery_login"
    )
    let summary = DiagnosticsPresentation.issueSummary(
      issue,
      component: cachedAccountComponent()
    )
    #expect(summary.title == "Account data couldn’t be updated")
    #expect(summary.solution == "Open Account in Settings, sign in again, then recheck.")
  }

  @Test
  func issueRecoveryDistinguishesRetryConfigurationUpgradeAndFeedback() {
    let retry = diagnosticIssue(component: "sync", code: "pending_upload", message: "recovery_retry")
    let retrySolution = DiagnosticsPresentation.issueSummary(retry, component: nil).solution
    #expect(retrySolution.hasPrefix("Refresh QuotaBar"))

    let configure = diagnosticIssue(
      component: "providers",
      code: "config_unreadable",
      message: "recovery_configure_provider"
    )
    #expect(
      DiagnosticsPresentation.issueSummary(configure, component: nil).solution.hasPrefix("Open Agents")
    )

    let upgrade = diagnosticIssue(
      code: "client_upgrade_required",
      message: "recovery_upgrade"
    )
    #expect(
      DiagnosticsPresentation.issueSummary(upgrade, component: nil).solution.hasPrefix("Open Support")
    )

    let feedback = diagnosticIssue(code: "internal", message: "component_not_ready")
    #expect(
      DiagnosticsPresentation.issueSummary(feedback, component: nil).solution.hasPrefix("Copy the report")
    )
  }

  @Test
  func accountNetworkWarningWithCacheExplainsLastKnownData() {
    let issue = diagnosticIssue(code: "network_error", message: "recovery_retry")
    let summary = DiagnosticsPresentation.issueSummary(
      issue,
      component: cachedAccountComponent()
    )
    #expect(summary.title == "Account data couldn’t be updated")
    #expect(summary.solution.hasPrefix("Your saved account data is still available"))
    #expect(!summary.solution.contains("sign in"))
  }

  @Test
  func accountNetworkErrorWithoutCacheSaysUnavailable() {
    let issue = diagnosticIssue(
      code: "network_error",
      severity: .error,
      message: "recovery_retry"
    )
    let component = diagnosticComponent(
      name: "account",
      status: .blocked,
      metrics: ["signed_in": 0, "devices": 0, "observations": 0]
    )
    let summary = DiagnosticsPresentation.issueSummary(issue, component: component)
    #expect(summary.title == "Account is unavailable")
    #expect(summary.solution.hasPrefix("Account data is currently unavailable"))
    #expect(!summary.solution.contains("saved account data"))
  }

  @Test
  func unsupportedOperationDoesNotClaimAnUpdateIsRequired() {
    let issue = diagnosticIssue(code: "unsupported_operation", message: "component_not_ready")
    let summary = DiagnosticsPresentation.issueSummary(issue, component: nil)
    #expect(summary.title == "Account operation isn’t supported")
    #expect(!summary.title.contains("update"))
    #expect(summary.solution.hasPrefix("Copy the report"))
  }

  @Test
  func quotaWithoutConfiguredProvidersPointsToAgentsSetup() {
    let issue = diagnosticIssue(
      component: "quota",
      code: "not_configured",
      severity: .error,
      message: "recovery_configure_provider"
    )
    let summary = DiagnosticsPresentation.issueSummary(issue, component: nil)
    #expect(summary.title == "No providers configured")
    #expect(summary.solution.hasPrefix("Open Agents in Settings"))
  }

  @Test
  func coverageReasonsOfferDataAccessRefreshOrSourceUpdateRecovery() {
    for code in ["permission_denied", "source_unreadable"] {
      let issue = diagnosticIssue(component: "usage", code: code, message: "coverage_partial")
      let solution = DiagnosticsPresentation.issueSummary(issue, component: nil).solution
      #expect(solution.hasPrefix("Check that QuotaBar can access"))
    }

    for code in ["source_changed", "scan_cancelled"] {
      let issue = diagnosticIssue(component: "usage", code: code, message: "coverage_partial")
      let solution = DiagnosticsPresentation.issueSummary(issue, component: nil).solution
      #expect(solution.hasPrefix("Refresh QuotaBar"))
    }

    for code in [
      "discovery_limit", "record_limit", "line_too_large", "truncated_tail", "malformed_json",
      "unknown_record", "invalid_timestamp", "invalid_model", "invalid_usage",
    ] {
      let issue = diagnosticIssue(component: "usage", code: code, message: "coverage_partial")
      let solution = DiagnosticsPresentation.issueSummary(issue, component: nil).solution
      #expect(solution.hasPrefix("Update the app or CLI"))
    }
  }

  @Test
  func componentStatusLabelsAreAccessibleWithoutColor() {
    #expect(DiagnosticsPresentation.statusLabel(.ready) == "Working")
    #expect(DiagnosticsPresentation.statusLabel(.degraded) == "Needs attention")
    #expect(DiagnosticsPresentation.statusLabel(.blocked) == "Unavailable")
  }

  @Test
  func issueAccessibilityLabelsIncludeSeverity() {
    for (severity, label) in [
      (LocalServiceDiagnosticSeverity.error, "Error"),
      (.warning, "Warning"),
      (.info, "Info"),
    ] {
      let issue = diagnosticIssue(code: "internal", severity: severity, message: "recovery_none")
      let summary = DiagnosticsPresentation.issueSummary(issue, component: nil)
      #expect(
        DiagnosticsPresentation.issueAccessibilityLabel(issue, summary: summary)
          .hasPrefix("\(label):")
      )
    }
  }

  @Test
  func issuesArePrioritizedBySeverityAndStableWithinEachLevel() {
    let issues = [
      diagnosticIssue(code: "info_first", severity: .info, message: "recovery_none"),
      diagnosticIssue(code: "warning_first", severity: .warning, message: "recovery_retry"),
      diagnosticIssue(code: "error_first", severity: .error, message: "recovery_none"),
      diagnosticIssue(code: "warning_second", severity: .warning, message: "recovery_retry"),
    ]

    #expect(
      DiagnosticsPresentation.prioritizedIssues(issues).map(\.code)
        == ["error_first", "warning_first", "warning_second", "info_first"]
    )
  }
}

private enum TestDiagnosticError: LocalizedError {
  case failed

  var errorDescription: String? { "diagnostic failed" }
}

private enum TestDiagnosticsPageState: Equatable {
  case loading
  case error(String)
  case report(
    status: LocalServiceDiagnosticStatus,
    isRechecking: Bool,
    refreshWarning: String?
  )
}

private func pageStateSummary(_ state: DiagnosticsPageState) -> TestDiagnosticsPageState {
  switch state {
  case .loading:
    .loading
  case .error(let message):
    .error(message)
  case .report(let report, let isRechecking, let refreshWarning):
    .report(
      status: report.status,
      isRechecking: isRechecking,
      refreshWarning: refreshWarning
    )
  }
}

private actor CallCounter {
  private(set) var started = 0
  private(set) var finished = 0

  func incrementStarted() { started += 1 }
  func incrementFinished() { finished += 1 }
}

/// One-shot async gate so tests can hold a diagnose call mid-flight.
private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

private func sampleReport(status: LocalServiceDiagnosticStatus) -> LocalServiceDiagnosticReport {
  LocalServiceDiagnosticReport(
    schemaVersion: 1,
    status: status,
    generatedAt: Date(timeIntervalSince1970: 1_786_617_600),
    client: LocalServiceDiagnosticClient(name: "test", version: "1"),
    components: ["providers", "quota", "usage", "pricing", "account", "sync"].map {
      LocalServiceDiagnosticComponent(name: $0, status: .ready, message: nil, metrics: [:])
    },
    issues: []
  )
}

private func diagnosticIssue(
  component: String = "account",
  code: String,
  severity: LocalServiceDiagnosticSeverity = .warning,
  message: String
) -> LocalServiceDiagnosticIssue {
  LocalServiceDiagnosticIssue(
    component: component,
    code: code,
    severity: severity,
    count: 1,
    message: message
  )
}

private func diagnosticComponent(
  name: String,
  status: LocalServiceDiagnosticComponentStatus = .ready,
  metrics: [String: Int]
) -> LocalServiceDiagnosticComponent {
  LocalServiceDiagnosticComponent(
    name: name,
    status: status,
    message: nil,
    metrics: metrics
  )
}

private func cachedAccountComponent() -> LocalServiceDiagnosticComponent {
  diagnosticComponent(
    name: "account",
    status: .degraded,
    metrics: ["signed_in": 1, "devices": 1, "observations": 2]
  )
}
