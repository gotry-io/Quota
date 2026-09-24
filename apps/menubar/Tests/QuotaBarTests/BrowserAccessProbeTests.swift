import AppKit
import SweetCookieKit
import Testing

@testable import QuotaBar

@Test
func accessSnapshotSkipsSafariWithoutFullDiskAccessAndLeavesOtherBrowsersReadable() {
  let snapshot = BrowserAccessEvaluation.snapshot(
    browsers: [.safari, .chrome, .firefox],
    fullDiskAccessSettingsOpened: false,
    isInstalled: { _ in true },
    hasFullDiskAccess: { false },
    keychainAccess: { browser in browser == .chrome ? .allowed : .notFound }
  )
  #expect(snapshot.allowsReading(.safari) == false)
  #expect(snapshot.allowsReading(.chrome))
  #expect(snapshot.allowsReading(.firefox))
  #expect(snapshot.needs == [BrowserAccessNeed(browser: .safari, kind: .fullDiskAccess)])
  #expect(snapshot.awaitingRelaunch == false)
  #expect(
    snapshot.statuses.map(\.state) == [.needsFullDiskAccess, .readable, .readable])
}

@Test
func accessSnapshotOmitsFullDiskAccessWhenSafariIsNotInstalled() {
  let snapshot = BrowserAccessEvaluation.snapshot(
    browsers: [.safari, .chrome, .firefox],
    fullDiskAccessSettingsOpened: false,
    isInstalled: { $0 != .safari },
    hasFullDiskAccess: { false },
    keychainAccess: { _ in .allowed }
  )
  #expect(snapshot.needs.isEmpty)
  #expect(snapshot.allowsReading(.chrome))
  #expect(snapshot.allowsReading(.firefox))
  #expect(snapshot.allowsReading(.safari) == false)
  #expect(snapshot.status(for: .safari) == nil)
}

@Test
func accessSnapshotListsChromiumKeychainWhenInteractionIsRequired() {
  let snapshot = BrowserAccessEvaluation.snapshot(
    browsers: [.chrome, .edge],
    fullDiskAccessSettingsOpened: false,
    isInstalled: { _ in true },
    hasFullDiskAccess: { true },
    keychainAccess: { browser in
      browser == .chrome ? .interactionRequired : .notFound
    }
  )
  #expect(snapshot.needs == [BrowserAccessNeed(browser: .chrome, kind: .keychain)])
  #expect(snapshot.allowsReading(.chrome) == false)
  // A browser that never created its Safe Storage item has nothing to grant and is not a need.
  #expect(snapshot.status(for: .edge)?.state == .unavailable)
  #expect(snapshot.allowsReading(.edge) == false)
}

/// Full Disk Access lands on the next launch, so once the pane has been opened the next step
/// is a relaunch — stated as that, not as a claim that the grant is already in place.
@Test
func openingTheFullDiskAccessPaneMakesRelaunchTheNextStepWhileSafariStaysClosed() {
  let opened = BrowserAccessEvaluation.snapshot(
    browsers: [.safari],
    fullDiskAccessSettingsOpened: true,
    isInstalled: { _ in true },
    hasFullDiskAccess: { false },
    keychainAccess: { _ in .notFound }
  )
  #expect(opened.awaitingRelaunch)
  #expect(opened.needs.contains { $0.kind == .fullDiskAccess })

  let granted = BrowserAccessEvaluation.snapshot(
    browsers: [.safari],
    fullDiskAccessSettingsOpened: true,
    isInstalled: { _ in true },
    hasFullDiskAccess: { true },
    keychainAccess: { _ in .notFound }
  )
  #expect(granted.awaitingRelaunch == false)
  #expect(granted.needs.isEmpty)
}

@Test @MainActor
func fullDiskAccessDragIconDoesNotMoveTheWindow() {
  let view = FullDiskAccessDragSourceView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
  #expect(view.mouseDownCanMoveWindow == false)
  #expect(view.intrinsicContentSize == NSSize(width: 40, height: 40))
}

@Test
func aDropCountsOnlyWhenAcceptedWithSystemSettingsInFront() {
  #expect(
    FullDiskAccessDragSourceView.droppedIntoSystemSettings(
      operation: .copy, frontmostBundleIdentifier: "com.apple.systempreferences"))
  #expect(
    FullDiskAccessDragSourceView.droppedIntoSystemSettings(
      operation: .copy, frontmostBundleIdentifier: "com.apple.Settings"))
  // A copy onto the desktop is accepted too, but by Finder.
  #expect(
    !FullDiskAccessDragSourceView.droppedIntoSystemSettings(
      operation: .copy, frontmostBundleIdentifier: "com.apple.finder"))
  #expect(
    !FullDiskAccessDragSourceView.droppedIntoSystemSettings(
      operation: [], frontmostBundleIdentifier: "com.apple.systempreferences"))
  #expect(
    !FullDiskAccessDragSourceView.droppedIntoSystemSettings(
      operation: .copy, frontmostBundleIdentifier: nil))
  #expect(FullDiskAccessDragSourceView.dragThreshold >= 3)
}
