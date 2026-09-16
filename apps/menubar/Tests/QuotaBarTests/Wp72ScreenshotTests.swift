#if DEBUG
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import QuotaBar

  /// Renders the four Settings window pages WP 7.2 fills, at 720×520 in light and dark.
  /// Writes PNGs when `WP_72_SCREENSHOTS` is a directory.
  @MainActor
  struct Wp72ScreenshotTests {
    @Test
    func settingsWindowPagesRenderAtMinimumSizeInLightAndDark() throws {
      let dirPath = ProcessInfo.processInfo.environment["WP_72_SCREENSHOTS"] ?? ""
      let dir = dirPath.isEmpty ? nil : URL(fileURLWithPath: dirPath)
      if let dir {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }

      let size = QuotaDesign.Layout.settingsWindowMinSize
      let pages: [(route: String, fileStem: String, expandDiagnostics: Bool)] = [
        ("settings-account", "settings-account", false),
        ("settings-notifications", "settings-notifications", false),
        ("settings-general", "settings-general", false),
        ("settings-support", "settings-support", true),
      ]

      for page in pages {
        let configuration = try #require(
          VisualTestConfiguration(
            arguments: ["QuotaBar", "--fixture", "content", "--route", page.route]
          )
        )
        let model = configuration.makeModel()
        let diagnostics = configuration.makeDiagnosticsModel()
        for (scheme, appearance) in [(ColorScheme.light, "light"), (.dark, "dark")] {
          let image = try render(
            model: model,
            diagnostics: diagnostics,
            page: configuration.settingsPage,
            expandsDiagnostics: page.expandDiagnostics,
            scheme: scheme,
            size: size
          )
          #expect(image.size.width == size.width)
          #expect(image.size.height == size.height)
          if let dir {
            try write(
              image,
              to: dir.appendingPathComponent("\(page.fileStem)-\(appearance).png")
            )
          }
        }
      }
    }

    private func render(
      model: MenuBarViewModel,
      diagnostics: DiagnosticsPageModel,
      page: SettingsPage?,
      expandsDiagnostics: Bool,
      scheme: ColorScheme,
      size: CGSize
    ) throws -> NSImage {
      let root = SettingsWindowView(
        model: model,
        pageOverride: page,
        diagnostics: diagnostics,
        expandsDiagnostics: expandsDiagnostics
      )
      .environment(\.colorScheme, scheme)
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

    private func write(_ image: NSImage, to url: URL) throws {
      let tiff = try #require(image.tiffRepresentation)
      let pngRep = try #require(NSBitmapImageRep(data: tiff))
      let png = try #require(pngRep.representation(using: .png, properties: [:]))
      try png.write(to: url)
    }
  }
#endif
