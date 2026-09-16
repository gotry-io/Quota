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
      // SceneBuilder on macOS 14 cannot `if` between window styles, so one
      // WindowGroup hosts the panel, Settings, and Dashboard roots. Titled
      // windows keep the default chrome; panel routes hide the title bar.
      WindowGroup(visualWindowTitle) {
        visualRoot
          .preferredColorScheme(visualTestConfiguration.colorScheme)
          .dynamicTypeSize(visualTestConfiguration.dynamicTypeSize)
          .background(Color(nsColor: .windowBackgroundColor))
          .background(
            VisualTestWindowChrome(
              hiddenTitleBar: !visualTestConfiguration.hostsTitledWindow
            )
          )
          .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
      }
      .defaultSize(
        width: visualWindowSize.width,
        height: visualWindowSize.height
      )
      .windowResizability(
        visualTestConfiguration.hostsTitledWindow ? .automatic : .contentSize
      )
    }

    private var visualWindowTitle: String {
      if visualTestConfiguration.hostsDashboardWindow {
        "QuotaBar Dashboard"
      } else if visualTestConfiguration.hostsSettingsWindow {
        "QuotaBar Settings"
      } else {
        "QuotaBar Visual QA"
      }
    }

    private var visualWindowSize: CGSize {
      if visualTestConfiguration.hostsDashboardWindow {
        QuotaDesign.Layout.dashboardWindowMinSize
      } else if visualTestConfiguration.hostsSettingsWindow {
        QuotaDesign.Layout.settingsWindowMinSize
      } else {
        CGSize(
          width: QuotaDesign.Layout.panelWidth,
          height: QuotaDesign.Layout.panelMaxHeight
        )
      }
    }

    @ViewBuilder
    private var visualRoot: some View {
      if visualTestConfiguration.hostsDashboardWindow {
        DashboardView(
          model: model,
          now: visualTestConfiguration.dataSource == .fixture
            ? visualTestConfiguration.referenceDate : nil,
          initialSelection: visualTestConfiguration.dashboardSelection,
          initialUsageSource: visualTestConfiguration.dashboardUsageSource
        )
      } else if visualTestConfiguration.hostsSettingsWindow {
        SettingsWindowView(
          model: model,
          pageOverride: visualTestConfiguration.settingsPage,
          diagnostics: visualTestConfiguration.makeDiagnosticsModel(),
          expandsDiagnostics: visualTestConfiguration.route == .settingsSupport,
          initialAgentsProvider: visualTestConfiguration.settingsAgentsProvider,
          now: visualTestConfiguration.dataSource == .fixture
            ? visualTestConfiguration.referenceDate : nil
        )
      } else {
        MenuBarContentView(
          model: model,
          initialPath: visualTestConfiguration.initialPath,
          performsInitialRefresh: visualTestConfiguration.performsInitialRefresh,
          seedsLaunchAtLogin: false
        )
        // The production panel has no title-bar safe area. Match that geometry
        // so large text cannot be obscured by hidden title-bar chrome.
        .ignoresSafeArea()
      }
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

#if VISUAL_TEST
  /// Applies hidden-title-bar chrome for panel Visual QA. Settings and Dashboard
  /// use the WindowGroup's ordinary titled style.
  private struct VisualTestWindowChrome: NSViewRepresentable {
    var hiddenTitleBar: Bool

    func makeNSView(context: Context) -> NSView {
      NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      DispatchQueue.main.async {
        guard let window = nsView.window else { return }
        if hiddenTitleBar {
          window.titleVisibility = .hidden
          window.titlebarAppearsTransparent = true
          window.styleMask.insert(.fullSizeContentView)
        } else {
          window.titleVisibility = .visible
          window.titlebarAppearsTransparent = false
          window.styleMask.remove(.fullSizeContentView)
        }
      }
    }
  }
#endif
