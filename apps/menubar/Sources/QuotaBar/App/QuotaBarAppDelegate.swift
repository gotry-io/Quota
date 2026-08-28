import AppKit

/// Quitting is the last moment QuotaBar can speak to its local service, and every route out of
/// the app — the panel's Quit item, ⌘Q, and logging out — arrives at
/// `applicationShouldTerminate`. The helper's own exit is asked for there rather than left to
/// the process dying, so a service that is mid-write finishes before its pipe disappears.
@MainActor
final class QuotaBarAppDelegate: NSObject, NSApplicationDelegate {
  private var model: MenuBarViewModel?
  private var statusItems: MenuBarStatusItemController?

  func attach(model: MenuBarViewModel) {
    self.model = model
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    startStatusItemsIfNeeded()
  }

  private func startStatusItemsIfNeeded() {
    guard statusItems == nil, let model else { return }
    statusItems = MenuBarStatusItemController(model: model)
  }

  /// `terminateLater` is what makes an asynchronous last message possible: AppKit runs the run
  /// loop until `reply(toApplicationShouldTerminate:)`, so nothing here blocks the main thread
  /// waiting for the helper, and a logout still reads this app as agreeing to quit — which
  /// `terminateCancel` would not. It does mean the quit has to reach here from the run loop
  /// rather than from inside a main-actor task, which would leave the main queue holding the
  /// task below; every route QuotaBar quits by — the panel's Quit item, ⌘Q, a Quit event, and
  /// logging out — is a run-loop one. The wait is capped by `MenuBarViewModel.shutdownDeadline`,
  /// so a wedged helper delays a quit by two seconds and then stops mattering: the reply always
  /// comes, and it is always yes.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    statusItems?.invalidate()
    statusItems = nil
    guard let model else { return .terminateNow }
    self.model = nil
    Task { @MainActor in
      await model.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
