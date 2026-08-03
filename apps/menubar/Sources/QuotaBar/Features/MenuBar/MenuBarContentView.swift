import SwiftUI

struct MenuBarContentView: View {
  @Bindable var model: MenuBarViewModel
  @AppStorage("provider.codex.visible") private var showsCodex = true
  @AppStorage("provider.claude.visible") private var showsClaude = true
  @AppStorage("provider.grok.visible") private var showsGrok = true
  @State private var navigation: MenuBarNavigationState
  private let performsInitialRefresh: Bool
  private let performsRelayRefreshes: Bool

  init(
    model: MenuBarViewModel,
    initialPath: [MenuBarRoute] = [],
    performsInitialRefresh: Bool = true,
    performsRelayRefreshes: Bool = true
  ) {
    self.model = model
    self.performsInitialRefresh = performsInitialRefresh
    self.performsRelayRefreshes = performsRelayRefreshes
    _navigation = State(initialValue: MenuBarNavigationState(path: initialPath))
  }

  var body: some View {
    MenuBarShell(
      model: model,
      title: navigation.title,
      canNavigateBack: navigation.canNavigateBack,
      onNavigateBack: navigateBack,
      onOpenSettings: openSettings
    ) {
      currentPage
    }
    .task {
      guard performsInitialRefresh else { return }
      await model.refreshIfNeeded()
    }
  }

  @ViewBuilder
  private var currentPage: some View {
    switch navigation.currentRoute {
    case nil:
      QuotaOverviewView(
        model: model,
        enabledProviders: enabledProviders,
        onOpenSettings: openSettings
      )
    case .settings:
      SettingsHomeView(
        model: model,
        showsCodex: $showsCodex,
        showsClaude: $showsClaude,
        showsGrok: $showsGrok,
        onOpenRelays: { navigation.open(.relays) }
      )
    case .relays:
      RelayListView(
        model: model.relayStateModel,
        onAddRelay: { navigation.open(.addRelay) },
        onOpenRelay: { navigation.open(.relayDetail($0)) }
      )
    case .addRelay:
      AddRelayView(model: model.relayStateModel) { profileID in
        navigation.replaceLast(with: .relayDetail(profileID))
      }
    case .relayDetail(let profileID):
      RelayDetailView(
        model: model.relayStateModel,
        profileID: profileID,
        onOpenPairing: { navigation.open(.pairing(profileID)) },
        onOpenDevices: { navigation.open(.devices(profileID)) },
        onDeleted: { navigation.navigateBack() }
      )
    case .pairing(let profileID):
      RelayPairingView(model: model.relayStateModel, profileID: profileID)
    case .devices(let profileID):
      RelayDevicesView(
        model: model.relayStateModel,
        profileID: profileID,
        performsInitialRefresh: performsRelayRefreshes
      )
    }
  }

  private var enabledProviders: Set<ProviderID> {
    var providers = Set<ProviderID>()
    if showsCodex { providers.insert(.codex) }
    if showsClaude { providers.insert(.claude) }
    if showsGrok { providers.insert(.grok) }
    return providers
  }

  private func openSettings() {
    navigation.open(.settings)
  }

  private func navigateBack() {
    navigation.navigateBack()
  }
}

enum MenuBarRoute: Hashable {
  case settings
  case relays
  case addRelay
  case relayDetail(UUID)
  case pairing(UUID)
  case devices(UUID)

  var title: String {
    switch self {
    case .settings: "Settings"
    case .relays: "Relays"
    case .addRelay: "Add Relay"
    case .relayDetail: "Relay"
    case .pairing: "Pair device"
    case .devices: "Devices"
    }
  }
}

struct MenuBarNavigationState: Equatable {
  var path: [MenuBarRoute] = []

  var currentRoute: MenuBarRoute? { path.last }
  var title: String { currentRoute?.title ?? "QuotaBar" }
  var canNavigateBack: Bool { !path.isEmpty }

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
