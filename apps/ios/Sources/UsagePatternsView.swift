import SwiftUI

/// Rhythm and the year Activity heatmap, with their legends and timezone.
struct UsagePatternsView: View {
  @Bindable var model: AppModel

  var body: some View {
    List {
      if let hours = model.usage.activityRhythm.hours {
        UsageRhythmSection(hoursOfDay: hours.hoursOfDay, weekdayHours: hours.weekdayHours)
      }
      UsageActivitySection(model: model)
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Activity patterns")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("usage.patterns")
    .task {
      await model.usage.loadActivity()
    }
    .task(id: model.usage.usagePeriodTitle) {
      await model.usage.loadRhythm()
    }
  }
}
