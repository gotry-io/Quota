import SwiftUI

struct RootView: View {
  @Bindable var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NavigationStack {
      Group {
        switch model.phase {
        case .launching:
          ProgressView("Loading account…")
            .accessibilityLabel("Loading account")
        case .signedOut, .connecting:
          ConnectAccountView(model: model)
        case .signedIn where model.summary == nil && model.isRefreshing:
          ProgressView("Loading account…")
            .accessibilityLabel("Loading account")
        case .signedIn:
          OverviewView(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { QuotaAmbientBackdrop() }
      .animation(reduceMotion ? .easeInOut(duration: 0.15) : .default, value: model.phase)
    }
  }
}
