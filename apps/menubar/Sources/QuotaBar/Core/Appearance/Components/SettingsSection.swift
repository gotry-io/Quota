import SwiftUI

/// Shared Settings page section: quiet header, optional trailing control, group or card body.
struct SettingsSection<Content: View, Trailing: View>: View {
  enum Chrome {
    /// Persistent grouped fill (`quotaGroupSurface`).
    case group
    /// Opaque card (`quotaCardSurface`) for the Agents provider list.
    case card
  }

  let title: String
  var chrome: Chrome = .group
  private let hasTrailing: Bool
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      header
        .zIndex(1)

      surfacedContent
    }
  }

  @ViewBuilder
  private var surfacedContent: some View {
    switch chrome {
    case .group:
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaGroupSurface()
    case .card:
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(
          RoundedRectangle(
            cornerRadius: QuotaDesign.Layout.cardCornerRadius,
            style: .continuous
          )
        )
        .quotaCardSurface()
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
  init(
    title: String,
    chrome: Chrome = .group,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.chrome = chrome
    self.hasTrailing = false
    self.trailing = { EmptyView() }
    self.content = content
  }
}

extension SettingsSection {
  init(
    title: String,
    chrome: Chrome = .group,
    @ViewBuilder trailing: @escaping () -> Trailing,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.chrome = chrome
    self.hasTrailing = true
    self.trailing = trailing
    self.content = content
  }
}
