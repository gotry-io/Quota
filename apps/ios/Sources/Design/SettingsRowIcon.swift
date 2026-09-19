import SwiftUI

/// Leading rounded-square icon for a Settings hub row (28pt at the default type size): white SF
/// Symbol on a tinted fill, matching the system Settings list.
struct SettingsRowIcon: View {
  let symbol: String
  let tint: Color

  /// The tile grows with the row's text, like the system Settings icons, and the glyph is sized
  /// from the tile, so a large type size never pushes the white glyph out onto the white card.
  @ScaledMetric(relativeTo: .body) private var scaledSide = QuotaDesign.Layout.settingsRowIconSize

  private var side: CGFloat {
    min(scaledSide, QuotaDesign.Layout.settingsRowIconSize * 1.75)
  }

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: side * 0.55, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: side, height: side)
      .background(
        tint,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}
