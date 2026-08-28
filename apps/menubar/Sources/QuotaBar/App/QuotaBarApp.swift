import SwiftUI

import AppKit

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
        // The production panel has no title-bar safe area. Match that geometry in the ordinary
        // Visual QA window so large text cannot be obscured by hidden title-bar chrome.
        .ignoresSafeArea()
        // The production panel supplies material. The ordinary Visual QA window instead
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

    init() {
      let model = MenuBarViewModel()
      model.start()
      appDelegate.attach(model: model)
      Task { @MainActor in
        QuotaBarUpdater.start()
      }
    }

    var body: some Scene {
      // SwiftUI App requires a Scene. Status items and the panel are AppKit-owned; this
      // empty Settings scene is only the process lifetime, not a settings page.
      Settings {
        EmptyView()
      }
    }
  #endif
}
