import Foundation
import QuotaPresentation
import Testing

/// Rust and Swift each fold local samples once, and this file is what neither may drift from.
struct QuotaHistoryConformanceTests {
  @Test func everyHistoryCaseMatchesTheSharedFixture() throws {
    let fixture = try HistoryFixture.load()
    #expect(fixture.cases.count >= 8)
    #expect(QuotaHistory.decimationSeconds == fixture.decimationSeconds)
    #expect(QuotaHistory.retentionDays == fixture.retentionDays)
    for testCase in fixture.cases {
      let folded = QuotaHistory.fold(
        window: QuotaHistoryReading(
          resetsAt: testCase.window.resetsAt,
          cadenceSeconds: testCase.window.durationSeconds
        ),
        samples: testCase.samples,
        now: testCase.now,
        utcOffsetSeconds: testCase.utcOffsetSeconds
      )
      guard let expected = testCase.expected else {
        #expect(folded == nil, "\(testCase.name)")
        continue
      }
      let history = try #require(folded, "\(testCase.name)")
      #expect(history.points.count == expected.points.count, "\(testCase.name)")
      for (point, want) in zip(history.points, expected.points) {
        #expect(abs(point.elapsedFraction - want.elapsedFraction) < 1e-6, "\(testCase.name)")
        #expect(abs(point.usedPercent - want.usedPercent) < 1e-6, "\(testCase.name)")
      }
      #expect((history.projection == nil) == (expected.projection == nil), "\(testCase.name)")
      if let projection = history.projection, let want = expected.projection {
        #expect(abs(projection.elapsedFraction - want.elapsedFraction) < 1e-6, "\(testCase.name)")
        #expect(abs(projection.usedPercent - want.usedPercent) < 1e-6, "\(testCase.name)")
      }
      #expect(history.windowsToday.count == expected.windowsToday.count, "\(testCase.name)")
      for (window, want) in zip(history.windowsToday, expected.windowsToday) {
        #expect(window.startedAt == want.startedAt, "\(testCase.name)")
        #expect(window.resetsAt == want.resetsAt, "\(testCase.name)")
        #expect(abs(window.peakUsedPercent - want.peakUsedPercent) < 1e-6, "\(testCase.name)")
        #expect(window.isCurrent == want.isCurrent, "\(testCase.name)")
      }
      if let peer = testCase.peer {
        let peerFolded = QuotaHistory.fold(
          window: QuotaHistoryReading(
            resetsAt: testCase.window.resetsAt,
            cadenceSeconds: testCase.window.durationSeconds
          ),
          samples: peer.samples,
          now: testCase.now,
          utcOffsetSeconds: testCase.utcOffsetSeconds
        )
        let peerHistory = try #require(peerFolded, "\(testCase.name) peer")
        #expect(peerHistory.points.map(\.usedPercent) != history.points.map(\.usedPercent))
        if let want = peer.expected {
          #expect(peerHistory.points.count == want.points.count, "\(testCase.name) peer")
          for (point, expectedPoint) in zip(peerHistory.points, want.points) {
            #expect(abs(point.usedPercent - expectedPoint.usedPercent) < 1e-6)
          }
        }
      }
    }
  }
}

private struct HistoryFixture: Decodable {
  var decimationSeconds: Double
  var retentionDays: Int
  var cases: [Case]

  struct Case: Decodable {
    var name: String
    var now: Date
    var utcOffsetSeconds: Int
    var window: Window
    var samples: [QuotaSample]
    var expected: Expected?
    var peer: Peer?
  }

  struct Peer: Decodable {
    var samples: [QuotaSample]
    var expected: Expected?
  }

  struct Window: Decodable {
    var resetsAt: Date?
    var durationSeconds: Int?
  }

  struct Expected: Decodable {
    var points: [QuotaHistoryPoint]
    var projection: QuotaHistoryPoint?
    var windowsToday: [QuotaHistoryWindow]
  }

  static func load() throws -> HistoryFixture {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(HistoryFixture.self, from: Data(contentsOf: fixtureURL))
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/quota-history-conformance.json")
}
