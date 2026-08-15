import SwiftUI

@main
struct QuotaApp: App {
  @State private var model: AppModel

  init() {
    #if DEBUG
      if let fixture = VisualFixture.parse(arguments: ProcessInfo.processInfo.arguments) {
        // Anchor synthetic ages/resets to launch time so screenshots stay current.
        _model = State(initialValue: AppModel.visualFixture(fixture, now: Date()))
        return
      }
    #endif
    _model = State(initialValue: AppModel())
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
