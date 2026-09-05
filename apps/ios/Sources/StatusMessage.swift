import SwiftUI

struct StatusMessage: View {
  let symbolName: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbolName)
        .foregroundStyle(Color(uiColor: .label))
        .accessibilityHidden(true)
      Text(text)
        .foregroundStyle(Color(uiColor: .label))
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
  }
}
