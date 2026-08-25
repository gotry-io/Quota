import Foundation
import Testing
@testable import QuotaBar

@MainActor
@Suite
struct SupportPageModelTests {
  @Test func initialCheckPublishesTheReportAndItsCopyText() async {
    let model = SupportPageModel()
    let report = sampleReport()

    await model.runCheck { report }

    #expect(model.report == report)
    #expect(model.canCopy)
    #expect(!model.isLoading)
    let text = report.textReport
    #expect(text.contains("Status: healthy"))
    #expect(text.contains("quota_overview"))
    // Recent work is not on the page but is in the copied report.
    #expect(text.contains("usage_scan/agent:cursor"))
    #expect(text.contains("code=malformed_json"))
    #expect(!text.contains("/Users/"))
  }

  @Test func recheckKeepsLastCompletedReportWhenRefreshFails() async {
    let original = sampleReport()
    let model = SupportPageModel(report: original)

    await model.runCheck { throw TestSupportError.failed }

    #expect(model.report == original)
    #expect(model.errorMessage != nil)
    #expect(model.canCopy)
  }

  @Test func resetDropsAbandonedResult() async {
    let model = SupportPageModel()
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
    #expect(!model.isResetConfirmationPresented)
  }

  /// The service owns every sentence; the page only names the thing the sentence is about.
  @Test func sourceTitlesNameTheProviderAndTheRungThatAnswered() {
    #expect(
      SupportPresentation.sourceTitle(subject: "provider:codex", sourceID: "oauth")
        == "Codex · Oauth")
    #expect(SupportPresentation.sourceTitle(subject: "agent:cursor", sourceID: nil) == "Cursor")
    #expect(
      SupportPresentation.sourceTitle(subject: "usage_upload", sourceID: nil) == "Usage Upload")
  }

  @Test func summaryLabelFollowsOperationThenAttention() {
    #expect(
      SupportPresentation.summaryLabel(
        LocalServiceDiagnosticSummary(operation: .healthy, attention: .none))
        == "All systems working")
    #expect(
      SupportPresentation.summaryLabel(
        LocalServiceDiagnosticSummary(operation: .healthy, attention: .required))
        == "Some checks need attention")
    #expect(
      SupportPresentation.summaryLabel(
        LocalServiceDiagnosticSummary(operation: .blocked, attention: .none)) == "Action needed")
  }
}

private enum TestSupportError: Error { case failed }

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
