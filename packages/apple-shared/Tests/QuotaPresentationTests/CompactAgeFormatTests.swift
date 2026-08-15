import Foundation
import QuotaPresentation
import Testing

struct CompactAgeFormatTests {
  @Test(
    arguments: [
      (0.0, "0s"),
      (59.0, "59s"),
      (60.0, "1min"),
      (3_599.0, "59min"),
      (3_600.0, "1h"),
      (86_400.0, "1d"),
      (604_800.0, "1w"),
      (31_536_000.0, "1y"),
    ]
  )
  func formatsLargestUsefulWholeUnit(age: TimeInterval, expected: String) {
    let now = Date(timeIntervalSince1970: 31_536_000)
    #expect(CompactAgeFormat.string(since: now.addingTimeInterval(-age), now: now) == expected)
  }
}
