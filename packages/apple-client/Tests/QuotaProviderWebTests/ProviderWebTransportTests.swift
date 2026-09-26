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

/// The bound the real `URLSession` transport promised: counted while reading, cancelled as
/// soon as it is crossed, and never a hop. Waits are for the protocol's own events; the time
/// limit only bounds a wait that never ends.
@Suite(.serialized, .timeLimit(.minutes(1)))
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
    await ProviderWebScriptedURLProtocol.waitUntilCancelled(for: url)
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
    await ProviderWebScriptedURLProtocol.waitUntilCancelled(for: url)
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

  /// A 429 is still "unavailable", and it carries the wait the provider named so the phone's
  /// backoff can honour it. A value that is not whole seconds names no wait.
  @Test func aRateLimitCarriesTheRetryAfterItWasSent() async throws {
    let url = URL(string: "https://provider-web.test/limited")!
    let transport = URLSessionProviderWebTransport(configuration: Self.stubbedConfiguration())
    let http = ProviderWebHTTP(transport: transport, userAgent: "Quota/test")
    for (header, seconds) in [("120", 120 as Int?), ("Wed, 21 Oct 2026 07:28:00 GMT", nil)] {
      ProviderWebScriptedURLProtocol.use(
        .init(status: 429, headers: ["Retry-After": header]), for: url)
      await #expect(
        throws: ProviderWebError(
          .unavailable, "claude_web_usage_api",
          rateLimit: ProviderRateLimit(retryAfterSeconds: seconds))
      ) {
        _ = try await http.getJSONSession(
          url, headers: [], timeout: ProviderWebLimits.validationTimeout,
          source: "claude_web_usage_api")
      }
    }
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
    await ProviderWebScriptedURLProtocol.waitUntilRequested(url)
    sendTask.cancel()
    do {
      _ = try await sendTask.value
      Issue.record("a cancelled caller must not produce a body")
    } catch let error as URLError {
      // A stalled body otherwise ends in the request's own timeout.
      #expect(error.code == .cancelled)
    }
    await ProviderWebScriptedURLProtocol.waitUntilCancelled(for: url)
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
    var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var cancelWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
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

  /// Returns once loading of `url` has been stopped.
  static func waitUntilCancelled(for url: URL) async {
    let key = key(url)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let now = lock.withLock { state -> Bool in
        if state.cancelled.contains(key) { return true }
        state.cancelWaiters[key, default: []].append(continuation)
        return false
      }
      if now { continuation.resume() }
    }
  }

  /// Returns once a request for `url` has started loading.
  static func waitUntilRequested(_ url: URL) async {
    let key = key(url)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let now = lock.withLock { state -> Bool in
        if state.requested.contains(key) { return true }
        state.requestWaiters[key, default: []].append(continuation)
        return false
      }
      if now { continuation.resume() }
    }
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
    let requestWaiters = Self.lock.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.requested.insert(key)
      state.cancelled.remove(key)
      state.finished.remove(key)
      state.bytesDelivered[key] = 0
      return state.requestWaiters.removeValue(forKey: key) ?? []
    }
    requestWaiters.forEach { $0.resume() }
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
    let key = Self.key(request.url)
    let cancelWaiters = Self.lock.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.cancelled.insert(key)
      return state.cancelWaiters.removeValue(forKey: key) ?? []
    }
    cancelWaiters.forEach { $0.resume() }
  }
}
