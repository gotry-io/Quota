import QuotaPresentation
import QuotaWire
import SwiftUI

/// Weekday × hour heatmap and the 24-hour bars of the selected period.
struct UsageRhythmSection: View {
  let hoursOfDay: [QuotaWire.UsageHourOfDay]
  let weekdayHours: [[Int]]

  private static let weekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]

  var body: some View {
    Section {
      heatmap
        .frame(height: heatmapHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage by weekday and hour")
        .accessibilityIdentifier("usage.rhythm.heatmap")

      bars
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage by hour of the day")
        .accessibilityIdentifier("usage.rhythm.bars")
    } header: {
      Text("Rhythm")
        .accessibilityIdentifier("section.header.rhythm")
    }
  }

  private var heatmapHeight: CGFloat {
    7 * (QuotaTheme.activityCellSize + QuotaTheme.activityCellGap) - QuotaTheme.activityCellGap
  }

  private var heatmap: some View {
    let maximum = weekdayHours.flatMap { $0 }.max() ?? 0
    return GeometryReader { proxy in
      let labelWidth: CGFloat = 16
      let gap = QuotaTheme.activityCellGap
      let cell = max(
        4,
        min(
          QuotaTheme.activityCellSize,
          (proxy.size.width - labelWidth - gap * 24) / 24
        )
      )
      HStack(alignment: .top, spacing: 4) {
        VStack(spacing: gap) {
          ForEach(0..<7, id: \.self) { weekday in
            Text(Self.weekdayLabels[weekday])
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: labelWidth, height: cell, alignment: .leading)
          }
        }
        VStack(spacing: gap) {
          ForEach(0..<7, id: \.self) { weekday in
            HStack(spacing: gap) {
              ForEach(0..<24, id: \.self) { hour in
                let tokens = weekday < weekdayHours.count && hour < weekdayHours[weekday].count
                  ? weekdayHours[weekday][hour]
                  : 0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                  .fill(QuotaTheme.activityFill(UsageActivityChart.activityLevel(tokens, maximum: maximum)))
                  .frame(width: cell, height: cell)
              }
            }
          }
        }
      }
    }
  }

  private var bars: some View {
    let maximum = hoursOfDay.map(\.totalTokens).max() ?? 0
    return HStack(alignment: .bottom, spacing: 2) {
      ForEach(hoursOfDay, id: \.hour) { hour in
        let share = maximum > 0 ? CGFloat(hour.totalTokens) / CGFloat(maximum) : 0
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(Color.primary.opacity(hour.totalTokens > 0 ? 0.55 : 0.12))
          .frame(maxWidth: .infinity)
          .frame(height: max(2, 36 * share))
      }
    }
    .frame(height: 36, alignment: .bottom)
  }
}
