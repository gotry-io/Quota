import SwiftUI

struct RelayListView: View {
  let model: RelayStateModel
  let onAddRelay: () -> Void
  let onOpenRelay: (UUID) -> Void

  @State private var isEnablingManagedRelay = false

  private var showsManagedReconnect: Bool {
    model.managedEnrollmentDisabled
      && !model.profiles.contains(where: { $0.mode == .managed })
  }

  private var isEmpty: Bool {
    model.profiles.isEmpty && !showsManagedReconnect
  }

  var body: some View {
    Group {
      if isEmpty {
        emptyState
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if showsManagedReconnect {
              managedRelayDisabledState
            }

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
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
          .padding(.vertical, 16)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "network")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(QuotaPalette.ink)

      Text("No Relays configured")
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .foregroundStyle(QuotaPalette.ink)

      Text("Add a self-hosted Relay to read quota from remote QuotaCLI devices.")
        .font(.subheadline)
        .foregroundStyle(QuotaPalette.body)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      Button("Add Relay", action: onAddRelay)
        .buttonStyle(QuotaPrimaryButtonStyle())
        .padding(.top, 4)
    }
    .frame(maxWidth: 280)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var managedRelayDisabledState: some View {
    RelayCard {
      VStack(alignment: .leading, spacing: 9) {
        Text("Managed Relay is disconnected")
          .font(QuotaDesign.Typography.providerTitle)
          .foregroundStyle(QuotaPalette.ink)
        Text("Reconnect to create a new anonymous controller without an account.")
          .font(.caption)
          .foregroundStyle(QuotaPalette.body)
          .fixedSize(horizontal: false, vertical: true)
        Button("Reconnect Quota Relay") {
          guard !isEnablingManagedRelay else { return }
          isEnablingManagedRelay = true
          Task {
            await model.enableManagedControllerProfile()
            isEnablingManagedRelay = false
          }
        }
        .buttonStyle(.plain)
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(QuotaPalette.ink)
        .disabled(isEnablingManagedRelay)
      }
    }
  }

  private func profileCard(_ profile: RelayProfile) -> some View {
    let state = model.state(for: profile.id)
    return RelayCard {
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
          if let issue = state?.issue {
            RelayStatusTag(text: shortIssueLabel(issue), systemImage: "exclamationmark.circle")
          } else {
            RelayStatusTag(
              text: state?.refreshLabel ?? "Not loaded",
              systemImage: state?.refreshIcon
            )
          }
        }

        if let issue = state?.issue {
          Text(issue.message)
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func shortIssueLabel(_ issue: RelayStateIssue) -> String {
    switch issue.category {
    case .unsupported: "Unsupported"
    case .authentication, .authorization, .credentialMissing: "Auth"
    case .unavailable: "Unavailable"
    case .configuration: "Config"
    case .persistence, .malformedData: "Error"
    }
  }
}
