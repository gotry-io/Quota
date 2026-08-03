import SwiftUI

struct RelayPairingView: View {
  let model: RelayStateModel
  let profileID: UUID

  @State private var userCode = ""
  @State private var statusMessage: String?
  @State private var errorMessage: String?
  @State private var isSubmitting = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Review a pairing request")
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(QuotaPalette.ink)
          Text("Enter the user code displayed by QuotaCLI on the device you want to connect.")
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
        }

        RelayCard {
          VStack(alignment: .leading, spacing: 8) {
            Text("User code")
              .font(.system(.subheadline, weight: .medium))
              .foregroundStyle(QuotaPalette.charcoal)
            TextField("ABCD-EFGH", text: $userCode)
              .textFieldStyle(RelayPillTextFieldStyle())
              .font(.system(.title3, design: .monospaced, weight: .medium))
              .accessibilityLabel("Pairing user code")
          }
        }

        if let statusMessage {
          Label(statusMessage, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .accessibilityLabel(statusMessage)
        }
        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Pairing failed. \(errorMessage)")
        }

        HStack(spacing: 8) {
          Button("Approve") {
            decide(approve: true)
          }
          .buttonStyle(QuotaPrimaryButtonStyle())
          .disabled(isSubmitting)

          Button("Deny") {
            decide(approve: false)
          }
          .buttonStyle(RelaySecondaryButtonStyle())
          .disabled(isSubmitting)

          if isSubmitting {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Submitting pairing decision")
          }
        }

        Text("Approve only when the same code is visible on a device you recognize.")
          .font(.caption2)
          .foregroundStyle(QuotaPalette.body)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, 16)
    }
  }

  private func decide(approve: Bool) {
    guard !isSubmitting else { return }
    let canonicalCode: String
    do {
      canonicalCode = try RelayPairingCodeValidation.validate(userCode)
    } catch {
      errorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "Enter a valid pairing code."
      )
      return
    }

    isSubmitting = true
    statusMessage = nil
    errorMessage = nil
    Task {
      defer { isSubmitting = false }
      do {
        if approve {
          try await model.approvePairing(profileID: profileID, userCode: canonicalCode)
        } else {
          try await model.denyPairing(profileID: profileID, userCode: canonicalCode)
        }
        userCode = ""
        statusMessage = approve ? "Pairing approved." : "Pairing denied."
      } catch {
        errorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not submit the pairing decision."
        )
      }
    }
  }
}
