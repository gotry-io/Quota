import Foundation
import Testing

@testable import QuotaBar

@MainActor
@Suite
struct RefreshLoopTests {
  @Test
  func refreshesImmediatelyRetriesPushAfterFailureAndIsIdempotent() async throws {
    let collector = LocalCollectionRecorder()
    let recorder = RelayPushRecorder(failsFirstPush: true)
    let sleeper = RefreshSleepSequence()
    let model = MenuBarViewModel(
      collector: collector,
      relayPusher: RecordingRelayPusher(recorder: recorder, hasRelayCredential: true),
      reportCache: nil,
      refreshInterval: .seconds(300),
      refreshSleep: { duration in
        try await sleeper.sleep(duration)
      }
    )

    model.startRefreshLoop()
    model.startRefreshLoop()
    try await waitUntil { await recorder.count >= 2 }

    #expect(await collector.count == 2)
    #expect(model.report?.capturedAt == Date(timeIntervalSince1970: 2))
    #expect(await recorder.count == 2)
    #expect(await sleeper.intervals == [.seconds(300), .seconds(300)])
  }

  @Test
  func refreshesLocalQuotaButSkipsPushWhileUnpaired() async throws {
    let collector = LocalCollectionRecorder()
    let recorder = RelayPushRecorder(failsFirstPush: false)
    let sleeper = RefreshSleepSequence()
    let model = MenuBarViewModel(
      collector: collector,
      relayPusher: RecordingRelayPusher(recorder: recorder, hasRelayCredential: false),
      reportCache: nil,
      refreshInterval: .seconds(300),
      refreshSleep: { duration in
        try await sleeper.sleep(duration)
      }
    )

    model.startRefreshLoop()
    try await waitUntil { await sleeper.intervals.count >= 2 }

    #expect(await collector.count == 2)
    #expect(await recorder.count == 0)
  }

  @Test
  func skipsPushWhileAnotherRefreshIsCollecting() async throws {
    let collector = SlowLocalCollector()
    let recorder = RelayPushRecorder(failsFirstPush: false)
    let sleeper = RefreshSleepSequence()
    let model = MenuBarViewModel(
      collector: collector,
      relayPusher: RecordingRelayPusher(recorder: recorder, hasRelayCredential: true),
      reportCache: nil,
      refreshInterval: .seconds(300),
      refreshSleep: { duration in
        try await sleeper.sleep(duration)
      }
    )

    let activeRefresh = Task { await model.refresh() }
    try await waitUntil { await collector.count == 1 }
    model.startRefreshLoop()
    try await waitUntil { await sleeper.intervals.count >= 2 }

    #expect(await recorder.count == 0)
    activeRefresh.cancel()
    await activeRefresh.value
  }

  private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if await predicate() {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The refresh loop did not run in time.")
  }
}

private actor LocalCollectionRecorder: LocalQuotaCollecting {
  private(set) var count = 0

  func collect() async throws -> QuotaCollectionReport {
    count += 1
    return QuotaCollectionReport(
      schemaVersion: 1,
      capturedAt: Date(timeIntervalSince1970: TimeInterval(count)),
      results: []
    )
  }
}

private actor SlowLocalCollector: LocalQuotaCollecting {
  private(set) var count = 0

  func collect() async throws -> QuotaCollectionReport {
    count += 1
    try await Task.sleep(for: .seconds(60))
    return QuotaCollectionReport(
      schemaVersion: 1,
      capturedAt: Date(timeIntervalSince1970: 1),
      results: []
    )
  }
}

private struct RecordingRelayPusher: RelaySnapshotPushing {
  let recorder: RelayPushRecorder
  let hasRelayCredential: Bool

  func push() async throws {
    try await recorder.push()
  }
}

private actor RelayPushRecorder {
  private(set) var count = 0
  private let failsFirstPush: Bool

  init(failsFirstPush: Bool) {
    self.failsFirstPush = failsFirstPush
  }

  func push() throws {
    count += 1
    if failsFirstPush, count == 1 {
      throw SyntheticRelayPushError()
    }
  }
}

private actor RefreshSleepSequence {
  private(set) var intervals: [Duration] = []

  func sleep(_ duration: Duration) async throws {
    intervals.append(duration)
    if intervals.count == 1 {
      return
    }
    try await Task.sleep(for: .seconds(60))
  }
}

private struct SyntheticRelayPushError: Error {}
