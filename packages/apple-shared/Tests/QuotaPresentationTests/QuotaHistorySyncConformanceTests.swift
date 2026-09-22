import Foundation
import QuotaPresentation
import Testing

/// TypeScript and Swift answer `quota-history-sync-conformance.json`. A case one runtime changes
/// cannot quietly drift from the other.
struct QuotaHistorySyncConformanceTests {
  @Test func everyBucketCaseMatchesTheSharedFixture() throws {
    let fixture = try QuotaHistorySyncFixture.load()
    #expect(fixture.bucket.count >= 6)
    #expect(fixture.shortWindowBucketSeconds == 900)
    #expect(fixture.longWindowBucketSeconds == 3_600)
    #expect(fixture.shortWindowMaxDurationSeconds == 86_400)
    #expect(fixture.spanMinSeconds == 48 * 3_600)
    #expect(fixture.spanMaxSeconds == 30 * 86_400)
    #expect(fixture.spanDurationMultiple == 4)
    #expect(fixture.retentionDays == 30)
    #expect(fixture.retentionDays == QuotaHistory.retentionDays)
    #expect(QuotaHistorySync.bucketSeconds(durationSeconds: 86_400) == 900)
    #expect(QuotaHistorySync.bucketSeconds(durationSeconds: 86_401) == 3_600)
    #expect(QuotaHistorySync.spanSeconds(durationSeconds: 18_000) == 48 * 3_600)
    #expect(QuotaHistorySync.spanSeconds(durationSeconds: 604_800) == 28 * 86_400)
    #expect(QuotaHistorySync.spanSeconds(durationSeconds: 2_592_000) == 30 * 86_400)
    for testCase in fixture.bucket {
      guard let duration = testCase.durationSeconds else {
        // `bucket` takes a non-optional duration and returns the points, so a missing duration
        // is not a call. The fixture still records that case as a refusal.
        #expect(testCase.refused, "\(testCase.name)")
        continue
      }
      let points = QuotaHistorySync.bucket(
        samples: testCase.samples,
        durationSeconds: duration,
        now: testCase.now,
        lastUploaded: testCase.previous
      )
      #expect(testCase.refused == false, "\(testCase.name)")
      #expect(points == testCase.expected, "\(testCase.name)")
    }
  }

  @Test func everyMergeCaseMatchesTheSharedFixture() throws {
    let fixture = try QuotaHistorySyncFixture.load()
    #expect(fixture.merge.count >= 2)
    for testCase in fixture.merge {
      let merged = QuotaHistorySync.merge(testCase.devices)
      #expect(merged == testCase.buckets, "\(testCase.name)")
    }
  }

  @Test func sourceCaptionNamesThisDeviceOrYourDevices() {
    #expect(QuotaHistoryCopy.sourceCaption(.thisDevice, deviceNoun: "This iPhone") == "This iPhone")
    #expect(QuotaHistoryCopy.sourceCaption(.thisDevice, deviceNoun: "This Mac") == "This Mac")
    #expect(
      QuotaHistoryCopy.sourceCaption(.yourDevices, deviceNoun: "This iPhone") == "From your devices"
    )
  }

  @Test func mergedBucketsAreTheSamplesFoldAlreadyTakes() throws {
    let now = try QuotaHistorySyncFixture.instant("2026-09-21T12:00:00Z")
    let reset = try QuotaHistorySyncFixture.instant("2026-09-21T15:00:00Z")
    let buckets = [
      QuotaHistorySync.Bucket(
        resetsAt: reset,
        bucketStart: try QuotaHistorySyncFixture.instant("2026-09-21T10:00:00Z"),
        usedPercent: 40
      ),
      QuotaHistorySync.Bucket(
        resetsAt: reset,
        bucketStart: try QuotaHistorySyncFixture.instant("2026-09-21T10:15:00Z"),
        usedPercent: 42.5
      ),
    ]
    let samples = QuotaHistorySync.samples(from: buckets)
    #expect(samples.map(\.resetsAt) == buckets.map(\.resetsAt))
    #expect(samples.map(\.observedAt) == buckets.map(\.bucketStart))
    #expect(samples.map(\.usedPercent) == buckets.map(\.usedPercent))
    let window = QuotaHistoryReading(resetsAt: reset, cadenceSeconds: 18_000)
    let folded = QuotaRemainingHistory.fold(
      window: window,
      samples: samples,
      usedPercent: 42.5,
      now: now
    )
    #expect(folded != nil)
  }
}

private struct QuotaHistorySyncFixture {
  let bucket: [BucketCase]
  let merge: [MergeCase]
  let shortWindowBucketSeconds: Int
  let longWindowBucketSeconds: Int
  let shortWindowMaxDurationSeconds: Int
  let spanMinSeconds: Int
  let spanMaxSeconds: Int
  let spanDurationMultiple: Int
  let retentionDays: Int

  struct BucketCase {
    let name: String
    let now: Date
    let durationSeconds: Int?
    let samples: [QuotaSample]
    let previous: [QuotaHistorySync.Bucket]
    let expected: [QuotaHistorySync.Bucket]
    let refused: Bool
  }

  /// `window_id` is not on ``QuotaHistorySync/Bucket``. These cases do not collide across windows,
  /// so maximum-per-`(resetsAt, bucketStart)` still matches the fixture.
  struct MergeCase {
    let name: String
    let devices: [[QuotaHistorySync.Bucket]]
    let buckets: [QuotaHistorySync.Bucket]
  }

  static func load() throws -> QuotaHistorySyncFixture {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let object = try #require(root)
    let now = try instant(object["now"])
    let bucket = try (object["bucket"] as? [[String: Any]] ?? []).map { testCase in
      try bucketCase(testCase, defaultNow: now)
    }
    let merge = try (object["merge"] as? [[String: Any]] ?? []).map { testCase in
      try mergeCase(testCase)
    }
    return QuotaHistorySyncFixture(
      bucket: bucket,
      merge: merge,
      shortWindowBucketSeconds: try integer(object["short_window_bucket_seconds"]),
      longWindowBucketSeconds: try integer(object["long_window_bucket_seconds"]),
      shortWindowMaxDurationSeconds: try integer(object["short_window_max_duration_seconds"]),
      spanMinSeconds: try integer(object["span_min_seconds"]),
      spanMaxSeconds: try integer(object["span_max_seconds"]),
      spanDurationMultiple: try integer(object["span_duration_multiple"]),
      retentionDays: try integer(object["retention_days"])
    )
  }

  static func instant(_ value: Any?) throws -> Date {
    let wire = try #require(value as? String)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: wire) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return try #require(plain.date(from: wire), "not an instant: \(wire)")
  }

  private static func bucketCase(
    _ testCase: [String: Any],
    defaultNow: Date
  ) throws -> BucketCase {
    let name = try #require(testCase["name"] as? String)
    let now = testCase["now"] == nil ? defaultNow : try instant(testCase["now"])
    let duration = try optionalInteger(testCase["duration_seconds"])
    let samples = try rows(testCase["samples"]).map { sample in
      QuotaSample(
        resetsAt: try instant(sample["resets_at"]),
        observedAt: try instant(sample["observed_at"]),
        usedPercent: try number(sample["used_percent"])
      )
    }
    let previous = try buckets(testCase["previous"])
    if let refusal = testCase["expected"] as? [String: Any] {
      let refused = try #require(refusal["refused"] as? Bool)
      return BucketCase(
        name: name,
        now: now,
        durationSeconds: duration,
        samples: samples,
        previous: previous,
        expected: [],
        refused: refused
      )
    }
    return BucketCase(
      name: name,
      now: now,
      durationSeconds: duration,
      samples: samples,
      previous: previous,
      expected: try buckets(testCase["expected"]),
      refused: false
    )
  }

  private static func mergeCase(_ testCase: [String: Any]) throws -> MergeCase {
    let name = try #require(testCase["name"] as? String)
    let groups = try #require(testCase["devices"] as? [Any])
    let devices = try groups.map { group in
      try buckets(group)
    }
    return MergeCase(name: name, devices: devices, buckets: try buckets(testCase["expected"]))
  }

  private static func buckets(_ value: Any?) throws -> [QuotaHistorySync.Bucket] {
    try rows(value).map { point in
      QuotaHistorySync.Bucket(
        resetsAt: try instant(point["resets_at"]),
        bucketStart: try instant(point["bucket_start"]),
        usedPercent: try number(point["used_percent"])
      )
    }
  }

  private static func rows(_ value: Any?) throws -> [[String: Any]] {
    try #require(value as? [[String: Any]])
  }

  private static func integer(_ value: Any?) throws -> Int {
    let number = try #require(value as? NSNumber)
    return number.intValue
  }

  private static func optionalInteger(_ value: Any?) throws -> Int? {
    if value == nil || value is NSNull { return nil }
    let number = try #require(value as? NSNumber)
    return number.intValue
  }

  private static func number(_ value: Any?) throws -> Double {
    try #require(value as? NSNumber).doubleValue
  }

  private static let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/quota-history-sync-conformance.json")
}
