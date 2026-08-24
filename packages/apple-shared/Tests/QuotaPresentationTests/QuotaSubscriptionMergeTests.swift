import Foundation
import Testing

@testable import QuotaPresentation

/// The rule every reader answers is stated once as a shared fixture. The native service and
/// the TypeScript model answer the same file, so an implementation that drifts fails here.
private let fixtureURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("protocol/fixtures/quota-observation-conformance.json")

private struct Fixture: Decodable {
  let freshness: [FreshnessCase]
  let merge: [MergeCase]
}

private struct FreshnessCase: Decodable {
  let name: String
  let now: String
  let snapshot: Snapshot
  let expected: Expectation

  struct Expectation: Decodable {
    let validUntil: String
    let status: String
  }
}

private struct MergeCase: Decodable {
  let name: String
  let now: String
  let observations: [Observation]
  let expected: [Expectation]

  struct Observation: Decodable {
    let deviceId: String
    let snapshot: Snapshot
  }

  struct Expectation: Decodable {
    let identity: Identity
    let selectedDeviceId: String
    let isStale: Bool
    let sources: [Source]

    struct Identity: Decodable {
      let provider: String
      let fingerprint: String
      let scope: String
      let sourceId: String?
    }

    struct Source: Decodable {
      let deviceId: String
      let observedAt: String
      let isStale: Bool
    }
  }
}

private struct Snapshot: Decodable {
  let provider: String
  let account: Account
  let windows: [Window]
  let status: String
  let observedAt: String

  struct Account: Decodable {
    let fingerprint: String
    let fingerprintScope: String
  }

  struct Window: Decodable {
    let resetsAt: String?
    let durationSeconds: Int?
  }
}

/// The reading as freshness sees it, derived from the snapshot exactly as the wire type does.
private struct Reading: QuotaObservationFreshness {
  let snapshot: Snapshot

  var reportedState: QuotaObservationState {
    switch snapshot.status {
    case "available": .available
    case "stale": .stale
    case "auth_required": .signInNeeded
    case "unavailable": .unavailable
    case "unsupported": .unsupported
    default: .failed
    }
  }

  var validUntil: Date? {
    QuotaObservationValidity.validUntil(
      observedAt: instant(snapshot.observedAt),
      windows: snapshot.windows.map {
        QuotaObservationWindow(
          resetsAt: $0.resetsAt.map(instant),
          durationSeconds: $0.durationSeconds
        )
      }
    )
  }
}

private func instant(_ value: String) -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  guard let date = formatter.date(from: value) else {
    fatalError("fixture instant \(value)")
  }
  return date
}

private func loadFixture() throws -> Fixture {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(Fixture.self, from: Data(contentsOf: fixtureURL))
}

@Suite
struct QuotaObservationConformanceTests {
  @Test func freshnessMatchesTheSharedConformanceFixture() throws {
    let fixture = try loadFixture()
    #expect(!fixture.freshness.isEmpty)
    for testCase in fixture.freshness {
      let reading = Reading(snapshot: testCase.snapshot)
      #expect(reading.validUntil == instant(testCase.expected.validUntil), "\(testCase.name)")
      let expectedCurrent = testCase.expected.status == "available"
      #expect(!reading.isStale(now: instant(testCase.now)) == expectedCurrent, "\(testCase.name)")
    }
  }

  @Test func subscriptionMergeMatchesTheSharedConformanceFixture() throws {
    let fixture = try loadFixture()
    #expect(!fixture.merge.isEmpty)
    for testCase in fixture.merge {
      let resolved = QuotaSubscriptionMerge.resolve(
        testCase.observations.map { observation in
          QuotaSubscriptionObservation(
            deviceID: observation.deviceId,
            provider: observation.snapshot.provider,
            fingerprint: observation.snapshot.account.fingerprint,
            isSourceScoped: observation.snapshot.account.fingerprintScope == "source",
            observedAt: instant(observation.snapshot.observedAt),
            reading: Reading(snapshot: observation.snapshot)
          )
        },
        now: instant(testCase.now)
      )
      #expect(resolved.count == testCase.expected.count, "\(testCase.name)")
      for (subscription, expected) in zip(resolved, testCase.expected) {
        #expect(subscription.identity.provider == expected.identity.provider, "\(testCase.name)")
        #expect(
          subscription.identity.fingerprint == expected.identity.fingerprint, "\(testCase.name)")
        #expect(subscription.identity.scope == expected.identity.scope, "\(testCase.name)")
        #expect(subscription.identity.sourceID == expected.identity.sourceId, "\(testCase.name)")
        #expect(subscription.selectedDeviceID == expected.selectedDeviceId, "\(testCase.name)")
        #expect(subscription.isStale == expected.isStale, "\(testCase.name)")
        #expect(subscription.sources.count == expected.sources.count, "\(testCase.name)")
        for (source, expectedSource) in zip(subscription.sources, expected.sources) {
          #expect(source.deviceID == expectedSource.deviceId, "\(testCase.name)")
          #expect(source.observedAt == instant(expectedSource.observedAt), "\(testCase.name)")
          #expect(source.isStale == expectedSource.isStale, "\(testCase.name)")
        }
      }
    }
  }
}
