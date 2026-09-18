import SwiftUI

struct QuotaCard<Content: View, Trailing: View>: View {
  var title: String? = nil
  var systemImage: String? = nil
  var titleIdentifier: String? = nil
  let trailing: Trailing
  let content: Content

  init(
    title: String? = nil,
    systemImage: String? = nil,
    titleIdentifier: String? = nil,
    @ViewBuilder content: () -> Content
  ) where Trailing == EmptyView {
    self.title = title
    self.systemImage = systemImage
    self.titleIdentifier = titleIdentifier
    trailing = EmptyView()
    self.content = content()
  }

  init(
    title: String? = nil,
    systemImage: String? = nil,
    titleIdentifier: String? = nil,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.titleIdentifier = titleIdentifier
    self.trailing = trailing()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Layout.rowSpacing) {
      if showsHeader {
        header
      }
      content
    }
    .padding(QuotaDesign.Layout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(
        cornerRadius: QuotaDesign.Layout.cardCornerRadius,
        style: .continuous
      )
    )
  }

  private var showsHeader: Bool {
    title != nil || systemImage != nil || Trailing.self != EmptyView.self
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 8) {
        titleCluster
        Spacer(minLength: 8)
        trailing
      }
      VStack(alignment: .leading, spacing: 8) {
        titleCluster
        trailing
      }
    }
  }

  private var titleCluster: some View {
    HStack(alignment: .center, spacing: 8) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(QuotaDesign.Typography.cardTitle)
          .foregroundStyle(.primary)
          .accessibilityHidden(true)
      }
      if let title {
        Text(title)
          .font(QuotaDesign.Typography.cardTitle)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
          .modifier(QuotaOptionalIdentifier(titleIdentifier))
      }
    }
  }
}

struct QuotaOptionalIdentifier: ViewModifier {
  var identifier: String?

  init(_ identifier: String?) {
    self.identifier = identifier
  }

  func body(content: Content) -> some View {
    if let identifier {
      content.accessibilityIdentifier(identifier)
    } else {
      content
    }
  }
}

extension View {
  /// Clears List chrome so a `QuotaCard` can sit in a row without a second background.
  func quotaCardRow() -> some View {
    listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
  }
}
