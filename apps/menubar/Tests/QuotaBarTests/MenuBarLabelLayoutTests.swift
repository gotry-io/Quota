import AppKit
import Foundation
import Testing

@testable import QuotaBar

/// What the status item actually draws, measured from the image it hands AppKit.
///
/// The item is one template image, so the only thing that decides whether the number looks
/// centered next to the mark is where this code put the ink. That is measurable, and it is the
/// kind of thing a later edit breaks silently, so it is measured.
@MainActor
struct MenuBarLabelLayoutTests {
  /// A quarter point: finer than anyone can see at menu-bar size, coarser than glyph
  /// antialiasing noise.
  private let tolerance: CGFloat = 0.25

  @Test
  func theMarkAndTheNumberShareACenter() throws {
    let ink = try #require(itemInk(of: iconAndPercent))
    let mark = try #require(ink.mark)
    let text = try #require(ink.text)

    #expect(abs(text.midY - mark.midY) <= tolerance)
    #expect(abs(mark.midY - ink.height / 2) <= tolerance)
  }

  @Test
  func theMarkIsTheSizeOfAMenuBarGlyphAndNotTheWholeItem() throws {
    let ink = try #require(itemInk(of: iconAndPercent))
    let mark = try #require(ink.mark)

    #expect(mark.height >= 14)
    #expect(mark.height <= 15.5)
    #expect(mark.height < ink.height)
  }

  @Test
  func everyMarkLandsAtTheSameSize() throws {
    let provider = try #require(itemInk(of: iconAndPercent)).mark
    let quota = try #require(itemInk(of: iconOnly)).mark
    let claudeLabel = MenuBarLabelModel(
      icon: .provider(.claude),
      text: "27%",
      accessibilityLabel: "QuotaBar, Claude Code 27% remaining"
    )
    let claude = try #require(itemInk(of: claudeLabel)).mark

    let heights = [provider, quota, claude].compactMap { $0?.height }
    #expect(heights.count == 3)
    #expect((heights.max() ?? 0) - (heights.min() ?? 0) <= tolerance)
  }

  @Test
  func theItemIsTheStandardStatusItemHeightInEveryStyle() throws {
    for label in [iconAndPercent, percentOnly, iconOnly] {
      let image = MenuBarItemImage.make(label)
      #expect(image.size.height == MenuBarItemImage.height)
      #expect(image.isTemplate)
    }
    // 18pt in the 22pt bar macOS ships, and never smaller than a glyph needs.
    #expect(MenuBarItemImage.height >= 16)
    #expect(MenuBarItemImage.height <= 20)
  }

  @Test
  func theNumberIsCenteredWithNoMarkBesideIt() throws {
    let ink = try #require(itemInk(of: percentOnly))
    let text = try #require(ink.text)

    #expect(ink.mark == nil)
    #expect(abs(text.midY - ink.height / 2) <= tolerance)
  }

  private var iconAndPercent: MenuBarLabelModel {
    MenuBarLabelModel(
      icon: .provider(.codex),
      text: "27%",
      accessibilityLabel: "QuotaBar, Codex 27% remaining"
    )
  }

  private var percentOnly: MenuBarLabelModel {
    MenuBarLabelModel(icon: nil, text: "27%", accessibilityLabel: "QuotaBar, Codex 27% remaining")
  }

  private var iconOnly: MenuBarLabelModel {
    MenuBarLabelModel(icon: .quota, text: nil, accessibilityLabel: "QuotaBar")
  }

  /// Drawn at eight samples a point: the item ships at two, and a half-point pixel row cannot
  /// answer a quarter-point question.
  private func itemInk(of label: MenuBarLabelModel) -> ItemInk? {
    ItemInk(MenuBarItemImage.make(label, samplingScale: 8))
  }
}

/// The drawn pixels of one rendered item, split at the gap between the mark and the number.
private struct ItemInk {
  let height: CGFloat
  let mark: CGRect?
  /// The digits only. A percent sign dips below the baseline, and centering a number on ink
  /// that includes that dip is the mistake this measurement exists to catch.
  let text: CGRect?

  init?(_ image: NSImage) {
    guard let rep = image.representations.first as? NSBitmapImageRep, let data = rep.bitmapData
    else { return nil }
    let bytesPerPixel = rep.bitsPerPixel / 8
    let horizontal = rep.size.width / CGFloat(rep.pixelsWide)
    let vertical = rep.size.height / CGFloat(rep.pixelsHigh)
    height = rep.size.height

    var columns: [(top: Int, bottom: Int)?] = Array(repeating: nil, count: rep.pixelsWide)
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide {
        guard data[y * rep.bytesPerRow + x * bytesPerPixel + 3] > 16 else { continue }
        columns[x] = columns[x].map { (min($0.top, y), max($0.bottom, y)) } ?? (y, y)
      }
    }

    // Runs of drawn columns, then the widest empty span between them: the mark and the number
    // are 4pt apart, and nothing inside either is.
    var runs: [(first: Int, last: Int)] = []
    var start: Int?
    for x in 0..<rep.pixelsWide {
      if columns[x] != nil {
        if start == nil { start = x }
      } else if let first = start {
        runs.append((first, x - 1))
        start = nil
      }
    }
    if let first = start { runs.append((first, rep.pixelsWide - 1)) }
    guard !runs.isEmpty else { return nil }

    func box(_ group: ArraySlice<(first: Int, last: Int)>) -> CGRect? {
      guard let first = group.first, let last = group.last else { return nil }
      let bounds = (first.first...last.last).compactMap { columns[$0] }
      guard let top = bounds.map(\.top).min(), let bottom = bounds.map(\.bottom).max() else {
        return nil
      }
      return CGRect(
        x: CGFloat(first.first) * horizontal,
        y: CGFloat(rep.pixelsHigh - 1 - bottom) * vertical,
        width: CGFloat(last.last - first.first + 1) * horizontal,
        height: CGFloat(bottom - top + 1) * vertical
      )
    }

    let widestGap = runs.indices.dropFirst().max {
      runs[$0].first - runs[$0 - 1].last < runs[$1].first - runs[$1 - 1].last
    }
    guard
      let split = widestGap,
      CGFloat(runs[split].first - runs[split - 1].last) * horizontal >= 2.5
    else {
      // One group: either a mark on its own or a number on its own.
      let isMarkAlone = image.size.width <= MenuBarItemImage.markSize + 1
      mark = isMarkAlone ? box(runs[...]) : nil
      text = isMarkAlone ? nil : box(runs.count > 1 ? runs[..<(runs.count - 1)] : runs[...])
      return
    }
    mark = box(runs[..<split])
    let glyphs = runs[split...]
    text = box(glyphs.count > 1 ? glyphs.dropLast() : glyphs)
  }
}
