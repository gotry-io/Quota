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
          .zIndex(1)

        if endpointChoice == .other {
          TextField("https://relay.example", text: $customOrigin)
            .focused($isCustomOriginFocused)
            .quotaTextFieldStyle(
              isFocused: isCustomOriginFocused,
              showsClear: !customOrigin.isEmpty,
              onClear: {
                customOrigin = ""
              }
            )
            .quotaMonoStyle()
            .disabled(isSubmitting)
            .accessibilityLabel("Relay URL")
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

        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
          Text("On the device")
            .quotaSectionHeaderStyle()

          QuotaCommandRow(
            command: pairCommand.command,
            copyLabel: "Copy pair command",
            isCopyEnabled: pairCommand.canCopy,
          )
          .quotaGroupSurface()

          collapsibleSection(title: "Need QuotaCLI?", isExpanded: $showsInstallHelp) {
            QuotaCommandRow(
              command: installCommand,
              copyLabel: "Copy install command"
            )
            .quotaGroupSurface()
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

      QuotaPopUpField(
        selection: $endpointChoice,
        options: endpointOptions,
        accessibilityLabel: "Relay endpoint"
      )
      .disabled(isSubmitting)
    }
  }

  private var endpointOptions: [QuotaPopUpOption<EndpointChoice>] {
    [QuotaPopUpOption(value: .official, title: "Quota Relay")]
      + knownEndpoints.map {
        QuotaPopUpOption(value: .known($0), title: $0.absoluteString)
      }
      + [QuotaPopUpOption(value: .other, title: "Other Relay…")]
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
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .contentShape(Rectangle())
        .frame(
          maxWidth: .infinity,
          minHeight: QuotaDesign.Layout.settingsRowHeight,
          alignment: .leading
        )
      }
      .buttonStyle(QuotaListRowButtonStyle())
      .accessibilityLabel(title)
      .accessibilityHint(isExpanded.wrappedValue ? "Collapse" : "Expand")

      if isExpanded.wrappedValue {
        content()
      }
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
