import Foundation
import QuotaWire
import Testing

/// Round-trip of the bodies `apps/relay/test/quota-history.test.ts` sends and answers, through
/// `WireCodec`. The README sketch is the same fields; these are the complete documents.
struct QuotaHistoryWireTests {
  @Test func uploadBodyRoundTripsTheRelayFixture() throws {
    let upload = try WireCodec.decode(QuotaHistoryUploadRequest.self, from: Data(uploadBody.utf8))
    #expect(upload.protocolVersion == 6)
    #expect(upload.generation == 1)
    let series = try #require(upload.series.first)
    #expect(series.provider == .codex)
    #expect(series.fingerprint == "account_test")
    #expect(series.windowId == "five_hour")
    #expect(series.durationSeconds == 18_000)
    #expect(series.points.map(\.usedPercent) == [40, 42.5])
    try expectSameJSON(uploadBody, WireCodec.encodeRequest(upload))
  }

  @Test func uploadAnswerRoundTripsTheRelayFixture() throws {
    let answer = try WireCodec.decode(
      QuotaHistoryUploadResponse.self,
      from: Data(uploadAnswer.utf8)
    )
    #expect(answer.protocolVersion == 6)
    let series = try #require(answer.series.first)
    #expect(series.provider == .codex)
    #expect(series.fingerprint == "account_test")
    #expect(series.windowId == "five_hour")
    #expect(series.newestBucketStart == instant("2026-09-21T10:15:00Z"))
    try expectSameJSON(uploadAnswer, WireCodec.encodeRequest(answer))
  }

  @Test func readAnswerRoundTripsTheRelayFixture() throws {
    let read = try WireCodec.decode(QuotaHistoryReadResponse.self, from: Data(readAnswer.utf8))
    #expect(read.protocolVersion == 6)
    #expect(read.sync)
    let window = try #require(read.windows["five_hour"])
    #expect(window.durationSeconds == 18_000)
    #expect(window.points.map(\.usedPercent) == [50, 55])
    #expect(window.points.map(\.bucketStart) == [
      instant("2026-09-21T10:00:00Z"),
      instant("2026-09-21T10:15:00Z"),
    ])
    try expectSameJSON(readAnswer, WireCodec.encodeRequest(read))
  }

  @Test func readAnswerWhileSyncIsOffRoundTrips() throws {
    let read = try WireCodec.decode(QuotaHistoryReadResponse.self, from: Data(syncOff.utf8))
    #expect(read.sync == false)
    #expect(read.windows.isEmpty)
    try expectSameJSON(syncOff, WireCodec.encodeRequest(read))
  }

  @Test func anUploadRefusesAKeyTheContractDoesNotName() throws {
    var object = try jsonObject(uploadBody)
    object["note"] = "no"
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try WireCodec.decode(QuotaHistoryUploadRequest.self, from: data)
    }
  }

  @Test func anUploadRefusesAnUnalignedBucketStart() throws {
    var object = try jsonObject(uploadBody)
    var series = try #require(object["series"] as? [[String: Any]])
    var points = try #require(series[0]["points"] as? [[String: Any]])
    points[0]["bucket_start"] = "2026-09-21T10:00:01Z"
    series[0]["points"] = points
    object["series"] = series
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try WireCodec.decode(QuotaHistoryUploadRequest.self, from: data)
    }
  }

  @Test func aReadIgnoresAKeyThisBuildDoesNotName() throws {
    var object = try jsonObject(syncOff)
    object["note"] = "ignored"
    let data = try JSONSerialization.data(withJSONObject: object)
    let read = try WireCodec.decode(QuotaHistoryReadResponse.self, from: data)
    #expect(read.sync == false)
    #expect(read.windows.isEmpty)
    try expectSameJSON(syncOff, WireCodec.encodeRequest(read))
  }
}

private let uploadBody = """
  {
    "protocol_version": 6,
    "generation": 1,
    "series": [
      {
        "provider": "codex",
        "fingerprint": "account_test",
        "window_id": "five_hour",
        "duration_seconds": 18000,
        "points": [
          {
            "resets_at": "2026-09-21T15:00:00Z",
            "bucket_start": "2026-09-21T10:00:00Z",
            "used_percent": 40
          },
          {
            "resets_at": "2026-09-21T15:00:00Z",
            "bucket_start": "2026-09-21T10:15:00Z",
            "used_percent": 42.5
          }
        ]
      }
    ]
  }
  """

private let uploadAnswer = """
  {
    "protocol_version": 6,
    "series": [
      {
        "provider": "codex",
        "fingerprint": "account_test",
        "window_id": "five_hour",
        "bucket_start": "2026-09-21T10:15:00Z"
      }
    ]
  }
  """

private let readAnswer = """
  {
    "protocol_version": 6,
    "sync": true,
    "windows": {
      "five_hour": {
        "duration_seconds": 18000,
        "points": [
          {
            "resets_at": "2026-09-21T15:00:00Z",
            "bucket_start": "2026-09-21T10:00:00Z",
            "used_percent": 50
          },
          {
            "resets_at": "2026-09-21T15:00:00Z",
            "bucket_start": "2026-09-21T10:15:00Z",
            "used_percent": 55
          }
        ]
      }
    }
  }
  """

private let syncOff = """
  {
    "protocol_version": 6,
    "sync": false,
    "windows": {}
  }
  """

private func expectSameJSON(_ original: String, _ encoded: Data) throws {
  let left = try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary
  let right = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
  #expect(left == right)
}

private func jsonObject(_ text: String) throws -> [String: Any] {
  let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
  return try #require(object as? [String: Any])
}

private func instant(_ wire: String) -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  guard let date = formatter.date(from: wire) else {
    preconditionFailure("not an instant: \(wire)")
  }
  return date
}
