import SwiftUI

enum RootPhaseTransition {
  static func animation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeInOut(duration: 0.15) : .default
  }
}

struct RootView: View {
  @Bindable var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      phaseContent
        .id(model.phase)
        .transition(.opacity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(RootPhaseTransition.animation(reduceMotion: reduceMotion), value: model.phase)
  }

  @ViewBuilder
  private var phaseContent: some View {
    switch model.phase {
    case .launching:
      loading
    case .signedOut, .connecting, .pendingRefreshFailed:
      ConnectAccountView(model: model)
    case .confirmingAccount(let label):
      ConfirmAccountView(model: model, label: label)
    case .signedIn:
      if model.summary == nil && model.isRefreshing {
        loading
      } else {
        signedInTabs
      }
    }
  }

  private var loading: some View {
    ProgressView("Loading account…")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(uiColor: .systemBackground))
      .accessibilityIdentifier("root.loading")
  }

  private var signedInTabs: some View {
    TabView(selection: $model.selectedTab) {
      Tab(AppTab.overview.title, systemImage: AppTab.overview.systemImage, value: AppTab.overview) {
        NavigationStack(path: $model.overviewPath) {
          OverviewView(model: model)
            .navigationDestination(for: String.self) { key in
              if let subscription = model.subscription(forKey: key) {
                SubscriptionDetailView(
                  subscription: subscription,
                  devices: model.summary?.devices ?? []
                )
              }
            }
        }
      }

      Tab(AppTab.usage.title, systemImage: AppTab.usage.systemImage, value: AppTab.usage) {
        NavigationStack {
          UsageView(model: model)
        }
      }

      Tab(AppTab.devices.title, systemImage: AppTab.devices.systemImage, value: AppTab.devices) {
        NavigationStack {
          DevicesView(model: model)
        }
      }

      Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
        NavigationStack {
          SettingsView(model: model)
        }
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
  }
}
