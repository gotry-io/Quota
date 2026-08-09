import SwiftUI

/// Unified Settings list row: fixed height, leading + title(+optional subtitle) + trailing.
/// Title-only rows center the title; rows with a subtitle stack title above meta.
struct SettingsListRow<Leading: View, Trailing: View>: View {
  let title: String
  var subtitle: String? = nil
  /// Single-line home rows vs stacked Agents/Devices rows.
  var height: CGFloat = QuotaDesign.Layout.settingsRowHeight
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing

  private var resolvedSubtitle: String? {
    guard let subtitle else { return nil }
    let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var body: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      leading()
        .frame(width: QuotaDesign.Layout.settingsIconColumnWidth, alignment: .center)

      if let resolvedSubtitle {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .quotaSettingsLabelStyle()
            .lineLimit(1)
          Text(resolvedSubtitle)
            .quotaListSecondaryStyle()
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(title)
          .quotaSettingsLabelStyle()
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      trailing()
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    // The row owns content inset; the hit surface still spans the full group width.
    .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
    .contentShape(Rectangle())
  }
}

extension SettingsListRow where Leading == SettingsListLeadingIcon {
  /// Convenience for SF Symbol leading marks (Settings home, Devices).
  init(
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    height: CGFloat = QuotaDesign.Layout.settingsRowHeight,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.height = height
    self.leading = { SettingsListLeadingIcon(systemImage: systemImage) }
    self.trailing = trailing
  }
}

struct SettingsListLeadingIcon: View {
  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .quotaFont(.secondary)
      .foregroundStyle(QuotaPalette.body)
      .frame(
        width: QuotaDesign.Layout.settingsIconColumnWidth,
        height: QuotaDesign.Layout.settingsIconColumnWidth
      )
  }
}
