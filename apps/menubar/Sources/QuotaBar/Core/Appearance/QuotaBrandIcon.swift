import AppKit
import CoreText
import SwiftUI

/// The status item's whole label, drawn once into a single template image.
///
/// A status item is one image to AppKit, and AppKit places it the way it places every other
/// one. Handing it a SwiftUI stack instead means asking two different layout systems to agree
/// about where a baseline is, and they do not: measurements taken off-screen did not match what
/// the menu bar drew. So the mark and the number are composed here, at known coordinates, and
/// the menu bar is given the result.
@MainActor
enum MenuBarItemImage {
  /// The standard status-item height: the bar's own thickness less the padding every item
  /// leaves above and below it — 18pt in the 22pt bar macOS ships.
  static var height: CGFloat { max(NSStatusBar.system.thickness - 4, 16) }

  /// How large a mark is allowed to be. SF Symbol menu-bar glyphs measure about this, and a
  /// brand mark drawn to the full item height stands out next to them as a mistake. Every mark
  /// is fitted into this square by its ink, so no catalog asset is optically larger than
  /// another because it happens to fill more of its own viewBox.
  nonisolated static let markSize: CGFloat = 14.5

  /// Optical gap between the mark and the number.
  nonisolated static let markSpacing: CGFloat = 4

  /// Gap between packed readings in one item. Wider than mark-to-number so the
  /// cells read as neighbors rather than one mark with two numbers.
  nonisolated static let cellSpacing: CGFloat = 8

  /// Size of a stacked cadence pair. Two cap-heights plus ``stackedLineGap`` fit the 18pt item.
  nonisolated static let stackedTextSize: CGFloat = 9

  /// Gap between the two stacked cadence rows.
  nonisolated static let stackedLineGap: CGFloat = 2

  /// Gap between a cadence tag (`H`) and its remaining percent. They are one reading, so they
  /// sit closer than the gap that separates whole cells.
  nonisolated static let stackedCadenceSpacing: CGFloat = 2

  /// Menu-bar items are drawn at the backing scale; two covers every shipping Mac.
  nonisolated static let scale: CGFloat = 2

  /// The menu bar's own font, with monospaced digits so the item does not twitch as the number
  /// moves. The body font is a different size and would read as a different app's item.
  static var textFont: NSFont {
    monospacedDigitFont(NSFont.menuBarFont(ofSize: 0))
  }

  /// The same family at 9pt, so two cadence rows fit the item the way a network extra stacks
  /// up and down.
  static var stackedTextFont: NSFont {
    monospacedDigitFont(NSFont.menuBarFont(ofSize: stackedTextSize))
  }

  private static func monospacedDigitFont(_ base: NSFont) -> NSFont {
    let descriptor = base.fontDescriptor.addingAttributes([
      .featureSettings: [
        [
          NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
          NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]
      ]
    ])
    return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
  }

  /// How many drawn items to keep. The bar shows a handful at a time, but a stacked pair is
  /// keyed by a *pair* of percents, so the key space is wide enough that a map that never
  /// forgot would keep growing for as long as the app runs.
  private static let cacheLimit = 32

  private static var cached: [MenuBarLabelModel: (height: CGFloat, image: NSImage)] = [:]

  /// `samplingScale` exists so the same drawing can be measured finely; the item itself always
  /// ships at the backing scale.
  static func make(_ label: MenuBarLabelModel, samplingScale: CGFloat = scale) -> NSImage {
    let height = height
    guard samplingScale == scale else {
      return draw(label, height: height, scale: samplingScale)
    }
    if let cached = cached[label], cached.height == height {
      return cached.image
    }
    let image = draw(label, height: height, scale: scale)
    // Only the items currently on the bar are worth keeping, and they are redrawn on the next
    // reading anyway, so a full reset is cheaper to hold than an eviction order.
    if cached.count >= cacheLimit {
      cached.removeAll(keepingCapacity: true)
    }
    cached[label] = (height, image)
    return image
  }

  private struct PreparedCell {
    var mark: PlacedMark?
    var text: PreparedText?

    /// Where the text starts, from the cell's left edge. Measuring and drawing ask the cell
    /// rather than each restating when the mark earns its gap.
    var textOrigin: CGFloat {
      let textWidth = text?.width ?? 0
      return (mark?.inkWidth ?? 0) + (mark != nil && textWidth > 0 ? markSpacing : 0)
    }

    var width: CGFloat { textOrigin + (text?.width ?? 0) }
  }

  /// Text measured and ready to draw. It carries the cap height it was measured with, so
  /// placing it never has to know which font produced it.
  private enum PreparedText {
    case single(line: CTLine, width: CGFloat, capHeight: CGFloat)
    case stacked(StackedText)

    var width: CGFloat {
      switch self {
      case .single(_, let width, _): width
      case .stacked(let stacked): stacked.width
      }
    }
  }

  private struct StackedText {
    struct Row {
      var cadence: CTLine
      var percent: CTLine
      var percentWidth: CGFloat
    }

    var rows: [Row]
    var cadenceColumn: CGFloat
    var cadenceGap: CGFloat
    var percentColumn: CGFloat
    var width: CGFloat
    var capHeight: CGFloat
  }

  private static func draw(
    _ label: MenuBarLabelModel,
    height: CGFloat,
    scale: CGFloat
  ) -> NSImage {
    // One item is one reading surface: if any cell stacks a cadence pair, every cell drops to
    // the stacked size, so a lone percent beside a pair is the same weight rather than looming
    // over it at the menu bar's own size.
    let compact = label.cells.contains { cell in cell.lines.contains(where: \.isStacked) }
    let prepared = label.cells.map {
      PreparedCell(
        mark: $0.icon.flatMap { placedMark($0, height: height) },
        text: preparedText($0, compact: compact)
      )
    }
    var totalWidth = prepared.map(\.width).reduce(0, +)
    if prepared.count > 1 {
      totalWidth += CGFloat(prepared.count - 1) * cellSpacing
    }
    let width = max(totalWidth.rounded(.up), 1)
    let size = NSSize(width: width, height: height)

    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale),
        pixelsHigh: Int(height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      return NSImage(size: size)
    }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    var x: CGFloat = 0
    for (index, cell) in prepared.enumerated() {
      if index > 0 { x += cellSpacing }
      if let mark = cell.mark {
        var frame = mark.frame
        frame.origin.x += x
        mark.image.draw(
          in: frame,
          from: .zero,
          operation: .sourceOver,
          fraction: 1,
          respectFlipped: true,
          hints: [.interpolation: NSImageInterpolation.high]
        )
      }
      if let text = cell.text, let cgContext = context?.cgContext {
        drawText(text, at: x + cell.textOrigin, height: height, in: cgContext)
      }
      x += cell.width
    }
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = true
    return image
  }

  private struct PlacedMark {
    let image: NSImage
    /// Where the whole asset goes so that its ink lands centered at `markSize`.
    let frame: NSRect
    let inkWidth: CGFloat
  }

  private static func placedMark(_ icon: MenuBarLabelIcon, height: CGFloat) -> PlacedMark? {
    guard
      let mark = ProviderBrandAssets.mark(named: assetName(for: icon)),
      mark.inkBounds.width > 0,
      mark.inkBounds.height > 0
    else { return nil }
    let ink = mark.inkBounds
    let scale = markSize / max(ink.width, ink.height)
    let inkHeight = ink.height * scale
    return PlacedMark(
      image: mark.image,
      frame: NSRect(
        x: -ink.minX * scale,
        y: (height - inkHeight) / 2 - ink.minY * scale,
        width: mark.image.size.width * scale,
        height: mark.image.size.height * scale
      ),
      inkWidth: ink.width * scale
    )
  }

  private static func assetName(for icon: MenuBarLabelIcon) -> String {
    switch icon {
    case .quota: QuotaBrandAssets.assetName
    case .provider(let provider): provider.brandIconAssetName
    }
  }

  private static func preparedText(_ cell: MenuBarLabelCell, compact: Bool) -> PreparedText? {
    if !compact, let text = cell.text {
      let font = textFont
      let drawn = line(for: text, font: font)
      return .single(line: drawn.line, width: drawn.width, capHeight: font.capHeight)
    }
    if cell.lines.isEmpty { return nil }
    let font = stackedTextFont
    var rows: [StackedText.Row] = []
    var cadenceColumn: CGFloat = 0
    // The percent column is at least as wide as a full reading, so a pair does not shuffle
    // sideways when a number loses a digit.
    var percentColumn = line(for: "100%", font: font).width
    for row in cell.lines {
      let cadence = line(for: row.compactCadence ?? "", font: font)
      let percent = line(for: row.percent, font: font)
      cadenceColumn = max(cadenceColumn, cadence.width)
      percentColumn = max(percentColumn, percent.width)
      rows.append(
        StackedText.Row(cadence: cadence.line, percent: percent.line, percentWidth: percent.width)
      )
    }
    // A cell with no tags at all (a lone percent riding along beside a stacked neighbour) owes
    // nothing for the tag column or its gap.
    let cadenceGap = cadenceColumn > 0 ? stackedCadenceSpacing : 0
    return .stacked(
      StackedText(
        rows: rows,
        cadenceColumn: cadenceColumn,
        cadenceGap: cadenceGap,
        percentColumn: percentColumn,
        width: cadenceColumn + cadenceGap + percentColumn,
        capHeight: font.capHeight
      )
    )
  }

  /// Digits stand on the baseline and reach a cap height up, so putting that span's middle on
  /// the item's middle is what centering a number means. A line box would center the room it
  /// reserves for descenders no digit uses instead.
  private static func drawText(
    _ text: PreparedText,
    at textX: CGFloat,
    height: CGFloat,
    in cgContext: CGContext
  ) {
    switch text {
    case .single(let line, _, let cap):
      cgContext.textPosition = CGPoint(x: textX, y: (height - cap) / 2)
      CTLineDraw(line, cgContext)
    case .stacked(let stacked):
      let cap = stacked.capHeight
      let extra = CGFloat(stacked.rows.count - 1)
      let block = cap * CGFloat(stacked.rows.count) + stackedLineGap * extra
      var baseline = (height - block) / 2 + (cap + stackedLineGap) * extra
      for row in stacked.rows {
        cgContext.textPosition = CGPoint(x: textX, y: baseline)
        CTLineDraw(row.cadence, cgContext)
        let percentX =
          textX + stacked.cadenceColumn + stacked.cadenceGap
          + (stacked.percentColumn - row.percentWidth)
        cgContext.textPosition = CGPoint(x: percentX, y: baseline)
        CTLineDraw(row.percent, cgContext)
        baseline -= cap + stackedLineGap
      }
    }
  }

  private static func line(for text: String, font: NSFont) -> (line: CTLine, width: CGFloat) {
    let attributed = NSAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: NSColor.black]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    return (line, width.rounded(.up))
  }
}

/// The menu-bar item: one template image AppKit centers like any other status item.
struct QuotaMenuBarLabel: View {
  let label: MenuBarLabelModel

  var body: some View {
    Image(nsImage: MenuBarItemImage.make(label))
      .renderingMode(.template)
      .accessibilityLabel(label.accessibilityLabel)
  }
}

@MainActor
enum QuotaBrandAssets {
  /// Quota's own mark is a catalog asset like any other, and the status item loads it the same
  /// way it loads a provider's. The header wants the whole 18pt box filled instead, so it keeps
  /// its own copy at that size.
  static let assetName = "quota"

  private static var cachedHeaderImage: NSImage?

  static func menuBarResourceURL() -> URL? {
    ProviderBrandAssets.resourceURL(named: assetName)
  }

  static func menuBarTemplateImage() -> NSImage? {
    if let cachedHeaderImage {
      return cachedHeaderImage
    }
    guard
      let url = menuBarResourceURL(),
      let image = NSImage(contentsOf: url)
    else {
      return nil
    }
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    cachedHeaderImage = image
    return image
  }
}
