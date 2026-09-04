import Foundation
import QuotaAlerts
import Testing

struct AlertStateJSONTests {
  @Test func roundTripPreservesFiredKeysAndReadings() throws {
    let resetsAt = Date(timeIntervalSince1970: 1_773_576_000)
    let state = AlertDedupState(
      fired: [
        AlertDedupKey(
          selector: "codex_acct",
          windowID: "weekly",
          resetsAt: resetsAt,
          threshold: 20
        )
      ],
      readings: [
        AlertStoredReading(
          selector: "codex_acct",
          windowID: "weekly",
          remainingPercent: 18,
          resetsAt: resetsAt
        )
      ]
    )
    let data = try AlertStateJSON.encode(state)
    let loaded = try AlertStateJSON.decode(data)
    #expect(loaded.sorted() == state.sorted())
  }
}
