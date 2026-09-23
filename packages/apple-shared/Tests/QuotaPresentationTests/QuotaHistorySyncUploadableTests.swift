import Foundation
import QuotaPresentation
import Testing

struct QuotaHistorySyncUploadableTests {
  @Test func uploadableDropsPointsRelayWouldRefuse() throws {
    let now = try instant("2026-09-21T10:00:00Z")
    let reset = try instant("2026-09-21T15:00:00Z")
    func point(_ wire: String, _ usedPercent: Double) throws -> QuotaHistorySync.Bucket {
      QuotaHistorySync.Bucket(
        resetsAt: reset,
        bucketStart: try instant(wire),
        usedPercent: usedPercent
      )
    }
    let kept = try QuotaHistorySync.uploadable(
      [
        point("2026-09-19T09:30:00Z", 1),
        point("2026-09-19T09:45:00Z", 2),
        point("2026-09-21T10:00:00Z", 3),
        point("2026-09-21T10:15:00Z", 4),
        point("2026-09-21T10:30:00Z", 5),
      ],
      durationSeconds: 18_000,
      now: now
    )
    #expect(kept.map(\.usedPercent) == [2, 3, 4])
  }

  @Test func relayLostRowsOnlyWhileTheRecordedOldestIsLive() throws {
    let now = try instant("2026-09-23T12:00:00Z")
    let recorded = try instant("2026-09-23T08:00:00Z")
    func lost(_ recorded: Date?, _ answer: QuotaHistorySync.UploadAnswer) -> Bool {
      QuotaHistorySync.rowsLost(
        recordedOldest: recorded,
        answer: answer,
        durationSeconds: 18_000,
        now: now
      )
    }
    #expect(lost(recorded, .oldest(try instant("2026-09-23T11:45:00Z"))))
    #expect(!lost(recorded, .oldest(recorded)))
    #expect(!lost(recorded, .oldest(try instant("2026-09-22T08:00:00Z"))))
    #expect(lost(recorded, .absent))
    #expect(!lost(recorded, .oldest(nil)))
    #expect(!lost(nil, .oldest(try instant("2026-09-23T11:45:00Z"))))
    #expect(!lost(try instant("2026-09-21T12:30:00Z"), .oldest(try instant("2026-09-23T11:45:00Z"))))
    #expect(
      QuotaHistorySync.oldestIsLive(
        try instant("2026-09-21T13:15:00Z"), durationSeconds: 18_000, now: now))
    #expect(
      !QuotaHistorySync.oldestIsLive(
        try instant("2026-09-21T12:45:00Z"), durationSeconds: 18_000, now: now))
  }
}

private func instant(_ wire: String) throws -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  return try #require(formatter.date(from: wire))
}
