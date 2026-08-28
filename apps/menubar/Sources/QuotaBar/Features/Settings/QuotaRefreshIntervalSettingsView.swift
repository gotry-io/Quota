import SwiftUI

/// Settings → General → Refresh Interval: how often this Mac collects provider quota.
struct QuotaRefreshIntervalSettingsView: View {
  let selected: QuotaRefreshInterval
  let onSelect: (QuotaRefreshInterval) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(QuotaRefreshInterval.allCases) { option in
          Button {
            onSelect(option)
          } label: {
            SettingsListRow(title: option.label, systemImage: "clock") {
              Image(systemName: "checkmark")
                .quotaFont(.secondary)
                .foregroundStyle(QuotaPalette.accent)
                .opacity(option == selected ? 1 : 0)
            }
          }
          .buttonStyle(QuotaListRowButtonStyle())
          .accessibilityLabel(option.label)
          .accessibilityAddTraits(option == selected ? .isSelected : [])
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .quotaGroupSurface()
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }
}
