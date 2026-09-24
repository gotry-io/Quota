import QuotaWire
import SweetCookieKit
import Testing

@testable import QuotaBar

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
    #expect(message.contains("until you turn this off"))
    // Which permission each browser needs is the Browser Access window's sentence, not this one's.
    #expect(!message.contains("Full Disk Access"))
    #expect(!message.contains("Chrome Safe Storage"))
    #expect(
      BrowserSessionCopy.consentTitle(provider: provider)
        == "Read \(provider.displayName) Cookies?")
  }
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
