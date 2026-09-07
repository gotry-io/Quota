import QuotaWidgetData
import QuotaWidgetViews
import SwiftUI
import WidgetKit

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
  let kind = WidgetAppGroup.widgetKind

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: OverviewWidgetIntent.self,
      provider: OverviewTimelineProvider()
    ) { entry in
      OverviewWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Overview")
    .description("Remaining quota, reset, and Today Usage at a glance.")
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
