import SwiftUI

/// Shared Settings page section: quiet header + soft rounded group for body rows.
struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text(title)
        .quotaSectionHeaderStyle()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)

      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaGroupSurface()
    }
  }
}
