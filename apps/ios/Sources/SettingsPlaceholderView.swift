import SwiftUI

struct SettingsPlaceholderView: View {
  @Bindable var model: AppModel
  @State private var confirmLogout = false

  var body: some View {
    List {
      Section {
        placeholderRow("Notifications", systemImage: "bell")
        placeholderRow("Appearance", systemImage: "circle.lefthalf.filled")
        placeholderRow("About", systemImage: "info.circle")
      }
      Section {
        Button("Log Out", role: .destructive) {
          confirmLogout = true
        }
        .frame(minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
        .accessibilityLabel("Log Out")
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
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
  }

  private func placeholderRow(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .frame(minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
      .allowsHitTesting(false)
      .accessibilityAddTraits(.isStaticText)
  }
}
