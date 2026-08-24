import Foundation
import Testing

@testable import QuotaWire

/// The zod schema is the definition; this package restates it for its own trust boundary.
/// Both answer the same file, so a payload one starts accepting cannot pass unnoticed.
@Suite
struct WireConformanceTests {
  @Test func accountSummaryMatchesTheSharedConformanceFixture() throws {
    let cases = try WireConformanceFixture.cases(for: "account_summary")
    #expect(cases.count > 1)
    for testCase in cases {
      let data = try JSONSerialization.data(withJSONObject: testCase.payload)
      let decoded = (try? WireCodec.decode(AccountSummary.self, from: data)) != nil
      #expect(decoded == testCase.accepted, "\(testCase.name)")
    }
  }
}

enum WireConformanceFixture {
  struct Case {
    let name: String
    let accepted: Bool
    let payload: [String: Any]
  }

  static func cases(for contract: String) throws -> [Case] {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
    let contracts = root["contracts"] as! [String: Any]
    let entries = contracts[contract] as! [[String: Any]]
    return entries.map {
      Case(
        name: $0["name"] as! String,
        accepted: $0["accepted"] as! Bool,
        payload: $0["payload"] as! [String: Any]
      )
    }
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/wire-conformance.json")
}
