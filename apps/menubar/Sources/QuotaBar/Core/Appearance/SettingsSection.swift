import SwiftUI

/// Shared Settings page section: quiet header + soft rounded group for body rows.
struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text(title)
        .quotaSectionHeaderStyle()
        .padding(.horizontal, 4)

      content()
        .padding(.horizontal, QuotaDesign.Spacing.sm)
        // No vertical group inset — row padding alone owns top/bottom so single- and
        // multi-row groups share the same per-row height.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(
            cornerRadius: QuotaDesign.Layout.groupCornerRadius,
            style: .continuous
          )
          .fill(QuotaPalette.settingsGroupFill)
        )
    }
  }
}
