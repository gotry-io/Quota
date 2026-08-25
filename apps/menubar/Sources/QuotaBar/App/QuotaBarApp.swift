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
          performsSupportCheckOnEntry: visualTestConfiguration.dataSource == .live,
          supportModel: visualTestConfiguration.makeSupportModel(),
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
      } label: {
        QuotaMenuBarLabel(label: model.menuBarLabel(preference: menuBarDisplay))
      }
      .menuBarExtraStyle(.window)
    }
  #endif
}
