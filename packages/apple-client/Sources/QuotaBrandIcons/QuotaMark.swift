import SwiftUI

/// The Quota wordmark from the brand catalog, sized in a square and tinted by the
/// caller's `foregroundStyle`.
public struct QuotaMark: View {
  let size: CGFloat

  public init(size: CGFloat) {
    self.size = size
  }

  public var body: some View {
    Image("quota", bundle: .module)
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
