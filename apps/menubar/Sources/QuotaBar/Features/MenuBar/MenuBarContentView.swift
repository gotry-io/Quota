import AppKit
import SwiftUI

struct MenuBarContentView: View {
  @Bindable var model: MenuBarViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var navigation: MenuBarNavigationState
  @State private var navigationDirection: NavigationDirection = .forward
  @State private var showsDeleteAllConfirmation = false
  @State private var showsLocalDeleteConfirmation = false
  @State private var isDeletingAllData = false
  @State private var deleteAllErrorMessage: String?
  @State private var pendingDeviceRemoval: OwnedRemoteDevice?
  @State private var isRemovingDevice = false
  @State private var deviceRemovalErrorMessage: String?
  /// Page-level issue shown in the shell title bar (API key failures, etc.).
  @State private var pageIssue: String?
  /// Bumped by header **Save** on configurable provider pages.
  @State private var providerSaveRequest = 0
  private let performsInitialRefresh: Bool
  private let performsRelayRefreshes: Bool
  /// Production only: one-shot default-on Login Item seed. Visual QA leaves system Login Items alone.
  private let seedsLaunchAtLogin: Bool

  init(
    model: MenuBarViewModel,
    initialPath: [MenuBarRoute] = [],
    performsInitialRefresh: Bool = true,
    performsRelayRefreshes: Bool = true,
    seedsLaunchAtLogin: Bool = true
  ) {
    self.model = model
    self.performsInitialRefresh = performsInitialRefresh
    self.performsRelayRefreshes = performsRelayRefreshes
    self.seedsLaunchAtLogin = seedsLaunchAtLogin
    _navigation = State(initialValue: MenuBarNavigationState(path: initialPath))
  }

  var body: some View {
    ZStack {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        MenuBarShell(
          model: model,
          title: navigation.title,
          issue: pageIssue,
          canNavigateBack: navigation.canNavigateBack,
          onNavigateBack: navigateBack,
          showsLeadingIcon: navigation.currentRoute == nil,
          trailing: headerTrailingAction
        ) {
          ZStack(alignment: .topLeading) {
            currentPage(now: context.date)
              .id(navigation.pageIdentity)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .transition(pageTransition)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .clipped()
        }
      }
      .animation(panelAnimation, value: navigation.pageIdentity)
      .allowsHitTesting(!showsConfirmation)
      .accessibilityHidden(showsConfirmation)

      confirmationLayer
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
    reduceMotion ? nil : .snappy(duration: 0.28)
  }

  private var showsConfirmation: Bool {
    showsDeleteAllConfirmation || showsLocalDeleteConfirmation || pendingDeviceRemoval != nil
  }

  private var confirmationLayer: some View {
    ZStack {
      if showsLocalDeleteConfirmation {
        QuotaConfirmationDialog(
          title: "Finish by deleting local data?",
          message:
            "QuotaBar could not confirm remote cleanup. Deleting locally may leave remote device groups behind while paired devices continue reporting. Use this only if you cannot retry while online.",
          confirmTitle: "Delete Locally Anyway",
          cancelTitle: "Keep Data",
          onConfirm: {
            showsLocalDeleteConfirmation = false
            deleteAllDataLocally()
          },
          onCancel: { showsLocalDeleteConfirmation = false }
        )
      } else if let pendingDeviceRemoval {
        QuotaConfirmationDialog(
          title: "Remove \(pendingDeviceRemoval.device.displayName)?",
          message: "This device will stop reporting to this QuotaBar.",
          confirmTitle: "Remove Device",
          cancelTitle: "Cancel",
          onConfirm: removePendingDevice,
          onCancel: { self.pendingDeviceRemoval = nil }
        )
      } else if showsDeleteAllConfirmation {
        QuotaConfirmationDialog(
          title: "Delete all QuotaBar data?",
          message:
            "QuotaBar will remove its remote device groups when reachable, then delete its cached quota and preferences. Paired devices will stop appearing in this QuotaBar.",
          confirmTitle: "Delete All Data",
          cancelTitle: "Cancel",
          onConfirm: {
            showsDeleteAllConfirmation = false
            deleteAllData()
          },
          onCancel: { showsDeleteAllConfirmation = false }
        )
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsConfirmation)
  }

  private var pageTransition: AnyTransition {
    if reduceMotion {
      return .opacity
    }
    switch navigationDirection {
    case .forward:
      return .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      )
    case .back:
      return .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
      )
    }
  }

  private var headerTrailingAction: MenuBarHeader.TrailingAction {
    if navigation.showsSettingsMenu {
      return .overflowMenu(deleteEnabled: !isDeletingAllData) {
        showsDeleteAllConfirmation = true
      }
    }
    if navigation.showsPairDeviceAction {
      return .pairDevice { navigate(to: .pairDevice) }
    }
    if navigation.showsProviderSaveAction {
      return .textAction(
        title: "Save",
        accessibilityHint: "Save or clear the API key."
      ) {
        providerSaveRequest += 1
      }
    }
    if !navigation.canNavigateBack {
      return .openSettings(openSettings)
    }
    return .none
  }

  @ViewBuilder
  private func currentPage(now: Date) -> some View {
    switch navigation.currentRoute {
    case nil:
      QuotaOverviewView(
        model: model,
        enabledProviders: enabledProviders,
        now: now,
        onOpenSettings: openSettings
      )
    case .settings:
      SettingsHomeView(
        model: model,
        onOpenAgents: { navigate(to: .agents) },
        onOpenRemoteDevices: { navigate(to: .remoteDevices) },
        deleteAllErrorMessage: deleteAllErrorMessage
      )
    case .agents:
      AgentsSettingsView(
        relayReportedProviders: model.relayReportingProviders(now: now),
        onOpenProvider: { provider in navigate(to: .provider(provider)) }
      )
    case .provider(let provider):
      ProviderSettingsView(
        provider: provider,
        reportingSources: model.reportingSources(for: provider, now: now),
        now: now,
        saveRequest: providerSaveRequest,
        onIssue: { pageIssue = $0 }
      )
    case .remoteDevices:
      RemoteDevicesView(
        model: model.relayStateModel,
        performsInitialRefresh: performsRelayRefreshes,
        errorMessage: deviceRemovalErrorMessage,
        isRemoving: isRemovingDevice,
        onRequestRemoval: { pendingDeviceRemoval = $0 }
      )
    case .pairDevice:
      PairDeviceView(model: model.relayStateModel, onFinished: navigateBack)
    }
  }

  private var enabledProviders: [ProviderID] {
    ProviderDisplayOrder.enabledProviders()
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
    pageIssue = nil
    providerSaveRequest = 0
    if let panelAnimation {
      withAnimation(panelAnimation) {
        navigation = next
      }
    } else {
      navigation = next
    }
  }

  private func deleteAllData() {
    guard !isDeletingAllData else { return }
    isDeletingAllData = true
    deleteAllErrorMessage = nil
    Task {
      defer { isDeletingAllData = false }
      do {
        try await model.deleteAllQuotaBarData()
      } catch {
        deleteAllErrorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not delete all data."
        )
        if !(error is CancellationError) {
          showsLocalDeleteConfirmation = true
        }
      }
    }
  }

  private func deleteAllDataLocally() {
    do {
      try model.deleteAllQuotaBarDataLocally()
      deleteAllErrorMessage = nil
    } catch {
      deleteAllErrorMessage = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "QuotaBar could not delete its local data."
      )
    }
  }

  private func removePendingDevice() {
    guard let pending = pendingDeviceRemoval, !isRemovingDevice else { return }
    pendingDeviceRemoval = nil
    isRemovingDevice = true
    deviceRemovalErrorMessage = nil
    Task {
      defer { isRemovingDevice = false }
      do {
        try await model.relayStateModel.revokeDevice(
          profileID: pending.profileID,
          deviceID: pending.device.deviceID
        )
      } catch {
        deviceRemovalErrorMessage = RelaySettingsErrorPresentation.message(
          for: error,
          fallback: "QuotaBar could not remove the device."
        )
      }
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
  case remoteDevices
  case pairDevice

  var title: String {
    switch self {
    case .settings: "Settings"
    case .agents: "Agents"
    case .provider(let provider): provider.displayName
    case .remoteDevices: "Remote Devices"
    case .pairDevice: "Pair Device"
    }
  }
}

struct MenuBarNavigationState: Equatable {
  var path: [MenuBarRoute] = []

  var currentRoute: MenuBarRoute? { path.last }
  var title: String { currentRoute?.title ?? "QuotaBar" }
  var canNavigateBack: Bool { !path.isEmpty }
  var showsSettingsMenu: Bool { path == [.settings] }
  var showsPairDeviceAction: Bool { currentRoute == .remoteDevices }
  /// Configurable provider detail: header trailing **Save** for the API-key form.
  var showsProviderSaveAction: Bool {
    if case .provider(let provider) = currentRoute {
      return provider.isConfigurable
    }
    return false
  }

  /// Stable identity for page transitions (depth + route).
  var pageIdentity: String {
    if let currentRoute {
      return "\(path.count):\(String(describing: currentRoute))"
    }
    return "overview"
  }

  mutating func open(_ route: MenuBarRoute) {
    guard path.last != route else { return }
    path.append(route)
  }

  mutating func replaceLast(with route: MenuBarRoute) {
    if !path.isEmpty {
      path.removeLast()
    }
    path.append(route)
  }

  mutating func navigateBack() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }
}
