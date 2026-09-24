import Foundation
import Testing
@testable import QuotaBar

@MainActor
@Suite
struct DiagnosticsPageModelTests {
  @Test func recheckKeepsLastCompletedReportWhenRefreshFails() async {
    let original = sampleReport()
    let model = DiagnosticsPageModel(report: original)

    await model.runCheck { throw TestDiagnosticsError.failed }

    #expect(model.report == original)
    #expect(model.errorMessage != nil)
  }

  @Test func resetDropsAbandonedResult() async {
    let model = DiagnosticsPageModel()
    let gate = TestGate()
    let task = Task { @MainActor in
      await model.runCheck {
        await gate.wait()
        return sampleReport()
      }
    }
    while !model.isLoading { await Task.yield() }
    model.prepareForEntry()
    await gate.open()
    await task.value
    #expect(model.report == nil)
  }

  /// A subject or surface this build has no name for is not introduced by its wire id. The row
  /// still carries the service's own sentence, which is what it was saying all along.
  @Test func anUnnamedSubjectIsNotDressedUpAsATitle() {
    #expect(
      DiagnosticsPresentation.sourceTitle(subject: "provider:a_provider_from_2027", sourceID: nil)
        == "Unknown provider")
    #expect(
      DiagnosticsPresentation.sourceTitle(subject: "agent:an_agent_from_2027", sourceID: nil)
        == "Other")
    #expect(DiagnosticsPresentation.sourceTitle(subject: "a_new_service_path", sourceID: nil) == "Other")
    #expect(DiagnosticsPresentation.surfaceTitle("a_new_surface") == "Other")
  }
}

private enum TestDiagnosticsError: Error { case failed }

private func sampleReport() -> LocalServiceDiagnosticReport {
  let date = Date(timeIntervalSince1970: 0)
  return LocalServiceDiagnosticReport(
    generatedAt: date,
    client: LocalServiceDiagnosticClient(name: "test", version: "1"),
    summary: LocalServiceDiagnosticSummary(operation: .healthy, attention: .automatic),
    surfaces: [
      LocalServiceDiagnosticSurface(
        id: "quota_overview", status: .ok, data: .current, lastSuccessAt: date,
        message: "1 subscription shown, all current.",
        recovery: .none),
      LocalServiceDiagnosticSurface(
        id: "usage_this_device", status: .ok, data: .empty, lastSuccessAt: nil,
        message: "No Usage records have been found on this Mac yet.", recovery: .none),
      LocalServiceDiagnosticSurface(
        id: "usage_account", status: .inactive, data: .empty, lastSuccessAt: nil,
        message: "Usage sync is off, so nothing leaves this Mac.", recovery: .none),
      LocalServiceDiagnosticSurface(
        id: "account", status: .ok, data: .current, lastSuccessAt: date,
        message: "Signed in · 1 device.", recovery: .none),
    ],
    sources: [
      LocalServiceDiagnosticSource(
        subject: "agent:cursor", status: .degraded, lastAttemptAt: date,
        code: "malformed_json",
        message: "Invalid Usage records were skipped and the valid ones were kept.",
        recovery: .updateSource)
    ],
    recent: [
      LocalServiceDiagnosticAttempt(
        kind: .usageScan, subject: "agent:cursor", startedAt: date, durationMs: 12,
        outcome: .partial, code: "malformed_json")
    ]
  )
}
