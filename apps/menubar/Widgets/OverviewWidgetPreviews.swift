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

#Preview("Medium content", as: .systemMedium) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Large content", as: .systemLarge) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}
