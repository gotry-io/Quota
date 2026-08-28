import Foundation
import Testing
@testable import QuotaBar

@MainActor
@Suite
struct DiagnosticsPageModelTests {
  @Test func initialCheckPublishesTheReportAndItsCopyText() async {
    let model = DiagnosticsPageModel()
    let report = sampleReport()

    await model.runCheck { report }

    #expect(model.report == report)
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
    let model = DiagnosticsPageModel(report: original)

    await model.runCheck { throw TestDiagnosticsError.failed }

    #expect(model.report == original)
    #expect(model.errorMessage != nil)
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

  /// Reset Local Data confirms through the panel's own popup, like Sign Out and Disconnect: a
  /// MenuBarExtra panel is not a window a system alert can sit over. These are the words the
  /// popup says, so the row and the confirmation cannot drift apart.
  @Test func resetLocalDataConfirmationSaysWhatItDeletes() {
    #expect(ResetLocalDataCopy.title == "Reset Local Data?")
    #expect(ResetLocalDataCopy.confirmTitle == "Reset Local Data")
    #expect(ResetLocalDataCopy.message.contains("deleted and rebuilt"))
    #expect(ResetLocalDataCopy.message.contains("You stay signed in."))
  }

  /// The service owns every sentence; the page only names the thing the sentence is about, and
  /// every one of those names comes from a table rather than from the id it arrived as.
  @Test func sourceTitlesNameTheProviderAndTheRungThatAnswered() {
    #expect(
      DiagnosticsPresentation.sourceTitle(subject: "provider:codex", sourceID: "chatgpt_usage_api")
        == "Codex · OAuth")
    #expect(
      DiagnosticsPresentation.sourceTitle(subject: "provider:cursor", sourceID: "browser_session")
        == "Cursor · Browser session")
    #expect(DiagnosticsPresentation.sourceTitle(subject: "agent:cursor", sourceID: nil) == "Cursor")
    #expect(
      DiagnosticsPresentation.sourceTitle(subject: "agent:claude_code", sourceID: nil) == "Claude Code")
    #expect(DiagnosticsPresentation.sourceTitle(subject: "usage_upload", sourceID: nil) == "Usage sync")
    #expect(DiagnosticsPresentation.sourceTitle(subject: "local_state", sourceID: nil) == "Local data")
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

  /// Support is the one page that states a clock time. A person presses Recheck to find out
  /// whether what they are looking at came from that run, and every run is "just now".
  @Test func theStatusLineStatesWhenTheCheckRanRatherThanHowLongAgo() {
    let label = DiagnosticsPresentation.checkedLabel(
      Date(timeIntervalSince1970: 1_786_300_000),
      locale: Locale(identifier: "en_US"),
      timeZone: TimeZone(identifier: "America/Los_Angeles")!
    )

    #expect(label.hasPrefix("Checked "))
    #expect(label.contains("11:26"))
    #expect(label.contains("AM"))
    #expect(!label.contains("ago"))

    // Locale-shortened, so the same instant reads as the clock the reader keeps.
    #expect(
      DiagnosticsPresentation.checkedLabel(
        Date(timeIntervalSince1970: 1_786_300_000),
        locale: Locale(identifier: "en_GB"),
        timeZone: TimeZone(identifier: "Europe/London")!
      ) == "Checked 19:26"
    )
  }

  @Test func summaryLabelFollowsOperationThenAttention() {
    #expect(
      DiagnosticsPresentation.summaryLabel(
        LocalServiceDiagnosticSummary(operation: .healthy, attention: .none))
        == "All systems working")
    #expect(
      DiagnosticsPresentation.summaryLabel(
        LocalServiceDiagnosticSummary(operation: .healthy, attention: .required))
        == "Some checks need attention")
    #expect(
      DiagnosticsPresentation.summaryLabel(
        LocalServiceDiagnosticSummary(operation: .blocked, attention: .none)) == "Action needed")
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
