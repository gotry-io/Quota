import QuotaWidgetData
import SwiftUI
import WidgetKit

struct OverviewEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
  let isPlaceholder: Bool
}

struct OverviewTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> OverviewEntry {
    OverviewEntry(date: Date(), snapshot: nil, isPlaceholder: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (OverviewEntry) -> Void) {
    completion(
      OverviewEntry(
        date: Date(),
        snapshot: OverviewWidgetContent.loadSnapshot(),
        isPlaceholder: false
      )
    )
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<OverviewEntry>) -> Void) {
    let now = Date()
    let entry = OverviewEntry(
      date: now,
      snapshot: OverviewWidgetContent.loadSnapshot(),
      isPlaceholder: false
    )
    let timeline = Timeline(
      entries: [entry],
      policy: .after(OverviewWidgetContent.nextRefreshDate(from: now))
    )
    completion(timeline)
  }
}

struct OverviewWidget: Widget {
  let kind = OverviewWidgetContent.widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: OverviewTimelineProvider()) { entry in
      OverviewWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Overview")
    .description("Remaining quota and Today Usage at a glance.")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .accessoryCircular,
      .accessoryRectangular,
    ])
  }
}

struct OverviewWidgetEntryView: View {
  @Environment(\.widgetFamily) private var family
  var entry: OverviewEntry

  var body: some View {
    Group {
      switch family {
      case .systemSmall:
        OverviewSmallView(entry: entry)
      case .systemMedium:
        OverviewMediumView(entry: entry)
      case .accessoryCircular:
        OverviewCircularView(entry: entry)
      case .accessoryRectangular:
        OverviewRectangularView(entry: entry)
      default:
        OverviewSmallView(entry: entry)
      }
    }
    .widgetURL(OverviewWidgetContent.overviewURL)
    .containerBackground(for: .widget) {
      // iOS 26 system owns Liquid Glass / accented / vibrant rendering for this container.
      // Earlier systems fall back to the platform widget material.
      Color.clear
    }
  }
}
