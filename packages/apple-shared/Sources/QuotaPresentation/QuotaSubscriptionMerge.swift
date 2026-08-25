import Foundation

/// One subscription, addressed the way ADR 0003 addresses it.
///
/// A `global` fingerprint identifies the same account wherever it was observed, so every
/// device that reported it resolves to one subscription. A `source` fingerprint means
/// nothing outside the source that produced it and therefore carries that source's id.
public struct QuotaSubscriptionIdentity: Hashable, Sendable {
  public let provider: String
  public let fingerprint: String
  public let scope: String
  public let sourceID: String?

  public init(provider: String, fingerprint: String, scope: String, sourceID: String?) {
    self.provider = provider
    self.fingerprint = fingerprint
    self.scope = scope
    self.sourceID = sourceID
  }
}

/// One device that reported a subscription, kept whether or not its reading is shown.
public struct QuotaSubscriptionSource: Equatable, Sendable {
  public let deviceID: String
  public let observedAt: Date
  public let isStale: Bool

  public init(deviceID: String, observedAt: Date, isStale: Bool) {
    self.deviceID = deviceID
    self.observedAt = observedAt
    self.isStale = isStale
  }
}

/// One account observation as the merge reads it.
public struct QuotaSubscriptionObservation<Reading: QuotaObservationFreshness> {
  public let deviceID: String
  public let provider: String
  public let fingerprint: String
  public let isSourceScoped: Bool
  public let observedAt: Date
  public let reading: Reading

  public init(
    deviceID: String,
    provider: String,
    fingerprint: String,
    isSourceScoped: Bool,
    observedAt: Date,
    reading: Reading
  ) {
    self.deviceID = deviceID
    self.provider = provider
    self.fingerprint = fingerprint
    self.isSourceScoped = isSourceScoped
    self.observedAt = observedAt
    self.reading = reading
  }
}

/// A subscription and the one reading shown for it; the others stay in ``sources``.
public struct QuotaSubscription<Reading: QuotaObservationFreshness>: Identifiable {
  public let identity: QuotaSubscriptionIdentity
  public let reading: Reading
  public let sources: [QuotaSubscriptionSource]
  /// The source whose reading is shown. It is one of ``sources``.
  public let selected: QuotaSubscriptionSource

  public var id: QuotaSubscriptionIdentity { identity }
  public var selectedDeviceID: String { selected.deviceID }
  public var isStale: Bool { selected.isStale }
}

extension QuotaSubscription: Equatable where Reading: Equatable {}

/// Resolving the devices that reported an account into the subscriptions a person reads.
///
/// Relay keeps one observation per reporting device and never deduplicates, so resolving
/// them is every reader's job. Conflicting readings are not additive measurements: this
/// selects one rather than combining values, and keeps every reporting device attached to
/// the subscription so provenance survives the merge.
///
/// Selection follows ADR 0003: a valid unexpired reading first, then the newest observation
/// time, then a deterministic device id. QuotaBar's service inserts locally collected
/// readings ahead of the last step, because local collection is the only authority for the
/// machine in front of you; a reader of uploaded observations has no local source and so
/// cannot reach that step.
///
/// When a row was last written to Relay takes no part. A device re-uploading a reading it
/// already knows moves that instant without making the reading newer.
public enum QuotaSubscriptionMerge {
  public static func resolve<Reading: QuotaObservationFreshness>(
    _ observations: [QuotaSubscriptionObservation<Reading>],
    now: Date = Date()
  ) -> [QuotaSubscription<Reading>] {
    var resolved: [QuotaSubscriptionIdentity: QuotaSubscription<Reading>] = [:]
    for observation in observations {
      let identity = QuotaSubscriptionIdentity(
        provider: observation.provider,
        fingerprint: observation.fingerprint,
        scope: observation.isSourceScoped ? "source" : "global",
        sourceID: observation.isSourceScoped ? observation.deviceID : nil
      )
      let source = QuotaSubscriptionSource(
        deviceID: observation.deviceID,
        observedAt: observation.observedAt,
        isStale: observation.reading.isStale(now: now)
      )
      guard let existing = resolved[identity] else {
        resolved[identity] = QuotaSubscription(
          identity: identity,
          reading: observation.reading,
          sources: [source],
          selected: source
        )
        continue
      }
      let replaces = isBetter(incoming: source, existing: existing.selected)
      resolved[identity] = QuotaSubscription(
        identity: identity,
        reading: replaces ? observation.reading : existing.reading,
        sources: existing.sources + [source],
        selected: replaces ? source : existing.selected
      )
    }
    return resolved.values
      .map {
        QuotaSubscription(
          identity: $0.identity,
          reading: $0.reading,
          sources: $0.sources.sorted { $0.deviceID < $1.deviceID },
          selected: $0.selected
        )
      }
      .sorted { precedes($0, $1) }
  }

  private static func isBetter(
    incoming: QuotaSubscriptionSource,
    existing: QuotaSubscriptionSource
  ) -> Bool {
    if incoming.isStale != existing.isStale { return !incoming.isStale }
    if incoming.observedAt != existing.observedAt {
      return incoming.observedAt > existing.observedAt
    }
    return incoming.deviceID < existing.deviceID
  }

  private static func precedes<Reading>(
    _ left: QuotaSubscription<Reading>,
    _ right: QuotaSubscription<Reading>
  ) -> Bool {
    (left.identity.provider, left.identity.fingerprint, left.identity.scope,
      left.identity.sourceID ?? "")
      < (right.identity.provider, right.identity.fingerprint, right.identity.scope,
        right.identity.sourceID ?? "")
  }
}
