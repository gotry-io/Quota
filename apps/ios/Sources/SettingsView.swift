import AuthenticationServices
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
  @Environment(\.colorScheme) private var colorScheme

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
      signInMethodsSection
      accountSection
    }
    .task { await model.loadIdentities() }
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
        "The remote Account stays signed in on the website. This device forgets the session and "
          + "saved overview."
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
        Task { await model.providerSessionsChanged() }
      }
      Button(ProvidersCopy.cancel, role: .cancel) {}
    } message: { session in
      Text(ProvidersCopy.removeMessage(provider: session.provider))
    }
    .sheet(item: $loginProvider) { provider in
      ProviderLoginView(provider: provider, store: model.providers.sessionStore) { session in
        model.providers.keep(session)
        Task { await model.providerSessionsChanged() }
      }
    }
  }

  /// The managed Account, when there is one. A phone that only reads its own providers has no
  /// devices to manage and nothing to delete, so the group is the one invitation instead.
  @ViewBuilder
  private var accountSection: some View {
    Section {
      if model.hasAccountSession {
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
      } else {
        Button(SettingsCopy.signIn) {
          model.showSignIn()
        }
        .accessibilityIdentifier("settings.signin")
      }
    } header: {
      Text(SettingsCopy.account)
        .accessibilityIdentifier("section.header.account")
    } footer: {
      Text(
        model.hasAccountSession
          ? SettingsCopy.deleteAccountExplanation
          : SettingsCopy.signInExplanation
      )
      .accessibilityIdentifier("section.footer.account")
    }
  }

  /// How this Account is signed in to. An Account owns its identities rather than being one
  /// ([ADR 0032](../../../docs/decisions/0032-an-account-owns-its-identities.md)), so this is a
  /// group of channels rather than one account name.
  ///
  /// Apple is bound on the device, the way it is signed in with. The browser channels and every
  /// unbind are the website's: binding writes to an Account, and unbinding is a destructive
  /// change the website asks for a recent sign-in before allowing.
  @ViewBuilder
  private var signInMethodsSection: some View {
    if model.hasAccountSession {
      Section {
        // Only a read that answered says which channels are bound. Until one has, the group is
        // the way to the website and nothing else: rows would otherwise say Not linked about
        // channels this app has not asked about yet.
        if case .loaded = model.identities {
          ForEach(IdentityProvider.offered, id: \.self) { provider in
            signInMethodRow(provider)
          }
        }
        Button(SettingsCopy.manageSignInMethods) {
          Task { await model.presentSignInMethodsOnWeb() }
        }
        .accessibilityIdentifier("settings.sign-in-methods.manage")
      } header: {
        Text(SettingsCopy.signInMethods)
          .accessibilityIdentifier("section.header.sign-in-methods")
      } footer: {
        Text(signInMethodsFooter)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("section.footer.sign-in-methods")
      }
    }
  }

  private var signInMethodsFooter: String {
    if let failure = model.linkFailure { return failure }
    if model.identities == .failed { return SettingsCopy.signInMethodsUnreadable }
    return SettingsCopy.signInMethodsFooter
  }

  @ViewBuilder
  private func signInMethodRow(_ provider: IdentityProvider) -> some View {
    let bound = model.identities.identities.first { $0.provider == provider }
    HStack {
      // The state line is the opaque label colour rather than the hierarchical `.primary` a
      // Providers row uses: as the second Text of a grouped-Form row, `.primary` resolves
      // against the level the row's content configuration already set, and the contrast auditor
      // reads what that resolves to rather than the label colour.
      VStack(alignment: .leading, spacing: 3) {
        Text(provider.displayName)
          .font(.subheadline.weight(.medium))
        Text(signInMethodState(provider, bound: bound))
          .font(.footnote)
          .foregroundStyle(Color(uiColor: .label))
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityIdentifier("settings.sign-in-methods.\(provider.rawValue)")
      Spacer(minLength: 12)
      if bound == nil, model.linkingProvider != provider {
        if provider == .apple {
          // Apple's own control asks on the device; there is no browser trip to bind it.
          SignInWithAppleButton(.continue) { request in
            model.prepareAppleRequest(request)
          } onCompletion: { result in
            Task { await model.linkApple(result) }
          }
          .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
          .frame(width: 132, height: 36)
          .clipShape(Capsule())
          .accessibilityIdentifier("settings.sign-in-methods.link.apple")
        } else {
          Button(SettingsCopy.linkOnWeb) {
            Task { await model.presentSignInMethodsOnWeb() }
          }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("settings.sign-in-methods.link.\(provider.rawValue)")
        }
      }
    }
  }

  private func signInMethodState(_ provider: IdentityProvider, bound: AccountIdentity?) -> String {
    if let bound { return SettingsCopy.linkedLabel(bound.label) }
    if model.linkingProvider == provider { return SettingsCopy.linking }
    return SettingsCopy.notLinked
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
        Text(
          model.providers.needsSignIn(session)
            ? ProvidersCopy.refused
            : ProvidersCopy.checked(at: session.lastValidatedAt, now: Date())
        )
        .font(.footnote)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityIdentifier("providers.session.\(session.key)")
      Spacer(minLength: 12)
      // The row's control is a standard button, not a red one: the system red on a Form row does
      // not clear the contrast bar this app holds itself to. What is destructive about it is said
      // by the confirmation it opens, whose Remove is the destructive one.
      if model.providers.needsSignIn(session) {
        Button(ProvidersCopy.signInAgain) {
          loginProvider = session.provider
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("providers.signin-again.\(session.key)")
      }
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
