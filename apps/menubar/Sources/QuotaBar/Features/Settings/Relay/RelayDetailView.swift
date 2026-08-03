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
  @State private var isDeleting = false

  var body: some View {
    ScrollView {
      if let profile {
        VStack(alignment: .leading, spacing: 16) {
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
          .font(.system(.subheadline, weight: .medium))
          .foregroundStyle(QuotaPalette.body)
          .disabled(isDeleting)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
        .padding(.vertical, 16)
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
      Text("QuotaBar will remove this profile and its Keychain owner credential.")
    }
  }

  private var profile: RelayProfile? {
    model.profiles.first { $0.id == profileID }
  }

  private func profileSummary(_ profile: RelayProfile) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 6) {
          Text(profile.name)
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(QuotaPalette.ink)
          if profile.isDefault {
            RelayStatusTag(text: "Default", systemImage: "checkmark")
          }
        }

        Text(profile.baseURL.absoluteString)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(QuotaPalette.body)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 6) {
          RelayStatusTag(text: profile.mode.displayName)
          RelayStatusTag(text: refreshStatus, systemImage: refreshStatusIcon)
        }

        Text("Instance \(shortInstanceID(profile.instanceID))")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(QuotaPalette.body)
          .textSelection(.enabled)
      }
    }
  }

  private func profileActions(_ profile: RelayProfile) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Profile")
          .font(.system(.subheadline, weight: .medium))
          .foregroundStyle(QuotaPalette.charcoal)

        HStack(spacing: 8) {
          TextField("Relay name", text: $renameValue)
            .textFieldStyle(RelayPillTextFieldStyle())
            .accessibilityLabel("Relay profile name")
          Button("Save") {
            renameProfile()
          }
          .buttonStyle(RelaySecondaryButtonStyle())
          .disabled(canonicalRenameValue.isEmpty || canonicalRenameValue == profile.name)
        }

        HStack(spacing: 8) {
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

        Divider().overlay(QuotaPalette.hairline)

        Button("Pair device", action: onOpenPairing)
          .buttonStyle(QuotaPrimaryButtonStyle())

        Button(action: onOpenDevices) {
          HStack {
            Label("Devices", systemImage: "laptopcomputer.and.iphone")
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(QuotaPalette.ink)
        .accessibilityLabel("Manage Relay devices")
      }
    }
  }

  private func capabilities(_ capabilities: RelayCapabilities) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Capabilities")
          .font(.system(.subheadline, weight: .medium))
          .foregroundStyle(QuotaPalette.charcoal)

        capability("Persistent snapshots", enabled: capabilities.persistentSnapshots)
        capability("Instant device revocation", enabled: capabilities.instantDeviceRevocation)
        capability("History", enabled: capabilities.history)
        capability("Realtime updates", enabled: capabilities.realtime)
        capability("Multi-tenant", enabled: capabilities.multiTenant)
      }
    }
  }

  private func capability(_ name: String, enabled: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: enabled ? "checkmark.circle" : "minus.circle")
        .foregroundStyle(QuotaPalette.body)
      Text(name)
        .font(.caption)
      Spacer()
      Text(enabled ? "Supported" : "Unavailable")
        .font(.caption2)
        .foregroundStyle(QuotaPalette.body)
    }
    .accessibilityElement(children: .combine)
  }

  private var refreshStatus: String {
    guard let state = model.state(for: profileID) else { return "Not loaded" }
    if state.isRefreshing { return "Refreshing…" }
    if state.refreshIssue != nil { return state.isStale ? "Stale" : "Unavailable" }
    guard let date = state.lastSuccessfulRefreshAt else { return "Not refreshed" }
    return "Updated \(date.formatted(date: .omitted, time: .shortened))"
  }

  private var canonicalRenameValue: String {
    renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var refreshStatusIcon: String? {
    guard let state = model.state(for: profileID) else { return nil }
    if state.isRefreshing { return "arrow.clockwise" }
    if state.refreshIssue != nil { return state.isStale ? "clock" : "exclamationmark.circle" }
    return state.lastSuccessfulRefreshAt == nil ? nil : "checkmark"
  }

  private func shortInstanceID(_ instanceID: String) -> String {
    guard instanceID.count > 16 else { return instanceID }
    return "\(instanceID.prefix(12))…"
  }

  private func issueLabel(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
      .font(.caption)
      .foregroundStyle(QuotaPalette.body)
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
    defer { isDeleting = false }
    do {
      try model.deleteProfile(profileID)
      errorMessage = nil
      onDeleted()
    } catch {
      errorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "QuotaBar could not delete the Relay."
      )
    }
  }
}
