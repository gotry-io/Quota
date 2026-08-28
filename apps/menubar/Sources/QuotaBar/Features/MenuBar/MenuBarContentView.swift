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
  @State private var diagnostics = DiagnosticsPageModel()
  @State private var isResetConfirmationPresented = false
  private let performsInitialRefresh: Bool
  private let performsDiagnosticsCheckOnEntry: Bool
  private let seedsLaunchAtLogin: Bool

  init(
    model: MenuBarViewModel,
    initialPath: [MenuBarRoute] = [],
    performsInitialRefresh: Bool = true,
    performsDiagnosticsCheckOnEntry: Bool = true,
    diagnosticsModel: DiagnosticsPageModel? = nil,
    seedsLaunchAtLogin: Bool = true
  ) {
    self.model = model
    self.performsInitialRefresh = performsInitialRefresh
    self.performsDiagnosticsCheckOnEntry = performsDiagnosticsCheckOnEntry
    self.seedsLaunchAtLogin = seedsLaunchAtLogin
    _navigation = State(initialValue: MenuBarNavigationState(path: initialPath))
    _diagnostics = State(initialValue: diagnosticsModel ?? DiagnosticsPageModel())
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
    .disabled(isPopupPresented)
    .accessibilityHidden(isPopupPresented)
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
      } else if isResetConfirmationPresented {
        QuotaConfirmationPopup(
          title: ResetLocalDataCopy.title,
          message: ResetLocalDataCopy.message,
          confirmTitle: ResetLocalDataCopy.confirmTitle,
          onCancel: { isResetConfirmationPresented = false }
        ) {
          isResetConfirmationPresented = false
          Task { await model.resetLocalData() }
        }
      } else if let popup = model.browserSessionPopup {
        providerBrowserSessionPopup(popup)
      }
    }
  }

  /// Every destructive confirmation in the panel is one of these, and while one is up the page
  /// under it takes neither pointer nor VoiceOver.
  private var isPopupPresented: Bool {
    isLogoutConfirmationPresented
      || isResetConfirmationPresented
      || model.browserSessionPopup != nil
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
            provider: provider,
            browserName: choice.title,
            family: choice.family,
            spec: spec
          ),
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
    if navigation.currentRoute == .diagnostics, diagnostics.showsHeaderActions {
      return .diagnostics(
        isChecking: diagnostics.isLoading,
        canRecheck: diagnostics.canRecheck,
        onRecheck: { Task { await runDiagnosticsCheck() } }
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
        onOpenSupport: { navigate(to: .support) },
        onOpenRefreshInterval: { navigate(to: .quotaRefreshInterval) }
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
    case .quotaRefreshInterval:
      QuotaRefreshIntervalSettingsView(
        selected: QuotaRefreshInterval.resolved(model.quotaRefreshIntervalSeconds)
      ) { interval in
        Task { await model.setQuotaRefreshInterval(interval) }
        navigateBack()
      }
    case .support:
      SettingsSupportView(
        onOpenDiagnostics: { navigate(to: .diagnostics) },
        onRequestResetLocalData: { isResetConfirmationPresented = true }
      )
    case .diagnostics:
      SettingsDiagnosticsView(
        state: diagnostics.pageState,
        model: diagnostics,
        onRetry: { Task { await runDiagnosticsCheck() } }
      )
      .task {
        guard performsDiagnosticsCheckOnEntry else { return }
        await runDiagnosticsCheck()
      }
    }
  }

  private func openSettings() {
    navigate(to: .settings)
  }

  private func runDiagnosticsCheck() async {
    await diagnostics.runCheck { try await model.diagnose() }
  }

  private func navigate(to route: MenuBarRoute) {
    navigationDirection = .forward
    var next = navigation
    next.open(route)
    if route == .diagnostics {
      diagnostics.prepareForEntry()
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
  case quotaRefreshInterval
  case support
  case diagnostics

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
    case .quotaRefreshInterval: "Refresh Interval"
    case .support: "Support"
    case .diagnostics: "Diagnostics"
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
