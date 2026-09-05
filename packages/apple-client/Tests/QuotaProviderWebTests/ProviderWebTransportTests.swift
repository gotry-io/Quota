import Foundation
import QuotaWire
import Testing

@testable import QuotaProviderWeb

/// The rules that hold whatever a provider answers: what a status means, what a cookie is
/// allowed to touch, and what an error is allowed to say.
@Suite
struct ProviderWebTransportTests {
  @Test func aStatusMeansTheSameThingItMeansInTheService() {
    #expect(ProviderWebHTTP.category(of: 401) == .authRequired)
    #expect(ProviderWebHTTP.category(of: 403) == .authRequired)
    #expect(ProviderWebHTTP.category(of: 404) == .unsupported)
    #expect(ProviderWebHTTP.category(of: 429) == .unavailable)
    #expect(ProviderWebHTTP.category(of: 500) == .unavailable)
    #expect(ProviderWebHTTP.category(of: 400) == .error)
  }

  /// A redirect is not followed, and a redirect answering a session request means the session
  /// was not accepted rather than the host being unreachable.
  @Test func aRedirectIsAnAnswerAndNeverAHop() async throws {
    let transport = FixedTransport(status: 302, body: Data())
    let collector = ClaudeWebCollector(transport: transport, clientVersion: "test")
    await #expect(throws: ProviderWebError(.authRequired, ClaudeWebCollector.source)) {
      try await collector.validate(cookieHeader: "sessionKey=sk-ant-ok")
    }
  }

  /// A body past the limit is refused rather than buffered into a reading.
  @Test func aBodyPastTheLimitIsRefused() async throws {
    let transport = FixedTransport(
      status: 200, body: Data(repeating: 0x20, count: ProviderWebLimits.bodyLimit + 1))
    let collector = ClaudeWebCollector(transport: transport, clientVersion: "test")
    await #expect(throws: ProviderWebError(.error, ClaudeWebCollector.source)) {
      try await collector.validate(cookieHeader: "sessionKey=sk-ant-ok")
    }
  }

  /// An error carries a category and a rung, and never the cookie or the address that produced
  /// it — the same bound the service's `ProviderError` keeps.
  @Test func anErrorCarriesNoCredentialAndNoAddress() async throws {
    let transport = FixedTransport(status: 401, body: Data("ada@example.com".utf8))
    let collector = CodexWebCollector(transport: transport, clientVersion: "test")
    do {
      _ = try await collector.validate(
        cookieHeader: "__Secure-next-auth.session-token=super-secret")
      Issue.record("an expired session is not a validated session")
    } catch let error as ProviderWebError {
      #expect(error.category == .authRequired)
      #expect(error.source == CodexWebCollector.source)
      let described = "\(error)"
      #expect(!described.contains("super-secret"))
      #expect(!described.contains("ada@example.com"))
    }
  }

  /// The cookie names come from the catalog, so the two products never disagree about which
  /// cookie is a sign-in.
  @Test func theCatalogNamesEveryCookieThisLibraryReads() throws {
    #expect(ProviderID.claude.browserSession?.cookieNames == ["sessionKey", "lastActiveOrg"])
    #expect(ProviderID.grok.browserSession?.cookieNames == ["sso", "sso-rw"])
    let codex = try #require(ProviderID.codex.browserSession)
    #expect(codex.cookieNames.contains("__Secure-next-auth.session-token"))
    #expect(CodexWebCollector.hasChatGPTSessionCookie("__Secure-next-auth.session-token=abc"))
    // A context cookie on its own is not a sign-in.
    #expect(!CodexWebCollector.hasChatGPTSessionCookie("_account=acct"))
    #expect(ClaudeWebCollector.sessionKey("sessionKey=not-anthropic") == nil)
    #expect(GrokWebCollector.ssoToken("sessionKey=sk-ant-ok") == nil)
  }

  /// The label a reader sees names the account without showing it.
  @Test func anIdentityIsMaskedBeforeItIsReported() {
    #expect(ProviderWebIdentity.maskEmail("ada@example.com") == "ad***@example.com")
    #expect(ProviderWebIdentity.maskEmail("@example.com") == nil)
    #expect(ProviderWebIdentity.maskEmail("ada") == nil)
  }

  /// Two signed-in accounts are two accounts, and the same account on two devices is one: the
  /// fingerprint is the account's key, so it is the digest and never the id itself.
  @Test func aFingerprintNamesTheAccountWithoutCarryingIt() {
    let first = ProviderWebIdentity.accountIdentity(
      provider: "grok", namespace: "user_id", owner: "user-1")
    let second = ProviderWebIdentity.accountIdentity(
      provider: "grok", namespace: "user_id", owner: "user-2")
    #expect(first.fingerprint.count == 64)
    #expect(first.scope == .global)
    #expect(first.fingerprint != second.fingerprint)
    #expect(!first.fingerprint.contains("user-1"))
    let anonymous = ProviderWebIdentity.accountIdentity(
      provider: "grok", namespace: "user_id", owner: nil)
    #expect(anonymous.scope == .source)
  }
}

/// One answer, however many times it is asked for.
struct FixedTransport: ProviderWebTransport {
  let status: Int
  let body: Data

  func send(_ request: URLRequest) async throws -> ProviderWebResponse {
    ProviderWebResponse(status: status, body: body)
  }
}
