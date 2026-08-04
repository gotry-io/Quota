import AppKit
import SwiftUI

struct QuotaMenuBarIcon: View {
  var body: some View {
    Group {
      if let image = QuotaBrandAssets.menuBarTemplateImage() {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .interpolation(.high)
          .scaledToFit()
      }
    }
    .frame(width: 18, height: 18)
    .foregroundStyle(.primary)
    .accessibilityLabel("QuotaBar")
  }
}

@MainActor
enum QuotaBrandAssets {
  private static var cachedMenuBarImage: NSImage?

  static func menuBarResourceURL() -> URL? {
    if let appResource = Bundle.main.url(
      forResource: "quota",
      withExtension: "svg",
      subdirectory: "BrandIcons"
    ) {
      return appResource
    }
    return Bundle.module.url(forResource: "quota", withExtension: "svg")
  }

  static func menuBarTemplateImage() -> NSImage? {
    if let cachedMenuBarImage {
      return cachedMenuBarImage
    }
    guard
      let url = menuBarResourceURL(),
      let image = NSImage(contentsOf: url)
    else {
      return nil
    }
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    cachedMenuBarImage = image
    return image
  }
}
