import Foundation
import QuotaPresentation
import Testing

@testable import QuotaObservations

/// The shared statement of how readings resolve into subscriptions. TypeScript in
/// `packages/quota-model` and Rust in `packages/service` answer the same file, so a rule one
/// runtime starts reading differently fails here rather than resolving one account into two
/// subscriptions on one client and one on another.
@Suite
struct QuotaObservationMergeConformanceTests {
  /// Relay resolves an account's readings without a local source, because only the machine in
  /// front of you collects locally.
  @Test func nWayMergeAnswersTheSharedConformanceFixture() throws {
    let cases = try MergeFixture.cases(named: "merge")
    #expect(!cases.isEmpty)
    for testCase in cases {
      let observations = try MergeFixture.array(testCase["observations"]).map { entry in
        let observation = try MergeFixture.object(entry)
        return QuotaObservation(
          origin: .device(id: try MergeFixture.string(observation["device_id"])),
          snapshot: try FixtureSnapshot(MergeFixture.object(observation["snapshot"]))
        )
      }
      let now = try MergeFixture.instant(testCase["now"])
      let merged = QuotaObservationMerge.merge(observations, now: now)
      let expected = try MergeFixture.array(testCase["expected"]).map(MergeFixture.object)
      let name = try MergeFixture.string(testCase["name"])
      #expect(merged.count == expected.count, "\(name)")
      for (subscription, expectation) in zip(merged, expected) {
        let identity = try MergeFixture.object(expectation["identity"])
        #expect(subscription.identity.provider == (identity["provider"] as? String), "\(name)")
        #expect(
          subscription.identity.fingerprint == (identity["fingerprint"] as? String), "\(name)")
        #expect(subscription.identity.scope == (identity["scope"] as? String), "\(name)")
        // The fixture names the caller-owned source identity, which is the bare device id: the
        // key a client derives has to be the key Relay wrote.
        #expect(subscription.identity.sourceID == identity["source_id"] as? String, "\(name)")
        #expect(
          subscription.selectedOrigin.deviceID == (expectation["selected_device_id"] as? String),
          "\(name)"
        )
        #expect(subscription.isStale == (expectation["is_stale"] as? Bool), "\(name)")
        let sources = try MergeFixture.array(expectation["sources"]).map(MergeFixture.object)
        #expect(subscription.sources.count == sources.count, "\(name)")
        for (source, expectation) in zip(subscription.sources, sources) {
          #expect(source.origin.deviceID == (expectation["device_id"] as? String), "\(name)")
          let observedAt = try MergeFixture.instant(expectation["observed_at"])
          #expect(source.observedAt == observedAt, "\(name)")
          #expect(source.isStale == (expectation["is_stale"] as? Bool), "\(name)")
          #expect(source.snapshot?.observedAt == observedAt, "\(name)")
        }
      }
    }
  }

  /// A client that collects for itself merges two ways: what Relay resolved from every other
  /// device, against its own reading of the account in front of it.
  @Test func twoWayMergeAnswersTheSharedConformanceFixture() throws {
    let cases = try MergeFixture.cases(named: "two_way_merge")
    #expect(!cases.isEmpty)
    for testCase in cases {
      let name = try MergeFixture.string(testCase["name"])
      let now = try MergeFixture.instant(testCase["now"])
      var observations: [QuotaObservation<FixtureSnapshot>] = []
      for entry in try MergeFixture.array(testCase["local"]) {
        observations.append(
          QuotaObservation(
            origin: .local, snapshot: try FixtureSnapshot(MergeFixture.object(entry)))
        )
      }
      for entry in try MergeFixture.array(testCase["remote"]) {
        observations.append(try MergeFixture.resolvedRow(MergeFixture.object(entry), now: now))
      }
      let merged = QuotaObservationMerge.merge(observations, now: now)
      let expected = try MergeFixture.array(testCase["expected"]).map(MergeFixture.object)
      #expect(merged.count == expected.count, "\(name)")
      for (subscription, expectation) in zip(merged, expected) {
        #expect(
          subscription.selectedOrigin.sourceID == (expectation["selected_source_id"] as? String),
          "\(name)"
        )
        #expect(subscription.sources.count == (expectation["sources"] as? Int), "\(name)")
        #expect(subscription.isStale == (expectation["is_stale"] as? Bool), "\(name)")
      }
    }
  }

  /// The key is what every runtime addresses a subscription by, and Relay writes it into the
  /// Account summary. A global subscription carries an empty fourth segment.
  @Test func theSubscriptionKeyIsTheFourPartsJoined() {
    let global = QuotaSubscriptionIdentity(
      provider: "codex", fingerprint: "fp", scope: "global", sourceID: nil)
    #expect(global.key == "codex|fp|global|")
    let scoped = QuotaSubscriptionIdentity(
      provider: "codex", fingerprint: "fp", scope: "source", sourceID: "device_1")
    #expect(scoped.key == "codex|fp|source|device_1")
  }
}

/// A reading as the fixture states it. The merge reads nothing else from a snapshot, so this is
/// the whole of what a test double has to be.
struct FixtureSnapshot: QuotaObservationSnapshot {
  let subscriptionProvider: String
  let subscriptionFingerprint: String
  let subscriptionScope: String
  let observedAt: Date
  let reportedState: QuotaObservationState
  let validUntil: Date?

  init(_ json: [String: Any]) throws {
    let account = try MergeFixture.object(json["account"])
    subscriptionProvider = try MergeFixture.string(json["provider"])
    subscriptionFingerprint = try MergeFixture.string(account["fingerprint"])
    subscriptionScope = try MergeFixture.string(account["fingerprint_scope"])
    observedAt = try MergeFixture.instant(json["observed_at"])
    reportedState = Self.state(try MergeFixture.string(json["status"]))
    let windows = try MergeFixture.array(json["windows"]).map(MergeFixture.object)
    validUntil = QuotaObservationValidity.validUntil(
      observedAt: observedAt,
      windows: try windows.map { window in
        QuotaObservationWindow(
          resetsAt: window["resets_at"] == nil
            ? nil : try MergeFixture.instant(window["resets_at"]),
          durationSeconds: window["duration_seconds"] as? Int
        )
      }
    )
  }

  private static func state(_ status: String) -> QuotaObservationState {
    switch status {
    case "available": .available
    case "stale": .stale
    case "auth_required": .signInNeeded
    case "unavailable": .unavailable
    case "unsupported": .unsupported
    default: .failed
    }
  }
}

enum MergeFixture {
  enum Failure: Error { case malformed(String) }

  static func cases(named section: String) throws -> [[String: Any]] {
    let root = try object(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as Any?
    )
    return try array(root[section]).map(object)
  }

  /// One subscription Relay already resolved: the reading it chose, attributed to the source that
  /// took it, and every other device that reported the same subscription.
  static func resolvedRow(_ row: [String: Any], now: Date) throws
    -> QuotaObservation<FixtureSnapshot>
  {
    let snapshot = try FixtureSnapshot(object(row["snapshot"]))
    let sources = try array(row["sources"]).map(object)
    let selected =
      try sources
      .filter { try instant($0["observed_at"]) == snapshot.observedAt }
      .compactMap { $0["device_id"] as? String }
      .min()
    guard let selected else { throw Failure.malformed("resolved row names no reading") }
    let others = try sources.compactMap { source -> QuotaObservationSource<FixtureSnapshot>? in
      guard let deviceID = source["device_id"] as? String, deviceID != selected else { return nil }
      let reading = source["snapshot"].map { try? FixtureSnapshot(object($0)) } ?? nil
      return QuotaObservationSource(
        origin: .device(id: deviceID),
        observedAt: try instant(source["observed_at"]),
        isStale: reading?.isStale(now: now) ?? false,
        snapshot: reading
      )
    }
    return QuotaObservation(
      origin: .device(id: selected),
      snapshot: snapshot,
      otherSources: others
    )
  }

  static func object(_ value: Any?) throws -> [String: Any] {
    guard let value = value as? [String: Any] else { throw Failure.malformed("object") }
    return value
  }

  static func array(_ value: Any?) throws -> [Any] {
    guard let value = value as? [Any] else { throw Failure.malformed("array") }
    return value
  }

  static func string(_ value: Any?) throws -> String {
    guard let value = value as? String else { throw Failure.malformed("string") }
    return value
  }

  static func instant(_ value: Any?) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let text = value as? String, let date = formatter.date(from: text) else {
      throw Failure.malformed("instant")
    }
    return date
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/quota-observation-conformance.json")
}
