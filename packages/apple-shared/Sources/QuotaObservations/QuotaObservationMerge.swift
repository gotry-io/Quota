import Foundation
import QuotaPresentation

/// A reading, as the merge reads it: the three parts of the subscription it describes, when it
/// was taken, and — through ``QuotaPresentation/QuotaObservationFreshness`` — whether it still
/// describes current quota.
///
/// The merge never looks at quota values, so the reading itself travels through untouched and
/// each product conforms its own wire type rather than converting into a second one.
public protocol QuotaObservationSnapshot: QuotaObservationFreshness, Sendable {
  var subscriptionProvider: String { get }
  var subscriptionFingerprint: String { get }
  var subscriptionScope: String { get }
  var observedAt: Date { get }
}

/// Where a reading came from.
///
/// Local collection is named apart from every device because it is the authority for the machine
/// in front of you, and the merge breaks a tie in its favour.
public enum QuotaObservationOrigin: Hashable, Sendable {
  case local
  case device(id: String)

  /// This reader's name for the source. A device is prefixed so it can never collide with local
  /// collection, whatever id Relay issued.
  public var sourceID: String {
    switch self {
    case .local: "local"
    case .device(let id): "device:\(id)"
    }
  }

  /// The caller-owned source identity a source-scoped subscription key carries. Relay writes the
  /// bare device id into that key, so a key derived from this names the subscription Relay named
  /// rather than a second one beside it.
  public var subscriptionSourceID: String {
    switch self {
    case .local: "local"
    case .device(let id): id
    }
  }

  public var deviceID: String? {
    switch self {
    case .local: nil
    case .device(let id): id
    }
  }

  public var isLocal: Bool { self == .local }
}

/// One source that reported a subscription, kept whether or not its reading is the one shown.
///
/// A source Relay names without its reading — an older Relay, or a reading it no longer holds —
/// is still listed with its own freshness and no invented quota.
public struct QuotaObservationSource<Snapshot: QuotaObservationSnapshot>: Sendable {
  public let origin: QuotaObservationOrigin
  public let observedAt: Date
  public let isStale: Bool
  public let snapshot: Snapshot?

  public init(
    origin: QuotaObservationOrigin,
    observedAt: Date,
    isStale: Bool,
    snapshot: Snapshot?
  ) {
    self.origin = origin
    self.observedAt = observedAt
    self.isStale = isStale
    self.snapshot = snapshot
  }
}

/// One reading handed to the merge, and the sources behind it.
///
/// `otherSources` is how a subscription another reader already resolved arrives: Relay answers
/// one row per subscription carrying the reading it chose and every device behind it, and those
/// devices take no further part in selection because Relay already selected among them.
public struct QuotaObservation<Snapshot: QuotaObservationSnapshot>: Sendable {
  public var origin: QuotaObservationOrigin
  public var snapshot: Snapshot
  public var otherSources: [QuotaObservationSource<Snapshot>]

  public init(
    origin: QuotaObservationOrigin,
    snapshot: Snapshot,
    otherSources: [QuotaObservationSource<Snapshot>] = []
  ) {
    self.origin = origin
    self.snapshot = snapshot
    self.otherSources = otherSources
  }
}

/// One subscription, resolved: the reading shown for it, and every source that reported it.
public struct MergedQuotaObservation<Snapshot: QuotaObservationSnapshot>: Sendable {
  public let identity: QuotaSubscriptionIdentity
  public fileprivate(set) var snapshot: Snapshot
  public fileprivate(set) var sources: [QuotaObservationSource<Snapshot>]
  public fileprivate(set) var selectedOrigin: QuotaObservationOrigin
  public fileprivate(set) var isStale: Bool

  public var key: String { identity.key }
}

/// The observation merge, stated in Swift.
///
/// The rule is [ADR 0003](../../../../docs/decisions/0003-observation-preserving-subscription-merge.md)
/// and `packages/protocol/fixtures/quota-observation-conformance.json` is what all three
/// implementations answer — TypeScript in `packages/quota-model`, Rust in `packages/service`, and
/// this one. A fingerprint or an order the three read differently resolves one account into two
/// subscriptions, which is what the shared fixture turns into a test failure.
public enum QuotaObservationMerge {
  /// The subscriptions behind a set of readings, one entry each.
  ///
  /// Conflicting readings are not additive measurements: this selects one rather than combining
  /// values, and keeps every reporting source attached so provenance survives the merge.
  /// Selection prefers a reading that is still current, then the newest `observed_at`, then local
  /// collection, then a stable source id. When Relay last wrote a row takes no part: a device
  /// re-uploading an unchanged old reading moves that instant without making the reading newer.
  public static func merge<Snapshot: QuotaObservationSnapshot>(
    _ observations: [QuotaObservation<Snapshot>],
    now: Date
  ) -> [MergedQuotaObservation<Snapshot>] {
    var merged: [String: MergedQuotaObservation<Snapshot>] = [:]
    for observation in observations {
      let candidate = row(for: observation, now: now)
      let key = candidate.key
      guard var existing = merged[key] else {
        merged[key] = candidate
        continue
      }
      if isBetter(candidate, than: existing) {
        existing.snapshot = candidate.snapshot
        existing.selectedOrigin = candidate.selectedOrigin
        existing.isStale = candidate.isStale
      }
      for source in candidate.sources {
        existing.sources.removeAll { $0.origin == source.origin }
        existing.sources.append(source)
      }
      merged[key] = existing
    }
    return merged.values
      .map { subscription in
        var sorted = subscription
        sorted.sources.sort { $0.origin.sourceID < $1.origin.sourceID }
        return sorted
      }
      .sorted { QuotaSubscriptionIdentity.isOrderedBefore($0.identity, $1.identity) }
  }

  private static func row<Snapshot: QuotaObservationSnapshot>(
    for observation: QuotaObservation<Snapshot>,
    now: Date
  ) -> MergedQuotaObservation<Snapshot> {
    let snapshot = observation.snapshot
    let scope = snapshot.subscriptionScope
    let isStale = snapshot.isStale(now: now)
    let selected = QuotaObservationSource(
      origin: observation.origin,
      observedAt: snapshot.observedAt,
      isStale: isStale,
      snapshot: snapshot
    )
    let others = observation.otherSources.filter { $0.origin != observation.origin }
    return MergedQuotaObservation(
      identity: QuotaSubscriptionIdentity(
        provider: snapshot.subscriptionProvider,
        fingerprint: snapshot.subscriptionFingerprint,
        scope: scope,
        sourceID: scope == "source" ? observation.origin.subscriptionSourceID : nil
      ),
      snapshot: snapshot,
      sources: [selected] + others,
      selectedOrigin: observation.origin,
      isStale: isStale
    )
  }

  private static func isBetter<Snapshot: QuotaObservationSnapshot>(
    _ incoming: MergedQuotaObservation<Snapshot>,
    than existing: MergedQuotaObservation<Snapshot>
  ) -> Bool {
    if incoming.isStale != existing.isStale { return !incoming.isStale }
    let incomingObserved = incoming.snapshot.observedAt
    let existingObserved = existing.snapshot.observedAt
    if incomingObserved != existingObserved { return incomingObserved > existingObserved }
    if incoming.selectedOrigin.isLocal != existing.selectedOrigin.isLocal {
      return incoming.selectedOrigin.isLocal
    }
    return incoming.selectedOrigin.sourceID < existing.selectedOrigin.sourceID
  }
}
