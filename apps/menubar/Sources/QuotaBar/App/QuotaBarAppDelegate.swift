import AppKit

/// Quitting is the last moment QuotaBar can speak to its local service, and every route out of
/// the app — the panel's Quit item, ⌥⌘Q, Sparkle relaunch, Browser Access relaunch, ⌘Q, and
/// logging out — arrives at `applicationShouldTerminate`. A plain Quit while the main window is
/// open closes that window and keeps the menu bar; a full quit still asks the helper to exit
/// there rather than leaving it to the process dying, so a service that is mid-write finishes
/// before its pipe disappears. Closing the main window never quits; a Dock click or `open -a`
/// reopens it.
@MainActor
final class QuotaBarAppDelegate: NSObject, NSApplicationDelegate {
  private var model: MenuBarViewModel?
  private var statusItems: MenuBarStatusItemController?
  private var openedAsLoginItem = false

  func attach(model: MenuBarViewModel) {
    self.model = model
    MainWindowController.shared.attach(model: model)
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    WindowActivation.shared.applyDockVisibility()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The Open Application event is delivered between willFinishLaunching and here, so this is
    // the first moment `currentAppleEvent` names it; earlier it is nil and every launch would
    // read as manual.
    openedAsLoginItem = LaunchAtLoginController.launchedAsLoginItem
    QuotaBarMainMenu.install()
    startStatusItemsIfNeeded()
    switch LaunchPresentation.resolve(
      loginItem: openedAsLoginItem,
      opensWindow: LaunchWindowPreference.isOn,
      hasShownQuota: LaunchHasShownQuota.hasShown
    ) {
    case .silent:
      break
    case .mainWindow:
      MainWindowController.shared.show()
    case .panel:
      // The status item is created here but placed a beat later (it resizes in place, then
      // moves), and a panel opened against the first frame hangs off the wrong spot.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.statusItems?.openPanel(revealing: nil)
      }
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows _: Bool
  ) -> Bool {
    MainWindowController.shared.show()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// A desktop widget's `quotabar:` link, or `quotabar://dashboard`. Overview opens the panel as
  /// it stands; a subscription opens it scrolled to that subscription's provider. A link this
  /// installation never published — an old salt, a provider since removed — resolves to nothing
  /// and lands on Overview. `quotabar://dashboard` opens the main window on Quota.
  func application(_ application: NSApplication, open urls: [URL]) {
    startStatusItemsIfNeeded()
    guard let statusItems, let model else { return }
    for url in urls {
      guard let link = QuotaBarDeepLink.parse(url) else { continue }
      switch link {
      case .overview:
        statusItems.openPanel(revealing: nil)
      case .subscription(let id):
        statusItems.openPanel(revealing: model.provider(forWidgetSelectionID: id))
      case .dashboard:
        MainWindowController.shared.show(page: .quota)
      }
      return
    }
  }

  private func startStatusItemsIfNeeded() {
    guard statusItems == nil, let model else { return }
    statusItems = MenuBarStatusItemController(model: model)
    let closePanel: () -> Void = { [weak self] in
      self?.statusItems?.panel.close()
    }
    MainWindowController.shared.closePanel = closePanel
  }

  /// `terminateLater` is what makes an asynchronous last message possible: AppKit runs the run
  /// loop until `reply(toApplicationShouldTerminate:)`, so nothing here blocks the main thread
  /// waiting for the helper, and a logout still reads this app as agreeing to quit — which
  /// `terminateCancel` would not. It does mean the quit has to reach here from the run loop
  /// rather than from inside a main-actor task, which would leave the main queue holding the
  /// task below; every route QuotaBar quits by — the panel's Quit item, ⌥⌘Q, a Quit event, and
  /// logging out — is a run-loop one. The wait is capped by `MenuBarViewModel.shutdownDeadline`,
  /// so a wedged helper delays a quit by two seconds and then stops mattering: the reply always
  /// comes, and it is always yes.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    switch QuitDecision.resolve(
      windowPresented: MainWindowController.shared.isOpen,
      fullQuitRequested: QuitIntent.fullQuitRequested,
      systemQuit: QuitIntent.isSystemQuit
    ) {
    case .closeWindow:
      MainWindowController.shared.close()
      QuitKeepRunningExplanation.presentIfNeeded()
      return .terminateCancel
    case .terminate:
      break
    }
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
