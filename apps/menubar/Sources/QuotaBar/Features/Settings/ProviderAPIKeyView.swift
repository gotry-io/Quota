import QuotaWire
import SwiftUI

/// Settings → Agents → <Provider> → API Key: the one place a key is typed. New values travel only
/// over private child stdin; the field is cleared after Save and the service keeps the masked
/// state.
struct ProviderAPIKeyView: View {
  @Bindable var model: MenuBarViewModel
  let provider: ProviderID

  @State private var apiKey = ""
  @State private var baseURL = ""
  @State private var isSaving = false
  @State private var configurationError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "API Key") {
          form
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .onAppear(perform: loadConfigurationPresentation)
    .onChange(of: model.providerConfigurations[provider]) {
      loadConfigurationPresentation()
    }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      if let config = model.providerConfigurations[provider], config.configured {
        Text("Configured as \(config.maskedAPIKey ?? "saved credential")")
          .quotaSecondaryStyle()
      } else {
        Text("Stored by QuotaBar's local service on this Mac. Never uploaded.")
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
      }

      SecureField(
        model.providerConfigurations[provider]?.configured == true
          ? "Enter a new API key to replace it"
          : "API key",
        text: $apiKey
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("\(provider.displayName) API key")

      if provider.supportsBaseURL {
        TextField("Base URL", text: $baseURL)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("\(provider.displayName) base URL")
      }

      HStack(spacing: QuotaDesign.Spacing.sm) {
        Button(isSaving ? "Saving…" : "Save") {
          saveConfiguration()
        }
        .buttonStyle(QuotaPrimaryButtonStyle(isCompact: true))
        .disabled(
          isSaving
            || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (provider.requiresBaseURL
              && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )

        if model.providerConfigurations[provider]?.configured == true {
          Button("Remove") {
            removeConfiguration()
          }
          .buttonStyle(QuotaSecondaryButtonStyle(isDestructive: true))
          .disabled(isSaving)
        }
      }

      if let configurationError {
        Label(configurationError, systemImage: "exclamationmark.circle")
          .quotaMetaStyle()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(QuotaDesign.Layout.groupContentInset)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func loadConfigurationPresentation() {
    guard baseURL.isEmpty else { return }
    baseURL = model.providerConfigurations[provider]?.baseURL ?? ""
  }

  private func saveConfiguration() {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    isSaving = true
    configurationError = nil
    Task { @MainActor in
      defer { isSaving = false }
      do {
        try await model.setProviderConfig(provider, apiKey: key, baseURL: url.isEmpty ? nil : url)
        apiKey = ""
      } catch {
        configurationError = Self.message(for: error)
      }
    }
  }

  private func removeConfiguration() {
    isSaving = true
    configurationError = nil
    Task { @MainActor in
      defer { isSaving = false }
      do {
        try await model.removeProviderConfig(provider)
        apiKey = ""
        baseURL = ""
      } catch {
        configurationError = Self.message(for: error)
      }
    }
  }

  private static func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "Could not update this provider."
  }
}
