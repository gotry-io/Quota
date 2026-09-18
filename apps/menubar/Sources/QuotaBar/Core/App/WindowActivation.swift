import AppKit

/// Show in Dock. Default off: accessory until the main window is open.
/// On: QuotaBar stays a regular app. An installation that never wrote
/// `dock.shown` takes this default; a stored value is read as written.
enum DockVisibilityPreference {
  static let storageKey = "dock.shown"
  static let fallback = false

  static var isShown: Bool {
    guard UserDefaults.standard.object(forKey: storageKey) != nil else {
      return fallback
    }
    return UserDefaults.standard.bool(forKey: storageKey)
  }
}

/// Counts the regular windows that should bring QuotaBar to the Dock when
/// Show in Dock is off.
///
/// Show in Dock (`dock.shown`, default off) is the process-wide rule. On, this
/// type does not change the activation policy — the process stays `.regular`.
/// Off, the first registered window becoming visible switches the process to
/// `.regular` and activates it; closing the last registered window returns to
/// `.accessory` without activating. Callers do not branch on the preference;
/// they always register the main window and call `applyDockVisibility()` when
/// the switch changes.
///
/// Browser Access and Sparkle windows are not registered: they are floating
/// helpers, not the main window. When Show in Dock is on they need no
/// WindowActivation exemption, because this type is then a no-op; when it is
/// off they still must not count, or a helper would pin the process in the Dock.
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
    applyPolicy(activatingFirstWindow: first, window: window)
  }

  /// Re-reads Show in Dock and applies it without activating, closing a window,
  /// or moving focus.
  func applyDockVisibility() {
    applyPolicy(activatingFirstWindow: false, window: nil)
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
    applyPolicy(activatingFirstWindow: false, window: nil)
  }

  private func handleDidBecomeKey(_ id: ObjectIdentifier) {
    guard shouldActivateWhenVisible, observations[id] != nil else { return }
    shouldActivateWhenVisible = false
    NSApp.activate(ignoringOtherApps: true)
  }

  private func applyPolicy(activatingFirstWindow: Bool, window: NSWindow?) {
    if DockVisibilityPreference.isShown {
      shouldActivateWhenVisible = false
      setActivationPolicyIfNeeded(.regular)
      return
    }
    if observations.isEmpty {
      shouldActivateWhenVisible = false
      setActivationPolicyIfNeeded(.accessory)
      return
    }
    setActivationPolicyIfNeeded(.regular)
    guard activatingFirstWindow, let window else { return }
    if window.isVisible {
      NSApp.activate(ignoringOtherApps: true)
    } else {
      shouldActivateWhenVisible = true
    }
  }

  private func setActivationPolicyIfNeeded(_ policy: NSApplication.ActivationPolicy) {
    guard NSApp.activationPolicy() != policy else { return }
    NSApp.setActivationPolicy(policy)
  }

  private struct Observation {
    let close: any NSObjectProtocol
    let becameKey: any NSObjectProtocol
  }
}
