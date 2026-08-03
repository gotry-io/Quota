import SwiftUI

struct RelayPairingView: View {
  let model: RelayStateModel
  let profileID: UUID

  @State private var pairingCode = ""
  @State private var statusMessage: String?
  @State private var errorMessage: String?
  @State private var isSubmitting = false
  @State private var lastAttemptedCode: String?
  @State private var retryToken = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .center, spacing: 18) {
        VStack(spacing: 6) {
          Text("Pair a device")
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(QuotaPalette.ink)
          Text("Enter the 8-character code shown by QuotaCLI on the device you trust.")
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 300)

        VStack(spacing: 10) {
          PairingCodeEntryView(
            code: $pairingCode,
            isDisabled: isSubmitting,
            showsError: errorMessage != nil,
            retryToken: retryToken,
            onComplete: { canonical in
              submit(canonicalCode: canonical)
            }
          )

          if isSubmitting {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Pairing…")
                .font(.caption)
                .foregroundStyle(QuotaPalette.body)
            }
          }

          if let statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle")
              .font(.caption)
              .foregroundStyle(QuotaPalette.body)
          }

          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle")
              .font(.caption)
              .foregroundStyle(QuotaPalette.body)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel("Pairing failed. \(errorMessage)")
          }
        }

        Text("Pairing starts automatically when all eight characters are entered.")
          .font(.caption2)
          .foregroundStyle(QuotaPalette.mute)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 280)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, 20)
    }
  }

  private func submit(canonicalCode: String) {
    guard !isSubmitting else { return }
    if lastAttemptedCode == canonicalCode, errorMessage == nil, statusMessage != nil {
      return
    }

    isSubmitting = true
    statusMessage = nil
    errorMessage = nil
    lastAttemptedCode = canonicalCode

    Task {
      defer { isSubmitting = false }
      do {
        try await model.approvePairing(profileID: profileID, userCode: canonicalCode)
        pairingCode = ""
        lastAttemptedCode = nil
        statusMessage = "Device paired."
      } catch {
        errorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not complete pairing."
        )
        lastAttemptedCode = nil
        retryToken += 1
      }
    }
  }
}
