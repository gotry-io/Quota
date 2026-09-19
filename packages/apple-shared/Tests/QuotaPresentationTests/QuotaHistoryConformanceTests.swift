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

  @Test func todayNamesEveryWindowTheDayHeldAndTheirPeaks() {
    let start = Date(timeIntervalSince1970: 1_788_000_000)
    let windows = [82.0, 40.0, 12.4].enumerated().map { index, peak in
      QuotaHistoryWindow(
        startedAt: start.addingTimeInterval(Double(index) * 18_000),
        resetsAt: start.addingTimeInterval(Double(index + 1) * 18_000),
        peakUsedPercent: peak,
        isCurrent: index == 2
      )
    }
    #expect(QuotaHistoryCopy.todayLine(windows) == "Today: 3 windows · 82% / 40% / 12%")
    #expect(QuotaHistoryCopy.todayLine([windows[0]]) == "Today: 1 window · 82%")
    #expect(QuotaHistoryCopy.todayLine([]) == nil)
  }

  /// Two providers and two window ids fold independently: a window never takes another
  /// window's samples, even when they share an observed_at.
  @Test func twoProvidersAndTwoWindowsFoldSeparately() throws {
    let now = Date(timeIntervalSince1970: 1_788_100_000)
    let fiveHourReset = now.addingTimeInterval(2 * 3_600)
    let weeklyReset = now.addingTimeInterval(3 * 86_400)
    let earlier = now.addingTimeInterval(-3_600)
    func fold(first: Double, last: Double, resetsAt: Date, cadence: Int) throws -> QuotaHistory {
      try #require(
        QuotaHistory.fold(
          window: QuotaHistoryReading(resetsAt: resetsAt, cadenceSeconds: cadence),
          samples: [
            QuotaSample(resetsAt: resetsAt, observedAt: earlier, usedPercent: first),
            QuotaSample(resetsAt: resetsAt, observedAt: now, usedPercent: last),
          ],
          now: now,
          utcOffsetSeconds: 0
        ))
    }
    let codexFiveHour = try fold(first: 10, last: 40, resetsAt: fiveHourReset, cadence: 18_000)
    let codexWeekly = try fold(first: 12, last: 20, resetsAt: weeklyReset, cadence: 604_800)
    let claudeFiveHour = try fold(first: 50, last: 60, resetsAt: fiveHourReset, cadence: 18_000)
    let claudeWeekly = try fold(first: 70, last: 80, resetsAt: weeklyReset, cadence: 604_800)
    #expect(codexFiveHour.points.map(\.usedPercent) == [10, 40])
    #expect(codexWeekly.points.map(\.usedPercent) == [12, 20])
    #expect(claudeFiveHour.points.map(\.usedPercent) == [50, 60])
    #expect(claudeWeekly.points.map(\.usedPercent) == [70, 80])
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
