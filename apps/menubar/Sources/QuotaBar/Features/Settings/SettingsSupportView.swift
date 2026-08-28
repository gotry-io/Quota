import SwiftUI

/// The confirmation Reset Local Data raises. It is an app-owned popup at the panel root, like
/// Sign Out and Disconnect: the menu panel is not a window a system alert can sit over.
enum ResetLocalDataCopy {
  static let title = "Reset Local Data?"
  static let confirmTitle = "Reset Local Data"
  static let message =
    "This Mac's collected quota and Usage history are deleted and rebuilt on the next refresh. "
    + "You stay signed in."
}

/// Support is where help lives: the Diagnostics page, feedback, the local-data reset, and the
/// build. It asks the service nothing on its own — opening it costs no refresh — so the
/// diagnostic report is one step further in, on the page that is about it.
struct SettingsSupportView: View {
  let onOpenDiagnostics: () -> Void
  let onRequestResetLocalData: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        helpView
        aboutView
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private var helpView: some View {
    SettingsSection(title: "Help") {
      VStack(alignment: .leading, spacing: 0) {
        settingsDestinationRow(
          title: "Diagnostics",
          systemImage: "stethoscope",
          accessibilityLabel: "Diagnostics",
          action: onOpenDiagnostics
        )

        settingsExternalLinkRow(
          title: "Feedback",
          systemImage: "envelope",
          url: AppMetadata.feedbackURL
        )

        Button(action: onRequestResetLocalData) {
          SettingsListRow(title: "Reset Local Data", systemImage: "trash") {
            EmptyView()
          }
        }
        .buttonStyle(QuotaListRowButtonStyle())
        .accessibilityLabel("Reset local data")
        .accessibilityHint("Deletes collected quota and Usage history on this Mac and refreshes.")
      }
    }
  }

  private var aboutView: some View {
    SettingsSection(title: "About") {
      VStack(alignment: .leading, spacing: 0) {
        settingsExternalLinkRow(
          title: "Website",
          systemImage: "globe",
          url: AppMetadata.websiteURL
        )
        SettingsListRow(title: "Version", systemImage: "info.circle") {
          Text(AppMetadata.versionLabel)
            .quotaMonoListValueStyle()
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Version \(AppMetadata.versionLabel)")

        // One word, like the rows beside it; the spoken label keeps the whole action.
        Button(action: QuotaBarUpdater.checkForUpdates) {
          SettingsListRow(title: "Updates", systemImage: "arrow.triangle.2.circlepath") {
            EmptyView()
          }
        }
        .buttonStyle(QuotaListRowButtonStyle())
        .accessibilityLabel("Updates")
        .accessibilityHint("Checks for a new QuotaBar version")
      }
    }
  }
}

@MainActor
func settingsExternalLinkRow(title: String, systemImage: String, url: URL) -> some View {
  Link(destination: url) {
    SettingsListRow(title: title, systemImage: systemImage) {
      Image(systemName: "arrow.up.right")
        .quotaAffordanceStyle()
    }
  }
  .buttonStyle(QuotaListRowButtonStyle())
  .accessibilityLabel(title)
  .accessibilityHint("Opens in browser")
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
