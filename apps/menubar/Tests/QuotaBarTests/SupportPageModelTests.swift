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

  /// Reset Local Data confirms through the panel's own popup, like Sign Out and Disconnect: a
  /// MenuBarExtra panel is not a window a system alert can sit over. Leaving the page takes the
  /// question with it, because the answer belonged to a page that is no longer on screen.
  @Test @MainActor func resetLocalDataRaisesThePanelsOwnConfirmation() async {
    let model = SupportPageModel(report: sampleReport())
    #expect(!model.isResetConfirmationPresented)

    model.isResetConfirmationPresented = true
    #expect(model.isResetConfirmationPresented)

    model.prepareForEntry()
    #expect(!model.isResetConfirmationPresented)

    // The words the popup says, so the row and the confirmation cannot drift apart.
    #expect(ResetLocalDataCopy.title == "Reset Local Data?")
    #expect(ResetLocalDataCopy.confirmTitle == "Reset Local Data")
    #expect(ResetLocalDataCopy.message.contains("deleted and rebuilt"))
    #expect(ResetLocalDataCopy.message.contains("You stay signed in."))
  }

  /// The service owns every sentence; the page only names the thing the sentence is about, and
  /// every one of those names comes from a table rather than from the id it arrived as.
  @Test func sourceTitlesNameTheProviderAndTheRungThatAnswered() {
    #expect(
      SupportPresentation.sourceTitle(subject: "provider:codex", sourceID: "chatgpt_usage_api")
        == "Codex · OAuth")
    #expect(
      SupportPresentation.sourceTitle(subject: "provider:cursor", sourceID: "browser_session")
        == "Cursor · Browser session")
    #expect(SupportPresentation.sourceTitle(subject: "agent:cursor", sourceID: nil) == "Cursor")
    #expect(
      SupportPresentation.sourceTitle(subject: "agent:claude_code", sourceID: nil) == "Claude Code")
    #expect(SupportPresentation.sourceTitle(subject: "usage_upload", sourceID: nil) == "Usage sync")
    #expect(SupportPresentation.sourceTitle(subject: "local_state", sourceID: nil) == "Local data")
  }

  /// A subject or surface this build has no name for is not introduced by its wire id. The row
  /// still carries the service's own sentence, which is what it was saying all along.
  @Test func anUnnamedSubjectIsNotDressedUpAsATitle() {
    #expect(
      SupportPresentation.sourceTitle(subject: "provider:a_provider_from_2027", sourceID: nil)
        == "Unknown provider")
    #expect(
      SupportPresentation.sourceTitle(subject: "agent:an_agent_from_2027", sourceID: nil)
        == "Other")
    #expect(SupportPresentation.sourceTitle(subject: "a_new_service_path", sourceID: nil) == "Other")
    #expect(SupportPresentation.surfaceTitle("a_new_surface") == "Other")
  }

  /// Support is the one page that states a clock time. A person presses Recheck to find out
  /// whether what they are looking at came from that run, and every run is "just now".
  @Test func theStatusLineStatesWhenTheCheckRanRatherThanHowLongAgo() {
    let label = SupportPresentation.checkedLabel(
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
      SupportPresentation.checkedLabel(
        Date(timeIntervalSince1970: 1_786_300_000),
        locale: Locale(identifier: "en_GB"),
        timeZone: TimeZone(identifier: "Europe/London")!
      ) == "Checked 19:26"
    )
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
