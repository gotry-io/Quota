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
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardStack) {
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
          .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: QuotaDesign.Spacing.sectionBody) {
      Image(systemName: "network")
        .quotaEmptyIconStyle()

      Text("No Relays Configured")
        .quotaEmptyTitleStyle()

      Text("Add a self-hosted Relay to read quota from remote QuotaCLI devices.")
        .quotaSecondaryStyle()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      Button("Add Relay", action: onAddRelay)
        .buttonStyle(QuotaPrimaryButtonStyle())
        .padding(.top, QuotaDesign.Spacing.xxs)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var managedRelayDisabledState: some View {
    RelayCard {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardBody) {
        Text("Managed Relay Is Disconnected")
          .quotaRowTitleStyle()
        Text("Reconnect to create a new anonymous controller without an account.")
          .quotaSecondaryStyle()
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
        .quotaRowTitleStyle()
        .disabled(isEnablingManagedRelay)
      }
    }
  }

  private func profileCard(_ profile: RelayProfile) -> some View {
    let state = model.state(for: profile.id)
    return RelayCard {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardBody) {
        HStack(spacing: QuotaDesign.Spacing.iconLabel) {
          Text(profile.name)
            .quotaRowTitleStyle()
            .lineLimit(1)

          if profile.isDefault {
            QuotaStatusTag(text: "Default", systemImage: "checkmark")
          }

          Spacer(minLength: QuotaDesign.Spacing.xxs)
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }

        Text(profile.baseURL.absoluteString)
          .quotaMonoStyle()
          .lineLimit(2)
          .multilineTextAlignment(.leading)

        HStack(spacing: QuotaDesign.Spacing.iconLabel) {
          QuotaStatusTag(text: profile.mode.displayName)
          if let issue = state?.issue {
            QuotaStatusTag(text: shortIssueLabel(issue), systemImage: "exclamationmark.circle")
          } else {
            QuotaStatusTag(
              text: state?.refreshLabel ?? "Not Loaded",
              systemImage: state?.refreshIcon
            )
          }
        }

        if let issue = state?.issue {
          Text(issue.message)
            .quotaSecondaryStyle()
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
