import SwiftUI

/// Shared Settings page section chrome (title + body).
struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text(title)
        .quotaSectionHeaderStyle()
      content()
    }
  }
}
