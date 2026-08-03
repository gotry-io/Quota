import SwiftUI

struct SettingsHomeView: View {
  let model: MenuBarViewModel
  @Binding var showsCodex: Bool
  @Binding var showsClaude: Bool
  @Binding var showsGrok: Bool
  let onOpenRelays: () -> Void
  var deleteAllErrorMessage: String? = nil

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        settingsSection("Agents") {
          VStack(alignment: .leading, spacing: 12) {
            providerToggle(.codex, isOn: $showsCodex)
            providerToggle(.claude, isOn: $showsClaude)
            providerToggle(.grok, isOn: $showsGrok)
          }

          Text("Turn on signed-in agents to show them in Overview.")
            .font(QuotaDesign.Typography.resetTime)
            .foregroundStyle(QuotaPalette.body)
            .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

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
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, 12)
    }
  }

  private var relaySummary: String {
    let count = model.relayStateModel.profiles.count
    return count == 1 ? "1 configured Relay" : "\(count) configured Relays"
  }

  private func providerToggle(_ provider: ProviderID, isOn: Binding<Bool>) -> some View {
    let status = AgentStatusPresentation.resolve(
      result: model.result(for: provider)
    )

    return HStack(alignment: .center, spacing: 12) {
      ProviderBrandIcon(provider: provider, size: 16)

      VStack(alignment: .leading, spacing: 3) {
        Text(provider.displayName)
          .font(QuotaDesign.Typography.providerTitle)
          .foregroundStyle(status.canToggle ? QuotaPalette.ink : QuotaPalette.body)

        if let detail = status.detail {
          Text(detail)
            .font(QuotaDesign.Typography.resetTime)
            .foregroundStyle(QuotaPalette.mute)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 8)

      // Keep stored preference even when disabled; only block interaction.
      Toggle("Show \(provider.displayName)", isOn: isOn)
        .labelsHidden()
        .controlSize(.small)
        .disabled(!status.canToggle)
        .opacity(status.canToggle ? 1 : 0.45)
        .accessibilityHint(status.accessibilityHint)
    }
    .accessibilityElement(children: .combine)
  }

  private func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(QuotaPalette.charcoal)

      content()
    }
  }
}

/// Settings Agents row model: signed-in agents are toggleable with no status chrome;
/// everything else shows a short recovery hint and a disabled toggle.
struct AgentStatusPresentation: Equatable {
  /// When true, the visibility toggle is interactive.
  let canToggle: Bool
  /// Optional secondary line. Nil for healthy signed-in agents.
  let detail: String?
  let accessibilityHint: String

  static func resolve(result: QuotaCollectionResult?) -> AgentStatusPresentation {
    guard let result else {
      return AgentStatusPresentation(
        canToggle: false,
        detail: "Refresh to check access.",
        accessibilityHint: "Not checked yet. Refresh quota, then sign in if needed."
      )
    }

    switch result.outcome {
    case .success:
      return AgentStatusPresentation(
        canToggle: true,
        detail: nil,
        accessibilityHint: "Signed in. Toggle to show or hide in Overview."
      )
    case .authRequired:
      return AgentStatusPresentation(
        canToggle: false,
        detail: authHint(for: result.provider, message: result.message),
        accessibilityHint: "Not signed in. Sign in with the provider CLI to enable."
      )
    case .unavailable:
      return AgentStatusPresentation(
        canToggle: false,
        detail: conciseMessage(result.message) ?? "Temporarily unavailable.",
        accessibilityHint: "Provider unavailable."
      )
    case .unsupported:
      return AgentStatusPresentation(
        canToggle: false,
        detail: conciseMessage(result.message) ?? "Not supported here.",
        accessibilityHint: "Provider unsupported."
      )
    case .error:
      return AgentStatusPresentation(
        canToggle: false,
        detail: conciseMessage(result.message) ?? "Could not read quota.",
        accessibilityHint: "Provider error."
      )
    }
  }

  private static func authHint(for provider: ProviderID, message: String?) -> String {
    if let command = loginCommand(in: message) {
      return "Run \(command)"
    }
    switch provider {
    case .codex:
      return "Run `codex login`"
    case .claude:
      return "Run `claude auth login`"
    case .grok:
      return "Run `grok login`"
    }
  }

  private static func loginCommand(in message: String?) -> String? {
    guard let message else { return nil }
    if let match = message.range(of: #"`([^`]+)`"#, options: .regularExpression) {
      let full = String(message[match])
      return String(full.dropFirst().dropLast())
    }
    return nil
  }

  private static func conciseMessage(_ message: String?) -> String? {
    guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    if let command = loginCommand(in: trimmed) {
      return "Run \(command)"
    }
    if trimmed.count <= 96 {
      return trimmed
    }
    if let period = trimmed.firstIndex(of: ".") {
      let sentence = String(trimmed[...period]).trimmingCharacters(in: .whitespacesAndNewlines)
      if sentence.count >= 12, sentence.count <= 96 {
        return sentence
      }
    }
    return String(trimmed.prefix(93)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
