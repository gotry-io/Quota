import SwiftUI

struct RelayDevicesView: View {
  let model: RelayStateModel
  let profileID: UUID
  let performsInitialRefresh: Bool

  @State private var pendingRevocationDeviceID: String?
  @State private var errorMessage: String?
  @State private var isRevoking = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sectionBody) {
        if state?.isRefreshing == true, devices.isEmpty {
          HStack(spacing: QuotaDesign.Spacing.inline) {
            ProgressView().controlSize(.small)
            Text("Refreshing devices…")
              .quotaSecondaryStyle()
          }
          .frame(maxWidth: .infinity, minHeight: 80)
        } else if devices.isEmpty {
          emptyState
        } else {
          ForEach(devices) { device in
            deviceCard(device)
          }
        }

        if let issue = state?.issue {
          issueLabel(issue.message)
        }
        if let errorMessage {
          issueLabel(errorMessage)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .task(id: profileID) {
      guard performsInitialRefresh else { return }
      await model.refreshProfile(profileID)
    }
    .confirmationDialog(
      "Revoke \(pendingDevice?.displayName ?? "this device")?",
      isPresented: Binding(
        get: { pendingRevocationDeviceID != nil },
        set: { if !$0 { pendingRevocationDeviceID = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Revoke device", role: .destructive) {
        revokePendingDevice()
      }
      Button("Cancel", role: .cancel) {
        pendingRevocationDeviceID = nil
      }
    } message: {
      Text("The device credential will stop working immediately.")
    }
  }

  private var state: RelayProfileState? {
    model.state(for: profileID)
  }

  private var devices: [RelayDevice] {
    state?.devices.sorted { left, right in
      if (left.revokedAt == nil) != (right.revokedAt == nil) {
        return left.revokedAt == nil
      }
      return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
    } ?? []
  }

  private var pendingDevice: RelayDevice? {
    guard let pendingRevocationDeviceID else { return nil }
    return devices.first { $0.deviceID == pendingRevocationDeviceID }
  }

  private var emptyState: some View {
    VStack(spacing: QuotaDesign.Spacing.cardBody) {
      Image(systemName: "laptopcomputer.and.iphone")
        .quotaEmptyIconStyle()
      Text("No Paired Devices")
        .quotaEmptyTitleStyle()
      Text("Run the QuotaCLI pairing command on a device, then approve its code from Pair Device.")
        .quotaSecondaryStyle()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, QuotaDesign.Layout.emptyStateVerticalPadding)
  }

  private func deviceCard(_ device: RelayDevice) -> some View {
    RelayCard {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardBody) {
        HStack(spacing: QuotaDesign.Spacing.iconLabel) {
          Text(device.displayName)
            .quotaRowTitleStyle()
            .lineLimit(2)
          Spacer(minLength: 4)
          if device.revokedAt != nil {
            QuotaStatusTag(text: "Revoked", systemImage: "slash.circle")
          } else {
            QuotaStatusTag(text: "Active", systemImage: "checkmark.circle")
          }
        }

        Text(device.shortID)
          .quotaMonoStyle()
          .textSelection(.enabled)

        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
            Text(lastSeenLabel(device))
            Text(device.sequenceLabel)
          }
          .quotaMetaStyle()

          Spacer()

          if device.revokedAt == nil {
            Button("Revoke") {
              pendingRevocationDeviceID = device.deviceID
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            .disabled(isRevoking)
            .accessibilityLabel("Revoke \(device.displayName)")
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func lastSeenLabel(_ device: RelayDevice) -> String {
    if let revokedAt = device.revokedAt {
      return "Revoked \(revokedAt.formatted(date: .abbreviated, time: .shortened))"
    }
    guard let lastSeenAt = device.lastSeenAt else { return "Never seen" }
    return "Last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))"
  }

  private func issueLabel(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
      .quotaSecondaryStyle()
      .fixedSize(horizontal: false, vertical: true)
  }

  private func revokePendingDevice() {
    guard let deviceID = pendingRevocationDeviceID, !isRevoking else { return }
    pendingRevocationDeviceID = nil
    isRevoking = true
    errorMessage = nil
    Task {
      defer { isRevoking = false }
      do {
        try await model.revokeDevice(profileID: profileID, deviceID: deviceID)
      } catch {
        errorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not revoke the device."
        )
      }
    }
  }
}
