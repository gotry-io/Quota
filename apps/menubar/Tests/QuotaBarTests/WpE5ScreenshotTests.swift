import AppKit
import Foundation
import QuotaWire
import SwiftUI
import Testing

@testable import QuotaBar

/// Writes the WP-E5 Settings › Agents screenshot when `WP_E5_SCREENSHOTS` is a directory.
@MainActor
struct WpE5ScreenshotTests {
  @Test
  func exportAgentsSettingsWhenAsked() throws {
    let path = ProcessInfo.processInfo.environment["WP_E5_SCREENSHOTS"] ?? ""
    guard !path.isEmpty else { return }
    let dir = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let shown = ProviderID.allCases.filter(\.defaultVisible)
    let hidden = ProviderID.allCases.filter { !$0.defaultVisible }
    try writeView(
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Shown in Overview") {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { provider in
              row(provider, subtitle: "Not set up on this Mac")
            }
          }
        }
        SettingsSection(title: "Hidden from Overview") {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(hidden) { provider in
              row(provider, subtitle: "Hidden from Overview")
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading),
      to: dir.appendingPathComponent("settings-agents.png")
    )
  }

  private func row(_ provider: ProviderID, subtitle: String) -> some View {
    SettingsListRow(
      title: provider.displayName,
      subtitle: subtitle,
      height: QuotaDesign.Layout.settingsListRowHeight,
      leading: {
        ProviderBrandIcon(provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
      },
      trailing: {
        Image(systemName: "chevron.right")
          .quotaChevronStyle()
      }
    )
  }

  private func writeView<Content: View>(_ content: Content, to url: URL) throws {
    let root = content
      .padding(16)
      .frame(width: 360)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: root)
    let fitting = host.fittingSize
    let width = max(fitting.width, 360)
    let height = max(fitting.height, 48)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    let bounds = host.bounds
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
    host.cacheDisplay(in: bounds, to: rep)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    let tiff = try #require(image.tiffRepresentation)
    let pngRep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(pngRep.representation(using: .png, properties: [:]))
    try png.write(to: url)
  }
}
