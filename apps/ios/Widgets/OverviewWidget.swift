import QuotaWidgetData
import SwiftUI
import WidgetKit

struct OverviewEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
  let isPlaceholder: Bool
  let configuredSelectionID: String?

  var selectedItems: [WidgetQuotaItem] {
    OverviewWidgetContent.select(
      items: snapshot?.items ?? [],
      configuredSelectionID: configuredSelectionID
    )
  }
}

struct OverviewTimelineProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> OverviewEntry {
    OverviewEntry(date: Date(), snapshot: nil, isPlaceholder: true, configuredSelectionID: nil)
  }

  func snapshot(for configuration: OverviewWidgetIntent, in context: Context) async
    -> OverviewEntry
  {
    makeEntry(configuration: configuration, date: Date())
  }

  func timeline(for configuration: OverviewWidgetIntent, in context: Context) async
    -> Timeline<OverviewEntry>
  {
    let now = Date()
    let entry = makeEntry(configuration: configuration, date: now)
    return Timeline(
      entries: [entry],
      policy: .after(OverviewWidgetContent.nextRefreshDate(from: now))
    )
  }

  private func makeEntry(configuration: OverviewWidgetIntent, date: Date) -> OverviewEntry {
    OverviewEntry(
      date: date,
      snapshot: OverviewWidgetContent.loadSnapshot(),
      isPlaceholder: false,
      configuredSelectionID: configuration.subscription?.id
    )
  }
}

struct OverviewWidget: Widget {
  let kind = OverviewWidgetContent.widgetKind

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: OverviewWidgetIntent.self,
      provider: OverviewTimelineProvider()
    ) { entry in
      OverviewWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Overview")
    .description("Remaining quota and Today Usage at a glance.")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .systemLarge,
      .accessoryCircular,
      .accessoryRectangular,
      .accessoryInline,
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
      case .systemLarge:
        OverviewLargeView(entry: entry)
      case .accessoryCircular:
        OverviewCircularView(entry: entry)
      case .accessoryRectangular:
        OverviewRectangularView(entry: entry)
      case .accessoryInline:
        OverviewInlineView(entry: entry)
      default:
        OverviewSmallView(entry: entry)
      }
    }
    .widgetURL(OverviewWidgetContent.widgetURL(for: entry.selectedItems))
    .containerBackground(for: .widget) {
      // iOS 26 system owns Liquid Glass / accented / vibrant rendering for this container.
      Color.clear
    }
  }
}
