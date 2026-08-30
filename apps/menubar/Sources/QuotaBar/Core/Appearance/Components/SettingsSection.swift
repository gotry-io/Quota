import SwiftUI

/// Shared Settings page section: quiet header, optional trailing control, group body.
struct SettingsSection<Content: View, Trailing: View>: View {
  let title: String
  private let hasTrailing: Bool
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      header
        .zIndex(1)

      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaGroupSurface()
    }
  }

  @ViewBuilder
  private var header: some View {
    if hasTrailing {
      HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
        Text(title)
          .quotaSectionHeaderStyle()
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        trailing()
          .layoutPriority(1)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    } else {
      Text(title)
        .quotaSectionHeaderStyle()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    }
  }
}

extension SettingsSection where Trailing == EmptyView {
  init(title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.hasTrailing = false
    self.trailing = { EmptyView() }
    self.content = content
  }
}

extension SettingsSection {
  init(
    title: String,
    @ViewBuilder trailing: @escaping () -> Trailing,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.hasTrailing = true
    self.trailing = trailing
    self.content = content
  }
}
