import SwiftUI

struct RelayListView: View {
  let model: RelayStateModel
  let onAddRelay: () -> Void
  let onOpenRelay: (UUID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let issue = model.globalIssue {
          relayIssue(issue)
        }

        if model.profiles.isEmpty {
          emptyState
        } else {
          ForEach(model.profiles) { profile in
            Button {
              onOpenRelay(profile.id)
            } label: {
              profileCard(profile)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(profile.name) Relay")
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, 16)
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        Spacer()
        Button("Add Relay", action: onAddRelay)
          .buttonStyle(QuotaPrimaryButtonStyle())
      }
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, 12)
      .background(.bar)
      .overlay(alignment: .top) {
        Divider().overlay(QuotaPalette.hairline)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "network")
        .font(.system(size: 24, weight: .regular))
      Text("No Relays configured")
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .foregroundStyle(QuotaPalette.ink)
      Text("Add a self-hosted Relay to read quota reported by remote QuotaCLI devices.")
        .font(.subheadline)
        .foregroundStyle(QuotaPalette.body)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 32)
  }

  private func profileCard(_ profile: RelayProfile) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 6) {
          Text(profile.name)
            .font(QuotaDesign.Typography.providerTitle)
            .foregroundStyle(QuotaPalette.ink)
            .lineLimit(1)

          if profile.isDefault {
            RelayStatusTag(text: "Default", systemImage: "checkmark")
          }

          Spacer(minLength: 4)
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(QuotaPalette.body)
        }

        Text(profile.baseURL.absoluteString)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(QuotaPalette.body)
          .lineLimit(2)
          .multilineTextAlignment(.leading)

        HStack(spacing: 6) {
          RelayStatusTag(text: profile.mode.displayName)
          RelayStatusTag(
            text: refreshLabel(for: profile.id),
            systemImage: refreshIcon(for: profile.id)
          )
        }
      }
    }
  }

  private func refreshLabel(for profileID: UUID) -> String {
    guard let state = model.state(for: profileID) else { return "Not loaded" }
    if state.isRefreshing { return "Refreshing…" }
    if state.refreshIssue != nil { return state.isStale ? "Stale" : "Unavailable" }
    guard let refreshedAt = state.lastSuccessfulRefreshAt else { return "Not refreshed" }
    return "Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
  }

  private func refreshIcon(for profileID: UUID) -> String? {
    guard let state = model.state(for: profileID) else { return nil }
    if state.isRefreshing { return "arrow.clockwise" }
    if state.refreshIssue != nil { return state.isStale ? "clock" : "exclamationmark.circle" }
    return state.lastSuccessfulRefreshAt == nil ? nil : "checkmark"
  }

  private func relayIssue(_ issue: RelayStateIssue) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.circle")
      Text(issue.message)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption)
    .foregroundStyle(QuotaPalette.body)
    .accessibilityElement(children: .combine)
  }
}
