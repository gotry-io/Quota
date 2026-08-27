import Foundation
import Testing

@testable import QuotaBar

/// The zod schema is the definition; QuotaBar restates the Usage upload contract for its
/// own trust boundary. Both answer the same file, so a payload one starts accepting cannot
/// pass unnoticed.
@Test
func usageSubmissionMatchesTheSharedConformanceFixture() throws {
  let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("packages/protocol/fixtures/wire-conformance.json")
  let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
  let contracts = root["contracts"] as! [String: Any]
  let cases = contracts["usage_submission"] as! [[String: Any]]
  #expect(cases.count > 1)

  for testCase in cases {
    let name = testCase["name"] as! String
    let accepted = testCase["accepted"] as! Bool
    let data = try JSONSerialization.data(withJSONObject: testCase["payload"] as! [String: Any])
    let decoded =
      (try? QuotaWireCodec.makeDecoder().decode(UsageUpload.self, from: data)) != nil
    #expect(decoded == accepted, "\(name)")
  }
}
