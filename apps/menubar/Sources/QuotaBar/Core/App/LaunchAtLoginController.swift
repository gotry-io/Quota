import Foundation
import ServiceManagement

/// Login Item via `SMAppService.mainApp`. Toggle UI mirrors system status, not a UserDefaults flag.
@MainActor
enum LaunchAtLoginController {
  /// One-shot first-run default-on seed. Survives wipe so we never re-enable after a user disable.
  private static let seedKey = "settings.launchAtLogin.seeded"

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
