import Foundation
import SweetCookieKit
import Testing

@testable import QuotaBar

@Test
func catalogBrowserSessionsCoverOfficialCookieProviders() {
  #expect(ProviderID.claude.browserSession?.cookieNames == ["sessionKey", "lastActiveOrg"])
  #expect(ProviderID.kimi.browserSession?.cookieNames == ["kimi-auth"])
  #expect(ProviderID.grok.browserSession?.cookieNames == ["sso", "sso-rw"])
  #expect(ProviderID.codex.browserSession?.cookieNames.contains("__Secure-next-auth.session-token") == true)
  #expect(ProviderID.cursor.browserSession?.exclusive == true)
  #expect(ProviderID.codex.browserSession?.exclusive == false)
  #expect(ProviderID.claude.browserSession?.exclusive == false)
  #expect(ProviderID.grok.browserSession?.exclusive == false)
  #expect(ProviderID.kimi.browserSession?.exclusive == false)
  #expect(ProviderID.openrouter.browserSession == nil)
}

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

@Test
func complementaryPairsAreSortedIntoOneHeader() throws {
  let spec = try #require(ProviderID.codex.browserSession)
  let combined = BrowserSessionImporter.candidate(
    pairs: [
      (name: "__Secure-next-auth.session-token.1", value: "second"),
      (name: "__Secure-next-auth.session-token.0", value: "first"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1"
  )
  #expect(
    combined?.cookieHeader
      == "__Secure-next-auth.session-token.0=first; __Secure-next-auth.session-token.1=second"
  )
  #expect(Set(spec.cookieNames).isSuperset(of: [
    "__Secure-next-auth.session-token.0",
    "__Secure-next-auth.session-token.1",
  ]))
  #expect(combined?.cookieHeader.contains("private") == false)
}

@Test
func complementaryCookiesCombinePerHostAndCursorNamesStaySeparate() throws {
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  func record(domain: String, name: String, value: String) -> BrowserCookieRecord {
    BrowserCookieRecord(
      domain: domain,
      name: name,
      path: "/",
      value: value,
      expires: now.addingTimeInterval(3_600),
      isSecure: true,
      isHTTPOnly: true
    )
  }
  let cursor = try #require(ProviderID.cursor.browserSession)
  let cursorCandidates = BrowserSessionImporter.groupedCandidates(
    records: [
      record(domain: "cursor.com", name: "wos-session", value: "wos"),
      record(domain: "cursor.com", name: "WorkosCursorSessionToken", value: "workos"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(cursor.cookieHosts),
    allowedNames: Set(cursor.cookieNames),
    now: now
  )
  #expect(Set(cursorCandidates.map(\.cookieHeader)) == [
    "wos-session=wos",
    "WorkosCursorSessionToken=workos",
  ])

  let grok = try #require(ProviderID.grok.browserSession)
  let grokCandidates = BrowserSessionImporter.groupedCandidates(
    records: [
      record(domain: "grok.com", name: "sso", value: "a"),
      record(domain: "grok.com", name: "sso-rw", value: "b"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(grok.cookieHosts),
    allowedNames: Set(grok.cookieNames),
    now: now
  )
  #expect(grokCandidates.map(\.cookieHeader) == ["sso=a; sso-rw=b"])

  let codex = try #require(ProviderID.codex.browserSession)
  let codexCandidates = BrowserSessionImporter.groupedCandidates(
    records: [
      record(domain: "chatgpt.com", name: "__Secure-next-auth.session-token.0", value: "first"),
      record(domain: "chatgpt.com", name: "__Secure-next-auth.session-token.1", value: "second"),
      record(domain: "chatgpt.com", name: "_account", value: "acct"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(codex.cookieHosts),
    allowedNames: Set(codex.cookieNames),
    now: now
  )
  #expect(
    codexCandidates.map(\.cookieHeader)
      == ["__Secure-next-auth.session-token.0=first; __Secure-next-auth.session-token.1=second; _account=acct"]
  )

  let claude = try #require(ProviderID.claude.browserSession)
  let claudeCandidates = BrowserSessionImporter.groupedCandidates(
    records: [
      record(domain: "claude.ai", name: "sessionKey", value: "sk-ant-ok"),
      record(domain: "claude.ai", name: "lastActiveOrg", value: "org-2"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(claude.cookieHosts),
    allowedNames: Set(claude.cookieNames),
    now: now
  )
  #expect(claudeCandidates.map(\.cookieHeader) == ["lastActiveOrg=org-2; sessionKey=sk-ant-ok"])
}
