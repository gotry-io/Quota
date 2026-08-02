import SwiftUI

struct MenuBarContentView: View {
  @Bindable var model: MenuBarViewModel
  @AppStorage("provider.codex.visible") private var showsCodex = true
  @AppStorage("provider.claude.visible") private var showsClaude = true
  @AppStorage("provider.grok.visible") private var showsGrok = true
  @State private var path: [MenuBarRoute]
  private let performsInitialRefresh: Bool

  init(
    model: MenuBarViewModel,
    initialPath: [MenuBarRoute] = [],
    performsInitialRefresh: Bool = true
  ) {
    self.model = model
    self.performsInitialRefresh = performsInitialRefresh
    _path = State(initialValue: initialPath)
  }

  var body: some View {
    MenuBarShell(
      model: model,
      title: path.isEmpty ? "QuotaBar" : "Settings",
      canNavigateBack: !path.isEmpty,
      onNavigateBack: navigateBack,
      onOpenSettings: openSettings
    ) {
      NavigationStack(path: $path) {
        QuotaOverviewView(
          model: model,
          enabledProviders: enabledProviders,
          onOpenSettings: openSettings
        )
        .navigationDestination(for: MenuBarRoute.self) { route in
          switch route {
          case .settings:
            SettingsHomeView(
              model: model,
              showsCodex: $showsCodex,
              showsClaude: $showsClaude,
              showsGrok: $showsGrok
            )
          }
        }
      }
      .toolbar(.hidden, for: .windowToolbar)
    }
    .task {
      guard performsInitialRefresh else { return }
      await model.refreshIfNeeded()
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
    guard path.last != .settings else { return }
    path.append(.settings)
  }

  private func navigateBack() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }
}

enum MenuBarRoute: Hashable {
  case settings
}
