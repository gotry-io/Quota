import SwiftUI

struct MenuBarContentView: View {
  private enum Page {
    case overview
    case settings
  }

  @Bindable var model: MenuBarViewModel
  @AppStorage("provider.codex.visible") private var showsCodex = true
  @AppStorage("provider.claude.visible") private var showsClaude = true
  @AppStorage("provider.grok.visible") private var showsGrok = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var page = Page.overview

  var body: some View {
    VStack(spacing: 0) {
      panelHeader

      Divider()
        .overlay(QuotaPalette.hairline)

      ScrollView {
        ZStack(alignment: .top) {
          if page == .overview {
            providerContent
              .transition(
                .asymmetric(
                  insertion: .move(edge: .leading).combined(with: .opacity),
                  removal: .move(edge: .leading).combined(with: .opacity)
                )
              )
          } else {
            SettingsView(
              model: model,
              showsCodex: $showsCodex,
              showsClaude: $showsClaude,
              showsGrok: $showsGrok
            )
            .transition(
              .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
              )
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      }
      .clipped()
      .animation(
        reduceMotion ? nil : .easeInOut(duration: QuotaDesign.Motion.navigationDuration),
        value: page
      )

      Divider()
        .overlay(QuotaPalette.hairline)

      panelFooter
    }
    .frame(width: QuotaDesign.Layout.panelWidth, height: QuotaDesign.Layout.panelHeight)
    .task {
      await model.refreshIfNeeded()
    }
  }

  private var panelHeader: some View {
    HStack(spacing: 8) {
      if page == .settings {
        Button {
          navigate(to: .overview)
        } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 13, weight: .semibold))
            .frame(
              width: QuotaDesign.Layout.navigationControlSize,
              height: QuotaDesign.Layout.navigationControlSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(QuotaPalette.body)
        .accessibilityLabel("Back to quota overview")
      }

      Text(page == .overview ? "QuotaBar" : "Settings")
        .font(QuotaDesign.Typography.panelTitle)
        .foregroundStyle(QuotaPalette.ink)
        .contentTransition(.opacity)

      Spacer()

      if page == .overview {
        Button {
          navigate(to: .settings)
        } label: {
          Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .medium))
            .frame(
              width: QuotaDesign.Layout.navigationControlSize,
              height: QuotaDesign.Layout.navigationControlSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(QuotaPalette.body)
        .accessibilityLabel("Open settings")
      }
    }
    .frame(height: QuotaDesign.Layout.headerHeight)
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .animation(
      reduceMotion ? nil : .easeInOut(duration: QuotaDesign.Motion.navigationDuration),
      value: page
    )
  }

  @ViewBuilder
  private var providerContent: some View {
    if model.report == nil, model.errorMessage == nil {
      EmptyStateView(
        systemImage: "gauge.with.dots.needle.50percent",
        title: "Reading local quota",
        message: "Checking your signed-in Codex, Claude Code, and Grok sessions."
      )
    } else if model.report == nil, let errorMessage = model.errorMessage {
      EmptyStateView(
        systemImage: "exclamationmark.circle",
        title: "Quota unavailable",
        message: errorMessage,
        actionTitle: "Retry"
      ) {
        Task { await model.refresh() }
      }
    } else {
      loadedProviderContent
    }
  }

  @ViewBuilder
  private var loadedProviderContent: some View {
    let providers = model.displayedProviders(enabledProviders: enabledProviders)
    if providers.isEmpty {
      EmptyStateView(
        systemImage: "eye.slash",
        title: "No providers to show",
        message: "Sign in with a provider CLI or enable a signed-in provider in Settings.",
        actionTitle: "Open settings"
      ) {
        navigate(to: .settings)
      }
    } else {
      VStack(spacing: 0) {
        if let errorMessage = model.errorMessage {
          InlineRefreshError(message: errorMessage)
        }

        ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
          if let snapshot = model.displaySnapshot(for: provider) {
            ProviderRow(provider: provider, sourceLabel: "Local", snapshot: snapshot)
          }

          if index < providers.count - 1 {
            Divider()
              .overlay(QuotaPalette.hairline)
          }
        }
      }
    }
  }

  private var panelFooter: some View {
    HStack(spacing: 12) {
      Text("v\(AppMetadata.version)")

      Spacer()

      Button {
        Task { await model.refresh() }
      } label: {
        if model.isRefreshing {
          Text("Refreshing…")
        } else {
          Text(lastRefreshLabel)
        }
      }
      .buttonStyle(.plain)
      .disabled(model.isRefreshing)
      .accessibilityLabel("Refresh local quota, \(lastRefreshLabel)")
    }
    .font(.system(size: 12))
    .foregroundStyle(QuotaPalette.body)
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .frame(height: QuotaDesign.Layout.footerHeight)
  }

  private var lastRefreshLabel: String {
    guard let refreshedAt = model.refreshedAt else {
      return "Not refreshed"
    }
    return "Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
  }

  private var enabledProviders: Set<ProviderID> {
    var providers = Set<ProviderID>()
    if showsCodex { providers.insert(.codex) }
    if showsClaude { providers.insert(.claude) }
    if showsGrok { providers.insert(.grok) }
    return providers
  }

  private func navigate(to destination: Page) {
    guard page != destination else { return }
    page = destination
  }
}

private struct ProviderRow: View {
  let provider: ProviderID
  let sourceLabel: String
  let snapshot: QuotaSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      availableContent(snapshot: snapshot)
    }
    .padding(.vertical, QuotaDesign.Layout.providerRowVerticalPadding)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func availableContent(snapshot: QuotaSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      HStack(spacing: 6) {
        ProviderBrandIcon(provider: provider)
        Text(provider.displayName)
      }
      .font(QuotaDesign.Typography.providerTitle)
      .foregroundStyle(QuotaPalette.ink)

      SourceTag(title: sourceLabel)

      if snapshot.status != .available {
        StatusTag(title: snapshot.status.displayName, systemImage: snapshot.status.systemImage)
      }

      Spacer()
    }

    if let accountSummary = accountSummary(snapshot.account) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(accountSummary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(QuotaDesign.Typography.metadata)
      .foregroundStyle(QuotaPalette.body)
    }

    ForEach(snapshot.windows) { window in
      QuotaWindowRow(window: window)
    }
  }
}

private struct QuotaWindowRow: View {
  let window: QuotaWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(window.title)
          .font(QuotaDesign.Typography.quotaLabel)
          .foregroundStyle(QuotaPalette.charcoal)
        Spacer()
        Text("\(percent(window.remainingPercent)) left")
          .font(QuotaDesign.Typography.quotaLabel)
          .monospacedDigit()
          .foregroundStyle(QuotaPalette.ink)
      }

      QuotaProgressBar(value: window.remainingPercent)
      Text(resetLabel(window.resetsAt))
        .font(QuotaDesign.Typography.resetTime)
        .foregroundStyle(QuotaPalette.body)
    }
    .padding(.top, 6)
  }
}

private struct QuotaProgressBar: View {
  let value: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(QuotaPalette.hairline)
        Capsule()
          .fill(QuotaPalette.ink)
          .frame(width: geometry.size.width * min(max(value / 100, 0), 1))
      }
    }
    .frame(height: QuotaDesign.Layout.progressHeight)
    .accessibilityLabel("Remaining quota")
    .accessibilityValue(percent(value))
  }
}

private struct StatusTag: View {
  let title: String
  let systemImage: String

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(QuotaDesign.Typography.statusTag)
      .foregroundStyle(QuotaPalette.charcoal)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .overlay {
        RoundedRectangle(cornerRadius: QuotaDesign.Layout.tagCornerRadius)
          .stroke(QuotaPalette.hairline.opacity(0.55))
      }
      .fixedSize()
  }
}

private struct EmptyStateView: View {
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
        .font(.system(size: 18, weight: .medium, design: .rounded))
        .foregroundStyle(QuotaPalette.ink)

      Text(message)
        .font(.system(size: 14))
        .multilineTextAlignment(.center)
        .foregroundStyle(QuotaPalette.body)
        .fixedSize(horizontal: false, vertical: true)

      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(QuietPillButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, minHeight: 320)
    .padding(.horizontal, 24)
  }
}

private struct InlineRefreshError: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "clock.arrow.circlepath")
      .font(.system(size: 12))
      .foregroundStyle(QuotaPalette.body)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 12)
  }
}

private struct SourceTag: View {
  let title: String

  var body: some View {
    Text(title)
      .font(QuotaDesign.Typography.sourceTag)
      .foregroundStyle(QuotaPalette.charcoal)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .overlay {
        RoundedRectangle(cornerRadius: QuotaDesign.Layout.tagCornerRadius)
          .stroke(QuotaPalette.hairline.opacity(0.5))
      }
      .fixedSize()
      .accessibilityLabel("Source: \(title)")
  }
}

private struct QuietPillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(QuotaPalette.ink)
      .padding(.horizontal, 20)
      .frame(height: 36)
      .background(QuotaPalette.soft.opacity(configuration.isPressed ? 0.72 : 1))
      .clipShape(Capsule())
      .overlay {
        Capsule()
          .stroke(QuotaPalette.hairline)
      }
  }
}

extension QuotaStatus {
  fileprivate var displayName: String {
    switch self {
    case .available: "Available"
    case .stale: "Stale"
    case .authRequired: "Auth required"
    case .unavailable: "Unavailable"
    case .unsupported: "Not supported"
    case .error: "Error"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .available: "gauge.with.dots.needle.50percent"
    case .stale: "clock"
    case .authRequired: "key"
    case .unavailable: "minus.circle"
    case .unsupported: "info.circle"
    case .error: "exclamationmark.circle"
    }
  }
}

private func accountSummary(_ account: QuotaAccount) -> String? {
  [account.plan, account.label]
    .compactMap { $0 }
    .filter { !$0.isEmpty }
    .joined(separator: " · ")
    .nilIfEmpty
}

private func percent(_ value: Double) -> String {
  if abs(value.rounded() - value) < 0.05 {
    return "\(Int(value.rounded()))%"
  }
  return String(format: "%.1f%%", value)
}

private func resetLabel(_ date: Date?) -> String {
  guard let date else { return "Reset time unavailable" }
  return "Resets \(relativeTime(from: date))"
}

private func relativeTime(from date: Date) -> String {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .abbreviated
  return formatter.localizedString(for: date, relativeTo: Date())
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
