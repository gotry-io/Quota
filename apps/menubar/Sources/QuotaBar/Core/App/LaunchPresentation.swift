import Foundation

/// Open window at launch. Default off: a manual launch shows the main window
/// only until this Mac has shown quota, then opens the panel instead.
enum LaunchWindowPreference {
  static let storageKey = "launch.opensMainWindow"
  static let fallback = false

  static var isOn: Bool {
    guard UserDefaults.standard.object(forKey: storageKey) != nil else {
      return fallback
    }
    return UserDefaults.standard.bool(forKey: storageKey)
  }
}

/// Set the first time a non-empty overview arrives; never cleared.
enum LaunchHasShownQuota {
  static let storageKey = "launch.hasShownQuota"

  static var hasShown: Bool {
    UserDefaults.standard.bool(forKey: storageKey)
  }

  static func markShown() {
    UserDefaults.standard.set(true, forKey: storageKey)
  }
}

/// What a launch should show after the status items exist.
enum LaunchPresentation: Equatable, Sendable {
  case silent
  case mainWindow
  case panel

  static func resolve(
    loginItem: Bool,
    opensWindow: Bool,
    hasShownQuota: Bool
  ) -> LaunchPresentation {
    if loginItem { return .silent }
    if opensWindow || !hasShownQuota { return .mainWindow }
    return .panel
  }
}
