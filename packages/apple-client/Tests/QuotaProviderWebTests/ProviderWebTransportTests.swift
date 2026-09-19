import Foundation
import QuotaWire
import Testing
import os

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

/// One answer, however many times it is asked for. An oversized canned body is the same
/// refusal the real session throws, so HTTP still maps it to `.error`.
struct FixedTransport: ProviderWebTransport {
  let status: Int
  let body: Data

  func send(_ request: URLRequest) async throws -> ProviderWebResponse {
    if body.count > ProviderWebLimits.bodyLimit {
      throw ProviderWebTransportError.bodyTooLarge
    }
    return ProviderWebResponse(status: status, body: body)
  }
}

/// The bound the real `URLSession` transport promised: counted while reading, cancelled as
/// soon as it is crossed, and never a hop.
@Suite(.serialized)
struct URLSessionProviderWebTransportBoundaryTests {
  @Test func aChunkedBodyOverTheLimitIsRefusedAndCancelled() async throws {
    let url = URL(string: "https://provider-web.test/chunked")!
    let limit = 64
    ProviderWebScriptedURLProtocol.use(
      .init(body: Data(repeating: 0x61, count: limit + 32), chunkSize: 8),
      for: url
    )
    let transport = URLSessionProviderWebTransport(
      configuration: Self.stubbedConfiguration(),
      bodyLimit: limit
    )
    await #expect(throws: ProviderWebTransportError.bodyTooLarge) {
      _ = try await transport.send(URLRequest(url: url))
    }
    #expect(await ProviderWebScriptedURLProtocol.waitUntilCancelled(for: url))
    #expect(ProviderWebScriptedURLProtocol.bytesDelivered(for: url) > limit)

    ProviderWebScriptedURLProtocol.use(
      .init(body: Data(repeating: 0x61, count: limit + 32), chunkSize: 8),
      for: url
    )
    let http = ProviderWebHTTP(transport: transport, userAgent: "Quota/test")
    await #expect(throws: ProviderWebError(.error, "claude_web_usage_api")) {
      _ = try await http.getJSONSession(
        url, headers: [], timeout: ProviderWebLimits.validationTimeout,
        source: "claude_web_usage_api")
    }
    #expect(await ProviderWebScriptedURLProtocol.waitUntilCancelled(for: url))
  }

  @Test func aDeclaredLengthOverTheLimitIsRefusedBeforeReading() async throws {
    let url = URL(string: "https://provider-web.test/content-length")!
    ProviderWebScriptedURLProtocol.use(
      .init(
        headers: ["Content-Length": String(ProviderWebLimits.bodyLimit + 1)],
        body: Data(repeating: 0x61, count: 8),
        sendBody: false
      ),
      for: url
    )
    let transport = URLSessionProviderWebTransport(configuration: Self.stubbedConfiguration())
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    await #expect(throws: ProviderWebTransportError.bodyTooLarge) {
      _ = try await transport.send(request)
    }
    #expect(ProviderWebScriptedURLProtocol.cancelled(for: url))
    #expect(ProviderWebScriptedURLProtocol.bytesDelivered(for: url) == 0)
  }

  @Test func aBodyExactlyAtTheLimitIsAccepted() async throws {
    let url = URL(string: "https://provider-web.test/exact")!
    let body = Data(repeating: 0x61, count: ProviderWebLimits.bodyLimit)
    ProviderWebScriptedURLProtocol.use(.init(body: body, chunkSize: 65_536), for: url)
    let transport = URLSessionProviderWebTransport(configuration: Self.stubbedConfiguration())
    let response = try await transport.send(URLRequest(url: url))
    #expect(response.status == 200)
    #expect(response.body.count == ProviderWebLimits.bodyLimit)
  }

  @Test func aRedirectIsReturnedAndNeverFollowed() async throws {
    let url = URL(string: "https://provider-web.test/redirect")!
    let location = URL(string: "https://evil.example/steal")!
    ProviderWebScriptedURLProtocol.use(
      .init(status: 302, headers: ["Location": location.absoluteString]),
      for: url
    )
    let transport = URLSessionProviderWebTransport(configuration: Self.stubbedConfiguration())
    let response = try await transport.send(URLRequest(url: url))
    #expect(response.status == 302)
    #expect(!ProviderWebScriptedURLProtocol.requested(location))

    let http = ProviderWebHTTP(transport: transport, userAgent: "Quota/test")
    await #expect(throws: ProviderWebError(.authRequired, "claude_web_usage_api")) {
      _ = try await http.getJSONSession(
        url, headers: [], timeout: ProviderWebLimits.validationTimeout,
        source: "claude_web_usage_api")
    }
    #expect(!ProviderWebScriptedURLProtocol.requested(location))
  }

  @Test func aTimeoutStillMapsToUnavailable() async throws {
    let url = URL(string: "https://provider-web.test/timeout")!
    ProviderWebScriptedURLProtocol.use(.init(error: URLError(.timedOut)), for: url)
    let http = ProviderWebHTTP(
      transport: URLSessionProviderWebTransport(configuration: Self.stubbedConfiguration()),
      userAgent: "Quota/test"
    )
    await #expect(throws: ProviderWebError(.unavailable, "claude_web_usage_api")) {
      _ = try await http.getJSONSession(
        url, headers: [], timeout: ProviderWebLimits.validationTimeout,
        source: "claude_web_usage_api")
    }
  }

  @Test func aCancelledCallerCancelsTheTask() async throws {
    let url = URL(string: "https://provider-web.test/stall")!
    ProviderWebScriptedURLProtocol.use(.init(stallAfterHeaders: true), for: url)
    let transport = URLSessionProviderWebTransport(configuration: Self.stubbedConfiguration())
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    let sendTask = Task {
      try await transport.send(request)
    }
    let started = Date()
    while !ProviderWebScriptedURLProtocol.requested(url)
      && Date().timeIntervalSince(started) < 1
    {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    sendTask.cancel()
    let cancelledAt = Date()
    do {
      _ = try await sendTask.value
      Issue.record("a cancelled caller must not produce a body")
    } catch {
      #expect(Date().timeIntervalSince(cancelledAt) < 1)
    }
    #expect(await ProviderWebScriptedURLProtocol.waitUntilCancelled(for: url))
  }

  private static func stubbedConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderWebScriptedURLProtocol.self]
    return configuration
  }
}

final class ProviderWebScriptedURLProtocol: URLProtocol, @unchecked Sendable {
  struct Script: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var chunkSize = 16
    var error: URLError?
    var sendBody = true
    var stallAfterHeaders = false
  }

  private struct State: Sendable {
    var scripts: [String: Script] = [:]
    var cancelled: Set<String> = []
    var finished: Set<String> = []
    var bytesDelivered: [String: Int] = [:]
    var requested: Set<String> = []
  }

  private static let lock = OSAllocatedUnfairLock<State>(initialState: State())

  static func use(_ script: Script, for url: URL) {
    let key = key(url)
    lock.withLock { state in
      state.scripts[key] = script
      state.cancelled.remove(key)
      state.finished.remove(key)
      state.bytesDelivered[key] = 0
      state.requested.remove(key)
    }
  }

  static func cancelled(for url: URL) -> Bool {
    lock.withLock { $0.cancelled.contains(key(url)) }
  }

  static func waitUntilCancelled(for url: URL, timeout: TimeInterval = 1) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if cancelled(for: url) { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return cancelled(for: url)
  }

  static func bytesDelivered(for url: URL) -> Int {
    lock.withLock { $0.bytesDelivered[key(url)] ?? 0 }
  }

  static func requested(_ url: URL) -> Bool {
    lock.withLock { $0.requested.contains(key(url)) }
  }

  private static func key(_ url: URL?) -> String {
    guard let url else { return "" }
    return "\(url.host ?? "")\(url.path)"
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let key = Self.key(request.url)
    Self.lock.withLock { state in
      state.requested.insert(key)
      state.cancelled.remove(key)
      state.finished.remove(key)
      state.bytesDelivered[key] = 0
    }
    let script = Self.lock.withLock { $0.scripts[key] }
    guard let script else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    if let error = script.error {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://provider-web.test")!,
      statusCode: script.status,
      httpVersion: "HTTP/1.1",
      headerFields: script.headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if script.stallAfterHeaders { return }
    guard script.sendBody else {
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    var remaining = script.body
    let chunkSize = max(script.chunkSize, 1)
    while !remaining.isEmpty {
      if Self.lock.withLock({ $0.cancelled.contains(key) }) { return }
      let chunk = remaining.prefix(chunkSize)
      client?.urlProtocol(self, didLoad: Data(chunk))
      Self.lock.withLock { state in
        state.bytesDelivered[key, default: 0] += chunk.count
      }
      remaining = remaining.dropFirst(chunk.count)
    }
    let shouldFinish = Self.lock.withLock { state -> Bool in
      if state.cancelled.contains(key) { return false }
      state.finished.insert(key)
      return true
    }
    if shouldFinish {
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    Self.lock.withLock { state in
      state.cancelled.insert(Self.key(request.url))
      return
    }
  }
}
