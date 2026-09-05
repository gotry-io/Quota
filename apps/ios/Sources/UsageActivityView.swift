import QuotaWire
import SwiftUI

struct UsageActivitySection: View {
  @Bindable var model: AppModel
  @State private var selectedDate = ""

  var body: some View {
    Section {
      switch model.activityChart {
      case .idle, .loading:
        activityStatus("Loading activity", identifier: "usage.activity.loading")
        UsageActivitySkeleton()
      case .failed:
        activityStatus("Couldn't load activity.", identifier: "usage.activity.failed")
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
          activityStatus("No activity in the last year.", identifier: "usage.activity.empty")
        }
      }
    } header: {
      Text("Activity")
        .foregroundStyle(Color(uiColor: .label))
    }
    if case .failed = model.activityChart {
      Section {
        Button("Retry") {
          Task { await model.retryActivity() }
        }
        .tint(.primary)
        .accessibilityLabel("Retry")
        .accessibilityIdentifier("usage.activity.retry")
      }
    }
  }

  @ViewBuilder
  private func loaded(_ chart: UsageActivityChart) -> some View {
    Group {
      if let day = chart.selectableDay(on: selectedDate) {
        selectedDaySummary(day)
        Button("View day") {
          Task { await model.openActivityDay(date: day.date) }
        }
        .tint(.primary)
        .accessibilityHint("Shows usage for \(UsageActivityCalendar.longDate(day.date)).")
        .accessibilityIdentifier("usage.activity.view-day")
      }
      UsageActivityHeatmap(chart: chart, selectedDate: $selectedDate)
        .padding(.bottom, QuotaTheme.tabBarClearance)
    }
    .onAppear { ensureSelection(in: chart) }
    .onChange(of: chart.selectableDays.map(\.date)) { _, _ in
      ensureSelection(in: chart)
    }
  }

  private func selectedDaySummary(_ day: UsageActivityChart.Day) -> some View {
    let costText = QuotaFormat.cost(day.cost ?? UsageActivityChart.emptyCost())
    return VStack(alignment: .leading, spacing: 4) {
      BodyLabel(text: UsageActivityCalendar.longDate(day.date), style: .subheadline)
      BodyLabel(
        text: "\(QuotaFormat.compactCount(day.tokens)) · \(costText)",
        style: .subheadline,
        monospacedDigit: true
      )
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

  @ViewBuilder
  private func activityStatus(_ text: String, identifier: String?) -> some View {
    let row = BodyLabel(text: text)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement()
      .accessibilityLabel(text)
    if let identifier {
      row
        .accessibilityValue(text)
        .accessibilityIdentifier(identifier)
    } else {
      row
    }
  }
}

struct UsageActivitySkeleton: View {
  var body: some View {
    let cell: CGFloat = 8
    let gap: CGFloat = 3
    let stride = cell + gap
    Canvas { context, _ in
      for week in 0..<12 {
        for day in 0..<7 {
          let rect = CGRect(
            x: CGFloat(week) * stride,
            y: CGFloat(day) * stride,
            width: cell,
            height: cell
          )
          let path = RoundedRectangle(
            cornerRadius: 2,
            style: .continuous
          ).path(in: rect)
          context.fill(path, with: .color(QuotaTheme.meterTrack))
        }
      }
    }
    .frame(
      width: 12 * stride - gap,
      height: 7 * stride - gap
    )
    .accessibilityHidden(true)
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
    let stride = QuotaTheme.activityCellSize + QuotaTheme.activityCellGap
    let height = 16 + 7 * stride - QuotaTheme.activityCellGap
    return Canvas { context, _ in
      for (index, label) in UsageActivityCalendar.weekdayLabels.enumerated() where !label.isEmpty {
        let y = 16 + CGFloat(index) * stride + QuotaTheme.activityCellSize / 2
        context.draw(
          Text(label).font(.caption2).foregroundColor(.primary),
          at: CGPoint(x: 0, y: y),
          anchor: .leading
        )
      }
    }
    .frame(width: QuotaTheme.activityWeekdayWidth, height: height)
    .dynamicTypeSize(...DynamicTypeSize.large)
    .accessibilityHidden(true)
  }

  private var monthRow: some View {
    let width =
      weekWidth(chart.weeks.count) + QuotaTheme.activityMonthLabelOverflow
    return Canvas { context, _ in
      for label in chart.monthLabels {
        let x = weekWidth(label.weekIndex)
        context.draw(
          Text(label.label).font(.caption2).foregroundColor(.primary),
          at: CGPoint(x: x, y: 8),
          anchor: .leading
        )
      }
    }
    .frame(width: max(width, 0), height: 16)
    .dynamicTypeSize(...DynamicTypeSize.large)
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
        BodyLabel(text: "Loading this day's usage…")
          .accessibilityIdentifier("usage.day.loading")
      }
    case .failed:
      Section {
        BodyLabel(text: "Couldn't load this day's usage.")
        Button("Retry") {
          Task { await model.retryActivityDay() }
        }
        .tint(.primary)
        .accessibilityIdentifier("usage.day.retry")
      }
    case .empty:
      Section {
        BodyLabel(text: "No usage on this day.")
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
