import SwiftUI

struct QuotaStatTile: View {
  let label: String
  let value: String
  var caption: String? = nil
  var valueFont: Font = QuotaDesign.Typography.statValue
  var valueIdentifier: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(QuotaDesign.Typography.support)
        .foregroundStyle(.secondary)
      Text(value)
        .font(valueFont)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .modifier(QuotaOptionalIdentifier(valueIdentifier))
      if let caption {
        Text(caption)
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(.primary)
      }
    }
    .frame(minWidth: QuotaDesign.Layout.statTileMinWidth, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

struct QuotaStatGrid<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    grid(columns: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
  }

  private func grid(columns: Int) -> some View {
    let item = GridItem(
      .flexible(minimum: columns == 1 ? 0 : QuotaDesign.Layout.statTileMinWidth),
      spacing: QuotaDesign.Layout.rowSpacing
    )
    return LazyVGrid(
      columns: Array(repeating: item, count: columns),
      alignment: .leading,
      spacing: QuotaDesign.Layout.rowSpacing
    ) {
      content
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
