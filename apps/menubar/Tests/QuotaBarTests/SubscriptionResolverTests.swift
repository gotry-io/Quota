import Foundation
import Testing

@testable import QuotaBar

private let resolverNow = Date(timeIntervalSince1970: 1_785_758_400)
private let localSource = QuotaObservationSource.local
private let remoteA = QuotaObservationSource.remote(
  relayInstanceID: "relay-a",
  deviceID: "device-a"
)
private let remoteB = QuotaObservationSource.remote(
  relayInstanceID: "relay-a",
  deviceID: "device-b"
)
private let remoteOtherRelay = QuotaObservationSource.remote(
  relayInstanceID: "relay-b",
  deviceID: "device-a"
)

@Test
func mergesGlobalAccountObservationsWithoutAccumulatingPercentages() throws {
  let observations = [
    observation(
      source: remoteB,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 80,
      observedAt: resolverNow.addingTimeInterval(-20)
    ),
    observation(
      source: remoteA,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 30,
      observedAt: resolverNow.addingTimeInterval(-10)
    ),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)
  let subscription = try #require(subscriptions.first)

  #expect(subscriptions.count == 1)
  #expect(subscription.sources == [remoteA, remoteB])
  #expect(subscription.selectedSource == remoteA)
  #expect(subscription.selectedSnapshot.windows.first?.usedPercent == 30)
}

@Test
func mergesLocalAndRemoteGlobalObservationsAndPrefersLocalOnATie() throws {
  let remote = observation(
    source: remoteA,
    fingerprint: "account-1",
    scope: .global,
    usedPercent: 70
  )
  let local = observation(
    source: localSource,
    fingerprint: "account-1",
    scope: .global,
    usedPercent: 20
  )

  let subscription = try #require(
    SubscriptionResolver().resolve([remote, local], now: resolverNow).first
  )

  #expect(subscription.sources == [localSource, remoteA])
  #expect(subscription.selectedSource == localSource)
  #expect(subscription.selectedSnapshot.windows.first?.usedPercent == 20)
}

@Test
func sourceScopedAccountsStaySeparateAcrossObservationSources() {
  let observations = [
    observation(source: localSource, fingerprint: "account-1", scope: .source),
    observation(source: remoteA, fingerprint: "account-1", scope: .source),
    observation(source: remoteB, fingerprint: "account-1", scope: .source),
    observation(source: remoteOtherRelay, fingerprint: "account-1", scope: .source),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)

  #expect(subscriptions.count == 4)
  #expect(
    subscriptions.map(\.sources) == [
      [localSource],
      [remoteA],
      [remoteB],
      [remoteOtherRelay],
    ]
  )
}

@Test
func globalAndSourceScopesNeverShareAGroup() {
  let observations = [
    observation(source: remoteA, fingerprint: "account-1", scope: .global),
    observation(source: remoteA, fingerprint: "account-1", scope: .source),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)

  #expect(subscriptions.count == 2)
  #expect(subscriptions.map(\.identity.scope) == [.global, .source(remoteA)])
}

@Test
func providersNeverShareAGroupAndUseProductOrder() {
  let observations = [
    observation(source: remoteA, provider: .grok, fingerprint: "account-1", scope: .global),
    observation(source: remoteA, provider: .claude, fingerprint: "account-1", scope: .global),
    observation(source: remoteA, provider: .codex, fingerprint: "account-1", scope: .global),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)

  #expect(subscriptions.map(\.identity.provider) == [.codex, .claude, .grok])
}

@Test
func availableAndUnexpiredBeatsNewerStaleOrExpiredObservations() throws {
  let available = observation(
    source: remoteA,
    fingerprint: "account-1",
    scope: .global,
    usedPercent: 20,
    observedAt: resolverNow.addingTimeInterval(-30),
    validUntil: resolverNow.addingTimeInterval(30)
  )
  let stale = observation(
    source: remoteB,
    fingerprint: "account-1",
    scope: .global,
    status: .stale,
    usedPercent: 40,
    observedAt: resolverNow.addingTimeInterval(-10),
    validUntil: resolverNow.addingTimeInterval(30)
  )
  let expired = observation(
    source: localSource,
    fingerprint: "account-1",
    scope: .global,
    usedPercent: 60,
    observedAt: resolverNow,
    validUntil: resolverNow
  )

  let subscription = try #require(
    SubscriptionResolver().resolve([expired, stale, available], now: resolverNow).first
  )

  #expect(subscription.selectedSource == remoteA)
  #expect(subscription.selectedSnapshot.windows.first?.usedPercent == 20)
  #expect(!subscription.isStale)
}

@Test
func newestObservationBeatsOlderLocalObservation() throws {
  let local = observation(
    source: localSource,
    fingerprint: "account-1",
    scope: .global,
    observedAt: resolverNow.addingTimeInterval(-20)
  )
  let remote = observation(
    source: remoteB,
    fingerprint: "account-1",
    scope: .global,
    observedAt: resolverNow.addingTimeInterval(-10)
  )

  let subscription = try #require(
    SubscriptionResolver().resolve([local, remote], now: resolverNow).first
  )

  #expect(subscription.selectedSource == remoteB)
}

@Test
func sourceStableIDBreaksAnOtherwiseExactRemoteTie() throws {
  let observations = [
    observation(source: remoteB, fingerprint: "account-1", scope: .global),
    observation(source: remoteA, fingerprint: "account-1", scope: .global),
  ]

  let subscription = try #require(
    SubscriptionResolver().resolve(observations, now: resolverNow).first
  )

  #expect(subscription.selectedSource == remoteA)
}

@Test
func derivesStalenessAtTheValidityBoundaryAndFromStatus() {
  let expiredAtBoundary = observation(
    source: remoteA,
    fingerprint: "expired",
    scope: .global,
    validUntil: resolverNow
  )
  let staleStatus = observation(
    source: remoteA,
    fingerprint: "stale",
    scope: .global,
    status: .stale,
    validUntil: resolverNow.addingTimeInterval(60)
  )

  let subscriptions = SubscriptionResolver().resolve(
    [staleStatus, expiredAtBoundary],
    now: resolverNow
  )

  #expect(subscriptions.map(\.isStale) == [true, true])
}

@Test
func deduplicatesSourcesWhileSelectingTheirNewestObservation() throws {
  let observations = [
    observation(
      source: remoteA,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 10,
      observedAt: resolverNow.addingTimeInterval(-20)
    ),
    observation(
      source: remoteA,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 25,
      observedAt: resolverNow.addingTimeInterval(-10)
    ),
  ]

  let subscription = try #require(
    SubscriptionResolver().resolve(observations, now: resolverNow).first
  )

  #expect(subscription.sources == [remoteA])
  #expect(subscription.selectedSnapshot.windows.first?.usedPercent == 25)
}

@Test
func inputOrderDoesNotChangeResolvedSubscriptions() {
  let observations = [
    observation(
      source: remoteB,
      provider: .claude,
      fingerprint: "beta",
      scope: .global,
      observedAt: resolverNow.addingTimeInterval(-20)
    ),
    observation(
      source: localSource,
      provider: .codex,
      fingerprint: "alpha",
      scope: .source
    ),
    observation(
      source: remoteA,
      provider: .claude,
      fingerprint: "beta",
      scope: .global,
      observedAt: resolverNow.addingTimeInterval(-10)
    ),
    observation(
      source: remoteB,
      provider: .grok,
      fingerprint: "gamma",
      scope: .source
    ),
  ]
  let resolver = SubscriptionResolver()
  let expected = resolver.resolve(observations, now: resolverNow)
  let reordered = [observations[2], observations[0], observations[3], observations[1]]

  #expect(resolver.resolve(Array(observations.reversed()), now: resolverNow) == expected)
  #expect(resolver.resolve(reordered, now: resolverNow) == expected)
}

private func observation(
  source: QuotaObservationSource,
  provider: ProviderID = .codex,
  fingerprint: String,
  scope: FingerprintScope,
  status: QuotaStatus = .available,
  usedPercent: Double = 50,
  observedAt: Date = resolverNow,
  validUntil: Date? = resolverNow.addingTimeInterval(300)
) -> QuotaObservation {
  QuotaObservation(
    snapshot: QuotaSnapshot(
      provider: provider,
      account: QuotaAccount(
        fingerprint: fingerprint,
        label: nil,
        plan: nil,
        fingerprintScope: scope
      ),
      windows: [
        QuotaWindow(
          id: "primary",
          title: "Primary",
          usedPercent: usedPercent,
          resetsAt: nil,
          durationSeconds: nil
        )
      ],
      source: "provider-reported-source",
      status: status,
      observedAt: observedAt,
      validUntil: validUntil
    ),
    source: source
  )
}
