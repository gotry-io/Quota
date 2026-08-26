import AppKit
import QuotaWire
import SwiftUI

struct ProviderBrandIcon: View {
  let provider: ProviderID
  var size: CGFloat = 14

  var body: some View {
    BrandAssetIcon(assetName: provider.brandIconAssetName, size: size)
  }
}

struct BrandAssetIcon: View {
  let assetName: String
  var size: CGFloat = 14

  var body: some View {
    Group {
      if let image = ProviderBrandAssets.templateImage(named: assetName) {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .interpolation(.high)
          .scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .clipped()
    .foregroundStyle(QuotaPalette.ink)
    .accessibilityHidden(true)
  }
}

/// A catalog mark baked for drawing, with the box its ink actually occupies.
///
/// Every asset fills its own viewBox differently — some to the edge, some with a wide margin —
/// so anything that has to draw two marks at the same optical size needs the ink, not the box.
struct BrandTemplateMark: Sendable {
  let image: NSImage
  /// The ink's bounding box in the image's own point coordinates, origin bottom-left.
  let inkBounds: CGRect
}

@MainActor
enum ProviderBrandAssets {
  private static var cache: [String: BrandTemplateMark] = [:]

  static func resourceURL(for provider: ProviderID) -> URL? {
    resourceURL(named: provider.brandIconAssetName)
  }

  static func resourceURL(named assetName: String) -> URL? {
    if let appResource = Bundle.main.url(
      forResource: assetName,
      withExtension: "svg",
      subdirectory: "BrandIcons"
    ) {
      return appResource
    }
    return Bundle.module.url(forResource: assetName, withExtension: "svg")
  }

  static func templateImage(named assetName: String) -> NSImage? {
    mark(named: assetName)?.image
  }

  /// Loads the SVG and bakes a square template bitmap so CoreSVG path quirks
  /// and 1em intrinsic sizes cannot clip at menu-bar icon sizes, then measures the ink.
  static func mark(named assetName: String) -> BrandTemplateMark? {
    if let cached = cache[assetName] {
      return cached
    }
    guard let url = resourceURL(named: assetName), let source = NSImage(contentsOf: url) else {
      return nil
    }

    let pointSize: CGFloat = 24
    let scale: CGFloat = 2
    let pixelSize = Int(pointSize * scale)
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      return nil
    }
    rep.size = NSSize(width: pointSize, height: pointSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pointSize, height: pointSize).fill()

    // Draw into a slightly inset rect so any residual stroke/edge AA stays inside.
    let inset: CGFloat = 1
    let drawRect = NSRect(
      x: inset,
      y: inset,
      width: pointSize - inset * 2,
      height: pointSize - inset * 2
    )
    source.size = NSSize(width: pointSize, height: pointSize)
    source.draw(
      in: drawRect,
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
    image.addRepresentation(rep)
    image.isTemplate = true
    let mark = BrandTemplateMark(image: image, inkBounds: inkBounds(of: rep))
    cache[assetName] = mark
    return mark
  }

  /// The box the drawn pixels occupy, in the rep's point coordinates with the origin at the
  /// bottom left — the same corner AppKit draws from.
  private static func inkBounds(of rep: NSBitmapImageRep) -> CGRect {
    guard let data = rep.bitmapData else { return .zero }
    let bytesPerPixel = rep.bitsPerPixel / 8
    var minX = Int.max
    var maxX = Int.min
    var minY = Int.max
    var maxY = Int.min
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide {
        guard data[y * rep.bytesPerRow + x * bytesPerPixel + 3] > 16 else { continue }
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    guard minX <= maxX, minY <= maxY else { return .zero }
    let horizontal = rep.size.width / CGFloat(rep.pixelsWide)
    let vertical = rep.size.height / CGFloat(rep.pixelsHigh)
    return CGRect(
      x: CGFloat(minX) * horizontal,
      // Bitmap rows run top-down; AppKit's point space runs bottom-up.
      y: CGFloat(rep.pixelsHigh - 1 - maxY) * vertical,
      width: CGFloat(maxX - minX + 1) * horizontal,
      height: CGFloat(maxY - minY + 1) * vertical
    )
  }
}
