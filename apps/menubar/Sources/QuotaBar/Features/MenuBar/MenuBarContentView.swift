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
  private let performsInitialRefresh: Bool
  private let seedsLaunchAtLogin: Bool
  private let overflowMenuStartsExpanded: Bool

  init(
    model: MenuBarViewModel,
    panelSession: MenuBarPanelSession? = nil,
    initialPath: [MenuBarRoute] = [],
    performsInitialRefresh: Bool = true,
    seedsLaunchAtLogin: Bool = true,
    overflowMenuStartsExpanded: Bool = false
  ) {
    self.model = model
    self.panelSession = panelSession
    self.performsInitialRefresh = performsInitialRefresh
    self.seedsLaunchAtLogin = seedsLaunchAtLogin
    self.overflowMenuStartsExpanded = overflowMenuStartsExpanded
    _navigation = State(initialValue: MenuBarNavigationState(path: initialPath))
  }

  var body: some View {
    let revealGeneration = panelSession?.revealGeneration ?? 0
    let revealProvider = panelSession?.revealProvider
    TimelineView(.periodic(from: .now, by: 1)) { context in
      MenuBarShell(
        model: model,
        title: navigation.title,
        usageSource: .account,
        now: context.date,
        canNavigateBack: navigation.canNavigateBack,
        onNavigateBack: navigateBack,
        showsLeadingIcon: navigation.currentRoute == nil,
        trailing: headerTrailingAction,
        overflowMenuStartsExpanded: overflowMenuStartsExpanded,
        onOpenUsage: { MainWindowController.shared.show(page: .usage) }
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
    switch navigation.currentRoute {
    case nil:
      return .overflowMenu
    case .provider:
      return .none
    }
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
    case .provider(let provider):
      providerQuotaDetail(provider, now: now)
    }
  }

  private func openSettings() {
    MainWindowController.shared.show(page: .agents)
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
          action: { MainWindowController.shared.show(page: .agents) }
        )
      }
    case .empty(_):
      QuotaPageStateView(
        emptySystemImage: "eye.slash",
        title: "No Quota to Show",
        message: "Sign in to a provider CLI or enable an agent in Settings.",
        actionTitle: "Open Settings",
        action: { MainWindowController.shared.show(page: .agents) }
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
  case provider(ProviderID)

  var title: String {
    switch self {
    case .provider(let provider): provider.displayName
    }
  }
}

struct MenuBarNavigationState: Equatable {
  var path: [MenuBarRoute] = []

  var currentRoute: MenuBarRoute? { path.last }
  var title: String { currentRoute?.title ?? "QuotaBar" }
  var canNavigateBack: Bool { !path.isEmpty }

  var pageIdentity: String {
    currentRoute.map { "\(path.count):\(String(describing: $0))" } ?? "overview"
  }

  mutating func open(_ route: MenuBarRoute) {
    guard path != [route] else { return }
    path = [route]
  }

  mutating func open(_ routes: [MenuBarRoute]) {
    guard let route = routes.last else { return }
    open(route)
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
