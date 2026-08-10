import Foundation
import Testing

@testable import QuotaBar

private let resolverNow = Date(timeIntervalSince1970: 1_785_758_400)
private let localSource = QuotaObservationSource.local
private let deviceA = QuotaObservationSource.device(deviceID: "device-a")
private let deviceB = QuotaObservationSource.device(deviceID: "device-b")
private let deviceC = QuotaObservationSource.device(deviceID: "device-c")

@Test
func mergesGlobalAccountObservationsWithoutAccumulatingPercentages() throws {
  let observations = [
    observation(
      source: deviceB,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 80,
      observedAt: resolverNow.addingTimeInterval(-20)
    ),
    observation(
      source: deviceA,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 30,
      observedAt: resolverNow.addingTimeInterval(-10)
    ),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)
  let subscription = try #require(subscriptions.first)

  #expect(subscriptions.count == 1)
  #expect(subscription.sources == [deviceA, deviceB])
  #expect(subscription.selectedSource == deviceA)
  #expect(subscription.selectedSnapshot.windows.first?.usedPercent == 30)
}

@Test
func mergesLocalAndDeviceGlobalObservationsAndPrefersLocalOnATie() throws {
  let device = observation(
    source: deviceA,
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
    SubscriptionResolver().resolve([device, local], now: resolverNow).first
  )

  #expect(subscription.sources == [localSource, deviceA])
  #expect(subscription.selectedSource == localSource)
  #expect(subscription.selectedSnapshot.windows.first?.usedPercent == 20)
}

@Test
func sourceScopedAccountsStaySeparateAcrossObservationSources() {
  let observations = [
    observation(source: localSource, fingerprint: "account-1", scope: .source),
    observation(source: deviceA, fingerprint: "account-1", scope: .source),
    observation(source: deviceB, fingerprint: "account-1", scope: .source),
    observation(source: deviceC, fingerprint: "account-1", scope: .source),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)

  #expect(subscriptions.count == 4)
  #expect(
    subscriptions.map(\.sources) == [
      [localSource],
      [deviceA],
      [deviceB],
      [deviceC],
    ]
  )
}

@Test
func globalAndSourceScopesNeverShareAGroup() {
  let observations = [
    observation(source: deviceA, fingerprint: "account-1", scope: .global),
    observation(source: deviceA, fingerprint: "account-1", scope: .source),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)

  #expect(subscriptions.count == 2)
  #expect(subscriptions.map(\.identity.scope) == [.global, .source(deviceA)])
}

@Test
func providersNeverShareAGroupAndUseProductOrder() {
  let observations = [
    observation(source: deviceA, provider: .grok, fingerprint: "account-1", scope: .global),
    observation(source: deviceA, provider: .claude, fingerprint: "account-1", scope: .global),
    observation(source: deviceA, provider: .codex, fingerprint: "account-1", scope: .global),
  ]

  let subscriptions = SubscriptionResolver().resolve(observations, now: resolverNow)

  #expect(subscriptions.map(\.identity.provider) == [.codex, .claude, .grok])
}

@Test
func availableAndUnexpiredBeatsNewerStaleOrExpiredObservations() throws {
  let available = observation(
    source: deviceA,
    fingerprint: "account-1",
    scope: .global,
    usedPercent: 20,
    observedAt: resolverNow.addingTimeInterval(-30),
    validUntil: resolverNow.addingTimeInterval(30)
  )
  let stale = observation(
    source: deviceB,
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

  #expect(subscription.selectedSource == deviceA)
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
  let device = observation(
    source: deviceB,
    fingerprint: "account-1",
    scope: .global,
    observedAt: resolverNow.addingTimeInterval(-10)
  )

  let subscription = try #require(
    SubscriptionResolver().resolve([local, device], now: resolverNow).first
  )

  #expect(subscription.selectedSource == deviceB)
}

@Test
func sourceStableIDBreaksAnOtherwiseExactDeviceTie() throws {
  let observations = [
    observation(source: deviceB, fingerprint: "account-1", scope: .global),
    observation(source: deviceA, fingerprint: "account-1", scope: .global),
  ]

  let subscription = try #require(
    SubscriptionResolver().resolve(observations, now: resolverNow).first
  )

  #expect(subscription.selectedSource == deviceA)
}

@Test
func derivesStalenessAtTheValidityBoundaryAndFromStatus() {
  let expiredAtBoundary = observation(
    source: deviceA,
    fingerprint: "expired",
    scope: .global,
    validUntil: resolverNow
  )
  let staleStatus = observation(
    source: deviceA,
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
      source: deviceA,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 10,
      observedAt: resolverNow.addingTimeInterval(-20)
    ),
    observation(
      source: deviceA,
      fingerprint: "account-1",
      scope: .global,
      usedPercent: 25,
      observedAt: resolverNow.addingTimeInterval(-10)
    ),
  ]

  let subscription = try #require(
    SubscriptionResolver().resolve(observations, now: resolverNow).first
  )

  #expect(subscription.sources == [deviceA])
  #expect(subscription.selectedSnapshot.windows.first?.usedPercent == 25)
}

@Test
func inputOrderDoesNotChangeResolvedSubscriptions() {
  let observations = [
    observation(
      source: deviceB,
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
      source: deviceA,
      provider: .claude,
      fingerprint: "beta",
      scope: .global,
      observedAt: resolverNow.addingTimeInterval(-10)
    ),
    observation(
      source: deviceB,
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
