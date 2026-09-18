import QuotaBrandIcons
import QuotaWire
import Testing

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

struct QuotaBrandIconsTests {
  @Test
  func everyKnownProviderResolvesACatalogImage() {
    for provider in ProviderID.allCases {
      #expect(
        catalogImage(named: provider.brandIconAssetName) != nil,
        "missing mark for \(provider.rawValue) (\(provider.brandIconAssetName))"
      )
    }
  }

  @Test
  func quotaBrandMarkResolvesACatalogImage() {
    #expect(catalogImage(named: "quota") != nil, "missing Quota mark")
  }
}

#if os(iOS)
  private func catalogImage(named name: String) -> UIImage? {
    Bundle.quotaBrandIcons.brandMarkUIImage(named: name)
  }
#elseif os(macOS)
  private func catalogImage(named name: String) -> NSImage? {
    Bundle.quotaBrandIcons.brandMarkNSImage(named: name)
  }
#endif
