import SwiftUI

struct MenuBarContentView: View {
  @Bindable var model: MenuBarViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var navigation: MenuBarNavigationState
  @State private var navigationDirection: NavigationDirection = .forward
  @State private var isLogoutConfirmationPresented = false
  @State private var usageSource: UsageSource = .account
  @State private var usagePeriod: UsagePeriod = .today
  private let performsInitialRefresh: Bool
  private let seedsLaunchAtLogin: Bool

  init(
    model: MenuBarViewModel,
    initialPath: [MenuBarRoute] = [],
    performsInitialRefresh: Bool = true,
    seedsLaunchAtLogin: Bool = true
  ) {
    self.model = model
    self.performsInitialRefresh = performsInitialRefresh
    self.seedsLaunchAtLogin = seedsLaunchAtLogin
    _navigation = State(initialValue: MenuBarNavigationState(path: initialPath))
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      MenuBarShell(
        model: model,
        title: navigation.title,
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
    .animation(panelAnimation, value: navigation.pageIdentity)
    .task {
      if seedsLaunchAtLogin {
        LaunchAtLoginController.seedDefaultOnIfNeeded()
      }
      guard performsInitialRefresh else { return }
      await model.refreshIfNeeded()
    }
    .focusEffectDisabled()
    .disabled(isLogoutConfirmationPresented)
    .accessibilityHidden(isLogoutConfirmationPresented)
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
      }
    }
  }

  private var panelAnimation: Animation? {
    reduceMotion ? nil : .snappy(duration: 0.28)
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
      SettingsSupportView(onOpenDiagnostics: { navigate(to: .diagnostics) })
    case .diagnostics:
      SettingsDiagnosticsView(model: model)
    }
  }

  private func openSettings() {
    navigate(to: .settings)
  }

  private func navigate(to route: MenuBarRoute) {
    navigationDirection = .forward
    var next = navigation
    next.open(route)
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
      withAnimation(panelAnimation) { navigation = next }
    } else {
      navigation = next
    }
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
