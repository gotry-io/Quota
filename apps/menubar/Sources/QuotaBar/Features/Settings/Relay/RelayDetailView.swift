import SwiftUI

struct RelayDetailView: View {
  let model: RelayStateModel
  let profileID: UUID
  let onOpenPairing: () -> Void
  let onOpenDevices: () -> Void
  let onDeleted: () -> Void

  @State private var renameValue = ""
  @State private var errorMessage: String?
  @State private var showsDeleteConfirmation = false
  @State private var showsLocalDeleteConfirmation = false
  @State private var isDeleting = false

  var body: some View {
    ScrollView {
      if let profile {
        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
          profileSummary(profile)
          profileActions(profile)
          capabilities(profile.capabilities)

          if let issue = model.state(for: profileID)?.issue {
            issueLabel(issue.message)
          }
          if let errorMessage {
            issueLabel(errorMessage)
          }

          Button("Delete Relay") {
            showsDeleteConfirmation = true
          }
          .buttonStyle(.plain)
          .quotaSecondaryStyle()
          .disabled(isDeleting)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
        .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
        .onAppear {
          if renameValue.isEmpty {
            renameValue = profile.name
          }
        }
      } else {
        ContentUnavailableView(
          "Relay not found",
          systemImage: "network.slash",
          description: Text("This Relay profile is no longer available.")
        )
      }
    }
    .confirmationDialog(
      "Delete this Relay?",
      isPresented: $showsDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete Relay", role: .destructive) {
        deleteProfile()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(deleteConfirmationMessage)
    }
    .confirmationDialog(
      "Delete only the local Relay data?",
      isPresented: $showsLocalDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete Locally Anyway", role: .destructive) {
        deleteProfileLocally()
      }
      Button("Keep Relay", role: .cancel) {}
    } message: {
      Text(
        "QuotaBar could not confirm remote deletion. Local cleanup may leave the managed controller and Relay data behind while paired devices continue reporting."
      )
    }
  }

  private var profile: RelayProfile? {
    model.profiles.first { $0.id == profileID }
  }

  private var deleteConfirmationMessage: String {
    if profile?.mode == .managed {
      return "QuotaBar will delete this managed controller and its linked Relay data, then remove the local profile and Keychain credential."
    }
    return "QuotaBar will remove this self-hosted profile and its local Keychain credential. The externally managed controller remains active."
  }

  private func profileSummary(_ profile: RelayProfile) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardBody) {
        HStack(spacing: QuotaDesign.Spacing.iconLabel) {
          Text(profile.name)
            .quotaRowTitleStyle()
          if profile.isDefault {
            QuotaStatusTag(text: "Default", systemImage: "checkmark")
          }
        }

        Text(profile.baseURL.absoluteString)
          .quotaMonoStyle()
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: QuotaDesign.Spacing.iconLabel) {
          QuotaStatusTag(text: profile.mode.displayName)
          QuotaStatusTag(text: refreshStatus, systemImage: refreshStatusIcon)
        }

        Text("Instance \(shortInstanceID(profile.instanceID))")
          .quotaMonoMetaStyle()
          .textSelection(.enabled)
      }
    }
  }

  private func profileActions(_ profile: RelayProfile) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sectionBody) {
        Text("Profile")
          .quotaSectionHeaderStyle()

        HStack(spacing: QuotaDesign.Spacing.inline) {
          TextField("Relay name", text: $renameValue)
            .textFieldStyle(RelayPillTextFieldStyle())
            .accessibilityLabel("Relay profile name")
          Button("Save") {
            renameProfile()
          }
          .buttonStyle(RelaySecondaryButtonStyle())
          .disabled(canonicalRenameValue.isEmpty || canonicalRenameValue == profile.name)
        }

        HStack(spacing: QuotaDesign.Spacing.inline) {
          Button("Refresh") {
            Task { await model.refreshProfile(profileID) }
          }
          .buttonStyle(RelaySecondaryButtonStyle())
          .disabled(model.state(for: profileID)?.isRefreshing == true)

          if !profile.isDefault {
            Button("Make default") {
              setDefault()
            }
            .buttonStyle(RelaySecondaryButtonStyle())
          }
        }

        Divider()

        Button("Pair Device", action: onOpenPairing)
          .buttonStyle(QuotaPrimaryButtonStyle())

        Button(action: onOpenDevices) {
          HStack {
            Label("Devices", systemImage: "laptopcomputer.and.iphone")
            Spacer()
            Image(systemName: "chevron.right")
              .quotaChevronStyle()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .quotaRowTitleStyle()
        .accessibilityLabel("Manage Relay devices")
      }
    }
  }

  private func capabilities(_ capabilities: RelayCapabilities) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardBody) {
        Text("Capabilities")
          .quotaSectionHeaderStyle()

        capability("Persistent snapshots", enabled: capabilities.persistentSnapshots)
        capability("Instant device revocation", enabled: capabilities.instantDeviceRevocation)
        capability("History", enabled: capabilities.history)
        capability("Realtime updates", enabled: capabilities.realtime)
        capability("Multi-tenant", enabled: capabilities.multiTenant)
      }
    }
  }

  private func capability(_ name: String, enabled: Bool) -> some View {
    HStack(spacing: QuotaDesign.Spacing.inline) {
      Image(systemName: enabled ? "checkmark.circle" : "minus.circle")
        .foregroundStyle(QuotaPalette.body)
      Text(name)
        .quotaSecondaryStyle()
      Spacer()
      Text(enabled ? "Supported" : "Unavailable")
        .quotaMetaStyle()
    }
    .accessibilityElement(children: .combine)
  }

  private var refreshStatus: String {
    model.state(for: profileID)?.refreshLabel ?? "Not Loaded"
  }

  private var canonicalRenameValue: String {
    renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var refreshStatusIcon: String? {
    model.state(for: profileID)?.refreshIcon
  }

  private func shortInstanceID(_ instanceID: String) -> String {
    guard instanceID.count > 16 else { return instanceID }
    return "\(instanceID.prefix(12))…"
  }

  private func issueLabel(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
      .quotaSecondaryStyle()
      .fixedSize(horizontal: false, vertical: true)
  }

  private func renameProfile() {
    do {
      try model.renameProfile(profileID, to: renameValue)
      renameValue = profile?.name ?? renameValue
      errorMessage = nil
    } catch {
      errorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "QuotaBar could not rename the Relay."
      )
    }
  }

  private func setDefault() {
    do {
      try model.setDefaultProfile(profileID)
      errorMessage = nil
    } catch {
      errorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "QuotaBar could not change the default Relay."
      )
    }
  }

  private func deleteProfile() {
    guard !isDeleting else { return }
    isDeleting = true
    Task {
      defer { isDeleting = false }
      do {
        try await model.deleteProfile(profileID)
        errorMessage = nil
        onDeleted()
      } catch {
        errorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not delete the Relay."
        )
        if profile?.mode == .managed, !(error is CancellationError) {
          showsLocalDeleteConfirmation = true
        }
      }
    }
  }

  private func deleteProfileLocally() {
    do {
      try model.deleteProfileLocally(profileID)
      errorMessage = nil
      onDeleted()
    } catch {
      errorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "QuotaBar could not delete the local Relay data."
      )
    }
  }
}
