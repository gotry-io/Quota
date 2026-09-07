import SwiftUI
import WidgetKit

/// The one Overview widget body every Apple platform draws. Each extension declares the widget
/// and its timeline; which families reach here is the extension's `supportedFamilies`.
public struct OverviewWidgetEntryView: View {
  @Environment(\.widgetFamily) private var family
  var entry: OverviewEntry

  public init(entry: OverviewEntry) { self.entry = entry }

  public var body: some View {
    familyView
      .widgetURL(widgetURL)
      .containerBackground(for: .widget) {
        // iOS 26 system owns Liquid Glass / accented / vibrant rendering for this container.
        Color.clear
      }
  }

  @ViewBuilder
  private var familyView: some View {
    switch family {
    case .systemSmall:
      OverviewSmallView(entry: entry)
    case .systemMedium:
      OverviewMediumView(entry: entry)
    case .systemLarge:
      OverviewLargeView(entry: entry)
    default:
      accessoryView
    }
  }

  /// The widget as a whole. A family showing one subscription opens that subscription; one
  /// showing several keeps Overview.
  private var widgetURL: URL {
    switch family {
    case .systemSmall:
      OverviewWidgetContent.widgetURL(
        for: OverviewWidgetContent.smallItems(
          from: entry.snapshot,
          configuredSelectionID: entry.configuredSelectionID
        )
      )
    case .systemMedium:
      OverviewWidgetContent.widgetURL(
        for: OverviewWidgetContent.mediumItems(
          from: entry.snapshot,
          configuredSelectionID: entry.configuredSelectionID
        )
      )
    case .systemLarge:
      OverviewWidgetContent.widgetURL(
        for: OverviewWidgetContent.largeItems(
          from: entry.snapshot,
          configuredSelectionID: entry.configuredSelectionID
        )
      )
    default:
      OverviewWidgetContent.lockScreenURL(
        from: entry.snapshot,
        configuredSelectionID: entry.configuredSelectionID
      )
    }
  }

  @ViewBuilder
  private var accessoryView: some View {
    #if os(iOS)
      switch family {
      case .accessoryCircular:
        OverviewCircularView(entry: entry)
      case .accessoryRectangular:
        OverviewRectangularView(entry: entry)
      case .accessoryInline:
        OverviewInlineView(entry: entry)
      default:
        OverviewSmallView(entry: entry)
      }
    #else
      OverviewSmallView(entry: entry)
    #endif
  }
}
