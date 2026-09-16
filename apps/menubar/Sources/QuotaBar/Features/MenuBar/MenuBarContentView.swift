import QuotaWire
import SwiftUI

struct MenuBarContentView: View {
  @Bindable var model: MenuBarViewModel
  var panelSession: MenuBarPanelSession? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var navigation: MenuBarNavigationState
  @State private var navigationDirection: NavigationDirection = .forward
  @State private var navigationTransitionActive = false
  @State private var navigationTransitionGeneration = 0
  @State private var usageSource: UsageSource = .account
  private let performsInitialRefresh: Bool
  private let seedsLaunchAtLogin: Bool

  init(
    model: MenuBarViewModel,
    panelSession: MenuBarPanelSession? = nil,
    initialPath: [MenuBarRoute] = [],
    initialUsageSource: UsageSource = .account,
    performsInitialRefresh: Bool = true,
    seedsLaunchAtLogin: Bool = true
  ) {
    self.model = model
    self.panelSession = panelSession
    self.performsInitialRefresh = performsInitialRefresh
    self.seedsLaunchAtLogin = seedsLaunchAtLogin
    _navigation = State(initialValue: MenuBarNavigationState(path: initialPath))
    _usageSource = State(initialValue: initialUsageSource)
  }

  var body: some View {
    let revealGeneration = panelSession?.revealGeneration ?? 0
    let revealProvider = panelSession?.revealProvider
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
        currentPage(
          now: context.date,
          revealGeneration: revealGeneration,
          revealProvider: revealProvider
        )
          .id(navigation.pageIdentity)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .transition(pageTransition)
      }
    }
    .environment(\.quotaPageTransitionActive, navigationTransitionActive)
    .onChange(of: revealGeneration) { _, _ in
      guard let provider = revealProvider else { return }
      navigationDirection = .forward
      applyNavigation(MenuBarNavigationState(path: [.provider(provider)]))
    }
    .task {
      if seedsLaunchAtLogin {
        LaunchAtLoginController.seedDefaultOnIfNeeded()
      }
      guard performsInitialRefresh else { return }
      await model.refreshIfNeeded()
    }
    .focusEffectDisabled()
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
    if !navigation.canNavigateBack { return .openSettings(openSettings) }
    return .none
  }

  @ViewBuilder
  private func currentPage(
    now: Date,
    revealGeneration: UInt,
    revealProvider: ProviderID?
  ) -> some View {
    switch navigation.currentRoute {
    case nil:
      QuotaOverviewView(
        model: model,
        enabledProviders: ProviderDisplayOrder.enabledProviders(),
        now: now,
        revealGeneration: revealGeneration,
        revealProvider: revealProvider,
        onOpenSettings: openSettings,
        onOpenProvider: openProvider
      )
    case .settings:
      SettingsHomeView(
        model: model,
        onOpenAgents: { SettingsWindowController.shared.show(page: .agents) },
        onOpenUsage: { navigate(to: .usage) },
        onOpenMenuBarStyle: { navigate(to: .menuBarStyle) },
        onOpenMenuBarProvider: { navigate(to: .menuBarProvider) },
        onOpenResetCopy: { navigate(to: .resetCopy) }
      )
    case .provider(let provider):
      providerQuotaDetail(provider, now: now)
    case .usage:
      AccountUsageView(model: model, source: $usageSource, now: now)
    case .menuBarStyle:
      MenuBarStyleSettingsView(onSelect: navigateBack)
    case .menuBarProvider:
      MenuBarProviderSettingsView(
        providers: ProviderDisplayOrder.enabledProviders()
      )
    case .resetCopy:
      ResetCopySettingsView(onSelect: navigateBack)
    }
  }

  private func openSettings() {
    SettingsWindowController.shared.show()
  }

  private func openProvider(_ provider: ProviderID) {
    navigate(to: .provider(provider))
  }

  @ViewBuilder
  private func providerQuotaDetail(_ provider: ProviderID, now: Date) -> some View {
    let state = model.overviewState(enabledProviders: [provider], now: now)
    switch state {
    case .content(let providers, _):
      if let presentation = providers.first {
        ScrollView {
          ProviderQuotaView(presentation: presentation, now: now)
            .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
            .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
        }
      } else {
        QuotaPageStateView(
          emptySystemImage: "eye.slash",
          title: "No Quota to Show",
          message: "Sign in to a provider CLI or enable an agent in Settings.",
          actionTitle: "Open Settings",
          action: { SettingsWindowController.shared.show(page: .agents) }
        )
      }
    case .empty(_):
      QuotaPageStateView(
        emptySystemImage: "eye.slash",
        title: "No Quota to Show",
        message: "Sign in to a provider CLI or enable an agent in Settings.",
        actionTitle: "Open Settings",
        action: { SettingsWindowController.shared.show(page: .agents) }
      )
    case .unavailable(let message):
      QuotaPageStateView(
        errorTitle: "Quota Unavailable",
        message: message,
        retry: { Task { await model.refresh() } }
      )
    case .loading:
      QuotaPageStateView(loadingTitle: "Reading quota…")
    }
  }

  private func navigate(to route: MenuBarRoute) {
    navigate(to: [route])
  }

  private func navigate(to routes: [MenuBarRoute]) {
    guard !routes.isEmpty else { return }
    navigationDirection = .forward
    var next = navigation
    next.open(routes)
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
  case provider(ProviderID)
  case usage
  case menuBarStyle
  case menuBarProvider
  case resetCopy

  var title: String {
    switch self {
    case .settings: "Settings"
    case .provider(let provider): provider.displayName
    case .usage: "Usage"
    // The section header says Menu Bar; a page carries its own context.
    case .menuBarStyle: "Menu Bar Style"
    case .menuBarProvider: "Menu Bar Provider"
    case .resetCopy: "Reset time"
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

  mutating func open(_ routes: [MenuBarRoute]) {
    for route in routes {
      open(route)
    }
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
