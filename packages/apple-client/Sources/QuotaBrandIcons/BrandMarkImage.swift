import Foundation

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

extension Bundle {
  #if os(macOS)
    /// Catalog mark as an `NSImage`.
    ///
    /// Xcode compiles `BrandIcons.xcassets` to `Assets.car`, which
    /// `image(forResource:)` reads. `swift build` copies the catalog folder, so
    /// the SVG is loaded from the imageset instead.
    public func brandMarkNSImage(named name: String) -> NSImage? {
      if let image = image(forResource: name) {
        return image
      }
      return url(
        forResource: name,
        withExtension: "svg",
        subdirectory: "BrandIcons.xcassets/\(name).imageset"
      ).flatMap { NSImage(contentsOf: $0) }
    }
  #endif

  #if os(iOS)
    public func brandMarkUIImage(named name: String) -> UIImage? {
      UIImage(named: name, in: self, with: nil)
    }
  #endif
}
