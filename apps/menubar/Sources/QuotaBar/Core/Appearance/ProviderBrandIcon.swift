import AppKit
import SwiftUI

struct ProviderBrandIcon: View {
  let provider: ProviderID

  var body: some View {
    Group {
      if let image = ProviderBrandAssets.image(for: provider) {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
      }
    }
    .frame(width: 14, height: 14)
    .foregroundStyle(QuotaPalette.ink)
    .accessibilityHidden(true)
  }
}

@MainActor
enum ProviderBrandAssets {
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

  static func image(for provider: ProviderID) -> NSImage? {
    guard let url = resourceURL(for: provider), let image = NSImage(contentsOf: url) else {
      return nil
    }
    image.isTemplate = true
    return image
  }
}

extension ProviderID {
  fileprivate var brandIconAssetName: String {
    switch self {
    case .codex: "codex"
    case .claude: "claudecode"
    case .grok: "grok"
    }
  }
}
