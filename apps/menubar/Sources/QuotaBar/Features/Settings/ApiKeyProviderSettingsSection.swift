import SwiftUI

/// Settings block for one API-key catalog provider (`ProviderID.configurableCases`).
struct ApiKeyProviderSettingsSection: View {
  let provider: ProviderID
  @Binding var isVisible: Bool

  @State private var status: ProviderApiKeyStatus
  @State private var keyDraft = ""
  @State private var message: String?

  init(provider: ProviderID, isVisible: Binding<Bool>) {
    self.provider = provider
    self._isVisible = isVisible
    _status = State(initialValue: ProviderConfigStore().status(for: provider))
  }

  var body: some View {
    SettingsSection(title: provider.displayName) {
      Text(statusLabel)
        .quotaMetaStyle()
        .fixedSize(horizontal: false, vertical: true)

      SecureField("API key", text: $keyDraft)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.system(size: 11, design: .monospaced))
        .accessibilityLabel("\(provider.displayName) API key")

      HStack(spacing: QuotaDesign.Spacing.inline) {
        Button("Save", action: save)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button("Clear", action: clear)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled({
            if case .configured = status { return false }
            return true
          }())
      }

      if let message {
        Text(message)
          .quotaMetaStyle()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear {
      status = ProviderConfigStore().status(for: provider)
    }
  }

  private var statusLabel: String {
    switch status {
    case .missing:
      return "No key saved. Paste a key and Save, or run \(provider.loginCommand)."
    case .unreadable:
      return "Could not read ~/.config/quotacli/providers.json."
    case .configured(let mask):
      return "Saved: \(mask). Shared with QuotaCLI."
    }
  }

  private func save() {
    do {
      try ProviderConfigStore().setApiKey(provider, apiKey: keyDraft)
      keyDraft = ""
      status = ProviderConfigStore().status(for: provider)
      message = "Saved. Refresh Overview to collect."
      isVisible = true
    } catch {
      message = "Could not save the API key."
    }
  }

  private func clear() {
    do {
      try ProviderConfigStore().clear(provider)
      keyDraft = ""
      status = ProviderConfigStore().status(for: provider)
      message = "Cleared \(provider.displayName) key."
    } catch {
      message = "Could not clear the API key."
    }
  }
}
