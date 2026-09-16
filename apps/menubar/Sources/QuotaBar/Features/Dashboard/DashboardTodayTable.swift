import QuotaPresentation
import QuotaWire
import SwiftUI

/// Today's windows as columns: the same facts `QuotaHistoryCopy.todayLine` names, laid out
/// for width. The sentence itself stays on the panel.
struct DashboardTodayTable: View {
  let rows: [DashboardTodayRow]

  var body: some View {
    SettingsSection(title: "Today") {
      if rows.isEmpty {
        Text("No windows with samples today")
          .quotaSecondaryStyle()
          .padding(.horizontal, QuotaDesign.Layout.groupContentInset * 2)
          .padding(.vertical, QuotaDesign.Layout.groupContentInset)
      } else {
        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
          header
          ForEach(rows) { row in
            HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.sm) {
              Text(row.windowName)
                .quotaFont(.listSecondary)
                .foregroundStyle(QuotaPalette.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(row.usedLine)
                .quotaMonoListValueStyle()
                .monospacedDigit()
                .frame(minWidth: 88, alignment: .trailing)
              Text(row.cost ?? "—")
                .quotaMonoListValueStyle()
                .frame(minWidth: 64, alignment: .trailing)
              Text(row.resetText)
                .quotaMetaStyle()
                .lineLimit(1)
                .frame(minWidth: 96, alignment: .trailing)
            }
            .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
            .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.windowName)
            .accessibilityValue(accessibilityValue(row))
          }
        }
        .padding(.vertical, QuotaDesign.Spacing.sm)
      }
    }
  }

  private var header: some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      Text("Window")
        .quotaMetaStyle()
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Used")
        .quotaMetaStyle()
        .frame(minWidth: 88, alignment: .trailing)
      Text("Cost")
        .quotaMetaStyle()
        .frame(minWidth: 64, alignment: .trailing)
      Text("Reset")
        .quotaMetaStyle()
        .frame(minWidth: 96, alignment: .trailing)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .accessibilityHidden(true)
  }

  private func accessibilityValue(_ row: DashboardTodayRow) -> String {
    var parts = [row.usedLine]
    if let cost = row.cost {
      parts.append(cost)
    }
    parts.append(row.resetText)
    return parts.joined(separator: ", ")
  }
}
