import BackgroundTasks
import Foundation

/// The background account refresh. The app process wakes, reads the account summary through the
/// same `AccountClient` path a pull-to-refresh takes, and republishes the App Group widget
/// snapshot. The WidgetKit extension still only reads that file and never fetches
/// (`docs/decisions/0014-nonsecret-ios-widget-snapshot.md`).
enum BackgroundRefresh {
  /// Must match `BGTaskSchedulerPermittedIdentifiers` in `Sources/Info.plist`.
  static let taskIdentifier = "io.gotry.quota.refresh"

  /// The earliest instant the app asks to be woken at. Collecting Macs poll every five minutes
  /// and Relay resolves the account from what they last sent, so waking the phone more often
  /// than every half hour spends battery on a number that has barely moved.
  static let earliestInterval: TimeInterval = 30 * 60

  /// Register the launch handler for a scheduled background refresh. `BGTaskScheduler` refuses
  /// a registration made after launch finishes, and `QuotaApp.init` runs inside launch.
  @MainActor
  static func register(model: AppModel) {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: taskIdentifier,
      using: .main
    ) { task in
      // Registered against the main queue, so the launch handler already runs on the main actor.
      MainActor.assumeIsolated { run(task, model: model) }
    }
  }

  /// Run one background refresh and report its outcome to the system. A refresh that does not
  /// reach Relay completes the task unsuccessfully and says nothing: the on-screen app already
  /// states a failed refresh when the user opens it.
  @MainActor
  static func run(_ task: BGTask, model: AppModel) {
    let work = Task { @MainActor in
      task.setTaskCompleted(success: await model.refresh())
    }
    // Cancelling ends the Relay read, which returns a failure result, so the task is completed
    // exactly once whether it finishes or the system cuts it short.
    task.expirationHandler = { work.cancel() }
  }
}

/// Asking the system for the next background refresh window. `AppModel` schedules through this
/// so the refresh both entry points share stays testable without `BGTaskScheduler`.
protocol BackgroundRefreshScheduling: Sendable {
  func scheduleNextRefresh()
}

struct NoOpBackgroundRefreshScheduler: BackgroundRefreshScheduling {
  func scheduleNextRefresh() {}
}

struct SystemBackgroundRefreshScheduler: BackgroundRefreshScheduling {
  func scheduleNextRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundRefresh.earliestInterval)
    // A pending request for this identifier is replaced, so submitting again is how the window
    // moves forward. Simulators, and devices where the user turned Background App Refresh off,
    // refuse the submission; there is nothing to tell the user, and foreground refresh is
    // unaffected.
    try? BGTaskScheduler.shared.submit(request)
  }
}
