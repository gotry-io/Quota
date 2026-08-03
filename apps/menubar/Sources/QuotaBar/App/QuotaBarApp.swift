import SwiftUI

#if VISUAL_TEST
  import AppKit
#endif

@main
struct QuotaBarApp: App {
  #if VISUAL_TEST
    @State private var model: MenuBarViewModel
    private let visualTestConfiguration: VisualTestConfiguration

    init() {
      guard
        let configuration = VisualTestConfiguration(
          arguments: ProcessInfo.processInfo.arguments
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
          performsInitialRefresh: visualTestConfiguration.performsInitialRefresh
        )
        .background(.regularMaterial)
        .preferredColorScheme(visualTestConfiguration.colorScheme)
        .dynamicTypeSize(visualTestConfiguration.dynamicTypeSize)
        .onAppear {
          NSApplication.shared.setActivationPolicy(.regular)
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
      }
      .windowResizability(.contentSize)
      .windowStyle(.hiddenTitleBar)
    }
  #else
    @State private var model = MenuBarViewModel()

    var body: some Scene {
      MenuBarExtra("QuotaBar", systemImage: "gauge.with.dots.needle.50percent") {
        MenuBarContentView(model: model)
      }
      .menuBarExtraStyle(.window)
    }
  #endif
}
