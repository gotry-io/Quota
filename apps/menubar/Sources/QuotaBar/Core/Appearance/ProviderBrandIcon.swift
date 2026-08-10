import AppKit
import SwiftUI

struct ProviderBrandIcon: View {
  let provider: ProviderID
  var size: CGFloat = 14

  var body: some View {
    Group {
      if let image = ProviderBrandAssets.templateImage(for: provider) {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .interpolation(.high)
          .scaledToFit()
      }
    }
    .frame(width: size, height: size)
    // Keep drawing inside the frame; fixed assets should already be padded.
    .clipped()
    .foregroundStyle(QuotaPalette.ink)
    .accessibilityHidden(true)
  }
}

@MainActor
enum ProviderBrandAssets {
  private static var cache: [ProviderID: NSImage] = [:]

  static func resourceURL(for provider: ProviderID) -> URL? {
    if let appResource = Bundle.main.url(
      forResource: provider.brandIconAssetName,
      withExtension: "svg",
      subdirectory: "BrandIcons"
    ) {
      return appResource
    }
    return Bundle.module.url(forResource: provider.brandIconAssetName, withExtension: "svg")
  }

  /// Loads the SVG and bakes a square template bitmap so CoreSVG path quirks
  /// and 1em intrinsic sizes cannot clip at menu-bar icon sizes.
  static func templateImage(for provider: ProviderID) -> NSImage? {
    if let cached = cache[provider] {
      return cached
    }
    guard let url = resourceURL(for: provider), let source = NSImage(contentsOf: url) else {
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
    cache[provider] = image
    return image
  }
}
