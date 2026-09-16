#if DEBUG
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import QuotaBar

  /// Renders Dashboard at 960×640 and 1280×800 in light and dark. Writes PNGs when
  /// `WP_77_SCREENSHOTS` is a directory.
  @MainActor
  struct Wp77ScreenshotTests {
    @Test
    func dashboardRendersAtWindowSizesInLightAndDark() throws {
      let keys = [DashboardRange.storageKey, ResetCopyStylePreference.storageKey]
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
      UserDefaults.standard.set(
        DashboardRange.sevenDays.rawValue, forKey: DashboardRange.storageKey)
      UserDefaults.standard.set(
        ResetCopyStylePreference.fallback.rawValue,
        forKey: ResetCopyStylePreference.storageKey
      )

      let dirPath = ProcessInfo.processInfo.environment["WP_77_SCREENSHOTS"] ?? ""
      let dir = dirPath.isEmpty ? nil : URL(fileURLWithPath: dirPath)
      if let dir {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }

      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "dashboard"]
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let sizes: [(CGSize, String)] = [
        (QuotaDesign.Layout.dashboardWindowMinSize, "960x640"),
        (CGSize(width: 1280, height: 800), "1280x800"),
      ]
      for (size, label) in sizes {
        for (scheme, appearance) in [
          (ColorScheme.light, "light"),
          (.dark, "dark"),
        ] {
          let image = try render(
            model: model,
            now: configuration.referenceDate,
            scheme: scheme,
            size: size
          )
          #expect(image.size.width == size.width)
          #expect(image.size.height == size.height)
          if let dir {
            try write(
              image,
              to: dir.appendingPathComponent("dashboard-\(label)-\(appearance).png")
            )
          }
        }
      }
    }

    private func render(
      model: MenuBarViewModel,
      now: Date,
      scheme: ColorScheme,
      size: CGSize
    ) throws -> NSImage {
      let root = DashboardView(model: model, now: now)
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
