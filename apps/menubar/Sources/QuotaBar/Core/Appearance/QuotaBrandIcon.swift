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
    .accessibilityHidden(true)
  }
}

/// The menu-bar item itself: the template mark, the tightest remaining percent, or both.
/// The status bar owns the text style, so this adds none.
struct QuotaMenuBarLabel: View {
  let label: MenuBarLabelModel

  var body: some View {
    HStack(spacing: QuotaDesign.Spacing.xxs) {
      if label.showsIcon {
        QuotaMenuBarIcon()
      }
      if let text = label.text {
        Text(text)
          .monospacedDigit()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label.accessibilityLabel)
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
