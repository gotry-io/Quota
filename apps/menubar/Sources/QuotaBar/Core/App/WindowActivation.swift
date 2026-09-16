import AppKit

/// Counts the regular windows that should bring QuotaBar to the Dock.
///
/// The first registered window becoming visible switches the process to
/// `.regular` and activates it, so a Dock icon and ⌘Tab entry exist while a
/// window is open. Closing the last registered window returns to `.accessory`
/// and does not activate — the user may already be in another app.
///
/// Browser Access and Sparkle windows are not registered: they are floating
/// helpers, not Settings or Dashboard.
@MainActor
final class WindowActivation {
  static let shared = WindowActivation()

  private var observations: [ObjectIdentifier: Observation] = [:]
  private var shouldActivateWhenVisible = false

  private init() {}

  /// Windows still registered, including miniaturized ones that have not closed.
  var registeredCount: Int { observations.count }

  func register(_ window: NSWindow) {
    let id = ObjectIdentifier(window)
    guard observations[id] == nil else { return }
    let first = observations.isEmpty

    let close = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleWillClose(id)
      }
    }
    let becameKey = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleDidBecomeKey(id)
      }
    }
    observations[id] = Observation(close: close, becameKey: becameKey)

    if first {
      NSApp.setActivationPolicy(.regular)
      if window.isVisible {
        NSApp.activate(ignoringOtherApps: true)
      } else {
        shouldActivateWhenVisible = true
      }
    }
  }

  func resetForTests() {
    for observation in observations.values {
      NotificationCenter.default.removeObserver(observation.close)
      NotificationCenter.default.removeObserver(observation.becameKey)
    }
    observations.removeAll()
    shouldActivateWhenVisible = false
  }

  private func handleWillClose(_ id: ObjectIdentifier) {
    guard let observation = observations.removeValue(forKey: id) else { return }
    NotificationCenter.default.removeObserver(observation.close)
    NotificationCenter.default.removeObserver(observation.becameKey)
    if observations.isEmpty {
      shouldActivateWhenVisible = false
      NSApp.setActivationPolicy(.accessory)
    }
  }

  private func handleDidBecomeKey(_ id: ObjectIdentifier) {
    guard shouldActivateWhenVisible, observations[id] != nil else { return }
    shouldActivateWhenVisible = false
    NSApp.activate(ignoringOtherApps: true)
  }

  private struct Observation {
    let close: any NSObjectProtocol
    let becameKey: any NSObjectProtocol
  }
}
