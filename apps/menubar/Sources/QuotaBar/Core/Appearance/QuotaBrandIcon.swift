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

  /// Size of a stacked cadence pair. The ceiling is what two cap-heights plus ``stackedLineGap``
  /// leave room for; 9pt is a choice inside it, and `MenuBarLabelLayoutTests` holds the margin.
  /// See `apps/menubar/DESIGN.md`.
  nonisolated static let stackedTextSize: CGFloat = 9

  /// Gap between the two stacked cadence rows.
  nonisolated static let stackedLineGap: CGFloat = 2

  /// Gap between a remaining percent and its cadence tag (`H`). The tag reads as the
  /// reading's unit, the way a speed carries `KB/s`, so it sits a word-space after it.
  nonisolated static let stackedCadenceSpacing: CGFloat = 3

  /// The retina drawing scale. The shipped image also carries a 1x representation, so a
  /// display picks the raster made for it instead of downsampling this one.
  nonisolated static let scale: CGFloat = 2

  /// The menu bar's own font, with monospaced digits so the item does not twitch as the number
  /// moves. The body font is a different size and would read as a different app's item.
  static var textFont: NSFont {
    monospacedDigitFont(NSFont.menuBarFont(ofSize: 0))
  }

  /// The same family at ``stackedTextSize``, the way a network extra stacks up and down.
  /// Medium, so the small size keeps presence against the bar without clotting on retina.
  static var stackedTextFont: NSFont {
    .monospacedDigitSystemFont(ofSize: stackedTextSize, weight: .medium)
  }

  /// The bar's own font has no monospaced-digit variant of its own, so the feature is set on
  /// its descriptor; the stacked font uses the system API for the same thing directly.
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
    // One raster per display scale, in one image: AppKit picks the representation matching
    // the screen the item is on, so a 1x display shows glyphs rasterized at 1x — with the
    // whole-point origins landing on its actual pixels — rather than a downsampled retina
    // bitmap. This is what lets one bar item look native on both kinds of screen at once.
    if let oneX = draw(label, height: height, scale: 1).representations.first {
      image.addRepresentation(oneX)
    }
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
      var cadence: CTLine?
      var cadenceWidth: CGFloat
      var percent: CTLine
      var percentWidth: CGFloat
    }

    var rows: [Row]
    var cadenceColumn: CGFloat
    var percentColumn: CGFloat
    var capHeight: CGFloat

    /// A cell with no tags at all — a lone percent riding along beside a stacked neighbour —
    /// owes nothing for the tag column or the gap before it.
    var cadenceGap: CGFloat { cadenceColumn > 0 ? stackedCadenceSpacing : 0 }
    var width: CGFloat { percentColumn + cadenceGap + cadenceColumn }
  }

  private static func draw(
    _ label: MenuBarLabelModel,
    height: CGFloat,
    scale: CGFloat
  ) -> NSImage {
    let prepared = label.cells.map {
      PreparedCell(
        mark: $0.icon.flatMap { placedMark($0, height: height) },
        text: preparedText($0)
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
        drawText(text, at: x + cell.textOrigin, height: height, scale: scale, in: cgContext)
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

  /// A lone reading keeps the menu bar's own size even beside a stacked pair: only a pair pays
  /// the stacked size, because only a pair has two rows to fit.
  private static func preparedText(_ cell: MenuBarLabelCell) -> PreparedText? {
    switch cell.content {
    case .absent:
      return nil
    case .lone(let percent):
      let font = textFont
      let drawn = line(for: percent, font: font)
      return .single(line: drawn.line, width: drawn.width, capHeight: font.capHeight)
    case .rows(let rows):
      return stacked(rows)
    }
  }

  private static func stacked(_ lines: [MenuBarLabelLine]) -> PreparedText {
    let font = stackedTextFont
    var rows: [StackedText.Row] = []
    var cadenceColumn: CGFloat = 0
    // Rows share a percent column as wide as the wider number and no wider: digits are
    // monospaced, so equal counts already line up, and a reserved third digit would sit as a
    // permanent gap between a tag and the reading it belongs to.
    var percentColumn: CGFloat = 0
    for row in lines {
      let cadence = row.compactCadence.map { line(for: $0, font: font) }
      let percent = line(for: row.percent, font: font)
      cadenceColumn = max(cadenceColumn, cadence?.width ?? 0)
      percentColumn = max(percentColumn, percent.width)
      rows.append(
        StackedText.Row(
          cadence: cadence?.line,
          cadenceWidth: cadence?.width ?? 0,
          percent: percent.line,
          percentWidth: percent.width
        )
      )
    }
    return .stacked(
      StackedText(
        rows: rows,
        cadenceColumn: cadenceColumn,
        percentColumn: percentColumn,
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
    scale: CGFloat,
    in cgContext: CGContext
  ) {
    // Origins snap to the pixel grid of the raster being drawn — whole points at 1x, half
    // points at 2x. A fractional origin lands glyphs between pixels, smearing stems into
    // something both thin and misaligned; snapping to points alone would waste the retina
    // raster's finer grid.
    func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    switch text {
    case .single(let line, _, let cap):
      cgContext.textPosition = CGPoint(x: snap(textX), y: snap((height - cap) / 2))
      CTLineDraw(line, cgContext)
    case .stacked(let stacked):
      let cap = stacked.capHeight
      let extra = CGFloat(stacked.rows.count - 1)
      // The row step rounds UP on the pixel grid: the designed gap is a minimum, so
      // quantization on a 1x display may widen the air between the rows but never eat it.
      let step = ((cap + stackedLineGap) * scale).rounded(.up) / scale
      let block = cap + step * extra
      var baseline = snap((height - block) / 2) + step * extra
      for row in stacked.rows {
        // Percents right-align so the % signs share an edge, and the tag follows as the
        // reading's unit. A shorter number's slack falls before it as leading air — the way a
        // ragged-left speed pair sits beside its mark — never as a hole inside the reading.
        let y = snap(baseline)
        let percentX = snap(textX + (stacked.percentColumn - row.percentWidth))
        cgContext.textPosition = CGPoint(x: percentX, y: y)
        CTLineDraw(row.percent, cgContext)
        if let cadence = row.cadence {
          // Each tag is measured on its own and centered in the shared column. When the slack
          // is an odd number of pixels, the spare pixel trails: the tag stays against the
          // number it belongs to, and the leftover air falls outward.
          let inset =
            ((stacked.cadenceColumn - row.cadenceWidth) / 2 * scale).rounded(.down) / scale
          let cadenceX = snap(textX + stacked.percentColumn + stacked.cadenceGap) + inset
          cgContext.textPosition = CGPoint(x: cadenceX, y: y)
          CTLineDraw(cadence, cgContext)
        }
        baseline -= step
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
