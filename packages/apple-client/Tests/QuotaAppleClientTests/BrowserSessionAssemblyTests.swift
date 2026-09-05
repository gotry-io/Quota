import Foundation
import QuotaWire
import Testing

/// The rule that turns a pile of cookies into the sign-ins they are. QuotaBar applies it to a
/// browser's jar and Quota iOS to the web view the reader signed in inside, so it is stated once.
struct BrowserSessionAssemblyTests {
  static let now = Date(timeIntervalSince1970: 1_786_723_200)

  static func cookie(
    _ name: String,
    _ value: String,
    domain: String = "chatgpt.com",
    expiresAt: Date? = nil
  ) -> BrowserCookie {
    BrowserCookie(name: name, value: value, domain: domain, expiresAt: expiresAt)
  }

  static func spec(_ provider: ProviderID) -> BrowserSessionSpec {
    provider.browserSession!
  }

  @Test
  func numberedChunksAreOneSessionAndTheAccountCookieRidesAlong() {
    let headers = Self.spec(.codex).assembleCookieHeaders(
      cookies: [
        Self.cookie("__Secure-next-auth.session-token.1", "second"),
        Self.cookie("__Secure-next-auth.session-token.0", "first"),
        Self.cookie("_account", "acct"),
      ],
      now: Self.now
    )
    #expect(
      headers == [
        "__Secure-next-auth.session-token.0=first; "
          + "__Secure-next-auth.session-token.1=second; _account=acct"
      ])
  }

  @Test
  func grokKeepsItsTwoHalvesTogether() {
    let headers = Self.spec(.grok).assembleCookieHeaders(
      cookies: [
        Self.cookie("sso-rw", "write", domain: "grok.com"),
        Self.cookie("sso", "read", domain: "grok.com"),
      ],
      now: Self.now
    )
    #expect(headers == ["sso=read; sso-rw=write"])
  }

  @Test
  func claudeCarriesTheOrganizationCookieWithItsSession() {
    let headers = Self.spec(.claude).assembleCookieHeaders(
      cookies: [
        Self.cookie("sessionKey", "sk", domain: ".claude.ai"),
        Self.cookie("lastActiveOrg", "org_1", domain: "claude.ai"),
      ],
      now: Self.now
    )
    #expect(headers == ["lastActiveOrg=org_1; sessionKey=sk"])
  }

  /// A cookie that only says which organization a session is acting as is not a session.
  @Test
  func aContextCookieAloneIsNotASignIn() {
    #expect(
      Self.spec(.claude).assembleCookieHeaders(
        cookies: [Self.cookie("lastActiveOrg", "org_1", domain: "claude.ai")], now: Self.now
      ).isEmpty)
  }

  @Test
  func twoWholeSignInsStaySeparate() {
    let headers = Self.spec(.cursor).assembleCookieHeaders(
      cookies: [
        Self.cookie("wos-session", "a", domain: "cursor.com"),
        Self.cookie("WorkosCursorSessionToken", "b", domain: "cursor.com"),
      ],
      now: Self.now
    )
    #expect(headers == ["WorkosCursorSessionToken=b", "wos-session=a"])
  }

  @Test
  func hostsAreNeverCombined() {
    let headers = Self.spec(.codex).assembleCookieHeaders(
      cookies: [
        Self.cookie("__Secure-next-auth.session-token", "one", domain: "chatgpt.com"),
        Self.cookie("__Secure-next-auth.session-token", "two", domain: "www.chatgpt.com"),
      ],
      now: Self.now
    )
    #expect(
      headers == [
        "__Secure-next-auth.session-token=one", "__Secure-next-auth.session-token=two",
      ])
  }

  @Test
  func anExpiredEmptyUnnamedOrUnlistedCookieIsNotRead() {
    let headers = Self.spec(.codex).assembleCookieHeaders(
      cookies: [
        Self.cookie(
          "__Secure-next-auth.session-token", "old",
          expiresAt: Self.now.addingTimeInterval(-1)),
        Self.cookie("__Host-next-auth.session-token", ""),
        Self.cookie("oai-did", "device"),
        Self.cookie("__Secure-next-auth.session-token", "elsewhere", domain: "example.com"),
      ],
      now: Self.now
    )
    #expect(headers.isEmpty)
  }

  /// A header no provider would accept is not offered as a session.
  @Test
  func anOversizedHeaderIsRefused() {
    let value = String(repeating: "a", count: BrowserSessionSpec.maximumCookieHeaderBytes)
    #expect(
      Self.spec(.codex).assembleCookieHeaders(
        cookies: [Self.cookie("__Secure-next-auth.session-token", value)], now: Self.now
      ).isEmpty)
  }
}
