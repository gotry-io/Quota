import AppKit
import SwiftUI

struct PairDeviceView: View {
  let model: RelayStateModel
  let onFinished: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum EndpointChoice: Hashable {
    case official
    case known(URL)
    case other
  }

  @State private var endpointChoice: EndpointChoice = .official
  @State private var customOrigin = ""
  @State private var pairingCode = ""
  @State private var showsInstallHelp = false
  @State private var errorMessage: String?
  @State private var isSubmitting = false
  @State private var lastAttemptedCode: String?
  @State private var retryToken = 0
  @State private var installCopied = false
  @State private var pairCopied = false
  @FocusState private var isCustomOriginFocused: Bool

  private var officialURL: URL {
    model.officialRelayBaseURL ?? OfficialRelayEndpoint.production.baseURL
  }

  private var selectedURL: URL? {
    switch endpointChoice {
    case .official:
      return officialURL
    case .known(let url):
      return url
    case .other:
      let trimmed = customOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
      return try? RelayOrigin.canonicalURL(from: trimmed)
    }
  }

  private var pairCommand: RelayPairCommandPresentation {
    RelayPairCommandPresentation.make(
      selectedURL: selectedURL,
      officialURL: officialURL,
      isOtherChoice: endpointChoice == .other
    )
  }

  private let installCommand = "npm install -g @gotry-io/quotacli"

  private var knownEndpoints: [URL] {
    model.knownEndpointURLs.filter { $0 != officialURL }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
        endpointPicker

        if endpointChoice == .other {
          TextField("https://relay.example", text: $customOrigin)
            .focused($isCustomOriginFocused)
            .quotaTextFieldStyle(
              isFocused: isCustomOriginFocused,
              showsClear: !customOrigin.isEmpty,
              onClear: {
                customOrigin = ""
                pairCopied = false
              }
            )
            .quotaMonoStyle()
            .disabled(isSubmitting)
            .accessibilityLabel("Relay URL")
            .onChange(of: customOrigin) { _, _ in
              pairCopied = false
            }
        }

        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
          Text("On the Device")
            .quotaSectionHeaderStyle()

          commandRow(
            title: "Pair",
            command: pairCommand.command,
            copied: pairCopied,
            copyLabel: "Copy pair command",
            isCopyEnabled: pairCommand.canCopy,
            action: copyPairCommand
          )

          collapsibleSection(title: "Need QuotaCLI?", isExpanded: $showsInstallHelp) {
            commandRow(
              title: "Install",
              command: installCommand,
              copied: installCopied,
              copyLabel: "Copy install command",
              action: copyInstallCommand
            )
          }
        }

        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sectionRows) {
          Text("Pairing Code")
            .quotaSectionHeaderStyle()

          PairingCodeEntryView(
            code: $pairingCode,
            isDisabled: isSubmitting || selectedURL == nil,
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
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  @ViewBuilder
  private var endpointPicker: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Text("Relay")
        .quotaSectionHeaderStyle()

      Picker("Relay", selection: $endpointChoice) {
        Text("Quota Relay").tag(EndpointChoice.official)
        ForEach(knownEndpoints, id: \.absoluteString) { url in
          Text(url.absoluteString).tag(EndpointChoice.known(url))
        }
        Text("Other Relay…").tag(EndpointChoice.other)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .controlSize(.regular)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.fieldMinHeight, alignment: .leading)
      .background(QuotaPalette.fieldFill)
      .clipShape(
        RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
      )
      .disabled(isSubmitting)
      .accessibilityLabel("Relay endpoint")
      .onChange(of: endpointChoice) { _, _ in
        pairCopied = false
      }
    }
  }

  private func collapsibleSection<Content: View>(
    title: String,
    isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Button {
        if reduceMotion {
          isExpanded.wrappedValue.toggle()
        } else {
          withAnimation(.snappy(duration: 0.2)) {
            isExpanded.wrappedValue.toggle()
          }
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
        .frame(
          maxWidth: .infinity,
          minHeight: QuotaDesign.Layout.minimumInteractiveDimension,
          alignment: .leading
        )
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
    isCopyEnabled: Bool = true,
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

        Button(action: action) {
          Text(copied && isCopyEnabled ? "Copied" : "Copy")
            .quotaSecondaryStyle()
            .frame(
              minWidth: QuotaDesign.Layout.minimumInteractiveDimension,
              minHeight: QuotaDesign.Layout.minimumInteractiveDimension
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isCopyEnabled)
        .accessibilityLabel(copyLabel)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, QuotaDesign.Spacing.sm)
      .background(QuotaPalette.fieldFill)
      .clipShape(
        RoundedRectangle(cornerRadius: QuotaDesign.Layout.groupCornerRadius, style: .continuous)
      )
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
    guard pairCommand.canCopy else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(pairCommand.command, forType: .string)
    pairCopied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      pairCopied = false
    }
  }

  private func submit(canonicalCode: String) {
    guard !isSubmitting else { return }
    if lastAttemptedCode == canonicalCode, errorMessage == nil {
      return
    }

    errorMessage = nil
    lastAttemptedCode = canonicalCode
    isSubmitting = true

    Task {
      defer { isSubmitting = false }
      do {
        let origin = try resolvedOrigin()
        let profile = try await model.ensureEndpoint(origin: origin)
        // Approval alone is not success. Snapshot current devices, then wait until QuotaCLI
        // consumes the session and a new device appears before leaving this page.
        let knownDeviceIDs = Set(
          (model.state(for: profile.id)?.devices ?? [])
            .filter { $0.revokedAt == nil }
            .map(\.deviceID)
        )
        try await model.approvePairing(profileID: profile.id, userCode: canonicalCode)
        try await model.waitForJoinedDevice(
          profileID: profile.id,
          excludingDeviceIDs: knownDeviceIDs
        )
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

  private func resolvedOrigin() throws -> String {
    switch endpointChoice {
    case .official:
      return officialURL.absoluteString
    case .known(let url):
      return url.absoluteString
    case .other:
      let trimmed = customOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw RelayFormValidationError.invalidOrigin("Enter a Relay URL.")
      }
      return try RelayOrigin.canonicalURL(from: trimmed).absoluteString
    }
  }
}
