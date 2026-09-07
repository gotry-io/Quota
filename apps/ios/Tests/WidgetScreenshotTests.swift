import QuotaWidgetViews
import SwiftUI
import Testing
import UIKit

@testable import Quota

@MainActor
struct WidgetScreenshotTests {
  @Test
  func renderFamilyFixturesToPNG() throws {
    let directory = screenshotDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let content = OverviewWidgetPreviewFixtures.entry(
      snapshot: OverviewWidgetPreviewFixtures.contentSnapshot
    )
    let empty = OverviewWidgetPreviewFixtures.entry(snapshot: nil)
    let placeholder = OverviewWidgetPreviewFixtures.entry(
      snapshot: nil,
      isPlaceholder: true
    )

    try write(
      OverviewSmallView(entry: content),
      size: CGSize(width: 170, height: 170),
      name: "small-content",
      directory: directory
    )
    try write(
      OverviewSmallView(entry: empty),
      size: CGSize(width: 170, height: 170),
      name: "small-no-data",
      directory: directory
    )
    try write(
      OverviewSmallView(entry: placeholder),
      size: CGSize(width: 170, height: 170),
      name: "small-placeholder",
      directory: directory
    )
    try write(
      OverviewMediumView(entry: content),
      size: CGSize(width: 364, height: 170),
      name: "medium-content",
      directory: directory
    )
    try write(
      OverviewLargeView(entry: content),
      size: CGSize(width: 364, height: 382),
      name: "large-content",
      directory: directory
    )
    try write(
      OverviewCircularView(entry: content),
      size: CGSize(width: 76, height: 76),
      name: "circular-content",
      directory: directory,
      accessory: true
    )
    try write(
      OverviewRectangularView(entry: content),
      size: CGSize(width: 172, height: 76),
      name: "rectangular-content",
      directory: directory,
      accessory: true
    )
    try write(
      OverviewInlineView(entry: content),
      size: CGSize(width: 280, height: 20),
      name: "inline-content",
      directory: directory,
      accessory: true
    )
  }

  private func screenshotDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["WP_D8_SCREENSHOT_DIR"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("quota-widget-screenshots", isDirectory: true)
  }

  private func write(
    _ view: some View,
    size: CGSize,
    name: String,
    directory: URL,
    accessory: Bool = false
  ) throws {
    // Lock Screen accessories render light-on-dark, so the fixture uses the dark scheme too.
    let background = accessory ? Color.black : Color(uiColor: .secondarySystemBackground)
    let framed = view
      .frame(width: size.width, height: size.height)
      .padding(accessory ? 8 : 16)
      .background(background)
      .clipShape(RoundedRectangle(cornerRadius: accessory ? 12 : 22, style: .continuous))
      .environment(\.colorScheme, accessory ? .dark : .light)
      // The extension gets this from its own AccentColor asset catalog; a test bundle runs
      // inside the app, whose accent is the same product emerald.
      .tint(QuotaTheme.emerald)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 3
    renderer.proposedSize = ProposedViewSize(
      width: size.width + (accessory ? 16 : 32),
      height: size.height + (accessory ? 16 : 32)
    )
    guard let data = renderer.uiImage?.pngData() else {
      throw ScreenshotError.unrenderable(name)
    }
    #expect(data.count > 100)
    try data.write(to: directory.appendingPathComponent("\(name).png"))
  }
}

private enum ScreenshotError: Error {
  case unrenderable(String)
}
