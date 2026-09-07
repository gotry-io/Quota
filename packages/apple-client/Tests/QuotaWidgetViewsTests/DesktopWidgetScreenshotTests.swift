import Foundation
import SwiftUI
import Testing

@testable import QuotaWidgetViews

/// Renders the three desktop families the way `apps/ios/Tests/WidgetScreenshotTests.swift` renders
/// the phone's: a real `ImageRenderer` pass, so a view that cannot be drawn fails here rather than
/// on someone's desktop. Set `QUOTA_WIDGET_SCREENSHOT_DIR` to keep the PNGs.
@MainActor
struct DesktopWidgetScreenshotTests {
  @Test
  func rendersEveryDesktopFamilyToPNG() throws {
    let directory = screenshotDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let content = OverviewWidgetPreviewFixtures.entry(
      snapshot: OverviewWidgetPreviewFixtures.contentSnapshot
    )
    let empty = OverviewWidgetPreviewFixtures.entry(snapshot: nil)
    let placeholder = OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)

    // The macOS Home Screen widget sizes, in points.
    try write(
      OverviewSmallView(entry: content),
      size: CGSize(width: 155, height: 155),
      name: "macos-small-content",
      directory: directory
    )
    try write(
      OverviewSmallView(entry: empty),
      size: CGSize(width: 155, height: 155),
      name: "macos-small-no-data",
      directory: directory
    )
    try write(
      OverviewSmallView(entry: placeholder),
      size: CGSize(width: 155, height: 155),
      name: "macos-small-placeholder",
      directory: directory
    )
    try write(
      OverviewMediumView(entry: content),
      size: CGSize(width: 329, height: 155),
      name: "macos-medium-content",
      directory: directory
    )
    try write(
      OverviewLargeView(entry: content),
      size: CGSize(width: 329, height: 345),
      name: "macos-large-content",
      directory: directory
    )
  }

  private func screenshotDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["QUOTA_WIDGET_SCREENSHOT_DIR"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("quota-desktop-widget-screenshots", isDirectory: true)
  }

  private func write(
    _ view: some View,
    size: CGSize,
    name: String,
    directory: URL
  ) throws {
    let framed =
      view
      .frame(width: size.width, height: size.height)
      .padding(16)
      .background(Color(nsColor: .windowBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
      .environment(\.colorScheme, .light)
      // The extensions get this from their own AccentColor asset catalog; a test bundle has
      // none, so the fixture names the same product emerald.
      .tint(Color(red: 0.031, green: 0.455, blue: 0.337))
      .environment(\.overviewWidgetRowLinksEnabled, false)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    renderer.proposedSize = ProposedViewSize(
      width: size.width + 32,
      height: size.height + 32
    )
    guard let cgImage = renderer.cgImage else {
      throw DesktopScreenshotError.unrenderable(name)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw DesktopScreenshotError.unrenderable(name)
    }
    #expect(data.count > 100)
    try data.write(to: directory.appendingPathComponent("\(name).png"))
  }
}

private enum DesktopScreenshotError: Error {
  case unrenderable(String)
}
