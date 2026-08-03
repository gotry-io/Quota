import SwiftUI

struct QuotaOverviewView: View {
  let model: MenuBarViewModel
  let enabledProviders: Set<ProviderID>
  let onOpenSettings: () -> Void

  var body: some View {
    ScrollView {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        providerContent(now: context.date)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      }
    }
  }

  @ViewBuilder
  private func providerContent(now: Date) -> some View {
    switch model.overviewState(enabledProviders: enabledProviders, now: now) {
    case .loading:
      OverviewEmptyStateView(
        systemImage: "gauge.with.dots.needle.50percent",
        title: "Reading quota",
        message: "Checking your local and Relay quota sources."
      )
    case .unavailable(let message):
      OverviewEmptyStateView(
        systemImage: "exclamationmark.circle",
        title: "Quota unavailable",
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
          title: "No providers to show",
          message: "Sign in with a provider CLI, connect a Relay, or enable a provider in Settings.",
          actionTitle: "Open settings",
          action: onOpenSettings
        )
      }
    case .content(let providers, let refreshWarning):
      loadedProviderContent(providers: providers, refreshWarning: refreshWarning)
    }
  }

  private func loadedProviderContent(
    providers: [ProviderQuotaPresentation],
    refreshWarning: String?
  ) -> some View {
    VStack(spacing: 0) {
      if let refreshWarning {
        InlineRefreshError(message: refreshWarning)
      }

      ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
        ProviderQuotaView(presentation: provider)

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
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 36, weight: .light))
        .foregroundStyle(QuotaPalette.ink)

      Text(title)
        .font(.system(.title3, design: .rounded, weight: .medium))
        .foregroundStyle(QuotaPalette.ink)

      Text(message)
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(QuotaPalette.body)
        .fixedSize(horizontal: false, vertical: true)

      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(QuotaPrimaryButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, minHeight: 260)
    .padding(.horizontal, 24)
  }
}

private struct InlineRefreshError: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "clock.arrow.circlepath")
      .font(.caption)
      .foregroundStyle(QuotaPalette.body)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 12)
  }
}
