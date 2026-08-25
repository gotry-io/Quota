import AppKit

/// Quitting is the last moment QuotaBar can speak to its local service, and every route out of
/// the app — the panel's Quit item, ⌘Q, and logging out — arrives at
/// `applicationShouldTerminate`. The helper's own exit is asked for there rather than left to
/// the process dying, so a service that is mid-write finishes before its pipe disappears.
@MainActor
final class QuotaBarAppDelegate: NSObject, NSApplicationDelegate {
  var model: MenuBarViewModel?

  /// `terminateLater` is what makes an asynchronous last message possible: AppKit runs the run
  /// loop until `reply(toApplicationShouldTerminate:)`, so nothing here blocks the main thread
  /// waiting for the helper, and a logout still reads this app as agreeing to quit — which
  /// `terminateCancel` would not. It does mean the quit has to reach here from the run loop
  /// rather than from inside a main-actor task, which would leave the main queue holding the
  /// task below; every route QuotaBar quits by — the panel's Quit item, ⌘Q, a Quit event, and
  /// logging out — is a run-loop one. Shutting the service down is bounded by the client's own
  /// liveness and kill escalation, so the reply always comes.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    self.model = nil
    Task { @MainActor in
      await model.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
