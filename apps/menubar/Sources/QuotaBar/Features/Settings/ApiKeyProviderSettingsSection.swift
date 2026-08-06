import SwiftUI

/// API-key form for one catalog-configurable provider (no outer section chrome).
/// Used on the provider detail page under Settings → Agents.
struct ApiKeyProviderSettingsForm: View {
  let provider: ProviderID
  @Binding var isVisible: Bool

  @State private var status: ProviderApiKeyStatus
  @State private var keyDraft = ""
  @State private var baseURLDraft = ""
  @State private var message: String?

  private let store = ProviderConfigStore()

  init(provider: ProviderID, isVisible: Binding<Bool>) {
    self.provider = provider
    self._isVisible = isVisible
    let store = ProviderConfigStore()
    _status = State(initialValue: store.status(for: provider))
    // Seed base URL so Save does not wipe a previously stored proxy endpoint.
    _baseURLDraft = State(initialValue: store.baseURL(for: provider) ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text(statusLabel)
        .quotaMetaStyle()
        .fixedSize(horizontal: false, vertical: true)

      SecureField("API key", text: $keyDraft)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.system(size: 11, design: .monospaced))
        .accessibilityLabel("\(provider.displayName) API key")

      // LiteLLM and other proxies need a base URL; optional for the rest.
      TextField("Base URL (optional)", text: $baseURLDraft)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.system(size: 11, design: .monospaced))
        .accessibilityLabel("\(provider.displayName) base URL")

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
      reloadStatus()
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

  private func reloadStatus() {
    status = store.status(for: provider)
    if baseURLDraft.isEmpty, let saved = store.baseURL(for: provider) {
      baseURLDraft = saved
    }
  }

  private func save() {
    do {
      let base = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      try store.setApiKey(
        provider,
        apiKey: keyDraft,
        baseURL: base.isEmpty ? nil : base
      )
      keyDraft = ""
      reloadStatus()
      message = "Saved. Refresh Overview to collect."
      isVisible = true
    } catch {
      message = "Could not save the API key."
    }
  }

  private func clear() {
    do {
      try store.clear(provider)
      keyDraft = ""
      baseURLDraft = ""
      reloadStatus()
      message = "Cleared \(provider.displayName) key."
    } catch {
      message = "Could not clear the API key."
    }
  }
}
