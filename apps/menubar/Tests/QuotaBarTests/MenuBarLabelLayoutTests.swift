import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuotaBar

/// What the status item actually draws, measured off-screen.
///
/// The menu bar centers whatever box the item hands it, so two things have to hold: the box is
/// the same height whatever the style is, and inside it the mark and the digits sit on the same
/// line. Neither is provable by reading the view, and both are the kind of thing a later edit
/// breaks silently, so this renders the real view and looks at the pixels.
@MainActor
struct MenuBarLabelLayoutTests {
  /// Half a point at the scale these are rendered: below what anyone can see, above the noise
  /// of glyph antialiasing.
  private let tolerance: CGFloat = 0.3

  @Test
  func theItemIsTheSameHeightInEveryStyle() throws {
    for label in [iconAndPercent, percentOnly, iconOnly] {
      let rendering = try #require(render(label))
      #expect(rendering.height == MenuBarLabelLayout.contentHeight)
    }
  }

  @Test
  func theMarkAndTheNumberSitOnTheSameLine() throws {
    let rendering = try #require(render(iconAndPercent))
    let mark = try #require(rendering.marks.first)
    let digits = try #require(rendering.digits)

    #expect(abs(digits.center - mark.center) < tolerance)
    #expect(abs(digits.center - rendering.height / 2) < tolerance)
    #expect(abs(mark.center - rendering.height / 2) < tolerance)
  }

  @Test
  func theNumberDoesNotMoveWhenTheMarkIsSwitchedOff() throws {
    let paired = try #require(render(iconAndPercent))
    let alone = try #require(render(percentOnly))
    let pairedDigits = try #require(paired.digits)
    let aloneDigits = try #require(alone.digits)

    #expect(abs(pairedDigits.center - aloneDigits.center) < tolerance)
    #expect(abs(aloneDigits.center - MenuBarLabelLayout.contentHeight / 2) < tolerance)
  }

  @Test
  func theProvidersMarkIsWhatAPercentWears() throws {
    let paired = try #require(render(iconAndPercent))
    let quotaOnly = try #require(render(iconOnly))
    let providerMark = try #require(paired.marks.first)
    let quotaMark = try #require(quotaOnly.marks.first)

    // Both are drawn, and the percent is not wearing the Quota mark.
    #expect(providerMark.height > 0)
    #expect(quotaMark.height > 0)
    #expect(providerMark != quotaMark)
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

  private func render(_ label: MenuBarLabelModel) -> Rendering? {
    let renderer = ImageRenderer(
      content: QuotaMenuBarLabel(label: label)
        .environment(\.colorScheme, .light)
        .background(Color.white)
    )
    renderer.scale = Rendering.scale
    guard let image = renderer.cgImage else { return nil }
    return Rendering(image)
  }
}

/// One rendered item, split into the ink it drew: everything the mark covers, and the digits
/// beside it. The `%` is dropped, because its ink is taller than a digit's and would move a
/// measurement that is about where the number sits.
private struct Rendering {
  struct Band: Equatable {
    let top: CGFloat
    let bottom: CGFloat

    var center: CGFloat { (top + bottom) / 2 }
    var height: CGFloat { bottom - top }
  }

  static let scale: CGFloat = 8

  let height: CGFloat
  /// Ink columns grouped into the runs the layout separates them into, in drawing order.
  let bands: [Band]

  /// The mark is the first band: it is drawn before the text and the two never overlap.
  var marks: [Band] { bands.count > 1 ? [bands[0]] : bands }

  /// The digits, with the trailing `%` band left out.
  var digits: Band? {
    let text = bands.count > 1 ? Array(bands.dropFirst().dropLast()) : []
    guard let first = text.first else { return nil }
    return text.dropFirst()
      .reduce(first) { Band(top: min($0.top, $1.top), bottom: max($0.bottom, $1.bottom)) }
  }

  init?(_ image: CGImage) {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = image.bitsPerPixel / 8
    var runs: [(first: Int, last: Int)] = []
    var column: [(top: Int, bottom: Int)?] = Array(repeating: nil, count: image.width)

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for y in 0..<image.height {
        for x in 0..<image.width {
          let offset = y * bytesPerRow + x * bytesPerPixel
          let luminance = (Int(raw[offset]) + Int(raw[offset + 1]) + Int(raw[offset + 2])) / 3
          guard luminance < 160 else { continue }
          if let existing = column[x] {
            column[x] = (min(existing.top, y), max(existing.bottom, y))
          } else {
            column[x] = (y, y)
          }
        }
      }
    }

    var start: Int?
    for x in 0..<image.width {
      if column[x] != nil {
        if start == nil { start = x }
      } else if let first = start {
        runs.append((first, x - 1))
        start = nil
      }
    }
    if let first = start { runs.append((first, image.width - 1)) }

    height = CGFloat(image.height) / Self.scale
    bands = runs.map { run in
      let bounds = (run.first...run.last).compactMap { column[$0] }
      return Band(
        top: CGFloat(bounds.map(\.top).min() ?? 0) / Self.scale,
        bottom: CGFloat(bounds.map(\.bottom).max() ?? 0) / Self.scale
      )
    }
  }
}
