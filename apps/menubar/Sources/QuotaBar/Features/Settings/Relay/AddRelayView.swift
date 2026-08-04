import AppKit
import SwiftUI

struct AddRelayView: View {
  let model: RelayStateModel
  let onFinished: () -> Void

  @State private var pairingCode = ""
  @State private var showsDeviceHelp = false
  @State private var showsAdvanced = false
  @State private var name = ""
  @State private var origin = ManagedRelayConfiguration.production.baseURL.absoluteString
  @State private var controllerBearer = ""
  @State private var errorMessage: String?
  @State private var isSubmitting = false
  @State private var lastAttemptedCode: String?
  @State private var retryToken = 0
  @State private var installCopied = false
  @State private var pairCopied = false

  private var usesOfficialRelay: Bool {
    guard let url = try? RelayOrigin.canonicalURL(from: origin) else { return false }
    return url == ManagedRelayConfiguration.production.baseURL
  }

  private var pairCommand: String {
    if usesOfficialRelay {
      return "quotacli relay pair"
    }
    let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
    return "quotacli relay pair --relay \(trimmed.isEmpty ? "https://relay.example" : trimmed)"
  }

  private let installCommand = "npm install -g @gotry-io/quotacli"

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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pairing")
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

        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
          collapsibleSection(title: "On the Device", isExpanded: $showsDeviceHelp) {
            VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardBody) {
              commandRow(
                title: "Install",
                command: installCommand,
                copied: installCopied,
                copyLabel: "Copy install command",
                action: copyInstallCommand
              )
              commandRow(
                title: "Pair",
                command: pairCommand,
                copied: pairCopied,
                copyLabel: "Copy pair command",
                action: copyPairCommand
              )
            }
          }

          collapsibleSection(title: "Advanced", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
              TextField("Name (optional)", text: $name)
                .textFieldStyle(RelayRoundedTextFieldStyle())
                .disabled(isSubmitting)

              TextField("https://quota.gotry.io", text: $origin)
                .textFieldStyle(RelayRoundedTextFieldStyle())
                .quotaMonoStyle()
                .disabled(isSubmitting)

              if !usesOfficialRelay {
                SecureField("Controller credential", text: $controllerBearer)
                  .textFieldStyle(RelayRoundedTextFieldStyle())
                  .disabled(isSubmitting)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private func collapsibleSection<Content: View>(
    title: String,
    isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Button {
        withAnimation(.snappy(duration: 0.2)) {
          isExpanded.wrappedValue.toggle()
        }
      } label: {
        HStack(spacing: QuotaDesign.Spacing.iconLabel) {
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
          Text(title)
            .quotaSectionHeaderStyle()
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, QuotaDesign.Spacing.xxs)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityHint(isExpanded.wrappedValue ? "Collapse" : "Expand")

      if isExpanded.wrappedValue {
        content()
      }
    }
  }

  private func commandRow(
    title: String,
    command: String,
    copied: Bool,
    copyLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.meta) {
      Text(title)
        .quotaMetaStyle()

      HStack(spacing: QuotaDesign.Spacing.inline) {
        Text(command)
          .quotaMonoStyle()
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)

        Button(copied ? "Copied" : "Copy", action: action)
          .buttonStyle(.plain)
          .quotaSecondaryStyle()
          .accessibilityLabel(copyLabel)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, QuotaDesign.Spacing.sm)
      .background(QuotaPalette.soft)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(QuotaPalette.hairlineBorder, lineWidth: 1)
      }
    }
  }

  private func copyInstallCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(installCommand, forType: .string)
    installCopied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      installCopied = false
    }
  }

  private func copyPairCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(pairCommand, forType: .string)
    pairCopied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      pairCopied = false
    }
  }

  private func submit(canonicalCode: String) {
    guard !isSubmitting else { return }
    // Same complete code only auto-fires once until failure clears the lock.
    if lastAttemptedCode == canonicalCode, errorMessage == nil {
      return
    }

    errorMessage = nil
    lastAttemptedCode = canonicalCode
    isSubmitting = true

    Task {
      defer { isSubmitting = false }
      do {
        let profileID = try await resolveProfileIDForPairing()
        try await model.approvePairing(profileID: profileID, userCode: canonicalCode)

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // ponytail: only rename when user typed a name; guessing newest device is wrong multi-device
        if !trimmedName.isEmpty {
          try? model.renameProfile(profileID, to: trimmedName)
        }

        onFinished()
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

  private func resolveProfileIDForPairing() async throws -> UUID {
    if usesOfficialRelay {
      await model.ensureManagedControllerProfile()
      if let existing = model.profiles.first(where: { $0.mode == .managed })?.id {
        return existing
      }
      throw RelayStateModelError(
        issue: RelayStateIssue(
          category: .unavailable,
          message: "QuotaBar could not prepare the official Relay controller."
        )
      )
    }

    let validated = try RelayAddFormValidation.validate(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Relay"
        : name,
      origin: origin,
      controllerBearer: controllerBearer
    )

    if let existing = model.profiles.first(where: {
      $0.baseURL.absoluteString == validated.origin
    }) {
      // Keep the bearer the user just entered; don't silently reuse a stale Keychain value.
      try model.updateControllerCredential(
        profileID: existing.id,
        controllerBearer: validated.controllerBearer
      )
      return existing.id
    }

    let profile = try await model.addSelfHostedProfile(
      name: validated.name,
      origin: validated.origin,
      controllerBearer: validated.controllerBearer
    )
    return profile.id
  }
}
