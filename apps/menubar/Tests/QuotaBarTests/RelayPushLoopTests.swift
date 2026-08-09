import Foundation
import Testing

@testable import QuotaBar

@MainActor
@Suite
struct RelayPushLoopTests {
  @Test
  func startsImmediatelyRetriesAfterFailureAndIsIdempotent() async throws {
    let recorder = RelayPushRecorder(failsFirstPush: true)
    let sleeper = RelayPushSleepSequence()
    let model = MenuBarViewModel(
      collector: EmptyLocalCollector(),
      relayPusher: RecordingRelayPusher(recorder: recorder, hasRelayCredential: true),
      reportCache: nil,
      relayPushInterval: .seconds(300),
      relayPushSleep: { duration in
        try await sleeper.sleep(duration)
      }
    )

    model.startRelayPushLoop()
    model.startRelayPushLoop()
    try await waitUntil { await recorder.count >= 2 }

    #expect(await recorder.count == 2)
    #expect(await sleeper.intervals == [.seconds(300), .seconds(300)])
  }

  @Test
  func skipsHelperWhileUnpaired() async throws {
    let recorder = RelayPushRecorder(failsFirstPush: false)
    let sleeper = RelayPushSleepSequence()
    let model = MenuBarViewModel(
      collector: EmptyLocalCollector(),
      relayPusher: RecordingRelayPusher(recorder: recorder, hasRelayCredential: false),
      reportCache: nil,
      relayPushInterval: .seconds(300),
      relayPushSleep: { duration in
        try await sleeper.sleep(duration)
      }
    )

    model.startRelayPushLoop()
    try await waitUntil { await sleeper.intervals.count >= 2 }

    #expect(await recorder.count == 0)
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
    Issue.record("The relay push loop did not run in time.")
  }
}

private struct EmptyLocalCollector: LocalQuotaCollecting {
  func collect() async throws -> QuotaCollectionReport {
    QuotaCollectionReport(
      schemaVersion: 1,
      capturedAt: Date(timeIntervalSince1970: 0),
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

private actor RelayPushSleepSequence {
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
