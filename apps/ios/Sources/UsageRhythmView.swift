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

      legend
        .accessibilityHidden(true)
    } header: {
      Text("Rhythm")
        .accessibilityIdentifier("section.header.rhythm")
    } footer: {
      Text(UsageTimeZoneCopy.name())
        .accessibilityIdentifier("section.footer.rhythm")
    }
  }

  private var legend: some View {
    let cell = QuotaTheme.activityCellSize
    let gap: CGFloat = 6
    let labelWidth: CGFloat = 36
    let width = labelWidth + gap + 5 * (cell + gap) + labelWidth
    return Canvas { context, _ in
      context.draw(
        Text("Less").font(.caption2).foregroundColor(.primary),
        at: CGPoint(x: 0, y: cell / 2),
        anchor: .leading
      )
      var x = labelWidth + gap
      for level in 0..<5 {
        let rect = CGRect(x: x, y: 0, width: cell, height: cell)
        let path = RoundedRectangle(
          cornerRadius: QuotaTheme.activityCellCorner,
          style: .continuous
        ).path(in: rect)
        context.fill(path, with: .color(QuotaTheme.activityFill(level)))
        context.stroke(path, with: .color(QuotaTheme.activityBorder(level)), lineWidth: 1)
        x += cell + gap
      }
      context.draw(
        Text("More").font(.caption2).foregroundColor(.primary),
        at: CGPoint(x: x, y: cell / 2),
        anchor: .leading
      )
    }
    .frame(width: width, height: cell)
    .accessibilityHidden(true)
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
        Canvas { context, _ in
          for weekday in 0..<7 {
            let y = CGFloat(weekday) * (cell + gap) + cell / 2
            context.draw(
              Text(Self.weekdayLabels[weekday]).font(.caption2).foregroundColor(
                QuotaTheme.secondary),
              at: CGPoint(x: 0, y: y),
              anchor: .leading
            )
          }
        }
        .frame(width: labelWidth, height: 7 * (cell + gap) - gap)
        .accessibilityHidden(true)
        VStack(spacing: gap) {
          ForEach(0..<7, id: \.self) { weekday in
            HStack(spacing: gap) {
              ForEach(0..<24, id: \.self) { hour in
                let tokens = weekday < weekdayHours.count && hour < weekdayHours[weekday].count
                  ? weekdayHours[weekday][hour]
                  : 0
                let level = UsageActivityChart.activityLevel(tokens, maximum: maximum)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                  .fill(QuotaTheme.activityFill(level))
                  .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                      .stroke(QuotaTheme.activityBorder(level), lineWidth: 1)
                  }
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
          .fill(hour.totalTokens > 0 ? QuotaTheme.emerald : QuotaTheme.meterTrack)
          .frame(maxWidth: .infinity)
          .frame(height: max(2, 36 * share))
      }
    }
    .frame(height: 36, alignment: .bottom)
  }
}
