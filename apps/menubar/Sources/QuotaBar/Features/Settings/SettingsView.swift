import AppKit
import SwiftUI

struct SettingsView: View {
  let model: MenuBarViewModel
  @Binding var showsCodex: Bool
  @Binding var showsClaude: Bool
  @Binding var showsGrok: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      settingsSection("Agents") {
        providerToggle(.codex, isOn: $showsCodex)
        providerToggle(.claude, isOn: $showsClaude)
        providerToggle(.grok, isOn: $showsGrok)

        Text("Only signed-in agents with available quota appear in the overview.")
          .font(.system(size: 12))
          .foregroundStyle(QuotaPalette.body)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
        .overlay(QuotaPalette.hairline)

      settingsSection("About") {
        HStack(alignment: .firstTextBaseline) {
          Text("QuotaBar")
            .font(.system(size: 14, weight: .medium))
          Spacer()
          Text("v\(AppMetadata.version)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(QuotaPalette.body)
        }

        Text(
          "Local-first subscription quota for coding agents. MIT licensed by gotry-io contributors."
        )
        .font(.system(size: 12))
        .foregroundStyle(QuotaPalette.body)
        .fixedSize(horizontal: false, vertical: true)

        Button("Quit QuotaBar") {
          NSApplication.shared.terminate(nil)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(QuotaPalette.ink)
      }
    }
    .padding(.vertical, 16)
  }

  private func providerToggle(_ provider: ProviderID, isOn: Binding<Bool>) -> some View {
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

  private func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(QuotaPalette.charcoal)

      content()
    }
  }
}
