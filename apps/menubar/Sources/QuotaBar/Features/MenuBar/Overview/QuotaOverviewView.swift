import SwiftUI

struct QuotaOverviewView: View {
  let model: MenuBarViewModel
  let enabledProviders: [ProviderID]
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
      ScrollView {
        loadedProviderContent(providers: providers, refreshWarning: refreshWarning, now: now)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      }
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
