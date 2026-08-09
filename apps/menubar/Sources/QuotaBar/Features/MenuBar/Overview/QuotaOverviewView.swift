import SwiftUI

struct QuotaOverviewView: View {
  let model: MenuBarViewModel
  let enabledProviders: [ProviderID]
  let now: Date
  let onOpenSettings: () -> Void

  var body: some View {
    ScrollView {
      providerContent(now: now)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    }
  }

  @ViewBuilder
  private func providerContent(now: Date) -> some View {
    switch model.overviewState(enabledProviders: enabledProviders, now: now) {
    case .loading:
      OverviewEmptyStateView(
        systemImage: "gauge.with.dots.needle.50percent",
        title: "Reading Quota",
        message: "Checking local and remote quota."
      )
    case .unavailable(let message):
      OverviewEmptyStateView(
        systemImage: "exclamationmark.circle",
        title: "Quota Unavailable",
        message: message,
        actionTitle: "Retry"
      ) {
        Task { await model.refresh() }
      }
    case .empty(let refreshWarning):
      VStack(spacing: 0) {
        if let refreshWarning {
          InlineRefreshError(message: refreshWarning)
        }
        OverviewEmptyStateView(
          systemImage: "eye.slash",
          title: "No Quota to Show",
          message: "Sign in to a provider CLI, pair a remote device, or enable an agent in Settings.",
          actionTitle: "Open Settings",
          action: onOpenSettings
        )
      }
    case .content(let providers, let refreshWarning):
      loadedProviderContent(providers: providers, refreshWarning: refreshWarning, now: now)
    }
  }

  private func loadedProviderContent(
    providers: [ProviderQuotaPresentation],
    refreshWarning: String?,
    now: Date
  ) -> some View {
    VStack(spacing: 0) {
      if let refreshWarning {
        InlineRefreshError(message: refreshWarning)
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

private struct OverviewEmptyStateView: View {
  let systemImage: String
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: QuotaDesign.Spacing.sectionBody) {
      Image(systemName: systemImage)
        .quotaEmptyIconStyle()

      Text(title)
        .quotaEmptyTitleStyle()

      Text(message)
        .quotaSecondaryStyle()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(QuotaPrimaryButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, minHeight: 260)
  }
}

private struct InlineRefreshError: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "clock.arrow.circlepath")
      .quotaSecondaryStyle()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, QuotaDesign.Spacing.sectionBody)
  }
}
