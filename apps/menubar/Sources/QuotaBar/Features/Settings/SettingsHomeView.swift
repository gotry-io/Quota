import AppKit
import SwiftUI

struct SettingsHomeView: View {
  let model: MenuBarViewModel
  @Binding var showsCodex: Bool
  @Binding var showsClaude: Bool
  @Binding var showsGrok: Bool
  let onOpenRelays: () -> Void

  @State private var showsDeleteAllConfirmation = false
  @State private var showsLocalDeleteConfirmation = false
  @State private var isDeletingAllData = false
  @State private var deleteAllErrorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        settingsSection("Agents") {
          providerToggle(.codex, isOn: $showsCodex)
          providerToggle(.claude, isOn: $showsClaude)
          providerToggle(.grok, isOn: $showsGrok)

          Text("Only signed-in agents with available or stale quota appear in the overview.")
            .font(.caption)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
        }

        Divider()
          .overlay(QuotaPalette.hairline)

        settingsSection("Remote quota") {
          Button(action: onOpenRelays) {
            HStack(spacing: 12) {
              Image(systemName: "network")
                .frame(width: 18)

              VStack(alignment: .leading, spacing: 3) {
                Text("Relays")
                  .font(QuotaDesign.Typography.providerTitle)
                  .foregroundStyle(QuotaPalette.ink)
                Text(relaySummary)
                  .font(QuotaDesign.Typography.resetTime)
                  .foregroundStyle(QuotaPalette.body)
                  .lineLimit(2)
              }

              Spacer()

              Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(QuotaPalette.body)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Manage Relays")
          .accessibilityHint(relaySummary)
        }

        Divider()
          .overlay(QuotaPalette.hairline)

        settingsSection("About") {
          HStack(alignment: .firstTextBaseline) {
            Text("QuotaBar")
              .font(.system(.subheadline, weight: .medium))
            Spacer()
            Text("v\(AppMetadata.version)")
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(QuotaPalette.body)
          }

          Text(
            "Local-first subscription quota for coding agents. MIT licensed by gotry-io contributors."
          )
          .font(.caption)
          .foregroundStyle(QuotaPalette.body)
          .fixedSize(horizontal: false, vertical: true)

          if let deleteAllErrorMessage {
            Label(deleteAllErrorMessage, systemImage: "exclamationmark.circle")
              .font(.caption)
              .foregroundStyle(QuotaPalette.body)
              .fixedSize(horizontal: false, vertical: true)
          }

          Button("Delete all QuotaBar data") {
            showsDeleteAllConfirmation = true
          }
          .buttonStyle(.plain)
          .font(.system(.subheadline, weight: .medium))
          .foregroundStyle(QuotaPalette.body)
          .disabled(isDeletingAllData)

          Button("Quit QuotaBar") {
            NSApplication.shared.terminate(nil)
          }
          .buttonStyle(.plain)
          .font(.system(.subheadline, weight: .medium))
          .foregroundStyle(QuotaPalette.ink)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, 16)
    }
    .confirmationDialog(
      "Delete all QuotaBar data?",
      isPresented: $showsDeleteAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete All Data", role: .destructive) {
        deleteAllData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "QuotaBar will delete its managed controller and linked Relay data, then delete all controller credentials, Relay profiles, cached quota, and user preferences. Managed Relay will stay disconnected until you reconnect it."
      )
    }
    .confirmationDialog(
      "Finish by deleting local data?",
      isPresented: $showsLocalDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete Locally Anyway", role: .destructive) {
        deleteAllDataLocally()
      }
      Button("Keep Data", role: .cancel) {}
    } message: {
      Text(
        "QuotaBar could not confirm full cleanup. Deleting locally may leave the managed controller and Relay data behind while paired devices continue reporting. Use this only if you cannot retry while online."
      )
    }
  }

  private var relaySummary: String {
    let count = model.relayStateModel.profiles.count
    return count == 1 ? "1 configured Relay" : "\(count) configured Relays"
  }

  private func providerToggle(_ provider: ProviderID, isOn: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        HStack(spacing: 6) {
          ProviderBrandIcon(provider: provider)
          Text(provider.displayName)
        }
        .font(QuotaDesign.Typography.providerTitle)

        Spacer()

        Text(providerStatus(provider))
          .font(QuotaDesign.Typography.resetTime)
          .foregroundStyle(QuotaPalette.body)

        Toggle("Show \(provider.displayName)", isOn: isOn)
          .labelsHidden()
          .controlSize(.small)
      }

      if let message = providerMessage(provider) {
        Text(message)
          .font(QuotaDesign.Typography.resetTime)
          .foregroundStyle(QuotaPalette.body)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(minHeight: 28)
  }

  private func providerStatus(_ provider: ProviderID) -> String {
    guard let result = model.result(for: provider) else {
      return "Not checked"
    }
    return switch result.outcome {
    case .success: "Signed in"
    case .authRequired: "Not signed in"
    case .unavailable: "Unavailable"
    case .unsupported: "Unsupported"
    case .error: "Error"
    }
  }

  private func providerMessage(_ provider: ProviderID) -> String? {
    guard let result = model.result(for: provider), result.outcome != .success else {
      return nil
    }
    return result.message
  }

  private func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(QuotaPalette.charcoal)

      content()
    }
  }

  private func deleteAllData() {
    guard !isDeletingAllData else { return }
    isDeletingAllData = true
    deleteAllErrorMessage = nil
    Task {
      defer { isDeletingAllData = false }
      do {
        try await model.deleteAllQuotaBarData()
      } catch {
        deleteAllErrorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not delete all data."
        )
        if shouldOfferLocalDelete(after: error) {
          showsLocalDeleteConfirmation = true
        }
      }
    }
  }

  private func deleteAllDataLocally() {
    do {
      try model.deleteAllQuotaBarDataLocally()
      deleteAllErrorMessage = nil
    } catch {
      deleteAllErrorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "QuotaBar could not delete its local data."
      )
    }
  }

  private func shouldOfferLocalDelete(after error: Error) -> Bool {
    !(error is CancellationError)
  }
}
