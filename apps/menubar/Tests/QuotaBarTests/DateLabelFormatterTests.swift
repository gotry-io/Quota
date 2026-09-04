import Foundation
import QuotaPresentation
import Testing

@testable import QuotaBar

/// The footer and the Support status line say the same thing the same way, and neither makes
/// the reader subtract a clock time from now.
struct FooterFreshnessTests {
  private let now = Date(timeIntervalSince1970: 1_786_617_600)

  @Test
  func nothingCheckedYetSaysSoInWords() {
    #expect(FreshnessCopy.updated(since: nil, now: now) == "Not checked")
  }

  @Test
  func aCompletedSyncStatesItsAgeRelativeToNow() {
    #expect(
      FreshnessCopy.updated(since: now.addingTimeInterval(-180), now: now) == "Updated 3m ago"
    )
    #expect(FreshnessCopy.updated(since: now, now: now) == "Updated just now")
  }
}

struct DiagnosticsHeaderActionTests {
  @Test
  func copyAccessibilityLabels() {
    #expect(DiagnosticsHeaderAction.copyAccessibilityLabel(didCopy: false) == "Copy report")
    #expect(DiagnosticsHeaderAction.copyAccessibilityLabel(didCopy: true) == "Report copied")
    #expect(DiagnosticsHeaderAction.recheckLabel == "Recheck")
    #expect(DiagnosticsHeaderAction.recheckAccessibilityLabel(isChecking: false) == "Recheck")
    #expect(DiagnosticsHeaderAction.recheckAccessibilityLabel(isChecking: true) == "Checking")
    #expect(DiagnosticsHeaderAction.copyFeedbackDuration == .seconds(2))
  }
}


