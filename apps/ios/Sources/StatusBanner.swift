import SwiftUI

struct StatusBanner: View {
  let symbolName: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbolName)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(minWidth: 24, minHeight: 24)
        .accessibilityHidden(true)
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface(showsStroke: true)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
  }
}
