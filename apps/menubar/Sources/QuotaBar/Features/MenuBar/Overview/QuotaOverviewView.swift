import QuotaWire
import SwiftUI

struct QuotaOverviewView: View {
  let model: MenuBarViewModel
  let enabledProviders: [ProviderID]
  let usageSource: UsageSource
  let now: Date
  let onOpenSettings: () -> Void

  var body: some View {
    QuotaNavigationStableContent(
      state: model.overviewState(enabledProviders: enabledProviders, now: now)
    ) { state in
      content(state)
    }
  }

  @ViewBuilder
  private func content(_ state: QuotaOverviewState) -> some View {
    switch state {
    case .loading:
      QuotaPageStateView(loadingTitle: "Reading quota…")
    case .unavailable(let message):
      QuotaPageStateView(
        errorTitle: "Quota Unavailable",
        message: message,
        retry: { Task { await model.refresh() } }
      )
    case .empty(let refreshWarning):
      VStack(spacing: 0) {
        if model.showsDerivedRepairNotice {
          RepairDerivedNotice(session: model.presentedRepair, now: now)
            .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
            .padding(.top, QuotaDesign.Layout.pageVerticalPadding)
        }
        if let refreshWarning {
          QuotaInlineNotice(message: refreshWarning)
            .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
            .padding(.top, QuotaDesign.Layout.pageVerticalPadding)
        }
        QuotaPageStateView(
          emptySystemImage: "eye.slash",
          title: "No Quota to Show",
          message: "Sign in to a provider CLI or enable an agent in Settings.",
          actionTitle: "Open Settings",
          action: onOpenSettings
        )
      }
    case .content(let providers, let refreshWarning):
      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: QuotaDesign.Spacing.sm) {
            if model.showsDerivedRepairNotice {
              RepairDerivedNotice(session: model.presentedRepair, now: now)
            }
            loadedProviderContent(providers: providers, refreshWarning: refreshWarning, now: now)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
        }

        if let today = model.todayUsageSummary(source: usageSource) {
          todayFooter(today)
        }
      }
    }
  }

  /// Quota is what Overview is for; today's spend is the one supporting number that belongs
  /// with it, so it sits below the list instead of scrolling away inside it.
  private func todayFooter(_ summary: UsageTodaySummary) -> some View {
    VStack(spacing: 0) {
      Divider()
        .opacity(0.35)

      Text(summary.text)
        .quotaMetaStyle()
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
        .padding(.vertical, QuotaDesign.Spacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel)
    }
  }

  private func loadedProviderContent(
    providers: [ProviderQuotaPresentation],
    refreshWarning: String?,
    now: Date
  ) -> some View {
    VStack(spacing: 0) {
      if let refreshWarning {
        QuotaInlineNotice(message: refreshWarning)
          .padding(.vertical, QuotaDesign.Spacing.sm)
      }

      ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
        ProviderQuotaView(presentation: provider, now: now)

        if index < providers.count - 1 {
          Divider()
        }
      }
    }
  }
}
