import SwiftUI

struct AddRelayView: View {
  let model: RelayStateModel
  let onAdded: (UUID) -> Void

  @State private var name = ""
  @State private var origin = ""
  @State private var controllerBearer = ""
  @State private var errorMessage: String?
  @State private var isSubmitting = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Connect a self-hosted Relay")
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(QuotaPalette.ink)
          Text("QuotaBar verifies the Relay before storing its controller credential in Keychain.")
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
        }

        formField("Name") {
          TextField("Home Relay", text: $name)
            .textFieldStyle(RelayPillTextFieldStyle())
            .accessibilityLabel("Relay profile name")
        }

        formField("Origin") {
          TextField("https://relay.example.com", text: $origin)
            .textFieldStyle(RelayPillTextFieldStyle())
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel("Relay origin")
        }

        formField("Controller credential") {
          SecureField("Controller bearer", text: $controllerBearer)
            .textFieldStyle(RelayPillTextFieldStyle())
            .accessibilityLabel("Relay controller credential")

          Text("Used only for authenticated requests to the verified Relay and stored in Keychain.")
            .font(.caption2)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Could not add Relay. \(errorMessage)")
        }

        HStack {
          Spacer()
          Button {
            submit()
          } label: {
            if isSubmitting {
              ProgressView()
                .controlSize(.small)
                .frame(minWidth: 64)
                .accessibilityLabel("Adding Relay")
            } else {
              Text("Add Relay")
            }
          }
          .buttonStyle(QuotaPrimaryButtonStyle())
          .disabled(isSubmitting)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, 16)
    }
  }

  @ViewBuilder
  private func formField<Content: View>(
    _ label: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(QuotaPalette.charcoal)
      content()
    }
  }

  private func submit() {
    guard !isSubmitting else { return }
    let validated: ValidatedRelayAddForm
    do {
      validated = try RelayAddFormValidation.validate(
        name: name,
        origin: origin,
        controllerBearer: controllerBearer
      )
    } catch {
      errorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "Check the Relay details and try again."
      )
      return
    }

    isSubmitting = true
    errorMessage = nil
    Task {
      defer { isSubmitting = false }
      do {
        let profile = try await model.addSelfHostedProfile(
          name: validated.name,
          origin: validated.origin,
          controllerBearer: validated.controllerBearer
        )
        controllerBearer = ""
        onAdded(profile.id)
      } catch {
        errorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not add the Relay."
        )
      }
    }
  }
}
