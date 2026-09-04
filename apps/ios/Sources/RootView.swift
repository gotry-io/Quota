import SwiftUI

struct RootView: View {
  @Bindable var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      switch model.phase {
      case .launching:
        ProgressView("Loading account…")
          .accessibilityLabel("Loading account")
      case .signedOut, .connecting:
        NavigationStack {
          ConnectAccountView(model: model)
        }
      case .confirmingAccount(let label):
        NavigationStack {
          ConfirmAccountView(model: model, label: label)
        }
      case .signedIn where model.summary == nil && model.isRefreshing:
        ProgressView("Loading account…")
          .accessibilityLabel("Loading account")
      case .signedIn:
        signedInTabs
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { QuotaAmbientBackdrop() }
    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .default, value: model.phase)
  }

  private var signedInTabs: some View {
    TabView(selection: $model.selectedTab) {
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
      .tabItem {
        Label(AppTab.overview.title, systemImage: AppTab.overview.systemImage)
      }
      .tag(AppTab.overview)

      NavigationStack {
        UsageView(model: model)
      }
      .tabItem {
        Label(AppTab.usage.title, systemImage: AppTab.usage.systemImage)
      }
      .tag(AppTab.usage)

      NavigationStack {
        DevicesView(model: model)
      }
      .tabItem {
        Label(AppTab.devices.title, systemImage: AppTab.devices.systemImage)
      }
      .tag(AppTab.devices)

      NavigationStack {
        SettingsView(model: model)
      }
      .tabItem {
        Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage)
      }
      .tag(AppTab.settings)
    }
  }
}
