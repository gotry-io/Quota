import AppKit
import Foundation
import QuotaWire
import SwiftUI
import Testing

@testable import QuotaBar

/// Renders the Settings window Agents page with a provider selected, at 720×520 and
/// 1100×700, light and dark. Writes PNGs when `WP_73_SCREENSHOTS` is a directory.
@MainActor
struct Wp73ScreenshotTests {
  @Test
  func agentsPageRendersWithAProviderSelectedInLightAndDark() throws {
    let pageKey = SettingsPage.storageKey
    let providerKey = SettingsPage.agentsProviderStorageKey
    let previousPage = UserDefaults.standard.object(forKey: pageKey)
    let previousProvider = UserDefaults.standard.object(forKey: providerKey)
    UserDefaults.standard.set(SettingsPage.agents.rawValue, forKey: pageKey)
    UserDefaults.standard.set(ProviderID.codex.rawValue, forKey: providerKey)
    defer {
      if let previousPage {
        UserDefaults.standard.set(previousPage, forKey: pageKey)
      } else {
        UserDefaults.standard.removeObject(forKey: pageKey)
      }
      if let previousProvider {
        UserDefaults.standard.set(previousProvider, forKey: providerKey)
      } else {
        UserDefaults.standard.removeObject(forKey: providerKey)
      }
    }

    let configuration = try #require(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--fixture", "content", "--route", "settings-agents-codex"]
      )
    )
    configuration.prepareEnvironment()
    let model = configuration.makeModel()

    let dirPath = ProcessInfo.processInfo.environment["WP_73_SCREENSHOTS"] ?? ""
    let dir = dirPath.isEmpty ? nil : URL(fileURLWithPath: dirPath)
    if let dir {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let sizes: [(CGSize, String)] = [
      (QuotaDesign.Layout.settingsWindowMinSize, "720x520"),
      (CGSize(width: 1100, height: 700), "1100x700"),
    ]
    for (size, sizeName) in sizes {
      for (scheme, appearance) in [
        (ColorScheme.light, "light"),
        (.dark, "dark"),
      ] {
        let image = try render(model: model, scheme: scheme, size: size)
        #expect(image.size.width == size.width)
        #expect(image.size.height == size.height)
        if let dir {
          try write(
            image,
            to: dir.appendingPathComponent("settings-agents-\(sizeName)-\(appearance).png")
          )
        }
      }
    }
  }

  private func render(
    model: MenuBarViewModel,
    scheme: ColorScheme,
    size: CGSize
  ) throws -> NSImage {
    let root = SettingsWindowView(model: model, initialAgentsProvider: .codex)
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
