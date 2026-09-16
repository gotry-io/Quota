import QuotaPresentation
import QuotaWire
import SwiftUI

/// Quota cards for the main window Quota page.
struct DashboardView: View {
  var dashboard: DashboardModel
  let now: Date

  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback

  var body: some View {
    let providers = dashboard.displayedProviders(now: now)
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
        ForEach(providers) { provider in
          quotaCard(provider, now: now)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func quotaCard(_ provider: DashboardProvider, now: Date) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Text(headerLine(provider, now: now))
        .quotaFont(.settingsLabel)
        .foregroundStyle(QuotaPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      if let empty = provider.empty {
        emptyState(empty)
      } else {
        DashboardQuotaChart(series: provider.series, now: now)
      }
    }
    .padding(QuotaDesign.Layout.groupContentInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaGroupSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(headerLine(provider, now: now))
  }

  @ViewBuilder
  private func emptyState(_ empty: DashboardEmptyState) -> some View {
    switch empty {
    case .rebuilding:
      CacheRebuildNotice()
    case .notSignedIn(let line):
      Text(line)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
    case .noHistory:
      Text("No history yet")
        .quotaSecondaryStyle()
    }
  }

  private func headerLine(_ provider: DashboardProvider, now: Date) -> String {
    var parts = [provider.provider.displayName]
    if let pace = provider.pacePhrase {
      parts.append(pace)
    }
    if let resetsAt = provider.resetsAt,
      let reset = FreshnessCopy.resetCopy(
        resetsAt: resetsAt, now: now, style: resetCopyStyle.style)
    {
      parts.append(reset)
    }
    if let peak = provider.peak {
      parts.append(peak)
    }
    return parts.joined(separator: " · ")
  }
}
