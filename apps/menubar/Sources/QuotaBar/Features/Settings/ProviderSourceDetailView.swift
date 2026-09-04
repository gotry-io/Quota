import QuotaPresentation
import QuotaWire
import SwiftUI

/// Settings → Agents → <Provider> → one reporting source.
struct ProviderSourceDetailView: View {
  @Bindable var model: MenuBarViewModel
  let provider: ProviderID
  let identityKey: String
  let sourceID: String
  let displayName: String
  let now: Date

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Quota") {
          if let source {
            VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
              Text(freshnessLabel(source))
                .quotaSecondaryStyle()
              if let snapshot = source.snapshot {
                QuotaReadingWindowsView(snapshot: snapshot, isStale: source.isStale, now: now)
              }
            }
            .padding(QuotaDesign.Layout.groupContentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text("This source is no longer reporting.")
              .quotaSecondaryStyle()
              .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
              .frame(
                maxWidth: .infinity,
                minHeight: QuotaDesign.Layout.settingsRowHeight,
                alignment: .leading
              )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var item: LocalServiceOverviewItem? {
    model.overviewItem(provider: provider, identityKey: identityKey)
  }

  private var source: LocalServiceOverviewSource? {
    item?.sources.first { $0.sourceID == sourceID }
  }

  private func freshnessLabel(_ source: LocalServiceOverviewSource) -> String {
    FreshnessCopy.observation(
      state: source.isStale ? .stale : .available,
      observedAt: source.observedAt,
      now: now
    )
  }
}

struct QuotaReadingWindowsView: View {
  let snapshot: QuotaSnapshot
  let isStale: Bool
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      ForEach(snapshot.windows) { window in
        QuotaWindowRow(
          window: window,
          provider: snapshot.provider,
          isStale: isStale,
          now: now
        )
      }
    }
  }
}
