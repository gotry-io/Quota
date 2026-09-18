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
    private static let owner = Owner()

    @MainActor
    static func start() {
      owner.startIfNeeded()
    }

    @MainActor
    static func checkForUpdates() {
      NSApp.activate(ignoringOtherApps: true)
      owner.startIfNeeded()
      owner.controller.checkForUpdates(nil)
    }

    @MainActor
    private final class Owner {
      let driver = QuotaBarSparkleDriver()
      let updaterDelegate = QuotaBarSparkleUpdaterDelegate()
      let controller: SPUStandardUpdaterController
      private var started = false

      init() {
        controller = SPUStandardUpdaterController(
          startingUpdater: false,
          updaterDelegate: updaterDelegate,
          userDriverDelegate: driver
        )
      }

      func startIfNeeded() {
        guard !started else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else {
          return
        }
        do {
          try controller.updater.start()
          started = true
        } catch {
          return
        }
      }
    }

    private final class QuotaBarSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
      func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Sparkle invokes this on the main thread, immediately before terminate.
        MainActor.assumeIsolated {
          QuitIntent.markFullQuitRequested()
        }
      }
    }

    private final class QuotaBarSparkleDriver: NSObject, SPUStandardUserDriverDelegate {
      func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
      ) {
        DispatchQueue.main.async {
          NSApp.activate(ignoringOtherApps: true)
        }
      }
    }
  #endif
}
