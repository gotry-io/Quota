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

@MainActor
enum ProviderBrandAssets {
  private static var cache: [String: NSImage] = [:]

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

  /// Loads the SVG and bakes a square template bitmap so CoreSVG path quirks
  /// and 1em intrinsic sizes cannot clip at menu-bar icon sizes.
  static func templateImage(named assetName: String) -> NSImage? {
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
    cache[assetName] = image
    return image
  }
}
