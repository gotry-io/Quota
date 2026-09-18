import SwiftUI

struct QuotaCard<Content: View>: View {
  var title: String? = nil
  let content: Content

  init(title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Layout.rowSpacing) {
      if let title {
        Text(title)
          .font(QuotaDesign.Typography.cardTitle)
          .foregroundStyle(.primary)
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
}

extension View {
  /// Clears List chrome so a `QuotaCard` can sit in a row without a second background.
  func quotaCardRow() -> some View {
    listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
  }
}
