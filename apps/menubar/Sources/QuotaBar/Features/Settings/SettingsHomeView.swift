import AppKit
import SwiftUI

struct SettingsHomeView: View {
  let model: MenuBarViewModel
  let onOpenRemoteDevices: () -> Void
  var deleteAllErrorMessage: String? = nil

  @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
  @State private var launchAtLoginMessage: String?
  /// Bump to re-read UserDefaults-backed visibility toggles.
  @State private var visibilityEpoch = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
        SettingsSection(title: "General") {
          HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Launch at Login")
                .quotaRowTitleStyle()
              if let launchAtLoginMessage {
                Text(launchAtLoginMessage)
                  .quotaMetaStyle()
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            Spacer(minLength: QuotaDesign.Spacing.sm)
            Toggle(
              "Launch at Login",
              isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { desired in
                  launchAtLoginMessage = LaunchAtLoginController.apply(enabled: desired)
                  launchAtLoginEnabled = LaunchAtLoginController.isEnabled
                }
              )
            )
            .labelsHidden()
            .controlSize(.small)
            .frame(
              minWidth: QuotaDesign.Layout.minimumInteractiveDimension,
              minHeight: QuotaDesign.Layout.minimumInteractiveDimension
            )
          }
          .padding(.vertical, QuotaDesign.Spacing.xxs)
          .accessibilityElement(children: .combine)
        }

        Divider()

        SettingsSection(title: "Agents") {
          Text("Choose which agents appear in Overview.")
            .quotaMetaStyle()
            .fixedSize(horizontal: false, vertical: true)

          VStack(alignment: .leading, spacing: 0) {
            ForEach(ProviderID.allCases) { provider in
              providerToggle(provider, isOn: visibilityBinding(for: provider))
            }
          }
          .id(visibilityEpoch)
        }

        ForEach(ProviderID.configurableCases) { provider in
          Divider()
          ApiKeyProviderSettingsSection(
            provider: provider,
            isVisible: visibilityBinding(for: provider)
          )
        }

        Divider()

        SettingsSection(title: "Remote Devices") {
          Button(action: onOpenRemoteDevices) {
            HStack(spacing: QuotaDesign.Spacing.sectionBody) {
              Image(systemName: "laptopcomputer.and.iphone")
                .frame(width: 18)

              VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
                Text("Remote Devices")
                  .quotaRowTitleStyle()
                Text(deviceSummary)
                  .quotaMetaStyle()
                  .lineLimit(2)
              }

              Spacer()

              Image(systemName: "chevron.right")
                .quotaChevronStyle()
            }
            .frame(
              maxWidth: .infinity,
              minHeight: QuotaDesign.Layout.minimumInteractiveDimension,
              alignment: .leading
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remote Devices")
          .accessibilityHint(deviceSummary)
        }

        Divider()

        SettingsSection(title: "About") {
          VStack(alignment: .leading, spacing: 0) {
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
    .onAppear {
      launchAtLoginEnabled = LaunchAtLoginController.isEnabled
      launchAtLoginMessage = LaunchAtLoginController.statusMessage
    }
  }

  private var deviceSummary: String {
    model.relayStateModel.remoteDeviceSummary
  }

  private func visibilityBinding(for provider: ProviderID) -> Binding<Bool> {
    Binding(
      get: { ProviderVisibility.isVisible(provider) },
      set: { newValue in
        ProviderVisibility.setVisible(provider, newValue)
        visibilityEpoch &+= 1
      }
    )
  }

  private func providerToggle(_ provider: ProviderID, isOn: Binding<Bool>) -> some View {
    let status = AgentStatusPresentation.resolve(
      result: model.result(for: provider)
    )

    return HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      ProviderBrandIcon(provider: provider, size: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(provider.displayName)
          .quotaRowTitleStyle()

        if let detail = status.detail {
          Text(detail)
            .quotaMetaStyle()
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: QuotaDesign.Spacing.sm)

      Toggle("Show \(provider.displayName)", isOn: isOn)
        .labelsHidden()
        .controlSize(.small)
        .frame(
          minWidth: QuotaDesign.Layout.minimumInteractiveDimension,
          minHeight: QuotaDesign.Layout.minimumInteractiveDimension
        )
        .accessibilityHint(status.accessibilityHint)
    }
    .padding(.vertical, QuotaDesign.Spacing.xxs)
    .accessibilityElement(children: .combine)
  }

  private func aboutValueRow(title: String, value: String) -> some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      // Labels stay quieter than the section title ("About").
      Text(title)
        .quotaSecondaryStyle()
      Spacer(minLength: QuotaDesign.Spacing.sm)
      Text(value)
        .quotaMonoMetaStyle()
        .textSelection(.enabled)
    }
    .padding(.vertical, aboutRowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title) \(value)")
  }

  private func aboutLinkRow(title: String, url: URL) -> some View {
    Button {
      NSWorkspace.shared.open(url)
    } label: {
      HStack(spacing: QuotaDesign.Spacing.sm) {
        Text(title)
          .quotaSecondaryStyle()
        Spacer(minLength: QuotaDesign.Spacing.sm)
        Image(systemName: "arrow.up.right")
          .quotaAffordanceStyle()
      }
      .padding(.vertical, aboutRowVerticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint("Opens in browser")
  }

  // ponytail: dense text row; keep hit target via contentShape, not minHeight 28
  private var aboutRowVerticalPadding: CGFloat { 3 }
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
