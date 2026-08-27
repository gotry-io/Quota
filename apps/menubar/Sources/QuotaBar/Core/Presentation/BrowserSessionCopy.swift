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
/// afterwards: which browser, which permission macOS will ask for, which cookies, where the
/// accepted session is kept, and that none of it is uploaded.
enum BrowserSessionCopy {
  static let consentConfirmTitle = "Read Cookies"

  static func consentTitle(provider: ProviderID) -> String {
    "Read \(provider.displayName) Cookies?"
  }

  /// The sheet shown before the first cookie is read.
  ///
  /// The permission sentence names only the gatekeeper the chosen browser actually has, because
  /// a Safari reader has no Keychain item to release and a Chrome reader needs no Full Disk
  /// Access. `hosts` and `names` come from the catalog, so the sheet cannot promise a narrower
  /// read than the one that happens.
  static func consentMessage(
    provider: ProviderID,
    browserName: String,
    family: BrowserSessionFamily,
    spec: BrowserSessionSpec
  ) -> String {
    let hosts = list(spec.cookieHosts)
    let names = list(spec.cookieNames)
    return """
      QuotaBar will read \(browserName)'s cookies for \(hosts), and only the \
      \(names) \(spec.cookieNames.count == 1 ? "cookie" : "cookies") stored there. \
      \(permissionSentence(browserName: browserName, family: family))
      The session you accept is stored in QuotaBar's local service database on this Mac until \
      you disconnect it. Nothing about it is uploaded to your Quota account or anywhere else.
      """
  }

  /// What macOS will ask for, in the words of the browser being read.
  static func permissionSentence(
    browserName: String,
    family: BrowserSessionFamily
  ) -> String {
    switch family {
    case .safari:
      """
      \(browserName) keeps its cookies behind Full Disk Access, so QuotaBar needs that grant in \
      System Settings › Privacy & Security to read them.
      """
    case .gecko:
      "\(browserName) stores its cookies in a profile QuotaBar reads directly."
    case .chromium:
      """
      \(browserName) encrypts its cookies with the "Chrome Safe Storage" Keychain item, so \
      macOS will ask you to allow QuotaBar to use it.
      """
    }
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
