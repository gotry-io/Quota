import AuthenticationServices
import QuotaBrandIcons
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
      accountSection
      Section {
        NavigationLink {
          SettingsNotificationsView(model: model, settings: settings)
        } label: {
          HStack(spacing: 12) {
            SettingsRowIcon(symbol: "bell.badge.fill", tint: .red)
            Text(SettingsCopy.notifications)
          }
        }
        .accessibilityIdentifier("settings.notifications")

        NavigationLink {
          SettingsAppearanceView(settings: settings)
        } label: {
          HStack(spacing: 12) {
            SettingsRowIcon(symbol: "circle.lefthalf.filled", tint: .indigo)
            Text(SettingsCopy.appearance)
            Spacer(minLength: 8)
            Text(settings.appearance.title)
              .foregroundStyle(QuotaTheme.secondary)
          }
        }
        .accessibilityIdentifier("settings.appearance")
      } header: {
        Text(SettingsCopy.preferences)
          .accessibilityIdentifier("section.header.preferences")
      }
      providersSection
      Section {
        Link(destination: QuotaWebLinks.privacy) {
          HStack(spacing: 12) {
            SettingsRowIcon(symbol: "hand.raised.fill", tint: .blue)
            Text(SettingsCopy.privacy)
              .foregroundStyle(Color.primary)
          }
        }
        .buttonStyle(.plain)
        Link(destination: QuotaWebLinks.support) {
          HStack(spacing: 12) {
            SettingsRowIcon(symbol: "questionmark.circle.fill", tint: .green)
            Text(SettingsCopy.support)
              .foregroundStyle(Color.primary)
          }
        }
        .buttonStyle(.plain)
        NavigationLink {
          SettingsAboutView()
        } label: {
          HStack(spacing: 12) {
            SettingsRowIcon(symbol: "info.circle.fill", tint: .gray)
            Text(SettingsCopy.about)
          }
        }
        .accessibilityIdentifier("settings.about")
      } header: {
        Text(SettingsCopy.privacyAndSupport)
          .accessibilityIdentifier("section.header.privacy-and-support")
      }
      signInMethodsSection
      accountActionsSection
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

  /// Identity first on the hub. Destructive account actions stay at the bottom so the
  /// existing scroll-from-About tests still find them, and so Providers is not pushed off
  /// the first screen.
  @ViewBuilder
  private var accountSection: some View {
    Section {
      if model.hasAccountSession {
        NavigationLink {
          SettingsAccountView(model: model)
        } label: {
          identityCard
        }
        NavigationLink {
          DevicesView(model: model)
        } label: {
          HStack(spacing: 12) {
            SettingsRowIcon(symbol: "laptopcomputer", tint: .gray)
            Text(SettingsCopy.devices)
          }
        }
        .accessibilityIdentifier("settings.devices")
      } else {
        Button(SettingsCopy.signIn) {
          model.showSignIn()
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.signin")
      }
    } header: {
      Text(SettingsCopy.account)
        .accessibilityIdentifier("section.header.account")
    } footer: {
      if !model.hasAccountSession {
        Text(SettingsCopy.signInExplanation)
          .accessibilityIdentifier("section.footer.account")
      }
    }
  }

  /// Manage / Delete / Log Out stay on the hub, after About, matching the UI-test scroll.
  @ViewBuilder
  private var accountActionsSection: some View {
    if model.hasAccountSession {
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
      } footer: {
        Text(SettingsCopy.deleteAccountExplanation)
          .accessibilityIdentifier("section.footer.account")
      }
    }
  }

  private var identityCard: some View {
    ViewThatFits(in: .horizontal) {
      identityCardRow
      identityCardStack
    }
  }

  private var identityCardRow: some View {
    HStack(spacing: 12) {
      QuotaIdentityAvatar(label: model.accountLabel)
      identityCardText
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
  }

  private var identityCardStack: some View {
    VStack(alignment: .leading, spacing: 12) {
      QuotaIdentityAvatar(label: model.accountLabel)
      identityCardText
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var identityCardText: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(model.accountLabel)
        .font(.headline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Text(SettingsCopy.identityMethodLine(model.identities.identities))
        .font(QuotaDesign.Typography.support)
        .foregroundStyle(QuotaTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
      SettingsSignInMethodsSection(model: model)
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

  /// Name, account and Remove share one line while they fit whole; otherwise (large type, a long
  /// provider name) they stack, so no word is broken or truncated to keep the line.
  private func connectedRow(_ session: StoredProviderSession) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 12) {
          connectedIdentity(session)
          Spacer(minLength: 8)
          connectedStatus(session)
          removeButton(session)
        }
        VStack(alignment: .leading, spacing: 6) {
          connectedIdentity(session)
          connectedStatus(session)
          removeButton(session)
        }
      }
      if model.providers.needsSignIn(session) {
        HStack {
          Text(ProvidersCopy.refused)
            .font(QuotaDesign.Typography.support)
            .foregroundStyle(QuotaTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button(ProvidersCopy.signInAgain) {
            loginProvider = session.provider
          }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("providers.signin-again.\(session.key)")
        }
      }
    }
  }

  private func connectedIdentity(_ session: StoredProviderSession) -> some View {
    HStack(alignment: .center, spacing: 12) {
      ProviderMark(provider: session.provider, size: QuotaDesign.Layout.markSize)
        .foregroundStyle(.primary)
      Text(session.provider.displayName)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(connectedAccessibilityLabel(session))
        .accessibilityIdentifier("providers.session.\(session.key)")
    }
  }

  private func removeButton(_ session: StoredProviderSession) -> some View {
    Button(ProvidersCopy.remove) {
      removing = session
    }
    .buttonStyle(.borderless)
    .accessibilityIdentifier("providers.remove.\(session.key)")
  }

  private func connectedAccessibilityLabel(_ session: StoredProviderSession) -> String {
    let connected = ProvidersCopy.connectedAs(label: session.accountLabel)
    if model.providers.needsSignIn(session) {
      return "\(session.provider.displayName), \(connected), \(ProvidersCopy.refused)"
    }
    return
      "\(session.provider.displayName), \(connected), "
      + ProvidersCopy.checked(at: session.lastValidatedAt, now: Date())
  }

  private func connectedStatus(_ session: StoredProviderSession) -> some View {
    HStack(spacing: 6) {
      if let label = session.accountLabel, !label.isEmpty {
        Text(label)
          .font(QuotaDesign.Typography.support)
          .foregroundStyle(QuotaTheme.secondary)
          .lineLimit(1)
      }
      Circle()
        .fill(QuotaTheme.emerald)
        .frame(width: QuotaTheme.statusDotSize, height: QuotaTheme.statusDotSize)
        .accessibilityHidden(true)
    }
    .accessibilityHidden(true)
  }

  private func connectRow(provider: ProviderID, isFirst: Bool) -> some View {
    Button {
      if model.providers.needsConsent(for: provider) {
        consentProvider = provider
      } else {
        loginProvider = provider
      }
    } label: {
      let action = isFirst ? ProvidersCopy.connect : ProvidersCopy.addAccount
      HStack(spacing: 12) {
        ProviderMark(provider: provider, size: QuotaDesign.Layout.markSize)
          .foregroundStyle(.primary)
        // The name and the action share a line only while both fit whole; a long name at a
        // large type size stacks the action under it instead of truncating the name.
        ViewThatFits(in: .horizontal) {
          LabeledContent(provider.displayName, value: action)
          VStack(alignment: .leading, spacing: 2) {
            Text(provider.displayName)
              .fixedSize(horizontal: false, vertical: true)
            Text(action)
              .foregroundStyle(QuotaTheme.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
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

/// Sign-in methods as a Form destination from the identity card, and as a hub section.
struct SettingsAccountView: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      SettingsSignInMethodsSection(model: model)
    }
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .navigationTitle(model.accountLabel)
  }
}

struct SettingsSignInMethodsSection: View {
  @Bindable var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
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
      .foregroundStyle(Color.primary)
      .buttonStyle(.plain)
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

  private var signInMethodsFooter: String {
    if let failure = model.linkFailure { return failure }
    if model.identities == .failed { return SettingsCopy.signInMethodsUnreadable }
    return SettingsCopy.signInMethodsFooter
  }

  @ViewBuilder
  private func signInMethodRow(_ provider: IdentityProvider) -> some View {
    let bound = model.identities.identities.first { $0.provider == provider }
    HStack {
      // Both lines take the opaque label colour rather than the hierarchical `.primary` a
      // Providers row uses: inside a grouped-Form row, `.primary` resolves against the level the
      // row's content configuration already set, and the contrast auditor reads what that
      // resolves to rather than the label colour.
      VStack(alignment: .leading, spacing: 3) {
        Text(provider.displayName)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Color(uiColor: .label))
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
}
