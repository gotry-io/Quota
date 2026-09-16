#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuotaBar

/// Renders the Settings window Menu Bar form at 720×520 in light and dark. Writes PNGs when
/// `WP_74_SCREENSHOTS` is a directory.
@MainActor
struct Wp74ScreenshotTests {
  @Test
  func menuBarSettingsFormRendersAtMinimumSizeInLightAndDark() throws {
    let keys = [
      "settings.page",
      MenuBarStylePreference.storageKey,
      MenuBarProviderPreference.storageKey,
      MenuBarArrangementPreference.storageKey,
      ResetCopyStylePreference.storageKey,
      PaceLinePreference.storageKey,
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

    UserDefaults.standard.set(SettingsPage.menuBar.rawValue, forKey: "settings.page")
    UserDefaults.standard.set(
      MenuBarStylePreference.fallback.rawValue,
      forKey: MenuBarStylePreference.storageKey
    )
    UserDefaults.standard.set(
      MenuBarProviderPreference.automatic.rawValue,
      forKey: MenuBarProviderPreference.storageKey
    )
    UserDefaults.standard.set(
      MenuBarArrangementPreference.fallback.rawValue,
      forKey: MenuBarArrangementPreference.storageKey
    )
    UserDefaults.standard.set(
      ResetCopyStylePreference.fallback.rawValue,
      forKey: ResetCopyStylePreference.storageKey
    )
    UserDefaults.standard.set(
      PaceLinePreference.fallback,
      forKey: PaceLinePreference.storageKey
    )

    let dirPath = ProcessInfo.processInfo.environment["WP_74_SCREENSHOTS"] ?? ""
    let dir = dirPath.isEmpty ? nil : URL(fileURLWithPath: dirPath)
    if let dir {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let (model, now) = try fixtureModel()
    let size = QuotaDesign.Layout.settingsWindowMinSize
    for (scheme, name) in [
      (ColorScheme.light, "settings-menu-bar-light.png"),
      (.dark, "settings-menu-bar-dark.png"),
    ] {
      let image = try render(model: model, now: now, scheme: scheme, size: size)
      #expect(image.size.width == size.width)
      #expect(image.size.height == size.height)
      if let dir {
        try write(image, to: dir.appendingPathComponent(name))
      }
    }
  }

  private func fixtureModel() throws -> (MenuBarViewModel, Date) {
    let configuration = try #require(
      VisualTestConfiguration(
        arguments: [
          "QuotaBar", "--fixture", "content", "--route", "settings-menu-bar",
        ]
      )
    )
    configuration.prepareEnvironment()
    return (configuration.makeModel(), configuration.referenceDate)
  }

  private func render(
    model: MenuBarViewModel,
    now: Date,
    scheme: ColorScheme,
    size: CGSize
  ) throws -> NSImage {
    let root = SettingsWindowView(model: model, initialPage: .menuBar, now: now)
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
