import Foundation
import QuotaRelay
import QuotaWire
import Testing
import os

@Suite(.serialized)
struct TransportTests {
  @Test
  func urlSessionStopsWhileReceivingBytesOverTheLimit() async throws {
    let url = URL(string: "https://quota.gotry.io/test/oversize-stream")!
    ScriptedURLProtocol.use(
      .init(body: Data(repeating: 0x61, count: 80), chunkSize: 8),
      for: url
    )
    let transport = URLSessionHTTPTransport(
      configuration: Self.stubbedConfiguration(),
      maximumResponseBytes: 32
    )
    await #expect(throws: HTTPTransportError.responseTooLarge) {
      _ = try await transport.perform(URLRequest(url: url))
    }
  }

  @Test
  func urlSessionRefusesContentLengthOverOneMebibyte() async throws {
    let url = URL(string: "https://quota.gotry.io/test/content-length")!
    ScriptedURLProtocol.use(
      .init(
        headers: ["Content-Length": String(WireCodec.maximumResponseBytes + 1)],
        body: Data(repeating: 0x61, count: 8)
      ),
      for: url
    )
    let transport = URLSessionHTTPTransport(configuration: Self.stubbedConfiguration())
    await #expect(throws: HTTPTransportError.responseTooLarge) {
      _ = try await transport.perform(URLRequest(url: url))
    }
  }

  @Test
  func urlSessionMapsTimeoutAndDoesNotCollapseTransportErrors() async throws {
    let url = URL(string: "https://quota.gotry.io/test/timeout")!
    ScriptedURLProtocol.use(.init(error: URLError(.timedOut)), for: url)
    let transport = URLSessionHTTPTransport(configuration: Self.stubbedConfiguration())
    await #expect(throws: HTTPTransportError.timeout) {
      _ = try await transport.perform(URLRequest(url: url))
    }
  }

  @Test
  func urlSessionRefusesRedirectsWithoutFollowing() async throws {
    let url = URL(string: "https://quota.gotry.io/test/redirect")!
    ScriptedURLProtocol.use(
      .init(status: 302, headers: ["Location": "https://evil.example/steal"]),
      for: url
    )
    let transport = URLSessionHTTPTransport(configuration: Self.stubbedConfiguration())
    await #expect(throws: HTTPTransportError.redirectRefused) {
      _ = try await transport.perform(URLRequest(url: url))
    }
  }

  @Test
  func relayClientPreservesTransportTooLargeAndTimeout() async throws {
    let summary = URL(string: "https://quota.gotry.io/api/v3/account/summary")!
    ScriptedURLProtocol.use(
      .init(
        body: Data(repeating: 0x61, count: WireCodec.maximumResponseBytes + 1),
        chunkSize: 4_096
      ),
      for: summary
    )
    let client = RelayClient(
      transport: URLSessionHTTPTransport(configuration: Self.stubbedConfiguration())
    )
    await #expect(throws: RelayClientError.responseTooLarge) {
      _ = try await client.fetchAccountSummary(
        from: "2026-08-14",
        to: "2026-08-14",
        accessToken: Fixtures.accessToken
      )
    }

    ScriptedURLProtocol.use(.init(error: URLError(.timedOut)), for: summary)
    let timeoutClient = RelayClient(
      transport: URLSessionHTTPTransport(configuration: Self.stubbedConfiguration())
    )
    await #expect(throws: RelayClientError.timeout) {
      _ = try await timeoutClient.fetchAccountSummary(
        from: "2026-08-14",
        to: "2026-08-14",
        accessToken: Fixtures.accessToken
      )
    }
  }

  private static func stubbedConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedURLProtocol.self]
    return configuration
  }
}

final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
  struct Script: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var chunkSize = 16
    var error: URLError?
  }

  private static let lock = OSAllocatedUnfairLock<[String: Script]>(initialState: [:])

  static func use(_ script: Script, for url: URL) {
    lock.withLock { $0[key(url)] = script }
  }

  private static func key(_ url: URL?) -> String {
    guard let url else { return "" }
    return "\(url.host ?? "")\(url.path)"
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let script = Self.lock.withLock { $0[Self.key(request.url)] }
    guard let script else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    if let error = script.error {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://quota.gotry.io")!,
      statusCode: script.status,
      httpVersion: "HTTP/1.1",
      headerFields: script.headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    var remaining = script.body
    let chunkSize = max(script.chunkSize, 1)
    while !remaining.isEmpty {
      let chunk = remaining.prefix(chunkSize)
      client?.urlProtocol(self, didLoad: Data(chunk))
      remaining = remaining.dropFirst(chunk.count)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
