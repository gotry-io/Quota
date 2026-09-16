import QuotaPresentation
import QuotaWire
import SwiftUI

/// Today's windows as columns: the same facts `QuotaHistoryCopy.todayLine` names, laid out
/// for width. The sentence itself stays on the panel.
struct DashboardTodayTable: View {
  let rows: [DashboardTodayRow]

  var body: some View {
    Group {
      if rows.isEmpty {
        Text("No windows with samples today")
          .quotaSecondaryStyle()
          .frame(maxWidth: .infinity, alignment: .leading)
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
              usedColumn(row)
                .frame(minWidth: 88, alignment: .trailing)
              Text(row.cost ?? "—")
                .quotaMonoListValueStyle()
                .frame(minWidth: 64, alignment: .trailing)
              Text(row.resetText)
                .quotaMetaStyle()
                .lineLimit(1)
                .frame(minWidth: 96, alignment: .trailing)
            }
            .frame(minHeight: QuotaDesign.Layout.todayRowHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.windowName)
            .accessibilityValue(accessibilityValue(row))
          }
        }
      }
    }
    .padding(QuotaDesign.Layout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaCardSurface()
  }

  private var header: some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      Text("Window")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Used")
        .frame(minWidth: 88, alignment: .trailing)
      Text("Cost")
        .frame(minWidth: 64, alignment: .trailing)
      Text("Reset")
        .frame(minWidth: 96, alignment: .trailing)
    }
    .quotaMetaStyle()
    .textCase(.uppercase)
    .accessibilityHidden(true)
  }

  private func usedColumn(_ row: DashboardTodayRow) -> some View {
    HStack(spacing: QuotaDesign.Spacing.xxs) {
      Text(QuotaHistoryCopy.peak(row.usedStartPercent))
      Text("→")
        .foregroundStyle(QuotaPalette.mute)
      Text(QuotaHistoryCopy.peak(row.usedNowPercent))
    }
    .quotaMonoListValueStyle()
    .monospacedDigit()
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
