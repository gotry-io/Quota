import Foundation
import QuotaWire
import SweetCookieKit
import Testing

@testable import QuotaBar

/// Every provider that has a web session declares one, and the catalog names the exact hosts
/// and cookies each read is limited to. Cursor is the only one with no official sign-in of its
/// own, which is what `exclusive` says.
@Test
func everyProviderWithAWebSessionDeclaresOne() {
  #expect(ProviderID.cursor.browserSession?.cookieNames == [
    "WorkosCursorSessionToken", "wos-session", "__Secure-wos-session",
  ])
  #expect(ProviderID.claude.browserSession?.cookieNames == ["sessionKey", "lastActiveOrg"])
  #expect(ProviderID.grok.browserSession?.cookieNames == ["sso", "sso-rw"])
  #expect(ProviderID.kimi.browserSession?.cookieNames == ["kimi-auth"])
  #expect(
    ProviderID.codex.browserSession?.cookieNames.contains("__Secure-next-auth.session-token")
      == true)
  #expect(ProviderID.codex.browserSession?.cookieHosts == ["chatgpt.com", "www.chatgpt.com"])
  #expect(ProviderID.claude.browserSession?.cookieHosts == ["claude.ai", "www.claude.ai"])
  #expect(ProviderID.grok.browserSession?.cookieHosts == ["grok.com", "www.grok.com"])
  #expect(ProviderID.kimi.browserSession?.cookieHosts == ["www.kimi.com", "kimi.com"])

  let declared = ProviderID.allCases.filter { $0.browserSession != nil }
  #expect(Set(declared) == Set([.codex, .claude, .grok, .kimi, .cursor]))
  // Only Cursor has no CLI sign-in command and no API key to omit the sign-in row for.
  #expect(declared.filter { $0.browserSession?.exclusive == true } == [.cursor])
  for provider in declared {
    let spec = provider.browserSession
    #expect(spec?.loginURL.hasPrefix("https://") == true)
    #expect(spec?.cookieNames.isEmpty == false)
  }
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
  func candidates(_ records: [BrowserCookieRecord]) -> [BrowserSessionCookieCandidate] {
    BrowserSessionImporter.candidates(
      records: records,
      spec: spec,
      browserName: "Chrome",
      profileName: "Profile 1",
      now: now
    )
  }
  let first = try #require(candidates([record(domain: ".cursor.com", value: "first")]).first)
  let second = try #require(candidates([record(domain: "www.cursor.com", value: "second")]).first)
  #expect(first.cookieHeader == "wos-session=first")
  #expect(second.cookieHeader == "wos-session=second")
  #expect(first.headerFingerprint != second.headerFingerprint)
  #expect(!first.cookieHeader.contains("private"))
  #expect(candidates([record(domain: "evilcursor.com", value: "bad")]).isEmpty)
  #expect(candidates([record(domain: "cursor.com", value: "old", expires: now)]).isEmpty)
  #expect(BrowserSessionImporter.sanitizedProfileName("\n\t") == "Default profile")
  #expect(!BrowserSessionImporter.sanitizedProfileName("Personal\n/path").contains("\n"))
  #expect(BrowserSessionImporter.sanitizedProfileName(String(repeating: "x", count: 80)).count == 64)
}

/// Two whole sign-ins are two candidates to choose between, never two halves of one header,
/// and two hosts are never merged into a single reading. The rule itself is
/// `BrowserSessionSpec.assembleCookieHeaders`, which both Apple products answer; what this
/// asserts is that a browser jar reaches it intact.
@Test
func eachAllowlistedNameAndHostStaysItsOwnCandidate() throws {
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
  let spec = try #require(ProviderID.cursor.browserSession)
  let candidates = BrowserSessionImporter.candidates(
    records: [
      record(domain: "cursor.com", name: "wos-session", value: "wos"),
      record(domain: "cursor.com", name: "WorkosCursorSessionToken", value: "workos"),
      record(domain: "authenticator.cursor.sh", name: "wos-session", value: "auth-host"),
      record(domain: "cursor.com", name: "not-allowlisted", value: "ignored"),
    ],
    spec: spec,
    browserName: "Chrome",
    profileName: "Profile 1",
    now: now
  )
  #expect(Set(candidates.map(\.cookieHeader)) == [
    "WorkosCursorSessionToken=workos",
    "wos-session=wos",
    "wos-session=auth-host",
  ])
  #expect(candidates.allSatisfy { $0.profileName == "Profile 1" })
}
