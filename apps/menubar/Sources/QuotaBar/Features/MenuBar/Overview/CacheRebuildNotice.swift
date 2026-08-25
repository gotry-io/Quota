import SwiftUI

/// Shown at the top of Overview while the local cache is filling itself in again.
///
/// Quota and Account are read from elsewhere and stay current; only this Mac's own Usage history
/// is missing, and only until the next scan finishes. There is nothing for anyone to do about it,
/// so the notice says what is happening and offers no action.
struct CacheRebuildNotice: View {
  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text("Usage history is catching up")
        .quotaFont(.settingsLabel)
        .foregroundStyle(QuotaPalette.ink)
      Text("Quota and Account stay available.")
        .quotaListSecondaryStyle()
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaGroupSurface()
    .accessibilityElement(children: .combine)
  }
}
