import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var settings = SettingsModel()
  @State private var confirmLogout = false
  @State private var promptSignOutAfterDelete = false

  var body: some View {
    Form {
      syncSection
      Section {
        NavigationLink {
          SettingsNotificationsView(model: model, settings: settings)
        } label: {
          Text(SettingsCopy.notifications)
        }
        .accessibilityIdentifier("settings.notifications")

        NavigationLink {
          SettingsAppearanceView(settings: settings)
        } label: {
          LabeledContent(SettingsCopy.appearance, value: settings.appearance.title)
        }
        .accessibilityIdentifier("settings.appearance")
      } header: {
        Text(SettingsCopy.preferences)
          .accessibilityIdentifier("section.header.preferences")
      }
      Section {
        Link(destination: QuotaWebLinks.privacy) {
          Text(SettingsCopy.privacy)
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        Link(destination: QuotaWebLinks.support) {
          Text(SettingsCopy.support)
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        NavigationLink {
          SettingsAboutView()
        } label: {
          Text(SettingsCopy.about)
        }
        .accessibilityIdentifier("settings.about")
      } header: {
        Text(SettingsCopy.privacyAndSupport)
          .accessibilityIdentifier("section.header.privacy-and-support")
      }
      Section {
        Link(SettingsCopy.manageDevices, destination: QuotaWebLinks.manageDevices)
        Button(SettingsCopy.deleteAccount, role: .destructive) {
          Task {
            await model.presentDeleteAccount()
            promptSignOutAfterDelete = true
          }
        }
        .accessibilityLabel(SettingsCopy.deleteAccount)
        .accessibilityIdentifier("settings.delete-account")
        Button(SettingsCopy.logOut, role: .destructive) {
          confirmLogout = true
        }
        .accessibilityLabel(SettingsCopy.logOut)
        .accessibilityIdentifier("settings.logout")
      } header: {
        Text(SettingsCopy.account)
          .accessibilityIdentifier("section.header.account")
      } footer: {
        Text(SettingsCopy.deleteAccountExplanation)
          .accessibilityIdentifier("section.footer.account")
      }
    }
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("settings.root")
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.large)
    .confirmationDialog(
      "Log out of Quota on this device?",
      isPresented: $confirmLogout,
      titleVisibility: .visible
    ) {
      Button("Log Out", role: .destructive) {
        Task { await model.logout() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The remote Account stays signed in on the website. This device forgets the session and saved overview."
      )
    }
    .alert(SettingsCopy.deleteAccountFollowUp, isPresented: $promptSignOutAfterDelete) {
      Button("OK", role: .cancel) {}
    }
  }

  /// Sync is one row: the paywall when the Account has not bought it, the state Relay reports
  /// plus the system's own management when it has.
  @ViewBuilder
  private var syncSection: some View {
    Section {
      if let status = SyncCopy.status(model.entitlement) {
        LabeledContent(SyncCopy.section, value: status)
          .accessibilityIdentifier("settings.sync.status")
        Link(SyncCopy.manage, destination: QuotaWebLinks.appleSubscriptions)
          .accessibilityIdentifier("settings.sync.manage")
      } else {
        NavigationLink {
          PaywallView(model: model)
        } label: {
          Text(SyncCopy.subscribeRow)
        }
        .accessibilityIdentifier("settings.sync.subscribe")
      }
    } header: {
      Text(SyncCopy.section)
        .accessibilityIdentifier("section.header.sync")
    } footer: {
      Text(SyncCopy.sectionFooter)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("section.footer.sync")
    }
  }
}
