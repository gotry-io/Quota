import AppKit
import SwiftUI

/// The status item's geometry, in one place because a test measures the same numbers.
///
/// The item is one fixed box whatever the style is: an item that changes height when the mark
/// is switched off changes where the menu bar centers it, and the number appears to move for a
/// reason that has nothing to do with quota.
enum MenuBarLabelLayout {
  static let contentHeight: CGFloat = 18
  static let iconSize: CGFloat = 18

  /// How far above the baseline the digits' optical middle sits — half a cap height.
  ///
  /// A line box also reserves room for descenders no digit uses, so centering the box centers
  /// the wrong thing and the number rides high next to the mark. The menu bar font answers for
  /// the measurement because the status bar is what draws it.
  static var digitCenterAboveBaseline: CGFloat {
    NSFont.menuBarFont(ofSize: 0).capHeight / 2
  }
}

/// The menu-bar item itself: a template mark, the remaining percent it belongs to, or both.
/// The status bar owns the text style, so this adds none.
///
/// Both children are the same fixed box, and the number is placed in its box by its own optical
/// middle rather than by the middle of a line box that reserves room for descenders no digit
/// uses. That is what keeps the number level with the mark, and in the same place when the mark
/// is not there at all.
struct QuotaMenuBarLabel: View {
  let label: MenuBarLabelModel

  var body: some View {
    HStack(spacing: QuotaDesign.Spacing.xxs) {
      if let icon = label.icon {
        MenuBarIcon(icon: icon)
      }
      if let text = label.text {
        Text(text)
          .monospacedDigit()
          .alignmentGuide(VerticalAlignment.center) { dimensions in
            dimensions[.firstTextBaseline] - MenuBarLabelLayout.digitCenterAboveBaseline
          }
          .frame(height: MenuBarLabelLayout.contentHeight)
      }
    }
    .frame(height: MenuBarLabelLayout.contentHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label.accessibilityLabel)
  }
}

/// The mark the item wears, always monochrome: the status bar renders a template image, and a
/// provider's brand color would be a lie about the number beside it anyway.
struct MenuBarIcon: View {
  let icon: MenuBarLabelIcon

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .interpolation(.high)
          .scaledToFit()
      }
    }
    .frame(width: MenuBarLabelLayout.iconSize, height: MenuBarLabelLayout.iconSize)
    .foregroundStyle(.primary)
    .accessibilityHidden(true)
  }

  private var image: NSImage? {
    switch icon {
    case .quota:
      QuotaBrandAssets.menuBarTemplateImage()
    case .provider(let provider):
      ProviderBrandAssets.templateImage(named: provider.brandIconAssetName)
    }
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
    image.size = NSSize(width: MenuBarLabelLayout.iconSize, height: MenuBarLabelLayout.iconSize)
    image.isTemplate = true
    cachedMenuBarImage = image
    return image
  }
}
