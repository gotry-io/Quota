import AppKit
import SwiftUI

struct MenuBarContentView: View {
  @Bindable var model: MenuBarViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("provider.codex.visible") private var showsCodex = true
  @AppStorage("provider.claude.visible") private var showsClaude = true
  @AppStorage("provider.grok.visible") private var showsGrok = true
  @State private var navigation: MenuBarNavigationState
  @State private var navigationDirection: NavigationDirection = .forward
  @State private var showsDeleteAllConfirmation = false
  @State private var showsLocalDeleteConfirmation = false
  @State private var isDeletingAllData = false
  @State private var deleteAllErrorMessage: String?
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
      trailing: { headerTrailing }
    ) {
      ZStack(alignment: .topLeading) {
        currentPage
          .id(navigation.pageIdentity)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .transition(pageTransition)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
    }
    .animation(panelAnimation, value: navigation.pageIdentity)
    .confirmationDialog(
      "Delete all QuotaBar data?",
      isPresented: $showsDeleteAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete All Data", role: .destructive) {
        deleteAllData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "QuotaBar will delete its managed controller and linked Relay data, then delete all controller credentials, Relay profiles, cached quota, and user preferences. Managed Relay will stay disconnected until you reconnect it."
      )
    }
    .confirmationDialog(
      "Finish by deleting local data?",
      isPresented: $showsLocalDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete Locally Anyway", role: .destructive) {
        deleteAllDataLocally()
      }
      Button("Keep Data", role: .cancel) {}
    } message: {
      Text(
        "QuotaBar could not confirm full cleanup. Deleting locally may leave the managed controller and Relay data behind while paired devices continue reporting. Use this only if you cannot retry while online."
      )
    }
    .task {
      guard performsInitialRefresh else { return }
      await model.refreshIfNeeded()
    }
  }

  private var panelAnimation: Animation? {
    reduceMotion ? nil : .snappy(duration: 0.28)
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

  @ViewBuilder
  private var headerTrailing: some View {
    if navigation.showsSettingsMenu {
      Menu {
        Button("Delete All QuotaBar Data…", role: .destructive) {
          showsDeleteAllConfirmation = true
        }
        .disabled(isDeletingAllData)

        Divider()

        Button("Quit QuotaBar") {
          NSApplication.shared.terminate(nil)
        }
      } label: {
        headerIcon("ellipsis", weight: .bold, pointSize: 16)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Settings menu")
    } else if navigation.showsAddRelayAction {
      Button {
        navigate(to: .addRelay)
      } label: {
        headerIcon("plus", weight: .semibold, pointSize: 15)
      }
      .buttonStyle(.plain)
      .fixedSize()
      .accessibilityLabel("Add Relay")
    } else if !navigation.canNavigateBack {
      Button(action: openSettings) {
        headerIcon("gearshape", weight: .medium, pointSize: 13)
      }
      .buttonStyle(.plain)
      .fixedSize()
      .accessibilityLabel("Open settings")
    }
  }

  private func headerIcon(
    _ systemName: String,
    weight: Font.Weight,
    pointSize: CGFloat
  ) -> some View {
    Image(systemName: systemName)
      .font(.system(size: pointSize, weight: weight))
      .foregroundStyle(QuotaPalette.body)
      .frame(
        width: QuotaDesign.Layout.navigationControlSize,
        height: QuotaDesign.Layout.navigationControlSize,
        alignment: .center
      )
      .contentShape(Rectangle())
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
        onOpenRelays: { navigate(to: .relays) },
        deleteAllErrorMessage: deleteAllErrorMessage
      )
    case .relays:
      RelayListView(
        model: model.relayStateModel,
        onAddRelay: { navigate(to: .addRelay) },
        onOpenRelay: { navigate(to: .relayDetail($0)) }
      )
    case .addRelay:
      AddRelayView(model: model.relayStateModel, onFinished: navigateBack)
    case .relayDetail(let profileID):
      RelayDetailView(
        model: model.relayStateModel,
        profileID: profileID,
        onOpenPairing: { navigate(to: .pairing(profileID)) },
        onOpenDevices: { navigate(to: .devices(profileID)) },
        onDeleted: navigateBack
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
}

private enum NavigationDirection {
  case forward
  case back
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
    case .addRelay: "Pair Device"
    case .relayDetail: "Relay"
    case .pairing: "Pair Device"
    case .devices: "Devices"
    }
  }
}

struct MenuBarNavigationState: Equatable {
  var path: [MenuBarRoute] = []

  var currentRoute: MenuBarRoute? { path.last }
  var title: String { currentRoute?.title ?? "QuotaBar" }
  var canNavigateBack: Bool { !path.isEmpty }
  var showsSettingsMenu: Bool { path == [.settings] }
  var showsAddRelayAction: Bool { currentRoute == .relays }

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
