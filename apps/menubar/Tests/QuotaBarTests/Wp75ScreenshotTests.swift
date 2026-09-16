#if DEBUG
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import QuotaBar

  /// Renders Overview at 320×480 with the overflow menu open, in light and dark.
  /// Writes PNGs when `WP_75_SCREENSHOTS` is a directory.
  @MainActor
  struct Wp75ScreenshotTests {
    @Test
    func overviewWithOverflowMenuOpenRendersAtPanelSizeInLightAndDark() throws {
      let dirPath = ProcessInfo.processInfo.environment["WP_75_SCREENSHOTS"] ?? ""
      let dir = dirPath.isEmpty ? nil : URL(fileURLWithPath: dirPath)
      if let dir {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }

      let size = CGSize(
        width: QuotaDesign.Layout.panelWidth,
        height: QuotaDesign.Layout.panelMaxHeight
      )
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "overview"]
        )
      )
      let model = configuration.makeModel()
      for (scheme, name) in [
        (ColorScheme.light, "overview-overflow-light.png"),
        (.dark, "overview-overflow-dark.png"),
      ] {
        let image = try render(model: model, scheme: scheme, size: size)
        #expect(image.size.width == size.width)
        #expect(image.size.height == size.height)
        if let dir {
          try write(image, to: dir.appendingPathComponent(name))
        }
      }
    }

    private func render(
      model: MenuBarViewModel,
      scheme: ColorScheme,
      size: CGSize
    ) throws -> NSImage {
      let root = MenuBarContentView(
        model: model,
        performsInitialRefresh: false,
        seedsLaunchAtLogin: false,
        overflowMenuStartsExpanded: true
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
