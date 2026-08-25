import QuotaWire
import SwiftUI

/// Settings → Agents → <Provider>: visibility, reporting provenance, and local configuration.
struct ProviderSettingsView: View {
  @Bindable var model: MenuBarViewModel
  let provider: ProviderID
  let reportingSources: [ProviderReportingSourcePresentation]
  let now: Date

  @State private var isVisible: Bool
  @State private var apiKey = ""
  @State private var baseURL = ""
  @State private var isSaving = false
  @State private var configurationError: String?

  init(
    model: MenuBarViewModel,
    provider: ProviderID,
    reportingSources: [ProviderReportingSourcePresentation] = [],
    now: Date
  ) {
    self.model = model
    self.provider = provider
    self.reportingSources = reportingSources
    self.now = now
    _isVisible = State(initialValue: ProviderVisibility.isVisible(provider))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Overview") {
          SettingsListRow(
            title: "Show in Overview",
            subtitle: "Applies to local and account device reports",
            height: QuotaDesign.Layout.settingsListRowHeight,
            leading: {
              ProviderBrandIcon(
                provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
            },
            trailing: {
              Toggle("Show in Overview", isOn: visibilityBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(QuotaPalette.accent)
                .accessibilityLabel("Show \(provider.displayName) in Overview")
                .accessibilityHint("Show or hide this agent in Overview")
            }
          )
        }

        SettingsSection(title: "Reporting From") {
          reportingSourcesContent
        }

        if provider.browserSession != nil {
          SettingsSection(title: "Browser Session") {
            browserSessionConfiguration
          }
        }

        if provider.isConfigurable {
          SettingsSection(title: "This Mac Configuration") {
            providerConfiguration
          }
        } else if showsOfficialSignInCommand {
          SettingsSection(title: "This Mac Sign-in") {
            QuotaCommandRow(command: provider.setupAction, copyLabel: "Copy sign-in command")
          }
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

  @ViewBuilder
  private var reportingSourcesContent: some View {
    if reportingSources.isEmpty {
      Text("No reports yet")
        .quotaSecondaryStyle()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .frame(
          maxWidth: .infinity,
          minHeight: QuotaDesign.Layout.settingsRowHeight,
          alignment: .leading
        )
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(reportingSources) { source in
          SettingsListRow(title: source.displayName, systemImage: source.symbolName) {
            Text(source.detailLabel(now: now))
              .quotaListSecondaryStyle()
              .lineLimit(1)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(source.displayName)
          .accessibilityValue(source.detailLabel(now: now))
        }
      }
    }
  }

  private var providerConfiguration: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      if let config = model.providerConfigurations[provider], config.configured {
        Text("Configured as \(config.maskedAPIKey ?? "saved credential")")
          .quotaSecondaryStyle()
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

  private var browserSessionConfiguration: some View {
    let session = model.providerBrowserSessions[provider]
    let waiting = model.browserSessionWaitingProvider == provider
    return VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      if session?.configured == true {
        Text("Connected as \(session?.accountLabel ?? "account")")
          .quotaSecondaryStyle()
      }

      HStack(spacing: QuotaDesign.Spacing.sm) {
        if waiting {
          if model.canCancelBrowserSessionLogin {
            Button("Cancel", action: model.cancelProviderBrowserSessionFlow)
              .buttonStyle(QuotaSecondaryButtonStyle())
          }
          Text(model.browserSessionActivityText ?? "Connecting…")
            .quotaMetaStyle()
        } else if session?.configured == true {
          Button("Disconnect") {
            model.requestProviderBrowserSessionDisconnect(provider)
          }
          .buttonStyle(QuotaSecondaryButtonStyle(isDestructive: true))
        } else {
          Button("Sign In") {
            model.startProviderBrowserSessionLogin(provider)
          }
          .buttonStyle(QuotaSecondaryButtonStyle())
        }
      }
      .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)

      // A refused read is not a failed one: it names a permission this Mac has to be given,
      // so it carries a warning rather than the generic error mark.
      if let denial = model.browserSessionAccessDenials[provider] {
        Label(denial.message, systemImage: "exclamationmark.triangle")
          .quotaMetaStyle()
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("\(denial.browserName) cookies could not be read")
          .accessibilityValue(denial.message)
      } else if let message = model.browserSessionErrorMessages[provider] {
        Label(message, systemImage: "exclamationmark.circle")
          .quotaMetaStyle()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(QuotaDesign.Layout.groupContentInset)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var showsOfficialSignInCommand: Bool {
    provider.browserSession?.exclusive != true
  }

  private var visibilityBinding: Binding<Bool> {
    Binding(
      get: { isVisible },
      set: { newValue in
        ProviderVisibility.setVisible(provider, newValue)
        isVisible = newValue
      }
    )
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
