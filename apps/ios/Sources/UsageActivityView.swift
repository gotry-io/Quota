import QuotaWire
import SwiftUI

struct UsageActivitySection: View {
  @Bindable var model: AppModel
  @State private var selectedDate = ""

  var body: some View {
    Section("Activity") {
      switch model.activityChart {
      case .idle, .loading:
        UsageActivitySkeleton()
      case .failed:
        Text("Couldn't load activity.")
          .foregroundStyle(.primary)
        Button("Retry") {
          Task { await model.retryActivity() }
        }
        .tint(.primary)
        .accessibilityLabel("Retry")
        .accessibilityIdentifier("usage.activity.retry")
      case .loaded(let days):
        if UsageActivityChart.hasReportedActivity(days) {
          loaded(
            UsageActivityChart.build(
              reported: days,
              range: model.activityDateRange,
              today: model.activityToday
            )
          )
        } else {
          Text("No activity in the last year.")
            .foregroundStyle(.primary)
            .accessibilityIdentifier("usage.activity.empty")
        }
      }
    }
  }

  @ViewBuilder
  private func loaded(_ chart: UsageActivityChart) -> some View {
    UsageActivityHeatmap(chart: chart, selectedDate: $selectedDate)
      .onAppear { ensureSelection(in: chart) }
      .onChange(of: chart.selectableDays.map(\.date)) { _, _ in
        ensureSelection(in: chart)
      }

    if let day = chart.selectableDay(on: selectedDate) {
      selectedDaySummary(day)
      Button("View day") {
        Task { await model.openActivityDay(date: day.date) }
      }
      .tint(.primary)
      .accessibilityHint("Shows usage for \(UsageActivityCalendar.longDate(day.date)).")
      .accessibilityIdentifier("usage.activity.view-day")
    }
  }

  private func selectedDaySummary(_ day: UsageActivityChart.Day) -> some View {
    let costText = QuotaFormat.cost(day.cost ?? UsageActivityChart.emptyCost())
    return VStack(alignment: .leading, spacing: 4) {
      Text(UsageActivityCalendar.longDate(day.date))
        .font(.subheadline)
      Text("\(QuotaFormat.compactCount(day.tokens)) · \(costText)")
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityHidden(true)
    .accessibilityIdentifier("usage.activity.selected-day")
  }

  private func ensureSelection(in chart: UsageActivityChart) {
    if chart.selectableDay(on: selectedDate) == nil {
      selectedDate = chart.defaultSelectedDate
    }
  }
}

struct UsageActivitySkeleton: View {
  var body: some View {
    let stride = QuotaTheme.activityCellSize + QuotaTheme.activityCellGap
    VStack(alignment: .leading, spacing: 8) {
      Text("Loading activity")
        .foregroundStyle(.primary)
        .accessibilityValue("Loading activity")
        .accessibilityIdentifier("usage.activity.loading")
      Canvas { context, _ in
        for week in 0..<16 {
          for day in 0..<7 {
            let rect = CGRect(
              x: CGFloat(week) * stride,
              y: CGFloat(day) * stride,
              width: QuotaTheme.activityCellSize,
              height: QuotaTheme.activityCellSize
            )
            let path = RoundedRectangle(
              cornerRadius: QuotaTheme.activityCellCorner,
              style: .continuous
            ).path(in: rect)
            context.fill(path, with: .color(QuotaTheme.meterTrack))
          }
        }
      }
      .frame(
        width: 16 * stride - QuotaTheme.activityCellGap,
        height: 7 * stride - QuotaTheme.activityCellGap
      )
      .dynamicTypeSize(...DynamicTypeSize.large)
      .accessibilityHidden(true)
    }
  }
}

struct UsageActivityHeatmap: View {
  let chart: UsageActivityChart
  @Binding var selectedDate: String

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
            .padding(.trailing, QuotaTheme.activityMonthLabelOverflow)
            .padding(.vertical, 3)
            .id("activity-end")
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
    .accessibilityHint("Adjusts the selected day.")
    .accessibilityAdjustableAction { direction in
      adjustSelection(direction)
    }
    .accessibilityIdentifier("usage.activity.heatmap")
  }

  private var selectedDay: UsageActivityChart.Day? {
    chart.selectableDay(on: selectedDate)
  }

  private var weekdayColumn: some View {
    VStack(alignment: .leading, spacing: QuotaTheme.activityCellGap) {
      Color.clear.frame(width: QuotaTheme.activityWeekdayWidth, height: 16)
      ForEach(Array(UsageActivityCalendar.weekdayLabels.enumerated()), id: \.offset) { _, label in
        Text(label.isEmpty ? " " : label)
          .font(.caption2)
          .foregroundStyle(.primary)
          .frame(width: QuotaTheme.activityWeekdayWidth, alignment: .leading)
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
          .foregroundStyle(.primary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .frame(
            minWidth: weekWidth(label.span) - QuotaTheme.activityCellGap,
            alignment: .leading
          )
      }
    }
    .accessibilityHidden(true)
  }

  private var weeksRow: some View {
    let stride = QuotaTheme.activityCellSize + QuotaTheme.activityCellGap
    let width = CGFloat(chart.weeks.count) * stride - QuotaTheme.activityCellGap
    let height = 7 * stride - QuotaTheme.activityCellGap
    return Canvas { context, _ in
      for (weekIndex, week) in chart.weeks.enumerated() {
        for (dayIndex, day) in week.enumerated() {
          guard !day.outside else { continue }
          let rect = CGRect(
            x: CGFloat(weekIndex) * stride,
            y: CGFloat(dayIndex) * stride,
            width: QuotaTheme.activityCellSize,
            height: QuotaTheme.activityCellSize
          )
          let path = RoundedRectangle(
            cornerRadius: QuotaTheme.activityCellCorner,
            style: .continuous
          ).path(in: rect)
          context.fill(path, with: .color(QuotaTheme.activityFill(day.level)))
          let selected = day.date == selectedDate
          context.stroke(
            path,
            with: .color(selected ? QuotaTheme.emerald : QuotaTheme.activityBorder(day.level)),
            lineWidth: selected ? 1.5 : 1
          )
          if day.today {
            let ring = RoundedRectangle(
              cornerRadius: QuotaTheme.activityCellCorner + 1,
              style: .continuous
            ).path(in: rect.insetBy(dx: -2, dy: -2))
            context.stroke(ring, with: .color(.primary), lineWidth: 2)
          }
        }
      }
    }
    .frame(width: max(width, 0), height: max(height, 0))
    .dynamicTypeSize(...DynamicTypeSize.large)
    .contentShape(Rectangle())
    .onTapGesture { location in
      select(at: location)
    }
    .gesture(
      DragGesture(minimumDistance: 12)
        .onChanged { value in
          select(at: value.location)
        }
    )
    .accessibilityHidden(true)
  }

  private var legend: some View {
    HStack(spacing: 6) {
      Text("Less")
        .font(.caption2)
        .foregroundStyle(.primary)
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
        .foregroundStyle(.primary)
    }
    .accessibilityHidden(true)
  }

  private func weekWidth(_ weeks: Int) -> CGFloat {
    CGFloat(weeks) * (QuotaTheme.activityCellSize + QuotaTheme.activityCellGap)
  }

  private func select(at point: CGPoint) {
    if let day = chart.nearestSelectableDay(
      atX: Double(point.x),
      atY: Double(point.y),
      cellSize: Double(QuotaTheme.activityCellSize),
      cellGap: Double(QuotaTheme.activityCellGap)
    ) {
      selectedDate = day.date
    }
  }

  private func adjustSelection(_ direction: AccessibilityAdjustmentDirection) {
    let increment: Bool
    switch direction {
    case .increment:
      increment = true
    case .decrement:
      increment = false
    @unknown default:
      return
    }
    if let next = chart.adjacentSelectableDay(from: selectedDate, increment: increment) {
      selectedDate = next.date
    }
  }
}

struct UsageDayDetailSheet: View {
  @Bindable var model: AppModel
  @State private var expandedProviderIDs: Set<String> = []
  @State private var detent: PresentationDetent = .large
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if let sheet = model.activityDaySheet {
          List {
            UsageTotalsSection(
              totals: sheet.headline.totals,
              cost: sheet.headline.cost,
              partial: sheet.headline.partial,
              partialCopy: "Some hours on this day were scanned incompletely.",
              identifier: "usage.day.headline"
            )
            agents(sheet)
          }
          .listStyle(.insetGrouped)
          .contentMargins(.bottom, 24, for: .scrollContent)
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
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationContentInteraction(.scrolls)
    .presentationDragIndicator(.visible)
    .presentationBackground(Color(uiColor: .systemGroupedBackground))
    .accessibilityIdentifier("usage.day")
  }

  @ViewBuilder
  private func agents(_ sheet: ActivityDaySheetState) -> some View {
    switch sheet.agents {
    case .loading:
      Section {
        Text("Loading this day's usage…")
          .foregroundStyle(.primary)
          .accessibilityIdentifier("usage.day.loading")
      }
    case .failed:
      Section {
        Text("Couldn't load this day's usage.")
          .foregroundStyle(.primary)
        Button("Retry") {
          Task { await model.retryActivityDay() }
        }
        .tint(.primary)
        .accessibilityIdentifier("usage.day.retry")
      }
    case .empty:
      Section {
        Text("No usage on this day.")
          .foregroundStyle(.primary)
          .accessibilityIdentifier("usage.day.empty")
      }
    case .loaded(let agents):
      UsageAgentListSections(
        sections: UsageBreakdown.sections(agents: agents),
        expandedProviderIDs: $expandedProviderIDs,
        modelIdentifier: "usage.day.model"
      )
    }
  }
}
