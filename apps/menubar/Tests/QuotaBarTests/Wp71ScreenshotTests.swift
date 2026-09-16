import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuotaBar

/// Renders `SettingsWindowView` at 720×520 in light and dark. Writes PNGs when
/// `WP_71_SCREENSHOTS` is a directory.
@MainActor
struct Wp71ScreenshotTests {
  @Test
  func settingsWindowViewRendersAtMinimumSizeInLightAndDark() throws {
    let key = "settings.page"
    let previous = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(SettingsPage.account.rawValue, forKey: key)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    let dirPath = ProcessInfo.processInfo.environment["WP_71_SCREENSHOTS"] ?? ""
    let dir = dirPath.isEmpty ? nil : URL(fileURLWithPath: dirPath)
    if let dir {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let size = QuotaDesign.Layout.settingsWindowMinSize
    for (scheme, name) in [
      (ColorScheme.light, "settings-window-light.png"),
      (.dark, "settings-window-dark.png"),
    ] {
      let image = try render(scheme: scheme, size: size)
      #expect(image.size.width == size.width)
      #expect(image.size.height == size.height)
      if let dir {
        try write(image, to: dir.appendingPathComponent(name))
      }
    }
  }

  private func render(scheme: ColorScheme, size: CGSize) throws -> NSImage {
    let root = SettingsWindowView()
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
