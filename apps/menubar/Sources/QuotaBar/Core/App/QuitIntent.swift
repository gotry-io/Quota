import AppKit

/// Routes that mean a real process exit, not “close the window and keep the
/// menu bar”. Panel **Quit QuotaBar**, **Quit QuotaBar Completely** ⌥⌘Q,
/// Browser Access relaunch, and Sparkle’s pre-relaunch hook set the flag
/// before `NSApp.terminate`.
@MainActor
enum QuitIntent {
  private(set) static var fullQuitRequested = false

  /// Open Application / Quit Apple Event keywords. `keyAEQuitReason` (`why?`)
  /// is present for log out, restart, and shut down — any value.
  nonisolated enum Event {
    static let coreEventClass = AEEventClass(0x6165_7674)  // 'aevt'
    static let quitApplication = AEEventID(0x7175_6974)  // 'quit'
    static let quitReason = AEKeyword(0x7768_793F)  // 'why?'
  }

  static func markFullQuitRequested() {
    fullQuitRequested = true
  }

  static func requestFullQuit() {
    markFullQuitRequested()
    NSApp.terminate(nil)
  }

  static func resetForTests() {
    fullQuitRequested = false
  }

  static var isSystemQuit: Bool {
    isSystemQuit(event: NSAppleEventManager.shared().currentAppleEvent)
  }

  /// A `kAEQuitApplication` event whose `keyAEQuitReason` param is present is
  /// a system quit. Tests construct the descriptor.
  nonisolated static func isSystemQuit(event: NSAppleEventDescriptor?) -> Bool {
    guard let event else { return false }
    guard event.eventClass == Event.coreEventClass,
      event.eventID == Event.quitApplication
    else { return false }
    return event.paramDescriptor(forKeyword: Event.quitReason) != nil
  }
}

/// Whether a terminate request should close the main window or exit.
enum QuitDecision: Equatable, Sendable {
  case closeWindow
  case terminate

  static func resolve(
    windowPresented: Bool,
    fullQuitRequested: Bool,
    systemQuit: Bool
  ) -> QuitDecision {
    if windowPresented && !fullQuitRequested && !systemQuit {
      return .closeWindow
    }
    return .terminate
  }
}

enum QuitKeepRunningCopy {
  static let title = "QuotaBar is still running in the menu bar"
  static let message =
    "Closing the window keeps your quota in the menu bar. To quit completely, choose Quit QuotaBar from the menu bar panel, or press ⌥⌘Q."
  static let ok = "OK"
  static let quitCompletely = "Quit Completely"
}

/// One-time explanation that ⌘Q with the window open keeps the menu bar.
@MainActor
enum QuitKeepRunningExplanation {
  static let storageKey = "quit.keepRunningExplained"

  enum Choice: Equatable, Sendable {
    case acknowledged
    case quitCompletely
  }

  /// Default presents an informational `NSAlert`. Tests replace this with a
  /// recorder so `swift test` never puts a panel on screen.
  static var present: @MainActor () -> Choice = presentDefaultAlert

  static func presentIfNeeded() {
    guard UserDefaults.standard.object(forKey: storageKey) == nil else { return }
    UserDefaults.standard.set(true, forKey: storageKey)
    if present() == .quitCompletely {
      DispatchQueue.main.async {
        QuitIntent.requestFullQuit()
      }
    }
  }

  private static func presentDefaultAlert() -> Choice {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = QuitKeepRunningCopy.title
    alert.informativeText = QuitKeepRunningCopy.message
    alert.addButton(withTitle: QuitKeepRunningCopy.ok)
    alert.addButton(withTitle: QuitKeepRunningCopy.quitCompletely)
    return alert.runModal() == .alertSecondButtonReturn ? .quitCompletely : .acknowledged
  }
}
