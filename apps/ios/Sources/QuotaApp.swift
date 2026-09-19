import SwiftUI

@main
struct QuotaApp: App {
  @State private var model: AppModel
  @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system

  init() {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if let fixture = VisualFixture.parse(arguments: arguments) {
        // Default: the scenario's reference date, so period titles and activity days agree.
        // `--visual-clock wall` keeps today's clock for marketing captures.
        let wall = VisualClock.parse(arguments: arguments) == .wall
        let now = wall ? Date() : VisualFixture.referenceDate
        let model = AppModel.visualFixture(fixture, now: now, clockIsFixed: !wall)
        if let route = FixtureRoute.parse(arguments: arguments) {
          model.applyFixtureRoute(route)
        }
        _model = State(initialValue: model)
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
        .environment(\.displayClock, model.displayClock)
        .preferredColorScheme(appearance.colorScheme)
        .task {
          #if DEBUG
            if model.skipsRestore { return }
          #endif
          await model.restore()
          await model.setForeground(true)
          model.observeApplicationLifecycle()
        }
        .onOpenURL { url in
          model.openDeepLink(url)
        }
    }
  }
}
