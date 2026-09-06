import AppKit
import Foundation
import QuotaPresentation
import QuotaWire
import SwiftUI
import Testing

@testable import QuotaBar

/// Writes the WP-D10 screenshot set when `WP_D10_SCREENSHOTS` is a directory.
@MainActor
struct WpD10ScreenshotTests {
  @Test
  func exportScreenshotsWhenAsked() throws {
    let path = ProcessInfo.processInfo.environment["WP_D10_SCREENSHOTS"] ?? ""
    guard !path.isEmpty else { return }
    let dir = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let resetKey = ResetCopyStylePreference.storageKey
    let previousReset = UserDefaults.standard.object(forKey: resetKey)
    defer {
      if let previousReset {
        UserDefaults.standard.set(previousReset, forKey: resetKey)
      } else {
        UserDefaults.standard.removeObject(forKey: resetKey)
      }
    }

    try write(
      MenuBarItemImage.make(
        MenuBarLabelModel(
          icon: .quota,
          text: "≥ $1.49",
          accessibilityLabel: "QuotaBar, today ≥ $1.49"
        )
      ),
      to: dir.appendingPathComponent("menubar-today-cost.png")
    )
    try write(
      MenuBarItemImage.make(
        MenuBarLabelModel(
          icon: .quota,
          text: "1.23M",
          accessibilityLabel: "QuotaBar, today 1,234,567 tokens"
        )
      ),
      to: dir.appendingPathComponent("menubar-today-tokens.png")
    )
    try write(
      MenuBarItemImage.make(
        MenuBarLabelModel(
          cells: [
            MenuBarLabelCell(icon: .provider(.codex), text: "$0.80"),
            MenuBarLabelCell(icon: .provider(.claude), text: "$0.40"),
          ],
          accessibilityLabel: "QuotaBar, Codex today $0.80, Claude Code today $0.40"
        )
      ),
      to: dir.appendingPathComponent("menubar-today-cost-combined.png")
    )

    let now = Date(timeIntervalSince1970: 1_788_804_000)
    try writeRow(
      QuotaWindow(
        id: "extra_usage",
        title: "Extra Usage",
        usedPercent: 12.5,
        remainingValue: 87.5,
        limitValue: 100,
        valueUnit: .usd
      ),
      provider: .claude,
      now: now,
      to: dir.appendingPathComponent("panel-extra-usage.png")
    )
    try writeRow(
      QuotaWindow(
        id: "credits",
        title: "Balance (USD)",
        usedPercent: 0,
        remainingValue: 45.25,
        valueUnit: .usd
      ),
      provider: .codex,
      now: now,
      to: dir.appendingPathComponent("panel-credits-balance.png")
    )
    try writeRow(
      QuotaWindow(
        id: "reset_credits",
        title: "Reset Credits",
        usedPercent: 0,
        remainingValue: 2,
        valueUnit: .count
      ),
      provider: .codex,
      now: now,
      to: dir.appendingPathComponent("panel-reset-credits.png")
    )
    try writeRow(
      QuotaWindow(
        id: "billing_cycle",
        title: "Weekly",
        usedPercent: 20,
        remainingValue: 80,
        limitValue: 100,
        valueUnit: .credits
      ),
      provider: .grok,
      now: now,
      to: dir.appendingPathComponent("panel-grok-credits.png")
    )

    let resetting = QuotaWindow(
      id: "five_hour",
      title: "5 Hours",
      usedPercent: 47,
      resetsAt: now.addingTimeInterval(3 * 3_600 + 53 * 60)
    )
    UserDefaults.standard.set(
      ResetCopyStylePreference.relative.rawValue,
      forKey: resetKey
    )
    try writeRow(
      resetting,
      provider: .claude,
      now: now,
      to: dir.appendingPathComponent("panel-reset-relative.png")
    )
    UserDefaults.standard.set(
      ResetCopyStylePreference.absolute.rawValue,
      forKey: resetKey
    )
    try writeRow(
      resetting,
      provider: .claude,
      now: now,
      to: dir.appendingPathComponent("panel-reset-absolute.png")
    )

    try writeView(
      VStack(alignment: .leading, spacing: 0) {
        ForEach(MenuBarStylePreference.allCases) { option in
          MenuBarChoiceRow(
            title: option.label,
            isSelected: option == .iconAndPercent
          ) {}
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .quotaGroupSurface(),
      to: dir.appendingPathComponent("settings-menu-bar-style.png")
    )
    try writeView(
      VStack(alignment: .leading, spacing: 0) {
        ForEach(ResetCopyStylePreference.allCases) { option in
          MenuBarChoiceRow(
            title: option.label,
            subtitle: option.summary,
            isSelected: option == .relative
          ) {}
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .quotaGroupSurface(),
      to: dir.appendingPathComponent("settings-reset-time.png")
    )
  }

  private func writeRow(
    _ window: QuotaWindow,
    provider: ProviderID,
    now: Date,
    to url: URL
  ) throws {
    try writeView(
      QuotaWindowRow(window: window, provider: provider, isStale: false, now: now),
      to: url
    )
  }

  private func writeView<Content: View>(_ content: Content, to url: URL) throws {
    let root = content
      .padding(16)
      .frame(width: 288)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: root)
    let fitting = host.fittingSize
    let width = max(fitting.width, 320)
    let height = max(fitting.height, 48)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    let bounds = host.bounds
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
    host.cacheDisplay(in: bounds, to: rep)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    try write(image, to: url, onWhite: false)
  }

  private func write(_ image: NSImage, to url: URL, onWhite: Bool = true) throws {
    let composed = onWhite ? padded(image) : image
    let tiff = try #require(composed.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: url)
  }

  private func padded(_ image: NSImage) -> NSImage {
    let size = NSSize(width: image.size.width + 24, height: image.size.height + 16)
    let out = NSImage(size: size)
    out.lockFocus()
    NSColor.windowBackgroundColor.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.draw(
      in: NSRect(
        x: (size.width - image.size.width) / 2,
        y: (size.height - image.size.height) / 2,
        width: image.size.width,
        height: image.size.height
      ),
      from: .zero,
      operation: .sourceOver,
      fraction: 1
    )
    out.unlockFocus()
    return out
  }
}
