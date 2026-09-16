import Foundation
import ServiceManagement

/// Login Item via `SMAppService.mainApp`. Toggle UI mirrors system status, not a UserDefaults flag.
@MainActor
enum LaunchAtLoginController {
  /// One-shot first-run default-on seed. Survives wipe so we never re-enable after a user disable.
  private static let seedKey = "settings.launchAtLogin.seeded"

  /// Open Application Apple Event keywords. `keyAEPropData` (`prdt`) holds
  /// `keyAELaunchedAsLogInItem` (`lgit`) when this process was started as a Login Item.
  nonisolated enum LaunchEvent {
    static let coreEventClass = AEEventClass(0x6165_7674)  // 'aevt'
    static let openApplication = AEEventID(0x6F61_7070)  // 'oapp'
    static let propData = AEKeyword(0x7072_6474)  // 'prdt'
    static let launchedAsLoginItem = AEKeyword(0x6C67_6974)  // 'lgit'
  }

  /// True when this process was started as a Login Item.
  static var launchedAsLoginItem: Bool {
    launchedAsLoginItem(event: NSAppleEventManager.shared().currentAppleEvent)
  }

  /// Parses the Open Application launch record. Tests construct the descriptor.
  nonisolated static func launchedAsLoginItem(event: NSAppleEventDescriptor?) -> Bool {
    guard let event else { return false }
    guard event.eventClass == LaunchEvent.coreEventClass,
      event.eventID == LaunchEvent.openApplication
    else { return false }
    guard let propData = event.paramDescriptor(forKeyword: LaunchEvent.propData) else {
      return false
    }
    return propData.forKeyword(LaunchEvent.launchedAsLoginItem) != nil
  }

  static var isEnabled: Bool {
    isEnabled(status: SMAppService.mainApp.status)
  }

  static var statusMessage: String? {
    message(for: SMAppService.mainApp.status)
  }

  nonisolated static func isEnabled(status: SMAppService.Status) -> Bool {
    switch status {
    case .enabled, .requiresApproval: true
    default: false
    }
  }

  nonisolated static func message(for status: SMAppService.Status) -> String? {
    switch status {
    case .requiresApproval:
      "Allow QuotaBar in System Settings → General → Login Items."
    case .notFound:
      "Login Items registration is unavailable for this build."
    default:
      nil
    }
  }

  static func seedDefaultOnIfNeeded() {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: seedKey) == nil else { return }
    defaults.set(true, forKey: seedKey)
    if SMAppService.mainApp.status == .notRegistered {
      _ = apply(enabled: true)
    }
  }

  @discardableResult
  static func apply(enabled: Bool) -> String? {
    let service = SMAppService.mainApp
    do {
      switch (enabled, service.status) {
      case (true, .enabled), (true, .requiresApproval), (false, .notRegistered):
        break
      case (true, _):
        try service.register()
      case (false, _):
        try service.unregister()
      }
    } catch {
      return message(for: service.status) ?? "QuotaBar could not update Login Items."
    }
    return message(for: service.status)
  }
}
