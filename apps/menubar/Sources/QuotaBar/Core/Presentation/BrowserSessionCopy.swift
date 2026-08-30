import Foundation
import QuotaWire

/// Which gatekeeper stands in front of a browser's cookie jar.
///
/// Safari's is Full Disk Access, a Chrome-family jar is sealed with a Keychain item, and a Gecko
/// profile has neither. That is one fact about a browser, and it decides both the refusal a read
/// can come back with and the permission consent has to name — so it travels as itself.
/// `BrowserSessionImporter` classifies it; nothing downstream re-derives it from a display name.
enum BrowserSessionFamily: Equatable, Sendable {
  case safari
  case chromium
  case gecko
}

/// Every sentence QuotaBar says about reading a browser's cookies.
///
/// Reading another program's cookie jar is the one thing this app does that a person has to
/// agree to, so what it is about to do is written out before it happens rather than summarised
/// afterwards: which cookies on which hosts, where the accepted session is kept, and that none
/// of it is uploaded — and, per installed browser, which permission macOS puts in the way.
enum BrowserSessionCopy {
  static let consentConfirmTitle = "Read Cookies"

  static func consentTitle(provider: ProviderID) -> String {
    "Read \(provider.displayName) Cookies?"
  }

  /// The sheet shown before the first cookie is read: which cookies, on which hosts, where they
  /// stay, and that they never leave. `hosts` and `names` come from the catalog, so the sheet
  /// cannot promise a narrower read than the one that happens. Which macOS permission each
  /// browser needs is the Browser Access window's job, told per browser once it is known.
  static func scanConsentMessage(provider: ProviderID, spec: BrowserSessionSpec) -> String {
    let hosts = list(spec.cookieHosts)
    let names = list(spec.cookieNames)
    let cookies = spec.cookieNames.count == 1 ? "cookie" : "cookies"
    return """
      QuotaBar will read the \(provider.displayName) sign-in \(cookies) — \(names) — that \
      browsers on this Mac hold for \(hosts). Sessions stay in QuotaBar's local service database \
      until you turn this off and are never uploaded.
      """
  }

  // MARK: Browser Access window

  static let grantWindowTitle = "Browser Access"
  static let grantWindowMessage = "Some browsers keep their cookies behind a macOS permission."
  static let grantOpenSettingsTitle = "Open Settings…"
  static let grantAllowTitle = "Allow…"
  static let grantReadyTitle = "Ready"
  static let grantUnavailableTitle = "Not set up yet"
  static let grantDoneTitle = "Done"
  static let dragHintTitle = "Turn on QuotaBar in the Full Disk Access list"
  static let dragHintSubtitle =
    "Not listed yet? Drag this icon into the list, or press + and choose QuotaBar."
  static let relaunchTitle = "Relaunch QuotaBar"
  static let relaunchSubtitle =
    """
    Once QuotaBar is in the list, relaunch to finish. macOS may offer to quit and reopen it \
    for you.
    """
  static let relaunchActionTitle = "Relaunch"

  /// What stands in front of this browser's cookies, or that nothing does.
  static func grantSubtitle(for status: BrowserAccessStatus) -> String {
    switch status.state {
    case .readable:
      switch status.family {
      case .safari: "Full Disk Access granted"
      case .chromium: "Keychain item allowed"
      case .gecko: "No permission needed"
      }
    case .needsFullDiskAccess:
      "Needs Full Disk Access"
    case .needsKeychain:
      "Needs the \"Chrome Safe Storage\" Keychain item. Choose Always Allow when asked."
    case .unavailable:
      "Has not saved a Keychain item yet. Open it once, then come back."
    }
  }

  // MARK: Agent page row

  static let accessRowTitle = "Browser Access"

  /// One line under the Scan browsers switch, or nil when nothing is outstanding.
  static func accessSummary(needs: [BrowserAccessNeed], awaitingRelaunch: Bool) -> String? {
    if awaitingRelaunch {
      return "Relaunch QuotaBar to finish granting Full Disk Access"
    }
    let names = needs.map(\.browser.displayName)
    guard !names.isEmpty else { return nil }
    if names.count == 1, let need = needs.first {
      return switch need.kind {
      case .fullDiskAccess: "\(names[0]) needs Full Disk Access"
      case .keychain: "\(names[0]) needs a Keychain grant"
      }
    }
    return "\(list(names)) need permission"
  }

  /// What a refusal means, and what fixes it.
  ///
  /// Each of these is a different action, and none of them is "wait": the read failed for a
  /// reason that stands until the reader changes something.
  static func accessDeniedMessage(
    browserName: String,
    reason: BrowserAccessDenialReason
  ) -> String {
    switch reason {
    case .fullDiskAccess:
      """
      QuotaBar could not read \(browserName)'s cookies. Grant Full Disk Access in System \
      Settings › Privacy & Security, then try again.
      """
    case .keychainRefused:
      """
      QuotaBar could not read \(browserName)'s cookies. macOS did not release the "Chrome Safe \
      Storage" Keychain item, so allow it when asked, then try again.
      """
    case .storeUnreadable:
      """
      QuotaBar could not read \(browserName)'s cookies. Its cookie store could not be opened. \
      Quit \(browserName) and try again, or choose another browser.
      """
    }
  }

  private static func list(_ values: [String]) -> String {
    switch values.count {
    case 0: ""
    case 1: values[0]
    case 2: "\(values[0]) and \(values[1])"
    default: "\(values.dropLast().joined(separator: ", ")), and \(values[values.count - 1])"
    }
  }
}
