import QuotaWire
import SwiftUI

struct MenuBarContentView: View {
  @Bindable var model: MenuBarViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var navigation: MenuBarNavigationState
  @State private var navigationDirection: NavigationDirection = .forward
  @State private var navigationTransitionActive = false
  @State private var navigationTransitionGeneration = 0
  @State private var isLogoutConfirmationPresented = false
  @State private var usageSource: UsageSource = .account
  @State private var usagePeriod: UsagePeriod = .today
  @State private var support = SupportPageModel()
  private let performsInitialRefresh: Bool
  private let performsSupportCheckOnEntry: Bool
  private let seedsLaunchAtLogin: Bool

  init(
    model: MenuBarViewModel,
    initialPath: [MenuBarRoute] = [],
    performsInitialRefresh: Bool = true,
    performsSupportCheckOnEntry: Bool = true,
    supportModel: SupportPageModel? = nil,
    seedsLaunchAtLogin: Bool = true
  ) {
    self.model = model
    self.performsInitialRefresh = performsInitialRefresh
    self.performsSupportCheckOnEntry = performsSupportCheckOnEntry
    self.seedsLaunchAtLogin = seedsLaunchAtLogin
    _navigation = State(initialValue: MenuBarNavigationState(path: initialPath))
    _support = State(initialValue: supportModel ?? SupportPageModel())
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      MenuBarShell(
        model: model,
        title: navigation.title,
        usageSource: usageSource,
        now: context.date,
        canNavigateBack: navigation.canNavigateBack,
        onNavigateBack: navigateBack,
        showsLeadingIcon: navigation.currentRoute == nil,
        trailing: headerTrailingAction
      ) {
        currentPage(now: context.date)
          .id(navigation.pageIdentity)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .transition(pageTransition)
      }
    }
    .environment(\.quotaPageTransitionActive, navigationTransitionActive)
    // The Account page belongs to a signed-in account. Signing out closes it rather than
    // leaving a page with nothing left to manage on screen.
    .onChange(of: model.accountState) { _, state in
      guard state != .signedIn, let next = navigation.closing(.account) else { return }
      navigationDirection = .back
      applyNavigation(next)
    }
    .task {
      if seedsLaunchAtLogin {
        LaunchAtLoginController.seedDefaultOnIfNeeded()
      }
      guard performsInitialRefresh else { return }
      await model.refreshIfNeeded()
    }
    .focusEffectDisabled()
    .disabled(isLogoutConfirmationPresented || model.browserSessionPopup != nil)
    .accessibilityHidden(isLogoutConfirmationPresented || model.browserSessionPopup != nil)
    .overlay {
      if isLogoutConfirmationPresented {
        QuotaConfirmationPopup(
          title: "Sign Out?",
          message:
            "This signs QuotaBar out on this Mac. Your device and synced data stay in your Quota account.",
          confirmTitle: "Sign Out",
          onCancel: { isLogoutConfirmationPresented = false }
        ) {
          isLogoutConfirmationPresented = false
          Task { await model.logout() }
        }
      } else if let popup = model.browserSessionPopup {
        providerBrowserSessionPopup(popup)
      }
    }
  }

  @ViewBuilder
  private func providerBrowserSessionPopup(_ popup: ProviderBrowserSessionPopup) -> some View {
    switch popup {
    case .browser(let provider, let choices):
      QuotaSelectionPopup(
        title: "Choose Browser",
        message: "Choose the browser you are signed in to \(provider.displayName) with. QuotaBar asks before it reads anything.",
        choices: choices.map {
          QuotaSelectionChoice(id: $0.id, title: $0.title, subtitle: nil)
        },
        onCancel: model.cancelProviderBrowserSessionFlow,
        onSelect: { model.selectBrowserApplication($0, provider: provider) }
      )
    case .consent(let provider, let choice):
      if let spec = provider.browserSession {
        QuotaConfirmationPopup(
          title: BrowserSessionCopy.consentTitle(provider: provider),
          message: BrowserSessionCopy.consentMessage(
            provider: provider, browserName: choice.title, spec: spec),
          confirmTitle: BrowserSessionCopy.consentConfirmTitle,
          onCancel: model.cancelProviderBrowserSessionFlow,
          onConfirm: model.confirmProviderBrowserSessionConsent
        )
      }
    case .account(let provider, let choices):
      QuotaSelectionPopup(
        title: "Choose \(provider.displayName) Account",
        message: "Choose the browser account to connect on this Mac.",
        choices: choices.map {
          QuotaSelectionChoice(id: $0.id, title: $0.title, subtitle: $0.subtitle)
        },
        onCancel: model.cancelProviderBrowserSessionFlow,
        onSelect: model.selectBrowserSessionAccount
      )
    case .confirmDisconnect(let provider):
      QuotaConfirmationPopup(
        title: "Disconnect \(provider.displayName)?",
        message: "Remove this browser session from QuotaBar on this Mac.",
        confirmTitle: "Disconnect",
        onCancel: model.cancelProviderBrowserSessionFlow,
        onConfirm: model.confirmProviderBrowserSessionDisconnect
      )
    }
  }

  private var panelAnimation: Animation? {
    reduceMotion ? nil : .snappy(duration: QuotaDesign.Motion.pageTransitionDuration)
  }

  private var pageTransition: AnyTransition {
    if reduceMotion { return .opacity }
    return switch navigationDirection {
    case .forward:
      .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      )
    case .back:
      .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
      )
    }
  }

  private var headerTrailingAction: MenuBarHeader.TrailingAction {
    guard !navigationTransitionActive else { return .none }
    if navigation.showsSettingsMenu { return .overflowMenu }
    if navigation.currentRoute == .usage,
      model.usageUploadEnabled,
      model.accountSummary != nil
    {
      return .usageSource(usageSource) { usageSource = $0 }
    }
    if navigation.currentRoute == .support, support.showsHeaderActions {
      return .support(
        isChecking: support.isLoading,
        canRecheck: support.canRecheck,
        onRecheck: { Task { await runSupportCheck() } }
      )
    }
    if !navigation.canNavigateBack { return .openSettings(openSettings) }
    return .none
  }

  @ViewBuilder
  private func currentPage(now: Date) -> some View {
    switch navigation.currentRoute {
    case nil:
      QuotaOverviewView(
        model: model,
        enabledProviders: ProviderDisplayOrder.enabledProviders(),
        now: now,
        onOpenSettings: openSettings
      )
    case .settings:
      SettingsHomeView(
        model: model,
        onOpenAccount: { navigate(to: .account) },
        onOpenAgents: { navigate(to: .agents) },
        onOpenUsage: { navigate(to: .usage) },
        onOpenMenuBarStyle: { navigate(to: .menuBarStyle) },
        onOpenMenuBarProvider: { navigate(to: .menuBarProvider) },
        onOpenSupport: { navigate(to: .support) }
      )
    case .account:
      AccountSettingsView(
        model: model,
        onOpenDevices: { navigate(to: .devices) },
        onRequestSignOut: { isLogoutConfirmationPresented = true }
      )
    case .agents:
      AgentsSettingsView(
        accountReportedProviders: model.accountReportingProviders(),
        onOpenProvider: { provider in navigate(to: .provider(provider)) }
      )
    case .provider(let provider):
      ProviderSettingsView(
        model: model,
        provider: provider,
        reportingSources: model.reportingSources(for: provider, now: now),
        now: now
      )
    case .devices:
      AccountDevicesView(model: model)
    case .usage:
      AccountUsageView(model: model, source: $usageSource, period: $usagePeriod)
    case .menuBarStyle:
      MenuBarStyleSettingsView(onSelect: navigateBack)
    case .menuBarProvider:
      MenuBarProviderSettingsView(
        providers: ProviderDisplayOrder.enabledProviders(),
        onSelect: navigateBack
      )
    case .support:
      SettingsSupportView(
        state: support.pageState,
        model: support,
        onRetry: { Task { await runSupportCheck() } },
        onResetLocalData: { Task { await resetLocalData() } }
      )
      .task {
        guard performsSupportCheckOnEntry else { return }
        await runSupportCheck()
      }
    }
  }

  private func openSettings() {
    navigate(to: .settings)
  }

  private func runSupportCheck() async {
    await support.runCheck { try await model.diagnose() }
  }

  private func resetLocalData() async {
    await model.resetLocalData()
    await runSupportCheck()
  }

  private func navigate(to route: MenuBarRoute) {
    navigationDirection = .forward
    var next = navigation
    next.open(route)
    if route == .support {
      support.prepareForEntry()
    }
    applyNavigation(next)
  }

  private func navigateBack() {
    navigationDirection = .back
    var next = navigation
    next.navigateBack()
    applyNavigation(next)
  }

  private func applyNavigation(_ next: MenuBarNavigationState) {
    guard next != navigation else { return }
    if let panelAnimation {
      let generation = navigationTransitionGeneration + 1
      updateWithoutAnimation {
        navigationTransitionGeneration = generation
        navigationTransitionActive = true
      }
      withAnimation(panelAnimation, completionCriteria: .removed) {
        navigation = next
      } completion: {
        guard navigationTransitionGeneration == generation else { return }
        updateWithoutAnimation {
          navigationTransitionActive = false
        }
      }
    } else {
      updateWithoutAnimation {
        navigationTransitionGeneration += 1
        navigationTransitionActive = false
        navigation = next
      }
    }
  }

  private func updateWithoutAnimation(_ update: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, update)
  }
}

private enum NavigationDirection {
  case forward
  case back
}

enum MenuBarRoute: Hashable {
  case settings
  case account
  case agents
  case provider(ProviderID)
  case devices
  case usage
  case menuBarStyle
  case menuBarProvider
  case support

  var title: String {
    switch self {
    case .settings: "Settings"
    case .account: "Account"
    case .agents: "Agents"
    case .provider(let provider): provider.displayName
    case .devices: "Devices"
    case .usage: "Usage"
    // The section header says Menu Bar; a page carries its own context.
    case .menuBarStyle: "Menu Bar Style"
    case .menuBarProvider: "Menu Bar Provider"
    case .support: "Support"
    }
  }
}

struct MenuBarNavigationState: Equatable {
  var path: [MenuBarRoute] = []

  var currentRoute: MenuBarRoute? { path.last }
  var title: String { currentRoute?.title ?? "QuotaBar" }
  var canNavigateBack: Bool { !path.isEmpty }
  var showsSettingsMenu: Bool { path == [.settings] }

  var pageIdentity: String {
    currentRoute.map { "\(path.count):\(String(describing: $0))" } ?? "overview"
  }

  mutating func open(_ route: MenuBarRoute) {
    guard path.last != route else { return }
    path.append(route)
  }

  mutating func navigateBack() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }

  /// Leaves a page that stopped existing — signing out closes Account — along with whatever was
  /// opened from it, rather than guessing how deep the person had gone.
  func closing(_ route: MenuBarRoute) -> MenuBarNavigationState? {
    guard let index = path.firstIndex(of: route) else { return nil }
    var next = self
    next.path.removeSubrange(index...)
    return next
  }
}
