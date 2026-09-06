import QuotaProviderSessions
import QuotaWire
import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var settings = SettingsModel()
  @State private var confirmLogout = false
  @State private var promptSignOutAfterDelete = false
  @State private var consentProvider: ProviderID?
  @State private var loginProvider: ProviderID?
  @State private var removing: StoredProviderSession?

  var body: some View {
    Form {
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
      providersSection
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
    .alert(
      consentProvider.map(ProvidersCopy.consentTitle(provider:)) ?? "",
      isPresented: consentAlertBinding,
      presenting: consentProvider
    ) { provider in
      Button(ProvidersCopy.consentConfirm) {
        model.providers.recordConsent(for: provider)
        loginProvider = provider
      }
      Button(ProvidersCopy.cancel, role: .cancel) {}
    } message: { provider in
      if let spec = provider.browserSession {
        Text(ProvidersCopy.consentMessage(provider: provider, spec: spec))
      }
    }
    .confirmationDialog(
      removing.map { ProvidersCopy.removeTitle(provider: $0.provider) } ?? "",
      isPresented: removeDialogBinding,
      titleVisibility: .visible,
      presenting: removing
    ) { session in
      Button(ProvidersCopy.remove, role: .destructive) {
        model.providers.remove(session)
      }
      Button(ProvidersCopy.cancel, role: .cancel) {}
    } message: { session in
      Text(ProvidersCopy.removeMessage(provider: session.provider))
    }
    .sheet(item: $loginProvider) { provider in
      ProviderLoginView(provider: provider, store: model.providers.sessionStore) { session in
        model.providers.keep(session)
      }
    }
  }

  /// One row per connected account, then the row that adds another. A provider this phone holds
  /// no session for shows only the second.
  private var providersSection: some View {
    Section {
      ForEach(model.providers.rows) { row in
        switch row.kind {
        case .connected(let session):
          connectedRow(session)
        case .connect(let isFirst):
          connectRow(provider: row.provider, isFirst: isFirst)
        }
      }
    } header: {
      Text(ProvidersCopy.section)
        .accessibilityIdentifier("section.header.providers")
    } footer: {
      Text(model.providers.isUnreadable ? ProvidersCopy.unreadable : ProvidersCopy.sectionFooter)
        .accessibilityIdentifier("section.footer.providers")
    }
  }

  private func connectedRow(_ session: StoredProviderSession) -> some View {
    HStack {
      // Footnote-size rows carry `.primary`, the way a Devices row does: `.secondary` at this
      // size does not clear the contrast bar this app's accessibility audit holds it to.
      VStack(alignment: .leading, spacing: 3) {
        Text(session.provider.displayName)
          .font(.subheadline.weight(.medium))
        Text(ProvidersCopy.connectedAs(label: session.accountLabel))
          .font(.footnote)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        Text(ProvidersCopy.checked(at: session.lastValidatedAt, now: Date()))
          .font(.footnote)
          .foregroundStyle(.primary)
      }
      .accessibilityIdentifier("providers.session.\(session.key)")
      Spacer(minLength: 12)
      // The row's control is a standard button, not a red one: the system red on a Form row does
      // not clear the contrast bar this app holds itself to. What is destructive about it is said
      // by the confirmation it opens, whose Remove is the destructive one.
      Button(ProvidersCopy.remove) {
        removing = session
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("providers.remove.\(session.key)")
    }
  }

  private func connectRow(provider: ProviderID, isFirst: Bool) -> some View {
    Button {
      if model.providers.needsConsent(for: provider) {
        consentProvider = provider
      } else {
        loginProvider = provider
      }
    } label: {
      LabeledContent(
        provider.displayName,
        value: isFirst ? ProvidersCopy.connect : ProvidersCopy.addAccount
      )
    }
    .accessibilityIdentifier("providers.connect.\(provider.rawValue)")
  }

  private var consentAlertBinding: Binding<Bool> {
    Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } })
  }

  private var removeDialogBinding: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }
}
