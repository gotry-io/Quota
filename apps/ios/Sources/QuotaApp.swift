import SwiftUI

@main
struct QuotaApp: App {
  @State private var model: AppModel

  init() {
    #if DEBUG
      if let fixture = VisualFixture.parse(arguments: ProcessInfo.processInfo.arguments) {
        // Anchor synthetic ages/resets to launch time so screenshots stay current. A fixture
        // session stays offline, so it neither registers nor schedules a background refresh.
        _model = State(initialValue: AppModel.visualFixture(fixture, now: Date()))
        return
      }
    #endif
    let model = AppModel(backgroundRefresh: SystemBackgroundRefreshScheduler())
    _model = State(initialValue: model)
    // `App.init` runs inside launch, which is the only time `BGTaskScheduler` accepts a
    // launch handler. Whether a window is worth asking for is a question about the session,
    // which only `restore()` has read yet, so the ask is made — or withdrawn — from there.
    BackgroundRefresh.register(model: model)
  }

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .task {
          #if DEBUG
            if model.skipsRestore { return }
          #endif
          await model.restore()
        }
    }
  }
}
