import QuotaWire
import SweetCookieKit
import Testing

@testable import QuotaBar

/// The consent copy has to say what is about to happen: which cookies on which hosts, where
/// the session is kept, and that it stays here — and nothing that belongs to a browser.
@Test
func consentCopyNamesTheBrowserThePermissionAndTheCookies() throws {
  let spec = try #require(ProviderID.cursor.browserSession)
  let message = BrowserSessionCopy.scanConsentMessage(provider: .cursor, spec: spec)
  #expect(message.contains("Cursor"))
  #expect(message.contains("cursor.com"))
  #expect(message.contains("WorkosCursorSessionToken"))
  #expect(message.contains("local service database"))
  #expect(message.contains("until you turn this off"))
  #expect(message.contains("never uploaded"))
  // Which permission each browser needs is the Browser Access window's sentence, not this one's.
  #expect(!message.contains("Full Disk Access"))
  #expect(!message.contains("Chrome Safe Storage"))
  #expect(message.count < 360)
  #expect(BrowserSessionCopy.consentTitle(provider: .cursor) == "Read Cursor Cookies?")
}

/// The permission a browser will ask for is a fact about the browser, not about the name on the
/// button, so the importer's classification is the one both the sheet and the refusal answer to.
@Test
func theConsentSheetNamesTheGatekeeperTheImporterFound() {
  #expect(BrowserSessionImporter.family(of: .safari) == .safari)
  #expect(BrowserSessionImporter.family(of: .chrome) == .chromium)
  #expect(BrowserSessionImporter.family(of: .arc) == .chromium)
  #expect(BrowserSessionImporter.family(of: .firefoxDeveloperEdition) == .gecko)
  #expect(BrowserSessionImporter.family(of: .zen) == .gecko)
}

/// The sheet cannot promise a narrower read than the one that happens, so for every provider
/// that declares a session it names that provider, every host it will open, and every cookie
/// name it will take.
@Test
func consentCopyNamesEveryHostAndCookieTheCatalogDeclares() throws {
  for provider in ProviderID.allCases {
    guard let spec = provider.browserSession else { continue }
    let message = BrowserSessionCopy.scanConsentMessage(provider: provider, spec: spec)
    for host in spec.cookieHosts {
      #expect(message.contains(host), "\(provider.rawValue) consent omits \(host)")
    }
    for name in spec.cookieNames {
      #expect(message.contains(name), "\(provider.rawValue) consent omits \(name)")
    }
    #expect(message.contains("local service database"))
    #expect(message.contains("never uploaded"))
    #expect(
      BrowserSessionCopy.consentTitle(provider: provider)
        == "Read \(provider.displayName) Cookies?")
  }
}

@Test
func eachRefusalNamesADifferentThingToDo() {
  let keychain = BrowserSessionCopy.accessDeniedMessage(
    browserName: "Chrome", reason: .keychainRefused)
  #expect(keychain.contains("Chrome Safe Storage"))
  #expect(!keychain.contains("Full Disk Access"))
  let unreadable = BrowserSessionCopy.accessDeniedMessage(
    browserName: "Firefox", reason: .storeUnreadable)
  #expect(unreadable.contains("could not be opened"))
  #expect(unreadable.contains("Firefox"))
}

/// A store that is not there is not a refusal: that browser has simply never been used.
@Test
func onlyARefusalCountsAsARefusal() {
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.notFound(browser: .safari, details: "/Users/ada/Library"),
      browser: .safari
    ) == nil
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.accessDenied(browser: .safari, details: "/Users/ada/Library"),
      browser: .safari
    ) == .fullDiskAccess
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.accessDenied(browser: .chrome, details: "keychain"),
      browser: .chrome
    ) == .keychainRefused
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.accessDenied(browser: .firefox, details: "profile"),
      browser: .firefox
    ) == .storeUnreadable
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.loadFailed(browser: .chrome, details: "sqlite"),
      browser: .chrome
    ) == .storeUnreadable
  )
}
