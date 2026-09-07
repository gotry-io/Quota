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
    // A sign-in in flight owns the screen, because it is a question waiting for an answer.
    case .connecting, .pendingRefreshFailed:
      ConnectAccountView(model: model)
    case .confirmingAccount(let label):
      ConfirmAccountView(model: model, label: label)
    // Signing in to Quota is one of two ways to get quota onto this phone, so it is an invitation
    // inside the app rather than a wall in front of it
    // ([ADR 0034](../../../docs/decisions/0034-ios-collects-for-itself.md)).
    case .signedOut, .signedIn:
      if model.summary == nil && model.subscriptions.isEmpty && model.isRefreshing {
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
                  deviceNames: model.readingDeviceNames,
                  samples: model.localSamples
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
    // Signing in is a question asked over the tabs, not a wall in front of them: this phone is
    // showing what it read for itself either way
    // ([ADR 0034](../../../docs/decisions/0034-ios-collects-for-itself.md)). It hangs on the
    // TabView rather than the phase switch above it, because a presentation attached outside the
    // TabView stops the iOS 26 tab bar re-expanding when a list is scrolled back up.
    .sheet(isPresented: $model.presentsSignIn) {
      ConnectAccountView(model: model)
        .presentationDragIndicator(.visible)
    }
  }
}
