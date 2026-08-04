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
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
        Text("Enter the 8-character code shown by QuotaCLI. Pairing starts automatically.")
          .quotaSecondaryStyle()
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)

        VStack(spacing: QuotaDesign.Spacing.cardBody) {
          PairingCodeEntryView(
            code: $pairingCode,
            isDisabled: isSubmitting,
            showsError: errorMessage != nil,
            retryToken: retryToken,
            onComplete: { canonical in
              submit(canonicalCode: canonical)
            }
          )
          .frame(maxWidth: .infinity)

          if isSubmitting {
            HStack(spacing: QuotaDesign.Spacing.inline) {
              ProgressView()
                .controlSize(.small)
              Text("Pairing…")
                .quotaSecondaryStyle()
            }
            .frame(maxWidth: .infinity)
          }

          if let statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle")
              .quotaSecondaryStyle()
              .frame(maxWidth: .infinity)
          }

          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle")
              .quotaSecondaryStyle()
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity)
              .accessibilityLabel("Pairing failed. \(errorMessage)")
          }
        }

        }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
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
