import SwiftUI

/// Support is where help lives: Feedback, the build, and Diagnostics as a disclosure.
/// It asks the service nothing on its own — opening it costs no refresh — so the
/// diagnostic report runs only when Diagnostics is expanded.
struct SettingsSupportView: View {
  @Bindable var model: MenuBarViewModel
  var diagnostics: DiagnosticsPageModel
  var expandsDiagnostics: Bool = false

  @State private var diagnosticsExpanded = false
  @State private var didRequestDiagnostics = false

  var body: some View {
    Form {
      SwiftUI.Section {
        Link("Feedback", destination: AppMetadata.feedbackURL)
      } header: {
        Text("Help")
      }

      SwiftUI.Section {
        Link("Website", destination: AppMetadata.websiteURL)
        LabeledContent("Version") {
          Text(AppMetadata.versionLabel)
            .textSelection(.enabled)
        }
        .accessibilityLabel("Version \(AppMetadata.versionLabel)")
        Button("Updates", action: QuotaBarUpdater.checkForUpdates)
          .accessibilityLabel("Updates")
          .accessibilityHint("Checks for a new QuotaBar version")
      } header: {
        Text("About")
      }

      Section {
        DisclosureGroup(isExpanded: $diagnosticsExpanded) {
          SettingsDiagnosticsView(
            state: diagnostics.pageState,
            model: diagnostics,
            widgetPublishingMessage: model.widgetPublishingMessage,
            onRetry: { Task { await runDiagnosticsCheck() } },
            onRecheck: { Task { await runDiagnosticsCheck() } }
          )
        } label: {
          Text("Diagnostics")
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear {
      if expandsDiagnostics {
        diagnosticsExpanded = true
        didRequestDiagnostics = true
      }
    }
    .onChange(of: diagnosticsExpanded) { _, expanded in
      guard expanded, !didRequestDiagnostics else { return }
      didRequestDiagnostics = true
      Task { await runDiagnosticsCheck() }
    }
  }

  private func runDiagnosticsCheck() async {
    await diagnostics.runCheck { try await model.diagnose() }
  }
}

@MainActor
func settingsToggleRow(
  title: String,
  systemImage: String,
  isOn: Binding<Bool>,
  accessibilityLabel: String,
  accessibilityHint: String
) -> some View {
  SettingsListRow(title: title, systemImage: systemImage) {
    Toggle(accessibilityLabel, isOn: isOn)
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.mini)
      .tint(QuotaPalette.accent)
  }
  .accessibilityElement(children: .combine)
  .accessibilityLabel(accessibilityLabel)
  .accessibilityHint(accessibilityHint)
}

/// A row that opens a page one level deeper, stating the choice in force on the right when the
/// page is about one.
@MainActor
func settingsDestinationRow(
  title: String,
  systemImage: String,
  trailing: String = "",
  accessibilityLabel: String,
  action: @escaping () -> Void
) -> some View {
  Button(action: action) {
    SettingsListRow(title: title, systemImage: systemImage) {
      HStack(spacing: QuotaDesign.Spacing.xxs) {
        if !trailing.isEmpty {
          Text(trailing)
            .quotaListSecondaryStyle()
            .lineLimit(1)
        }
        Image(systemName: "chevron.right")
          .quotaChevronStyle()
      }
    }
  }
  .buttonStyle(QuotaListRowButtonStyle())
  .accessibilityLabel(accessibilityLabel)
  .accessibilityHint(trailing)
}
