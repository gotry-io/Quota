#if DEBUG
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import QuotaBar

  /// Renders the close-out Visual QA matrix: every route × light/dark × standard/accessibility.
  /// Writes PNGs when `QUOTABAR_SCREENSHOTS` is a directory.
  @MainActor
  struct VisualMatrixScreenshotTests {
    @Test
    func closeoutVisualMatrixRendersEveryRouteInLightAndDarkAtStandardAndAccessibility() throws {
      let keys = [
        MainPage.storageKey,
        MainPage.agentsProviderStorageKey,
        DashboardRange.storageKey,
        ResetCopyStylePreference.storageKey,
        DockVisibilityPreference.storageKey,
        LaunchWindowPreference.storageKey,
        LaunchHasShownQuota.storageKey,
      ]
      let previous = Dictionary(
        uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
      )
      defer {
        for (key, value) in previous {
          if let value {
            UserDefaults.standard.set(value, forKey: key)
          } else {
            UserDefaults.standard.removeObject(forKey: key)
          }
        }
      }

      let dirPath = ProcessInfo.processInfo.environment["QUOTABAR_SCREENSHOTS"] ?? ""
      // Rendering the 60-cell matrix inside the default parallel suite starves the wait-loop
      // tests on a slow runner, so capture is opt-in: `swift test` without the env var is a
      // no-op, and scripts/test-swift.sh runs this test alone, afterwards, with it set.
      guard !dirPath.isEmpty else { return }
      let dir = URL(fileURLWithPath: dirPath)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      let routes = [
        "overview",
        "provider-codex",
        "main-quota",
        "main-quota-codex",
        "main-today",
        "main-usage",
        "main-usage-local",
        "main-account",
        "main-agents",
        "main-agents-codex",
        "main-agents-litellm-key",
        "main-notifications",
        "main-menu-bar",
        "main-general",
        "main-support",
      ]
      let appearances: [(ColorScheme, String)] = [(.light, "light"), (.dark, "dark")]
      let textSizes: [(DynamicTypeSize, String)] = [
        (.large, "standard"),
        (.accessibility3, "accessibility"),
      ]

      for route in routes {
        let configuration = try #require(
          VisualTestConfiguration(
            arguments: ["QuotaBar", "--fixture", "content", "--route", route]
          )
        )
        configuration.prepareEnvironment()
        let model = configuration.makeModel()
        if configuration.mainPage?.isQuotaGroup == true {
          model.selectUsagePeriod(.last7Days)
        }
        for (size, suffix) in captureSizes(for: configuration, route: route) {
          for (scheme, appearance) in appearances {
            for (textSize, textName) in textSizes {
              let image = try render(
                configuration: configuration,
                model: model,
                scheme: scheme,
                textSize: textSize,
                size: size
              )
              #expect(image.size.width == size.width)
              #expect(image.size.height == size.height)
              try write(
                image,
                to: dir.appendingPathComponent("\(route)\(suffix)-\(appearance)-\(textName).png")
              )
            }
          }
        }
      }
    }

    private func captureSize(for configuration: VisualTestConfiguration) -> CGSize {
      if configuration.hostsMainWindow {
        if configuration.route == .mainUsage || configuration.route == .mainUsageLocal {
          return CGSize(width: QuotaDesign.Layout.mainWindowMinSize.width, height: 2_200)
        }
        return QuotaDesign.Layout.mainWindowMinSize
      }
      return CGSize(
        width: QuotaDesign.Layout.panelWidth,
        height: QuotaDesign.Layout.panelMaxHeight
      )
    }

    /// Existing sizes stay; `main-quota` also renders at 1280×800 for the wide card layout.
    private func captureSizes(
      for configuration: VisualTestConfiguration,
      route: String
    ) -> [(CGSize, String)] {
      let base = captureSize(for: configuration)
      if route == "main-quota" {
        return [
          (base, ""),
          (QuotaDesign.Layout.mainWindowWideSize, "-1280x800"),
        ]
      }
      return [(base, "")]
    }

    private func render(
      configuration: VisualTestConfiguration,
      model: MenuBarViewModel,
      scheme: ColorScheme,
      textSize: DynamicTypeSize,
      size: CGSize
    ) throws -> NSImage {
      let root = matrixRoot(configuration: configuration, model: model)
        .environment(\.colorScheme, scheme)
        .dynamicTypeSize(textSize)
        .frame(width: size.width, height: size.height)
      let host = NSHostingView(rootView: root)
      host.frame = NSRect(origin: .zero, size: size)
      // Sidebar `List` is an AppKit outline view and does not draw cells unless it
      // lives in a window. Park it off-screen; do not order it front.
      // Liquid Glass is composited by the window server, so an off-screen bitmap shows no
      // glass at all (a white sidebar, cards without a surface). With
      // QUOTABAR_SCREENSHOTS_ONSCREEN the window is ordered front and captured through the
      // window server instead; scripts/test-swift.sh sets it, so CI's macOS 26 runner
      // produces real renders. Locally the off-screen bitmap stays the default.
      let onScreen = ProcessInfo.processInfo.environment["QUOTABAR_SCREENSHOTS_ONSCREEN"] == "1"
      let origin = onScreen ? NSPoint(x: 40, y: 40) : NSPoint(x: -10_000, y: -10_000)
      let window = NSWindow(
        contentRect: NSRect(origin: origin, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = host
      window.setContentSize(size)
      host.layoutSubtreeIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      defer {
        window.contentView = nil
        window.close()
      }
      if onScreen {
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let captured = Self.captureFromWindowServer(window, contentSize: size) {
          return captured
        }
      }
      let bounds = host.bounds
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
      host.cacheDisplay(in: bounds, to: rep)
      let image = NSImage(size: bounds.size)
      image.addRepresentation(rep)
      return image
    }

    /// The window as the window server shows it, cropped to the content view; nil when the
    /// process may not read the screen (then the caller keeps the off-screen bitmap).
    private static func captureFromWindowServer(_ window: NSWindow, contentSize: CGSize) -> NSImage? {
      let id = CGWindowID(window.windowNumber)
      guard
        let full = CGWindowListCreateImage(
          .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
      else { return nil }
      let scale = window.backingScaleFactor
      let contentHeight = Int(contentSize.height * scale)
      let contentWidth = Int(contentSize.width * scale)
      // `boundsIgnoreFraming` still includes the title bar; the content view is the bottom part.
      let cropY = max(0, full.height - contentHeight)
      guard
        let cropped = full.cropping(
          to: CGRect(x: 0, y: cropY, width: min(contentWidth, full.width), height: min(contentHeight, full.height - cropY)))
      else { return nil }
      return NSImage(cgImage: cropped, size: contentSize)
    }

    @ViewBuilder
    private func matrixRoot(
      configuration: VisualTestConfiguration,
      model: MenuBarViewModel
    ) -> some View {
      if configuration.hostsMainWindow {
        MainWindowView(
          model: model,
          pageOverride: configuration.mainPage,
          diagnostics: configuration.makeDiagnosticsModel(),
          expandsDiagnostics: configuration.route == .mainSupport,
          initialAgentsProvider: configuration.agentsProvider,
          now: configuration.referenceDate,
          initialSelection: configuration.quotaSelection,
          initialUsageSource: configuration.usageSource
        )
      } else {
        MenuBarContentView(
          model: model,
          initialPath: configuration.initialPath,
          performsInitialRefresh: false,
          seedsLaunchAtLogin: false
        )
      }
    }

    private func write(_ image: NSImage, to url: URL) throws {
      let tiff = try #require(image.tiffRepresentation)
      let pngRep = try #require(NSBitmapImageRep(data: tiff))
      let png = try #require(pngRep.representation(using: .png, properties: [:]))
      try png.write(to: url)
    }
  }
#endif
