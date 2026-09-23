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
        if let sentence = MenuBarPresenceCopy.sentence(onScreen: model.menuBarItemOnScreen) {
          LabeledContent("Menu bar") {
            Text(sentence)
              .multilineTextAlignment(.trailing)
          }
          .accessibilityLabel("Menu bar. \(sentence)")
        }
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
    .quotaSettingsColumn()
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

/// What Support says about the status item. The app knows only whether AppKit put the item's
/// window on screen; the two reasons it would not are the person's to check.
enum MenuBarPresenceCopy {
  static func sentence(onScreen: Bool?) -> String? {
    switch onScreen {
    case nil: nil
    case true?: "Shown."
    case false?:
      "Not shown. Allow QuotaBar in System Settings › Menu Bar, or make room on the bar."
    }
  }
}
