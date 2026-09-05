import Foundation
import QuotaWire
import Testing

@testable import QuotaProviderWeb

/// The shared statement of what a stored browser session answers. The Rust collectors answer the
/// same file, so a rule one runtime starts reading differently fails here rather than resolving
/// one account into two subscriptions.
@Suite
struct ProviderWebConformanceTests {
  @Test func everyProviderAnswersTheSharedConformanceFixture() async throws {
    let fixture = try ProviderWebFixture.load()
    #expect(fixture.cases.count >= 12)
    for testCase in fixture.cases {
      let source = try #require(fixture.sources[testCase.provider])
      try await run(testCase, source: source)
    }
  }

  /// Each of the three providers is covered, and each is covered by more than its happy path.
  @Test func theFixtureCoversEveryProviderAndBothOutcomes() throws {
    let fixture = try ProviderWebFixture.load()
    for provider in ["codex", "claude", "grok"] {
      let cases = fixture.cases.filter { $0.provider == provider }
      #expect(cases.count >= 3, "\(provider)")
      #expect(cases.contains { $0.expectedSnapshot != nil }, "\(provider) success")
      #expect(cases.contains { $0.validationError != nil }, "\(provider) failure")
    }
  }

  private func run(_ testCase: ProviderWebFixture.Case, source: String) async throws {
    let validation = StubTransport(exchanges: testCase.exchanges)
    let collector = try Self.collector(for: testCase, transport: validation)
    do {
      let validated = try await collector.validate(cookieHeader: testCase.cookieHeader)
      #expect(validated == testCase.expectedValidation, "\(testCase.name)")
    } catch let error as ProviderWebError {
      #expect(error.category.rawValue == testCase.validationError, "\(testCase.name)")
      #expect(error.source == source, "\(testCase.name)")
    }
    try await validation.verify(name: testCase.name)

    let reading = StubTransport(exchanges: testCase.exchanges)
    let reader = try Self.collector(for: testCase, transport: reading)
    do {
      let snapshot = try await reader.collect(cookieHeader: testCase.cookieHeader)
      #expect(snapshot == testCase.expectedSnapshot, "\(testCase.name)")
    } catch let error as ProviderWebError {
      #expect(error.category.rawValue == testCase.snapshotError, "\(testCase.name)")
      #expect(error.source == source, "\(testCase.name)")
    }
    try await reading.verify(name: testCase.name)
  }

  private static func collector(
    for testCase: ProviderWebFixture.Case,
    transport: StubTransport
  ) throws -> any ProviderWebCollector {
    switch testCase.provider {
    case "codex":
      return CodexWebCollector(transport: transport, clientVersion: "test", now: testCase.now)
    case "claude":
      return ClaudeWebCollector(transport: transport, clientVersion: "test", now: testCase.now)
    case "grok":
      return GrokWebCollector(transport: transport, clientVersion: "test", now: testCase.now)
    default:
      throw ProviderWebFixture.Failure.unknownProvider(testCase.provider)
    }
  }
}

/// The provider, answering the fixture's queue and remembering what it was asked.
actor StubTransport: ProviderWebTransport {
  private let exchanges: [ProviderWebFixture.Exchange]
  private var served = 0
  private var mismatch: String?

  init(exchanges: [ProviderWebFixture.Exchange]) {
    self.exchanges = exchanges
  }

  func send(_ request: URLRequest) async throws -> ProviderWebResponse {
    guard served < exchanges.count else {
      mismatch = mismatch ?? "asked for more exchanges than the case declares"
      throw URLError(.badServerResponse)
    }
    let exchange = exchanges[served]
    served += 1
    let path = request.url?.path ?? ""
    let method = request.httpMethod ?? ""
    if path != exchange.path || method != exchange.method {
      mismatch = mismatch ?? "expected \(exchange.method) \(exchange.path), sent \(method) \(path)"
    }
    // A cookie is sent in the one header it belongs in, and nowhere else.
    if request.value(forHTTPHeaderField: "Authorization") != nil {
      mismatch = mismatch ?? "a stored session was spent as a bearer token"
    }
    return ProviderWebResponse(status: exchange.status, body: exchange.body)
  }

  func verify(name: String) throws {
    if let mismatch { throw ProviderWebFixture.Failure.request("\(name): \(mismatch)") }
  }
}

enum ProviderWebFixture {
  enum Failure: Error {
    case malformed(String)
    case unknownProvider(String)
    case request(String)
  }

  struct Exchange {
    let method: String
    let path: String
    let status: Int
    let body: Data
  }

  struct Case {
    let provider: String
    let name: String
    let now: Date
    let cookieHeader: String
    let exchanges: [Exchange]
    let expectedValidation: ValidatedBrowserSession?
    let validationError: String?
    let expectedSnapshot: QuotaSnapshot?
    let snapshotError: String?
  }

  struct Fixture {
    let sources: [String: String]
    let cases: [Case]
  }

  static func load() throws -> Fixture {
    let data = try Data(contentsOf: url)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sources = root["sources"] as? [String: String],
      let entries = root["cases"] as? [[String: Any]]
    else { throw Failure.malformed("provider-web-conformance.json") }
    return Fixture(sources: sources, cases: try entries.map(parse))
  }

  private static func parse(_ entry: [String: Any]) throws -> Case {
    guard let provider = entry["provider"] as? String,
      let name = entry["name"] as? String,
      let now = entry["now"] as? String,
      let nowDate = ProviderJSON.rfc3339(now).map({ Date(timeIntervalSince1970: Double($0)) }),
      let cookieHeader = entry["cookie_header"] as? String,
      let exchanges = entry["exchanges"] as? [[String: Any]],
      let expect = entry["expect"] as? [String: Any]
    else { throw Failure.malformed(entry["name"] as? String ?? "case") }
    let expectedValidation: ValidatedBrowserSession?
    let validationError: String?
    switch expect["validated"] {
    case let validated as [String: Any]:
      guard let fingerprint = validated["account_fingerprint"] as? String else {
        throw Failure.malformed(name)
      }
      expectedValidation = ValidatedBrowserSession(
        accountFingerprint: fingerprint,
        accountLabel: validated["account_label"] as? String
      )
      validationError = nil
    case let category as String:
      expectedValidation = nil
      validationError = category
    default:
      throw Failure.malformed(name)
    }
    let expectedSnapshot = try (expect["snapshot"] as? [String: Any]).map { payload in
      try WireCodec.decode(
        QuotaSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    return Case(
      provider: provider,
      name: name,
      now: nowDate,
      cookieHeader: cookieHeader,
      exchanges: try exchanges.map(parse),
      expectedValidation: expectedValidation,
      validationError: validationError,
      expectedSnapshot: expectedSnapshot,
      snapshotError: expect["snapshot_error"] as? String
    )
  }

  private static func parse(_ exchange: [String: Any]) throws -> Exchange {
    guard let method = exchange["method"] as? String,
      let path = exchange["path"] as? String,
      let status = exchange["status"] as? Int
    else { throw Failure.malformed("exchange") }
    let body: Data
    if let encoded = exchange["body_base64"] as? String {
      guard let decoded = Data(base64Encoded: encoded) else {
        throw Failure.malformed("exchange body")
      }
      body = decoded
    } else if let value = exchange["body"] {
      body = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    } else {
      throw Failure.malformed("exchange body")
    }
    return Exchange(method: method, path: path, status: status, body: body)
  }

  private static let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/provider-web-conformance.json")
}
