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

  /// Menu-bar items are drawn at the backing scale; two covers every shipping Mac.
  nonisolated static let scale: CGFloat = 2

  /// The menu bar's own font, with monospaced digits so the item does not twitch as the number
  /// moves. The body font is a different size and would read as a different app's item.
  static var textFont: NSFont {
    let base = NSFont.menuBarFont(ofSize: 0)
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

  private static var cached: (key: MenuBarLabelModel, height: CGFloat, image: NSImage)?

  /// `samplingScale` exists so the same drawing can be measured finely; the item itself always
  /// ships at the backing scale.
  static func make(_ label: MenuBarLabelModel, samplingScale: CGFloat = scale) -> NSImage {
    let height = height
    guard samplingScale == scale else {
      return draw(label, height: height, scale: samplingScale)
    }
    if let cached, cached.key == label, cached.height == height {
      return cached.image
    }
    let image = draw(label, height: height, scale: scale)
    cached = (label, height, image)
    return image
  }

  private static func draw(
    _ label: MenuBarLabelModel,
    height: CGFloat,
    scale: CGFloat
  ) -> NSImage {
    let mark = label.icon.flatMap { placedMark($0, height: height) }
    let text = label.text.map(line(for:))
    let spacing = mark != nil && text != nil ? markSpacing : 0
    let width = max(((mark?.inkWidth ?? 0) + spacing + (text?.width ?? 0)).rounded(.up), 1)
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

    if let mark {
      mark.image.draw(
        in: mark.frame,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
    }
    if let text, let cgContext = context?.cgContext {
      // The digits stand on the baseline and reach a cap height up, so putting their middle on
      // the item's middle is what centering a number means. A line box would center the room it
      // reserves for descenders no digit uses instead.
      cgContext.textPosition = CGPoint(
        x: (mark?.inkWidth ?? 0) + spacing,
        y: (height - textFont.capHeight) / 2
      )
      CTLineDraw(text.line, cgContext)
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

  private static func line(for text: String) -> (line: CTLine, width: CGFloat) {
    let attributed = NSAttributedString(
      string: text,
      attributes: [.font: textFont, .foregroundColor: NSColor.black]
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
