import AppKit
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
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
        settingsSection("Agents") {
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sectionBody) {
            providerToggle(.codex, isOn: $showsCodex)
            providerToggle(.claude, isOn: $showsClaude)
            providerToggle(.grok, isOn: $showsGrok)
          }

          Text("Turn on signed-in agents to show them in Overview.")
            .quotaMetaStyle()
            .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        settingsSection("Remote Quota") {
          Button(action: onOpenRelays) {
            HStack(spacing: QuotaDesign.Spacing.sectionBody) {
              Image(systemName: "network")
                .frame(width: 18)

              VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
                Text("Relays")
                  .quotaRowTitleStyle()
                Text(relaySummary)
                  .quotaMetaStyle()
                  .lineLimit(2)
              }

              Spacer()

              Image(systemName: "chevron.right")
                .quotaChevronStyle()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Manage Relays")
          .accessibilityHint(relaySummary)
        }

        Divider()

        settingsSection("About") {
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sectionBody) {
            aboutValueRow(title: "Version", value: AppMetadata.versionLabel)

            aboutLinkRow(title: "Website", url: AppMetadata.websiteURL)
            aboutLinkRow(title: "Feedback", url: AppMetadata.feedbackURL)
          }

          if let deleteAllErrorMessage {
            Label(deleteAllErrorMessage, systemImage: "exclamationmark.circle")
              .quotaSecondaryStyle()
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
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

    return HStack(alignment: .center, spacing: QuotaDesign.Spacing.sectionBody) {
      ProviderBrandIcon(provider: provider, size: 16)

      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        Text(provider.displayName)
          .quotaRowTitleStyle()

        if let detail = status.detail {
          Text(detail)
            .quotaMetaStyle()
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: QuotaDesign.Spacing.sm)

      // Visibility is user preference only — auth/unavailable still show in Overview
      // when enabled, so the toggle stays interactive for every agent.
      Toggle("Show \(provider.displayName)", isOn: isOn)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityHint(status.accessibilityHint)
    }
    .accessibilityElement(children: .combine)
  }

  private func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.cardBody) {
      Text(title)
        .quotaSectionHeaderStyle()

      content()
    }
  }

  private func aboutValueRow(title: String, value: String) -> some View {
    HStack(spacing: QuotaDesign.Spacing.sectionBody) {
      // Labels stay quieter than the section title ("About").
      Text(title)
        .quotaSecondaryStyle()
      Spacer(minLength: QuotaDesign.Spacing.sm)
      Text(value)
        .quotaMonoMetaStyle()
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title) \(value)")
  }

  private func aboutLinkRow(title: String, url: URL) -> some View {
    Button {
      NSWorkspace.shared.open(url)
    } label: {
      HStack(spacing: QuotaDesign.Spacing.sectionBody) {
        Text(title)
          .quotaSecondaryStyle()
        Spacer(minLength: QuotaDesign.Spacing.sm)
        Image(systemName: "arrow.up.right")
          .quotaAffordanceStyle()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint("Opens in browser")
  }
}

/// Settings Agents row model: visibility toggle is always interactive; non-success
/// collection outcomes only add a short recovery/status detail.
struct AgentStatusPresentation: Equatable {
  /// Optional secondary line. Nil for healthy signed-in agents.
  let detail: String?
  let accessibilityHint: String

  static func resolve(result: QuotaCollectionResult?) -> AgentStatusPresentation {
    guard let result else {
      return AgentStatusPresentation(
        detail: "Refresh to check access.",
        accessibilityHint: "Not checked yet. Toggle visibility anytime; refresh to update status."
      )
    }

    switch result.outcome {
    case .success:
      return AgentStatusPresentation(
        detail: nil,
        accessibilityHint: "Toggle to show or hide in Overview."
      )
    case .authRequired, .unavailable, .unsupported, .error:
      guard let status = ProviderStatusCopy.from(result: result) else {
        return AgentStatusPresentation(
          detail: "Unavailable",
          accessibilityHint: "Provider unavailable. Toggle to show or hide in Overview."
        )
      }
      return AgentStatusPresentation(
        detail: status.detail ?? status.title,
        accessibilityHint: "\(status.accessibilityLabel) Toggle to show or hide in Overview."
      )
    }
  }
}
