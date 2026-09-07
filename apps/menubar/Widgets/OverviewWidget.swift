import QuotaWidgetData
import QuotaWidgetViews
import SwiftUI
import WidgetKit

/// Desktop Overview. The extension reads only the App Group snapshot QuotaBar publishes and
/// re-draws it on a local timeline; it never talks to the private service or to Relay
/// (`docs/decisions/0014-nonsecret-ios-widget-snapshot.md`).
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
    return Timeline(
      entries: [makeEntry(configuration: configuration, date: now)],
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
    // The desktop has no Lock Screen: the accessory families are iPhone's.
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
