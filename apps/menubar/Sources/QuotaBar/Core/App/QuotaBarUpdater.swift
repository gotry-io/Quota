import Foundation

#if !VISUAL_TEST
  import AppKit
  import Sparkle
#endif

enum QuotaBarUpdater {
  #if VISUAL_TEST
    static func start() {}
    static func checkForUpdates() {}
  #else
    @MainActor
    private static let controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    @MainActor
    static func start() {
      guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else {
        return
      }
      try? controller.updater.start()
    }

    @MainActor
    static func checkForUpdates() {
      NSApp.activate(ignoringOtherApps: true)
      try? controller.updater.start()
      controller.checkForUpdates(nil)
    }
  #endif
}
