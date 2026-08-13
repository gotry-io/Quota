import Foundation
import SweetCookieKit
import Testing

@testable import QuotaBar

@Test
func browserPriorityIsAValidatedPrefixOfEverySupportedBrowser() throws {
  #expect(ProviderID.allCases.contains(.cursor))
  let spec = try #require(ProviderID.cursor.browserSession)
  #expect(spec.browserPriority.compactMap(Browser.init(rawValue:)).count == spec.browserPriority.count)
  let ordered = BrowserSessionImporter.orderedBrowsers(for: spec)
  #expect(Array(ordered.prefix(spec.browserPriority.count)).map(\.rawValue) == spec.browserPriority)
  #expect(Set(ordered) == Set(Browser.defaultImportOrder))
  #expect(ordered.contains(.chromeBeta))
  #expect(ordered.contains(.zen))
  #expect(ordered.contains(.comet))
}

@Test
func browserCookieCandidatesUseExactHostsAndOneRecordPerHeader() throws {
  let spec = try #require(ProviderID.cursor.browserSession)
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  func record(domain: String, value: String, expires: Date? = nil) -> BrowserCookieRecord {
    BrowserCookieRecord(
      domain: domain,
      name: "wos-session",
      path: "/private/path-must-not-leak",
      value: value,
      expires: expires,
      isSecure: true,
      isHTTPOnly: true
    )
  }
  let first = BrowserSessionImporter.candidate(
    record: record(domain: ".cursor.com", value: "first"),
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(spec.cookieHosts),
    allowedNames: Set(spec.cookieNames),
    now: now
  )
  let second = BrowserSessionImporter.candidate(
    record: record(domain: "www.cursor.com", value: "second"),
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(spec.cookieHosts),
    allowedNames: Set(spec.cookieNames),
    now: now
  )
  #expect(first?.cookieHeader == "wos-session=first")
  #expect(second?.cookieHeader == "wos-session=second")
  #expect(first?.headerFingerprint != second?.headerFingerprint)
  #expect(!first!.cookieHeader.contains("private"))
  #expect(BrowserSessionImporter.candidate(
    record: record(domain: "evilcursor.com", value: "bad"),
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(spec.cookieHosts),
    allowedNames: Set(spec.cookieNames),
    now: now
  ) == nil)
  #expect(BrowserSessionImporter.candidate(
    record: record(domain: "cursor.com", value: "old", expires: now),
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(spec.cookieHosts),
    allowedNames: Set(spec.cookieNames),
    now: now
  ) == nil)
  #expect(BrowserSessionImporter.sanitizedProfileName("\n\t") == "Default profile")
  #expect(!BrowserSessionImporter.sanitizedProfileName("Personal\n/path").contains("\n"))
  #expect(BrowserSessionImporter.sanitizedProfileName(String(repeating: "x", count: 80)).count == 64)
}
