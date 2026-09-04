import QuotaWire
import SwiftUI

struct UsageActivityCard: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Activity")
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      switch model.activityChart {
      case .idle, .loading:
        UsageActivitySkeleton()
      case .failed:
        failed
      case .loaded(let days):
        UsageActivityHeatmap(
          chart: UsageActivityChart.build(
            reported: days,
            range: model.activityDateRange,
            today: model.activityToday
          ),
          onSelect: { day in
            Task { await model.openActivityDay(date: day.date) }
          }
        )
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
    .accessibilityIdentifier("usage.activity")
  }

  private var failed: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Could not load activity.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Retry") {
        Task { await model.retryActivity() }
      }
      .font(.subheadline.weight(.medium))
      .foregroundStyle(QuotaTheme.emerald)
      .frame(minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
      .contentShape(Rectangle())
      .accessibilityIdentifier("usage.activity.retry")
    }
  }
}

struct UsageActivitySkeleton: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(QuotaTheme.meterTrack)
        .frame(width: 120, height: 8)
      HStack(alignment: .top, spacing: 8) {
        VStack(spacing: QuotaTheme.activityCellGap) {
          ForEach(0..<7, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(QuotaTheme.meterTrack)
              .frame(width: 18, height: QuotaTheme.activityCellSize)
          }
        }
        HStack(spacing: QuotaTheme.activityCellGap) {
          ForEach(0..<16, id: \.self) { _ in
            VStack(spacing: QuotaTheme.activityCellGap) {
              ForEach(0..<7, id: \.self) { _ in
                RoundedRectangle(
                  cornerRadius: QuotaTheme.activityCellCorner,
                  style: .continuous
                )
                .fill(QuotaTheme.meterTrack)
                .frame(
                  width: QuotaTheme.activityCellSize,
                  height: QuotaTheme.activityCellSize
                )
              }
            }
          }
        }
      }
    }
    .redacted(reason: .placeholder)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading activity")
    .accessibilityIdentifier("usage.activity.loading")
  }
}

struct UsageActivityHeatmap: View {
  let chart: UsageActivityChart
  var onSelect: (UsageActivityChart.Day) -> Void
  @State private var selectedDate: String

  init(chart: UsageActivityChart, onSelect: @escaping (UsageActivityChart.Day) -> Void) {
    self.chart = chart
    self.onSelect = onSelect
    let today = chart.days.first(where: \.today)?.date ?? chart.selectableDays.last?.date ?? ""
    _selectedDate = State(initialValue: today)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        weekdayColumn
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
              monthRow
              weeksRow
            }
            .padding(.trailing, 2)
            .padding(.vertical, 3)
          }
          .task {
            proxy.scrollTo("activity-end", anchor: .trailing)
          }
        }
      }
      legend
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Usage activity")
    .accessibilityValue(selectedDay?.accessibilityValue ?? "No day selected")
    .accessibilityHint("Adjusts the selected day. Activates to show this day's usage.")
    .accessibilityAddTraits(.isButton)
    .accessibilityAdjustableAction { direction in
      adjustSelection(direction)
    }
    .accessibilityAction {
      if let day = selectedDay {
        onSelect(day)
      }
    }
  }

  private var selectedDay: UsageActivityChart.Day? {
    chart.days.first { $0.date == selectedDate && !$0.outside }
  }

  private var weekdayColumn: some View {
    VStack(alignment: .leading, spacing: QuotaTheme.activityCellGap) {
      Color.clear.frame(height: 14)
      ForEach(Array(UsageActivityCalendar.weekdayLabels.enumerated()), id: \.offset) { _, label in
        Text(label)
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .frame(
            width: QuotaTheme.activityWeekdayWidth,
            height: QuotaTheme.activityCellSize,
            alignment: .leading
          )
      }
    }
    .accessibilityHidden(true)
  }

  private var monthRow: some View {
    HStack(alignment: .bottom, spacing: 0) {
      if let first = chart.monthLabels.first, first.weekIndex > 0 {
        Color.clear.frame(width: weekWidth(first.weekIndex))
      }
      ForEach(chart.monthLabels) { label in
        Text(label.label)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(width: weekWidth(label.span) - QuotaTheme.activityCellGap, alignment: .leading)
      }
    }
    .accessibilityHidden(true)
  }

  private var weeksRow: some View {
    HStack(alignment: .top, spacing: QuotaTheme.activityCellGap) {
      ForEach(Array(chart.weeks.enumerated()), id: \.offset) { index, week in
        VStack(spacing: QuotaTheme.activityCellGap) {
          ForEach(week) { day in
            cell(day)
          }
        }
        .id(index == chart.weeks.count - 1 ? "activity-end" : "week-\(index)")
      }
    }
  }

  private func cell(_ day: UsageActivityChart.Day) -> some View {
    let selected = !day.outside && day.date == selectedDate
    return Button {
      guard !day.outside else { return }
      selectedDate = day.date
      onSelect(day)
    } label: {
      RoundedRectangle(cornerRadius: QuotaTheme.activityCellCorner, style: .continuous)
        .fill(day.outside ? Color.clear : QuotaTheme.activityFill(day.level))
        .overlay {
          if !day.outside {
            RoundedRectangle(cornerRadius: QuotaTheme.activityCellCorner, style: .continuous)
              .strokeBorder(
                selected ? QuotaTheme.emerald : QuotaTheme.activityBorder(day.level),
                lineWidth: selected ? 1.5 : 1
              )
          }
        }
        .overlay {
          if day.today {
            RoundedRectangle(cornerRadius: QuotaTheme.activityCellCorner + 1, style: .continuous)
              .strokeBorder(Color.primary, lineWidth: 2)
              .padding(-2)
          }
        }
        .frame(width: QuotaTheme.activityCellSize, height: QuotaTheme.activityCellSize)
        .opacity(day.outside ? 0 : 1)
    }
    .buttonStyle(.plain)
    .disabled(day.outside)
    .accessibilityHidden(true)
  }

  private var legend: some View {
    HStack(spacing: 6) {
      Text("Less")
        .font(.caption2)
        .foregroundStyle(.secondary)
      ForEach(0..<5, id: \.self) { level in
        RoundedRectangle(cornerRadius: QuotaTheme.activityCellCorner, style: .continuous)
          .fill(QuotaTheme.activityFill(level))
          .overlay {
            RoundedRectangle(cornerRadius: QuotaTheme.activityCellCorner, style: .continuous)
              .strokeBorder(QuotaTheme.activityBorder(level), lineWidth: 1)
          }
          .frame(width: QuotaTheme.activityCellSize, height: QuotaTheme.activityCellSize)
      }
      Text("More")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityHidden(true)
  }

  private func weekWidth(_ weeks: Int) -> CGFloat {
    CGFloat(weeks) * (QuotaTheme.activityCellSize + QuotaTheme.activityCellGap)
  }

  private func adjustSelection(_ direction: AccessibilityAdjustmentDirection) {
    let selectable = chart.selectableDays
    guard let index = selectable.firstIndex(where: { $0.date == selectedDate }) else {
      selectedDate = selectable.last?.date ?? selectedDate
      return
    }
    switch direction {
    case .increment:
      if index + 1 < selectable.count {
        selectedDate = selectable[index + 1].date
      }
    case .decrement:
      if index > 0 {
        selectedDate = selectable[index - 1].date
      }
    @unknown default:
      break
    }
  }
}

struct UsageDayDetailSheet: View {
  @Bindable var model: AppModel
  @State private var expandedProviderIDs: Set<String> = []
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if let sheet = model.activityDaySheet {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
              headline(sheet.headline)
              agents(sheet)
            }
            .frame(maxWidth: QuotaTheme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, QuotaTheme.contentGutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
          }
          .navigationTitle(QuotaFormat.utcLongDate(sheet.date))
          .navigationBarTitleDisplayMode(.inline)
        }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .accessibilityIdentifier("usage.day")
  }

  private func headline(_ day: UsageActivityDay) -> some View {
    UsageHeadlineCard(
      totals: day.totals,
      cost: day.cost,
      partial: day.partial,
      partialCopy: "Some hours on this day were scanned incompletely.",
      basisCopy: QuotaFormat.costBasis(day.cost),
      identifier: "usage.day.headline"
    )
  }

  @ViewBuilder
  private func agents(_ sheet: ActivityDaySheetState) -> some View {
    switch sheet.agents {
    case .loading:
      daySkeleton
    case .failed:
      VStack(alignment: .leading, spacing: 8) {
        Text("Could not load this day's usage.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry") {
          Task { await model.retryActivityDay() }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(QuotaTheme.emerald)
        .frame(minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("usage.day.retry")
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .quotaSurface()
    case .empty:
      Text("No Usage on this day.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaSurface()
        .accessibilityIdentifier("usage.day.empty")
    case .loaded(let agents):
      ForEach(UsageBreakdown.sections(agents: agents)) { section in
        UsageAgentCard(section: section, expandedProviderIDs: $expandedProviderIDs)
      }
    }
  }

  private var daySkeleton: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(0..<3, id: \.self) { _ in
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(QuotaTheme.meterTrack)
          .frame(height: 16)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
    .redacted(reason: .placeholder)
    .accessibilityLabel("Loading this day's usage")
    .accessibilityIdentifier("usage.day.loading")
  }
}
