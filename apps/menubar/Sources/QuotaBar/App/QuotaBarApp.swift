import SwiftUI

@main
struct QuotaBarApp: App {
  @State private var model = MenuBarViewModel()

  var body: some Scene {
    MenuBarExtra("QuotaBar", systemImage: "gauge.with.dots.needle.50percent") {
      MenuBarContentView(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}
