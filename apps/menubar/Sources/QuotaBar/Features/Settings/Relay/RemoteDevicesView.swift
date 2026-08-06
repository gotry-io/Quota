import SwiftUI

struct RemoteDevicesView: View {
  let model: RelayStateModel
  let performsInitialRefresh: Bool

  @State private var pendingRemoval: OwnedRemoteDevice?
  @State private var errorMessage: String?
  @State private var isRemoving = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        if isRefreshing && devices.isEmpty {
          HStack(spacing: QuotaDesign.Spacing.inline) {
            ProgressView().controlSize(.small)
            Text("Refreshing devices…")
              .quotaSecondaryStyle()
          }
          .frame(maxWidth: .infinity, minHeight: 80)
        } else if devices.isEmpty {
          emptyState
        } else {
          SettingsSection(title: "Devices") {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(devices) { owned in
                deviceRow(owned)
              }
            }
          }
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.circle")
            .quotaMetaStyle()
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .task {
      guard performsInitialRefresh else { return }
      await model.refreshAllProfiles()
    }
    .confirmationDialog(
      "Remove \(pendingRemoval?.device.displayName ?? "this device")?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Device", role: .destructive) {
        removePendingDevice()
      }
      Button("Cancel", role: .cancel) {
        pendingRemoval = nil
      }
    } message: {
      Text("This device will stop reporting to this QuotaBar.")
    }
  }

  private var devices: [OwnedRemoteDevice] {
    model.ownedDevices
  }

  private var isRefreshing: Bool {
    model.profiles.contains { model.state(for: $0.id)?.isRefreshing == true }
  }

  private var emptyState: some View {
    VStack(spacing: QuotaDesign.Spacing.sectionBody) {
      Image(systemName: "laptopcomputer.and.iphone")
        .quotaEmptyIconStyle()
      Text("Pair a device to see its quota in QuotaBar.")
        .quotaSecondaryStyle()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, QuotaDesign.Layout.emptyStateVerticalPadding)
  }

  private func deviceRow(_ owned: OwnedRemoteDevice) -> some View {
    let device = owned.device
    let subtitle = deviceSubtitle(owned)

    return SettingsListRow(
      title: device.displayName,
      subtitle: subtitle,
      systemImage: "laptopcomputer",
      height: QuotaDesign.Layout.settingsListRowHeight
    ) {
      Button("Remove", role: .destructive) {
        pendingRemoval = owned
      }
      .buttonStyle(.plain)
      .quotaMetaStyle()
      .foregroundStyle(QuotaPalette.critical)
      .disabled(isRemoving)
      .accessibilityLabel("Remove \(device.displayName)")
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(device.displayName)
    .accessibilityValue(subtitle)
  }

  private func deviceSubtitle(_ owned: OwnedRemoteDevice) -> String {
    let device = owned.device
    let health = device.lastSeenAt == nil ? "Waiting" : "Active"
    let seen = lastSeenLabel(device)
    // Keep one line; multi-Relay only appends endpoint (common case is shorter).
    if model.showsEndpointLabelOnDevices {
      return "\(health) · \(seen) · \(owned.endpointLabel)"
    }
    return "\(health) · \(seen)"
  }

  private func lastSeenLabel(_ device: RelayDevice) -> String {
    guard let lastSeenAt = device.lastSeenAt else {
      return "Never reported"
    }
    return lastSeenAt.formatted(date: .abbreviated, time: .shortened)
  }

  private func removePendingDevice() {
    guard let pending = pendingRemoval, !isRemoving else { return }
    pendingRemoval = nil
    isRemoving = true
    errorMessage = nil
    Task {
      defer { isRemoving = false }
      do {
        try await model.revokeDevice(
          profileID: pending.profileID,
          deviceID: pending.device.deviceID
        )
      } catch {
        errorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not remove the device."
        )
      }
    }
  }
}
