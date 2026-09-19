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
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
      ForEach(providers) { provider in
        quotaCard(provider, now: now)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func quotaCard(_ provider: DashboardProvider, now: Date) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      header(provider, now: now)

      if let empty = provider.empty {
        emptyState(empty)
      } else {
        DashboardQuotaChart(series: provider.series, now: now)
      }
    }
    .padding(QuotaDesign.Layout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaCardSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(headerLine(provider, now: now))
  }

  private func header(_ provider: DashboardProvider, now: Date) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
      HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
        HStack(spacing: QuotaDesign.Spacing.iconLabel) {
          ProviderBrandIcon(
            provider: provider.provider,
            size: QuotaDesign.Layout.settingsIconColumnWidth
          )
          VStack(alignment: .leading, spacing: 0) {
            Text(provider.provider.displayName)
              .quotaRowTitleStyle()
              .lineLimit(1)
            if let accountLabel = provider.accountLabel {
              Text(accountLabel)
                .quotaMetaStyle()
                .lineLimit(1)
            }
          }
        }
        .accessibilityAddTraits(.isHeader)

        Spacer(minLength: 0)

        if let remaining = provider.remainingPercent {
          VStack(alignment: .trailing, spacing: 0) {
            Text(RemainingQuotaFormat.percent(remaining))
              .font(QuotaDesign.Typography.statValue)
              .foregroundStyle(QuotaPalette.ink)
              .monospacedDigit()
              .lineLimit(1)
              .minimumScaleFactor(0.6)
            Text("remaining")
              .quotaMetaStyle()
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(RemainingQuotaFormat.percent(remaining)) remaining")
        }
      }

      if let subtitle = subtitleLine(provider, now: now) {
        Text(subtitle)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
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

  private func subtitleLine(_ provider: DashboardProvider, now: Date) -> String? {
    var parts: [String] = []
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
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func headerLine(_ provider: DashboardProvider, now: Date) -> String {
    var parts = [provider.provider.displayName]
    if let accountLabel = provider.accountLabel {
      parts.append(accountLabel)
    }
    if let remaining = provider.remainingPercent {
      parts.append("\(RemainingQuotaFormat.percent(remaining)) remaining")
    }
    if let subtitle = subtitleLine(provider, now: now) {
      parts.append(subtitle)
    }
    return parts.joined(separator: " · ")
  }
}
