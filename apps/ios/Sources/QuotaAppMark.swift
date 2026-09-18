import QuotaBrandIcons
import SwiftUI

/// The Quota catalog mark Connect and About share. The glyph fills the frame so
/// those screens cannot drift.
struct QuotaAppMark: View {
  var size: CGFloat = QuotaDesign.Layout.quotaMarkWelcome

  var body: some View {
    QuotaMark(size: size)
      .foregroundStyle(QuotaTheme.emerald)
      .accessibilityLabel("Quota")
      .accessibilityAddTraits(.isImage)
  }
}
