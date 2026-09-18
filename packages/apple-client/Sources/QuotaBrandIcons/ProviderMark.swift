import QuotaWire
import SwiftUI

/// A catalog provider mark, sized in a square and tinted by the caller's `foregroundStyle`.
public struct ProviderMark: View {
  let provider: ProviderID
  let size: CGFloat

  public init(provider: ProviderID, size: CGFloat) {
    self.provider = provider
    self.size = size
  }

  public var body: some View {
    Image(provider.brandIconAssetName, bundle: .module)
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
