import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWire
import Testing

@testable import QuotaBar

@MainActor
struct DesktopWidgetPublisherTests {
  private let salt = Data(repeating: 0x5a, count: 32)
  private let now = Date(timeIntervalSince1970: 1_786_723_200)

  @Test
  func aBuildWithNoAppGroupPublishesNothingAndSaysSo() {
    let publisher = DesktopWidgetPublisher(publisher: nil, loadSalt: { self.salt })
    publisher.publish(subscriptions: [subscription()], today: nil, fetchedAt: now)

    #expect(publisher.status == .unentitled)
    #expect(publisher.status.message().contains("not entitled"))
  }

  @Test
  func publishesTheOverviewRowsUnderTheirSaltedSelectionIDs() throws {
    let recorder = RecordingWidgetSnapshotPublisher()
    let publisher = DesktopWidgetPublisher(publisher: recorder, loadSalt: { self.salt })
    let row = subscription()

    publisher.publish(subscriptions: [row], today: nil, fetchedAt: now)

    let published = try #require(recorder.published.last)
    #expect(published.items.map(\.windowTitle) == ["5 Hours", "Weekly"])
    #expect(
      published.items.allSatisfy {
        $0.selectionID == SelectionIDs.make(selector: row.selector, salt: salt)
      }
    )
    // Nothing that names the account reaches the App Group file.
    #expect(published.items.allSatisfy { !$0.selectionID.contains("fp_codex") })
    #expect(publisher.status == .published(itemCount: 2, at: now))
    #expect(publisher.status.message(now: now).hasPrefix("2 readings published"))
    #expect(recorder.reloads == 1)
  }

  @Test
  func nothingToShowClearsWhatTheWidgetsWereReading() {
    let recorder = RecordingWidgetSnapshotPublisher()
    let publisher = DesktopWidgetPublisher(publisher: recorder, loadSalt: { self.salt })

    publisher.publish(subscriptions: [], today: nil, fetchedAt: now)

    #expect(recorder.published.isEmpty)
    #expect(recorder.clears == 1)
    #expect(publisher.status == .cleared)
  }

  /// A snapshot QuotaBar cannot write is a sentence on Diagnostics, never a thrown state update.
  @Test
  func anUnwritableSnapshotLeavesASentenceAndNothingElse() {
    let recorder = RecordingWidgetSnapshotPublisher(failure: WidgetPublishFailure())
    let publisher = DesktopWidgetPublisher(publisher: recorder, loadSalt: { self.salt })

    publisher.publish(subscriptions: [subscription()], today: nil, fetchedAt: now)

    #expect(publisher.status.message().hasPrefix("The last snapshot could not be written:"))
  }

  @Test
  func anUnreadableSaltStopsPublishingWithoutFailingTheUpdate() {
    let recorder = RecordingWidgetSnapshotPublisher()
    let publisher = DesktopWidgetPublisher(
      publisher: recorder,
      loadSalt: { throw DesktopWidgetPublishingError.saltUnavailable }
    )

    publisher.publish(subscriptions: [subscription()], today: nil, fetchedAt: now)

    #expect(recorder.published.isEmpty)
    #expect(
      publisher.status
        == .failed("the installation salt could not be read.")
    )
  }

  /// The link a widget row carries has to come back to the row that published it, or the panel
  /// would open on Overview after every click.
  @Test
  func resolvesAPublishedSelectionIDBackToItsRow() throws {
    let recorder = RecordingWidgetSnapshotPublisher()
    let publisher = DesktopWidgetPublisher(publisher: recorder, loadSalt: { self.salt })
    let row = subscription()

    publisher.publish(subscriptions: [row], today: nil, fetchedAt: now)
    let published = try #require(recorder.published.last?.items.first)

    #expect(
      publisher.subscription(forSelectionID: published.selectionID, in: [row])?.selector
        == row.selector
    )
    // A link made under an earlier salt names nothing this installation published.
    #expect(publisher.subscription(forSelectionID: "0123456789ab", in: [row]) == nil)
  }

  private func subscription() -> DesktopWidgetSubscription {
    DesktopWidgetSubscription(
      snapshot: QuotaSnapshot(
        provider: .codex,
        account: QuotaAccount(fingerprint: "fp_codex", fingerprintScope: .global),
        windows: [
          QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 60, limitValue: 100),
          QuotaWindow(id: "5h", title: "5 Hours", usedPercent: 82, limitValue: 100),
        ],
        status: .available,
        observedAt: now
      ),
      selector: "codex|fp_codex|global|"
    )
  }
}

private struct WidgetPublishFailure: LocalizedError {
  var errorDescription: String? { "the container is read-only." }
}

private final class RecordingWidgetSnapshotPublisher: WidgetSnapshotPublishing, @unchecked Sendable
{
  private(set) var published: [WidgetSnapshot] = []
  private(set) var clears = 0
  private(set) var reloads = 0
  private let failure: (any Error)?

  init(failure: (any Error)? = nil) {
    self.failure = failure
  }

  func publish(_ snapshot: WidgetSnapshot) throws {
    if let failure { throw failure }
    published.append(snapshot)
    reloads += 1
  }

  func clear() throws {
    if let failure { throw failure }
    clears += 1
    reloads += 1
  }
}
