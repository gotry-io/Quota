import SwiftUI

#if VISUAL_TEST
  import AppKit
#endif

@main
struct QuotaBarApp: App {
  #if VISUAL_TEST
    @State private var model: MenuBarViewModel
    private let visualTestConfiguration: VisualTestConfiguration
    private let relayAcceptanceConfiguration: RelayAcceptanceConfiguration?

    init() {
      let arguments = ProcessInfo.processInfo.arguments
      guard
        let configuration = VisualTestConfiguration(
          arguments: arguments
        )
      else {
        fatalError("Invalid Visual QA arguments.")
      }
      let relayAcceptanceRequested = arguments.contains(RelayAcceptanceConfiguration.flag)
      let relayAcceptance = RelayAcceptanceConfiguration(arguments: arguments)
      guard !relayAcceptanceRequested || relayAcceptance != nil else {
        fatalError("Invalid Relay acceptance arguments.")
      }
      visualTestConfiguration = configuration
      relayAcceptanceConfiguration = relayAcceptance
      configuration.prepareEnvironment()
      _model = State(
        initialValue: relayAcceptance?.makeModel() ?? configuration.makeModel()
      )
    }

    var body: some Scene {
      WindowGroup("QuotaBar Visual QA") {
        MenuBarContentView(
          model: model,
          initialPath: visualTestConfiguration.initialPath,
          performsInitialRefresh: visualTestConfiguration.performsInitialRefresh,
          performsRelayRefreshes: visualTestConfiguration.performsRelayRefreshes
        )
        .background(.regularMaterial)
        .preferredColorScheme(visualTestConfiguration.colorScheme)
        .dynamicTypeSize(visualTestConfiguration.dynamicTypeSize)
        .onAppear {
          NSApplication.shared.setActivationPolicy(.regular)
          NSApplication.shared.activate(ignoringOtherApps: true)
          if let relayAcceptanceConfiguration {
            RelayAcceptanceRunner.start(
              configuration: relayAcceptanceConfiguration,
              model: model
            )
          } else if let screenshotOutputPath = visualTestConfiguration.screenshotOutputPath {
            VisualTestWindowCapture.schedule(to: screenshotOutputPath)
          }
        }
      }
      .windowResizability(.contentSize)
      .windowStyle(.hiddenTitleBar)
    }
  #else
    @State private var model: MenuBarViewModel

    init() {
      let model = MenuBarViewModel()
      model.relayStateModel.startPolling()
      _model = State(initialValue: model)
    }

    var body: some Scene {
      MenuBarExtra("QuotaBar", systemImage: "gauge.with.dots.needle.50percent") {
        MenuBarContentView(model: model)
      }
      .menuBarExtraStyle(.window)
    }
  #endif
}

#if VISUAL_TEST
  /// Captures this process's own window contentView without Screen Recording.
  @MainActor
  enum VisualTestWindowCapture {
    private static let maxAttempts = 25
    private static let retryDelay: TimeInterval = 0.2
    private static let initialDelay: TimeInterval = 0.5
    private static let minimumEdge: CGFloat = 300

    static func schedule(to url: URL, attempt: Int = 0) {
      let delay = attempt == 0 ? initialDelay : retryDelay
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay))
        switch capture(to: url) {
        case .succeeded, .failed:
          return
        case .notReady:
          if attempt + 1 < maxAttempts {
            schedule(to: url, attempt: attempt + 1)
          } else {
            reportFailure()
          }
        }
      }
    }

    private enum CaptureResult {
      case succeeded
      case failed
      case notReady
    }

    private static func capture(to url: URL) -> CaptureResult {
      guard let contentView = targetContentView() else { return .notReady }
      let bounds = contentView.bounds
      guard bounds.width >= minimumEdge, bounds.height >= minimumEdge else {
        return .notReady
      }
      guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
        reportFailure()
        return .failed
      }
      contentView.cacheDisplay(in: bounds, to: rep)
      guard let pngData = rep.representation(using: .png, properties: [:]), !pngData.isEmpty else {
        reportFailure()
        return .failed
      }

      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        // Atomic same-directory write: the final path appears only after a complete PNG.
        try pngData.write(to: url, options: .atomic)
        return .succeeded
      } catch {
        reportFailure()
        return .failed
      }
    }

    private static func targetContentView() -> NSView? {
      NSApplication.shared.windows
        .first { $0.isVisible && $0.title == "QuotaBar Visual QA" }?
        .contentView
    }

    private static func reportFailure() {
      fputs("visual screenshot capture failed\n", stderr)
    }
  }
#endif
