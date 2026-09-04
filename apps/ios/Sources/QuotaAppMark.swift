import SwiftUI

/// The 56-point Quota mark Connect and Confirm share. The glyph fills the frame so the two
/// screens cannot drift.
struct QuotaAppMark: View {
  var body: some View {
    Image(systemName: "gauge.with.dots.needle.33percent")
      .resizable()
      .scaledToFit()
      .foregroundStyle(QuotaTheme.emerald)
      .frame(width: 56, height: 56)
      .accessibilityLabel("Quota")
      .accessibilityAddTraits(.isImage)
  }
}
