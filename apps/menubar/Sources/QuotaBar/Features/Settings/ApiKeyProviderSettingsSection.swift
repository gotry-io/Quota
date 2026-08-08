import SwiftUI

/// Header **Save** bumps `saveRequest`.
/// Non-empty key writes; empty key + base change updates base only; empty + no base change deletes.
struct ApiKeyProviderSettingsForm: View {
  let provider: ProviderID
  @Binding var isVisible: Bool
  var saveRequest: Int = 0
  var onIssue: (String?) -> Void = { _ in }

  @State private var status: ProviderApiKeyStatus
  @State private var keyDraft = ""
  @State private var baseURLDraft = ""
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case apiKey
    case baseURL
  }

  init(
    provider: ProviderID,
    isVisible: Binding<Bool>,
    saveRequest: Int = 0,
    onIssue: @escaping (String?) -> Void = { _ in }
  ) {
    self.provider = provider
    self._isVisible = isVisible
    self.saveRequest = saveRequest
    self.onIssue = onIssue
    let store = ProviderConfigStore()
    _status = State(initialValue: store.status(for: provider))
    _baseURLDraft = State(initialValue: store.baseURL(for: provider) ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      SecureField("API key", text: $keyDraft)
        .focused($focusedField, equals: .apiKey)
        .quotaTextFieldStyle(
          isFocused: focusedField == .apiKey,
          showsClear: !keyDraft.isEmpty,
          onClear: { keyDraft = "" }
        )
        .quotaMonoStyle()
        .textContentType(.password)
        .accessibilityLabel("\(provider.displayName) API key")

      if provider.supportsBaseURL {
        TextField("Base URL", text: $baseURLDraft)
          .focused($focusedField, equals: .baseURL)
          .quotaTextFieldStyle(
            isFocused: focusedField == .baseURL,
            showsClear: !baseURLDraft.isEmpty,
            onClear: { baseURLDraft = "" }
          )
          .quotaMonoStyle()
          .textContentType(.URL)
          .autocorrectionDisabled()
          .accessibilityLabel("\(provider.displayName) base URL")
      }
    }
    .onAppear {
      reloadStatus()
      if case .unreadable = status {
        onIssue("Could not read providers.json.")
      }
    }
    .onDisappear { onIssue(nil) }
    .onChange(of: saveRequest) { _, newValue in
      if newValue > 0 { save() }
    }
  }

  private func reloadStatus() {
    let store = ProviderConfigStore()
    status = store.status(for: provider)
    if baseURLDraft.isEmpty {
      baseURLDraft = store.baseURL(for: provider) ?? ""
    }
  }

  private func save() {
    let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let store = ProviderConfigStore()

    if !key.isEmpty {
      do {
        try store.setApiKey(provider, apiKey: key, baseURL: base.isEmpty ? nil : base)
        keyDraft = ""
        baseURLDraft = store.baseURL(for: provider) ?? ""
        reloadStatus()
        onIssue(nil)
        isVisible = true
      } catch {
        onIssue(saveErrorMessage(error, fallback: "Could not save the API key."))
      }
      return
    }

    switch status {
    case .missing:
      keyDraft = ""
      onIssue(nil)
    case .unreadable:
      onIssue("Could not clear the API key.")
    case .configured:
      let savedBase = store.baseURL(for: provider) ?? ""
      if base != savedBase {
        // Empty key field is normal when configured — only base changed.
        do {
          try store.updateBaseURL(provider, baseURL: base.isEmpty ? nil : base)
          baseURLDraft = store.baseURL(for: provider) ?? ""
          reloadStatus()
          onIssue(nil)
        } catch {
          onIssue(saveErrorMessage(error, fallback: "Could not save the base URL."))
        }
      } else {
        // Empty key + unchanged base → remove stored credential.
        do {
          try store.clear(provider)
          keyDraft = ""
          baseURLDraft = ""
          reloadStatus()
          onIssue(nil)
        } catch {
          onIssue("Could not clear the API key.")
        }
      }
    }
  }

  private func saveErrorMessage(_ error: Error, fallback: String) -> String {
    switch error as? ProviderConfigStoreError {
    case .invalidBaseURL:
      return provider.allowsPrivateHttpBaseURL
        ? "Invalid base URL. Use HTTPS, or HTTP for local/private hosts."
        : "Invalid base URL. Use an HTTPS origin."
    case .missingBaseURL:
      return "\(provider.displayName) requires a base URL."
    default:
      return fallback
    }
  }
}
