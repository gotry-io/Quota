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
        SettingsPage.storageKey,
        SettingsPage.agentsProviderStorageKey,
        DashboardRange.storageKey,
        ResetCopyStylePreference.storageKey,
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
        "settings-window",
        "settings-account",
        "settings-agents",
        "settings-agents-codex",
        "settings-agents-litellm-key",
        "settings-notifications",
        "settings-menu-bar",
        "settings-general",
        "settings-support",
        "dashboard",
        "dashboard-codex",
        "dashboard-usage",
        "dashboard-usage-local",
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
        if configuration.hostsDashboardWindow {
          model.selectUsagePeriod(.last7Days)
        }
        let size = captureSize(for: configuration)
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
              to: dir.appendingPathComponent("\(route)-\(appearance)-\(textName).png")
            )
          }
        }
      }
    }

    private func captureSize(for configuration: VisualTestConfiguration) -> CGSize {
      if configuration.hostsDashboardWindow {
        if configuration.route == .dashboardUsage || configuration.route == .dashboardUsageLocal {
          return CGSize(width: QuotaDesign.Layout.dashboardWindowMinSize.width, height: 2_200)
        }
        return QuotaDesign.Layout.dashboardWindowMinSize
      }
      if configuration.hostsSettingsWindow {
        return QuotaDesign.Layout.settingsWindowMinSize
      }
      return CGSize(
        width: QuotaDesign.Layout.panelWidth,
        height: QuotaDesign.Layout.panelMaxHeight
      )
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
      host.layoutSubtreeIfNeeded()
      let bounds = host.bounds
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
      host.cacheDisplay(in: bounds, to: rep)
      let image = NSImage(size: bounds.size)
      image.addRepresentation(rep)
      return image
    }

    @ViewBuilder
    private func matrixRoot(
      configuration: VisualTestConfiguration,
      model: MenuBarViewModel
    ) -> some View {
      if configuration.hostsDashboardWindow {
        DashboardView(
          model: model,
          now: configuration.referenceDate,
          initialSelection: configuration.dashboardSelection,
          initialUsageSource: configuration.dashboardUsageSource
        )
      } else if configuration.hostsSettingsWindow {
        SettingsWindowView(
          model: model,
          pageOverride: configuration.settingsPage ?? .account,
          diagnostics: configuration.makeDiagnosticsModel(),
          expandsDiagnostics: configuration.route == .settingsSupport,
          initialAgentsProvider: configuration.settingsAgentsProvider,
          now: configuration.referenceDate
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
