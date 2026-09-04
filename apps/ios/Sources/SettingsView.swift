import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var settings = SettingsModel()
  @State private var confirmLogout = false
  @State private var promptSignOutAfterDelete = false

  var body: some View {
    Form {
      Section(SettingsCopy.preferences) {
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
      }

      Section(SettingsCopy.privacyAndSupport) {
        Link(SettingsCopy.privacy, destination: QuotaWebLinks.privacy)
        Link(SettingsCopy.support, destination: QuotaWebLinks.support)
        NavigationLink {
          SettingsAboutView()
        } label: {
          Text(SettingsCopy.about)
        }
        .accessibilityIdentifier("settings.about")
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
        Button(SettingsCopy.logOut, role: .destructive) {
          confirmLogout = true
        }
        .accessibilityLabel(SettingsCopy.logOut)
        .accessibilityIdentifier("settings.logout")
      } header: {
        Text(SettingsCopy.account)
      } footer: {
        Text(SettingsCopy.deleteAccountExplanation)
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
}
