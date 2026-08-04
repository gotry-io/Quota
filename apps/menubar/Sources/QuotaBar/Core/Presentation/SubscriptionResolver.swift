import Foundation

struct SubscriptionResolver: Sendable {
  func resolve(
    _ observations: [QuotaObservation],
    now: Date
  ) -> [ResolvedQuotaSubscription] {
    Dictionary(grouping: observations, by: identity(for:))
      .map { identity, observations in
        let selected = observations.dropFirst().reduce(observations[0]) { selected, candidate in
          isPreferred(candidate, over: selected, now: now) ? candidate : selected
        }
        let sources = Array(Set(observations.map(\.source))).sorted(by: sourcesAreOrdered)

        return ResolvedQuotaSubscription(
          identity: identity,
          sources: sources,
          selectedSource: selected.source,
          selectedSnapshot: selected.snapshot,
          isStale: isStale(selected.snapshot, now: now)
        )
      }
      .sorted { subscriptionsAreOrdered($0.identity, $1.identity) }
  }

  private func identity(for observation: QuotaObservation) -> QuotaSubscriptionIdentity {
    let snapshot = observation.snapshot
    let scope: QuotaSubscriptionIdentity.Scope =
      switch snapshot.account.fingerprintScope {
      case .global:
        .global
      case .source:
        .source(observation.source)
      }

    return QuotaSubscriptionIdentity(
      provider: snapshot.provider,
      fingerprint: snapshot.account.fingerprint,
      scope: scope
    )
  }

  private func isPreferred(
    _ candidate: QuotaObservation,
    over selected: QuotaObservation,
    now: Date
  ) -> Bool {
    let candidateIsAvailable = isAvailableAndUnexpired(candidate.snapshot, now: now)
    let selectedIsAvailable = isAvailableAndUnexpired(selected.snapshot, now: now)
    if candidateIsAvailable != selectedIsAvailable {
      return candidateIsAvailable
    }
    if candidate.snapshot.observedAt != selected.snapshot.observedAt {
      return candidate.snapshot.observedAt > selected.snapshot.observedAt
    }
    if candidate.source.isLocal != selected.source.isLocal {
      return candidate.source.isLocal
    }
    return candidate.source.stableID < selected.source.stableID
  }

  private func isAvailableAndUnexpired(_ snapshot: QuotaSnapshot, now: Date) -> Bool {
    guard snapshot.status == .available else {
      return false
    }
    return snapshot.validUntil.map { $0 > now } ?? true
  }

  private func isStale(_ snapshot: QuotaSnapshot, now: Date) -> Bool {
    snapshot.status == .stale || snapshot.validUntil.map { $0 <= now } == true
  }

  private func sourcesAreOrdered(
    _ left: QuotaObservationSource,
    _ right: QuotaObservationSource
  ) -> Bool {
    if left.isLocal != right.isLocal {
      return left.isLocal
    }
    return left.stableID < right.stableID
  }

  private func subscriptionsAreOrdered(
    _ left: QuotaSubscriptionIdentity,
    _ right: QuotaSubscriptionIdentity
  ) -> Bool {
    let leftProviderOrder = providerOrder(left.provider)
    let rightProviderOrder = providerOrder(right.provider)
    if leftProviderOrder != rightProviderOrder {
      return leftProviderOrder < rightProviderOrder
    }
    if left.fingerprint != right.fingerprint {
      return left.fingerprint < right.fingerprint
    }

    switch (left.scope, right.scope) {
    case (.global, .global):
      return false
    case (.global, .source):
      return true
    case (.source, .global):
      return false
    case (.source(let leftSource), .source(let rightSource)):
      return sourcesAreOrdered(leftSource, rightSource)
    }
  }

  private func providerOrder(_ provider: ProviderID) -> Int {
    switch provider {
    case .codex: 0
    case .claude: 1
    case .grok: 2
    }
  }
}
