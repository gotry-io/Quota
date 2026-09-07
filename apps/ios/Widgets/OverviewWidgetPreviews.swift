import QuotaWidgetViews
import SwiftUI
import WidgetKit

#Preview("Small content", as: .systemSmall) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Small no data", as: .systemSmall) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Small placeholder", as: .systemSmall) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Medium content", as: .systemMedium) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Medium no data", as: .systemMedium) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Medium placeholder", as: .systemMedium) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Large content", as: .systemLarge) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Large no data", as: .systemLarge) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Large placeholder", as: .systemLarge) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Circular content", as: .accessoryCircular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Circular no data", as: .accessoryCircular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Circular placeholder", as: .accessoryCircular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Rectangular content", as: .accessoryRectangular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Rectangular no data", as: .accessoryRectangular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Rectangular placeholder", as: .accessoryRectangular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Inline content", as: .accessoryInline) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Inline no data", as: .accessoryInline) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Inline placeholder", as: .accessoryInline) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}
