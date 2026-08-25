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
        title: model.showsFullRepairPage ? model.repairHeaderTitle : navigation.title,
        canNavigateBack: model.showsFullRepairPage ? false : navigation.canNavigateBack,
        onNavigateBack: navigateBack,
        showsLeadingIcon: model.showsFullRepairPage ? false : navigation.currentRoute == nil,
        trailing: model.showsFullRepairPage ? .none : headerTrailingAction
      ) {
        if model.showsFullRepairPage {
          RepairPageView(
            session: model.presentedRepair,
            now: context.date,
            onRetry: { Task { await model.refresh() } }
          )
        } else {
          currentPage(now: context.date)
            .id(navigation.pageIdentity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(pageTransition)
        }
      }
    }
    .environment(\.quotaPageTransitionActive, navigationTransitionActive)
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
          title: "Log Out?",
          message:
            "This signs QuotaBar out on this Mac. Your device and synced data stay in your Quota account.",
          confirmTitle: "Log Out",
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
        message: "QuotaBar will open \(provider.displayName) and read only that browser's matching session cookies.",
        choices: choices.map {
          QuotaSelectionChoice(id: $0.id, title: $0.title, subtitle: nil)
        },
        onCancel: model.cancelProviderBrowserSessionFlow,
        onSelect: { model.selectBrowserApplication($0, provider: provider) }
      )
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
        canCopy: diagnostics.canCopy,
        didCopy: diagnostics.didCopy,
        onRecheck: { Task { await runDiagnosticsCheck() } },
        onCopy: { diagnostics.copyTextReport() }
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
        usageSource: usageSource,
        now: now,
        onOpenSettings: openSettings
      )
    case .settings:
      SettingsHomeView(
        model: model,
        onOpenAgents: { navigate(to: .agents) },
        onOpenDevices: { navigate(to: .devices) },
        onOpenUsage: { navigate(to: .usage) },
        onOpenSupport: { navigate(to: .support) },
        onRequestLogout: { isLogoutConfirmationPresented = true }
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
    case .support:
      SettingsSupportView(model: model, onOpenDiagnostics: { navigate(to: .diagnostics) })
    case .diagnostics:
      SettingsDiagnosticsView(
        state: diagnostics.pageState,
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
  case agents
  case provider(ProviderID)
  case devices
  case usage
  case support
  case diagnostics

  var title: String {
    switch self {
    case .settings: "Settings"
    case .agents: "Agents"
    case .provider(let provider): provider.displayName
    case .devices: "Devices"
    case .usage: "Usage"
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
}
