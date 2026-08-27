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

/// Two whole sign-ins are two candidates to choose between, never two halves of one header,
/// and two hosts are never merged into a single reading.
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
  let candidates = BrowserSessionImporter.groupedCandidates(
    records: [
      record(domain: "cursor.com", name: "wos-session", value: "wos"),
      record(domain: "cursor.com", name: "WorkosCursorSessionToken", value: "workos"),
      record(domain: "authenticator.cursor.sh", name: "wos-session", value: "auth-host"),
      record(domain: "cursor.com", name: "not-allowlisted", value: "ignored"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(spec.cookieHosts),
    allowedNames: Set(spec.cookieNames),
    now: now
  )
  #expect(Set(candidates.map(\.cookieHeader)) == [
    "WorkosCursorSessionToken=workos",
    "wos-session=wos",
    "wos-session=auth-host",
  ])
}

/// The two cookie jars where one sign-in is spread across several names: a chunked NextAuth
/// token, and Grok's read-only and read-write halves. Neither half is a session on its own, so
/// splitting them would offer the reader two candidates that both fail.
@Test
func complementaryCookiesShareOneHeaderAndContextRidesAlong() throws {
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
  let codex = try #require(ProviderID.codex.browserSession)
  let chunked = BrowserSessionImporter.groupedCandidates(
    records: [
      record(domain: "chatgpt.com", name: "__Secure-next-auth.session-token.0", value: "a"),
      record(domain: "chatgpt.com", name: "__Secure-next-auth.session-token.1", value: "b"),
      record(domain: "chatgpt.com", name: "_account", value: "acct"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(codex.cookieHosts),
    allowedNames: Set(codex.cookieNames),
    now: now
  )
  #expect(chunked.map(\.cookieHeader) == [
    "__Secure-next-auth.session-token.0=a; __Secure-next-auth.session-token.1=b; _account=acct"
  ])

  let grok = try #require(ProviderID.grok.browserSession)
  let sso = BrowserSessionImporter.groupedCandidates(
    records: [
      record(domain: "grok.com", name: "sso", value: "read"),
      record(domain: "grok.com", name: "sso-rw", value: "write"),
    ],
    browserName: "Chrome",
    profileName: "Profile 1",
    allowedHosts: Set(grok.cookieHosts),
    allowedNames: Set(grok.cookieNames),
    now: now
  )
  #expect(sso.map(\.cookieHeader) == ["sso=read; sso-rw=write"])

  // Claude's org hint is context, so it travels with the session rather than as a candidate.
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
  #expect(BrowserSessionImporter.complementaryFamily(for: "wos-session") == nil)
  #expect(BrowserSessionImporter.complementaryFamily(for: "sso-rw") == "sso")
  #expect(BrowserSessionImporter.isOptionalContextCookie("lastActiveOrg"))
  #expect(!BrowserSessionImporter.isOptionalContextCookie("sessionKey"))
}
