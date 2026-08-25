import SwiftUI

import AppKit

#if !VISUAL_TEST
  @MainActor
  final class QuotaBarAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MenuBarViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      guard let model, model.repairBlocksQuit else { return .terminateNow }
      model.presentRepairPageFromQuitAttempt()
      NSAccessibility.post(
        element: sender,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "QuotaBar is repairing local data. Keep the app open.",
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
      )
      return .terminateCancel
    }
  }
#endif

@main
struct QuotaBarApp: App {
  #if VISUAL_TEST
    @State private var model: MenuBarViewModel
    private let visualTestConfiguration: VisualTestConfiguration

    init() {
      let arguments = ProcessInfo.processInfo.arguments
      guard
        let configuration = VisualTestConfiguration(
          arguments: arguments
        )
      else {
        fatalError("Invalid Visual QA arguments.")
      }
      visualTestConfiguration = configuration
      configuration.prepareEnvironment()
      _model = State(initialValue: configuration.makeModel())
    }

    var body: some Scene {
      WindowGroup("QuotaBar Visual QA") {
        MenuBarContentView(
          model: model,
          initialPath: visualTestConfiguration.initialPath,
          performsInitialRefresh: visualTestConfiguration.performsInitialRefresh,
          performsDiagnosticsCheckOnEntry: visualTestConfiguration.dataSource == .live,
          diagnosticsModel: visualTestConfiguration.makeDiagnosticsModel(),
          seedsLaunchAtLogin: false
        )
        .preferredColorScheme(visualTestConfiguration.colorScheme)
        .dynamicTypeSize(visualTestConfiguration.dynamicTypeSize)
        // A MenuBarExtra panel has no title-bar safe area. Match that geometry in the ordinary
        // Visual QA window so large text cannot be obscured by hidden title-bar chrome.
        .ignoresSafeArea()
        // MenuBarExtra supplies material in production. The ordinary Visual QA window instead
        // uses an opaque system background for deterministic rendering.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
          NSApplication.shared.setActivationPolicy(.regular)
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
      }
      .windowResizability(.contentSize)
      .windowStyle(.hiddenTitleBar)
    }
  #else
    @NSApplicationDelegateAdaptor(QuotaBarAppDelegate.self) private var appDelegate
    @State private var model: MenuBarViewModel
    @AppStorage(MenuBarDisplayPreference.storageKey) private var menuBarDisplay =
      MenuBarDisplayPreference.fallback

    init() {
      let model = MenuBarViewModel()
      model.start()
      _model = State(initialValue: model)
      Task { @MainActor in
        QuotaBarUpdater.start()
      }
    }

    var body: some Scene {
      MenuBarExtra {
        MenuBarContentView(model: model)
          .onAppear { appDelegate.model = model }
      } label: {
        QuotaMenuBarLabel(label: model.menuBarLabel(preference: menuBarDisplay))
      }
      .menuBarExtraStyle(.window)
    }
  #endif
}
