import SwiftUI

struct UsagePlaceholderView: View {
  var body: some View {
    VStack(spacing: 12) {
      Text("Usage detail arrives with the next update.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: QuotaTheme.contentMaxWidth)
    .padding(.horizontal, QuotaTheme.contentGutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .accessibilityIdentifier("usage.root")
    .navigationTitle("Usage")
    .navigationBarTitleDisplayMode(.large)
  }
}
