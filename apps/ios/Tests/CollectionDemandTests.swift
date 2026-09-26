import Foundation
import QuotaAccount
import QuotaProviderSessions
import QuotaProviderWeb
import QuotaRelay
import QuotaWire
import Testing
import os

@testable import Quota

private let now = Fixtures.date("2026-08-14T16:00:00Z")
private let requestedAt = Fixtures.date("2026-08-14T16:00:05Z")
private let macID = "device_mac_1"
private let phoneID = "device_phone_1"

/// The Macs are asked only about what they last sent, and only when it is older than two
/// minutes or the provider's floor, whichever is longer.
struct CollectionDemandRuleTests {
  @Test
  func onlyAMacReadingOlderThanTwoMinutesOrItsProvidersFloorIsWorthAsking() throws {
    let summary = try accountSummary(subscriptions: [
      subscription("fresh", provider: .codex, sources: [(macID, now.addingTimeInterval(-60))]),
      subscription("stale", provider: .codex, sources: [(macID, now.addingTimeInterval(-121))]),
      // Claude's floor is three minutes: a Mac would not ask it again any sooner.
      subscription(
        "claude_inside_floor", sources: [(macID, now.addingTimeInterval(-179))]),
      subscription("claude_stale", sources: [(macID, now.addingTimeInterval(-181))]),
      // This phone's own reading is old, but a Mac is what answers a request.
      subscription("phone", sources: [(phoneID, now.addingTimeInterval(-600))]),
      // A second Mac read the same account recently, so nothing is waiting on the first.
      subscription(
        "both",
        sources: [(macID, now.addingTimeInterval(-600)), ("device_mac_2", now)]),
    ])

    let demand = try #require(
      CollectionDemand.stale(in: summary, selfDeviceID: phoneID, now: now))
    #expect(demand.subscriptionKeys == ["stale", "claude_stale"])
    #expect(demand.macCount == 1)

    let fresh = try accountSummary(subscriptions: [
      subscription("fresh", sources: [(macID, now.addingTimeInterval(-60))])
    ])
    #expect(CollectionDemand.stale(in: fresh, selfDeviceID: phoneID, now: now) == nil)
  }
}

/// Retry-After is honoured up to an hour; without one the wait is 5, 10, 20, then 30 minutes. A
/// manual refresh passes a held provider once a minute, and a reading starts the schedule over,
/// though the five-minute floor a 429 raises lasts its day.
struct ProviderBackoffTests {
  @Test
  func retryAfterIsHonouredAndOtherwiseTheWaitDoublesToThirtyMinutes() {
    var backoff = ProviderBackoff()
    backoff.rateLimited("claude:a", retryAfterSeconds: 7_200, now: now)
    #expect(backoff.entries["claude:a"]?.until == now.addingTimeInterval(3_600))

    var waits: [Int] = []
    for _ in 0..<4 {
      backoff.rateLimited("codex:b", retryAfterSeconds: 0, now: now)
      waits.append(backoff.entries["codex:b"]?.delaySeconds ?? 0)
    }
    #expect(waits == [300, 600, 1_200, 1_800])

    backoff.answered("codex:b")
    backoff.rateLimited("codex:b", retryAfterSeconds: nil, now: now)
    #expect(backoff.entries["codex:b"]?.delaySeconds == 300)
  }

  @Test
  func aManualRefreshPassesAHeldProviderOnceAMinute() {
    var backoff = ProviderBackoff()
    backoff.rateLimited("claude:a", retryAfterSeconds: nil, now: now)
    let answers = [(10, false), (10, true), (40, true), (71, true), (371, false)].map {
      backoff.admits("claude:a", now: now.addingTimeInterval(TimeInterval($0.0)), manual: $0.1)
    }
    #expect(answers == [false, true, false, true, true])
  }

  @Test
  func aRateLimitedSessionIsReadAtMostEveryFiveMinutesForADayAfterItAnswers() {
    var backoff = ProviderBackoff()
    backoff.rateLimited("claude:a", retryAfterSeconds: 60, now: now)
    backoff.answered("claude:a")
    let asks = [
      (120, false), (300, false), (420, false), (420, true), (86_300, false), (86_400, false),
    ].map {
      backoff.admits("claude:a", now: now.addingTimeInterval(TimeInterval($0.0)), manual: $0.1)
    }
    // A manual refresh is not held by the floor, and the floor ends with its day.
    #expect(asks == [false, true, false, true, true, true])
  }
}

@MainActor
struct LocalCollectorBackoffTests {
  /// A 429 keeps the reading already on screen, and the wait outlives the process: the next pass
  /// — even from a fresh collector over the same defaults — does not ask that provider at all.
  @Test
  func aRateLimitedProviderKeepsItsReadingAndIsNotAskedAgainAfterARelaunch() async throws {
    let defaults = UserDefaults(suiteName: "QuotaTests.Backoff.\(UUID().uuidString)")!
    let sessions = MemoryProviderSessionStore(sessions: [storedSession()])
    let asked = OSAllocatedUnfairLock(initialState: 0)
    func collector() -> LocalCollector {
      LocalCollector(
        sessions: sessions,
        collectors: { _, _ in
          ScriptedCollector {
            asked.withLock { $0 += 1 }
            throw ProviderWebError(
              .unavailable, "stub", rateLimit: ProviderRateLimit(retryAfterSeconds: nil))
          }
        },
        backoff: UserDefaultsProviderBackoffStore(defaults: defaults),
        now: { now }
      )
    }
    let previous = LocalCollection(collectedAt: now.addingTimeInterval(-600))
    let model = makeModel(
      session: nil,
      cache: nil,
      exchanges: [],
      providerSessions: sessions,
      localStore: MemoryLocalCollectionStore(value: collectionHolding(previous)),
      localCollector: collector(),
      now: { now }
    )
    await model.restore()
    #expect(model.localCollection?.snapshots.count == 1)

    await model.refresh()
    #expect(asked.withLock { $0 } == 1)
    // The reading from before the 429 is still the one shown.
    #expect(
      model.localCollection?.snapshots.map(\.observedAt) == [now.addingTimeInterval(-600)])

    let relaunched = await collector().collect(within: LocalCollector.foregroundBudget)
    #expect(asked.withLock { $0 } == 1)
    #expect(relaunched.heldSessionKeys == [storedSession().key])
  }
}

@MainActor
struct CollectionDemandFollowUpTests {
  /// Pull to refresh on an old Mac reading: one request, then a summary read every 20 seconds
  /// until the Mac's reading is newer than the instant Relay stored.
  @Test
  func theFollowUpStopsOnceTheMacHasAnswered() async throws {
    let relay = DemandRelay(
      summaries: [try stale(), try stale(), try answered()],
      collection: (200, requestAnswer()))
    let model = try await signedInModel(relay: relay, sleep: { _ in })

    await model.refreshOnRequest()
    await model.waitForCollectionDemand()

    #expect(relay.count("/api/v6/account/collection-request") == 1)
    // The refresh's read, then two follow-up reads: the second shows the Mac's answer.
    #expect(relay.count("/api/v6/account/summary") == 3)
    #expect(model.askingMacs == nil)
  }

  /// A Mac that never answers is waited on for three minutes of reads, then the subtitle goes
  /// back to the age, with nothing said about it.
  @Test
  func aMacThatNeverAnswersIsGivenUpOnWithoutAnError() async throws {
    let relay = DemandRelay(summaries: [try stale()], collection: (200, requestAnswer()))
    let model = try await signedInModel(relay: relay, sleep: { _ in })

    await model.refreshOnRequest()
    await model.waitForCollectionDemand()

    #expect(relay.count("/api/v6/account/summary") == 1 + CollectionDemand.followUpReads)
    #expect(model.askingMacs == nil)
    #expect(model.banner == nil)
  }

  /// Leaving the foreground ends the wait: nobody is looking any more.
  @Test
  func goingToTheBackgroundEndsTheFollowUp() async throws {
    let (waiting, signal) = AsyncStream<Void>.makeStream()
    let relay = DemandRelay(summaries: [try stale()], collection: (200, requestAnswer()))
    let model = try await signedInModel(
      relay: relay,
      sleep: { _ in
        signal.yield()
        try await Task.sleep(for: .seconds(3_600))
      })

    await model.refreshOnRequest()
    var iterator = waiting.makeAsyncIterator()
    await iterator.next()
    #expect(model.askingMacs == 1)

    await model.setForeground(false)
    await model.waitForCollectionDemand()
    #expect(model.askingMacs == nil)
    #expect(relay.count("/api/v6/account/summary") == 1)
  }

  /// A Relay from before the request answers 404. That is not an error, and there is nothing to
  /// wait for.
  @Test
  func aRelayWithoutTheRequestIsSilent() async throws {
    let relay = DemandRelay(
      summaries: [try stale()],
      collection: (404, Data(#"{"error":{"code":"not_found","message":"Not found"}}"#.utf8)))
    let model = try await signedInModel(relay: relay, sleep: { _ in })

    await model.refreshOnRequest()
    await model.waitForCollectionDemand()

    #expect(relay.count("/api/v6/account/collection-request") == 1)
    #expect(relay.count("/api/v6/account/summary") == 1)
    #expect(model.askingMacs == nil)
    #expect(model.banner == nil)
  }

  private func signedInModel(
    relay: DemandRelay,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async throws -> AppModel {
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(transport: relay),
        sessionStore: MemoryAccountSessionStore(session: Fixtures.session(deviceID: phoneID)),
        summaryStore: MemoryAccountSummaryStore(),
        now: { now }
      ),
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      settingsDefaults: UserDefaults(suiteName: "QuotaTests.Demand.\(UUID().uuidString)")!,
      now: { now },
      demandSleep: sleep
    )
    model.poseSession(activation: .active, deviceID: phoneID)
    await model.setForeground(true)
    return model
  }
}

/// Relay answering by route: the summary reads in order (the last one repeats), and the
/// collection request with one fixed answer. Anything else is unreachable.
private final class DemandRelay: HTTPTransport, @unchecked Sendable {
  private struct State {
    var summaries: [Data]
    var paths: [String] = []
  }

  private let state: OSAllocatedUnfairLock<State>
  private let collection: (status: Int, body: Data)

  init(summaries: [Data], collection: (Int, Data)) {
    state = OSAllocatedUnfairLock(initialState: State(summaries: summaries))
    self.collection = collection
  }

  func count(_ path: String) -> Int {
    state.withLock { $0.paths.filter { $0 == path }.count }
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let answer: (Int, Data)? = state.withLock { state in
      state.paths.append(url.path)
      switch url.path {
      case "/api/v6/account/summary":
        let body = state.summaries.count > 1 ? state.summaries.removeFirst() : state.summaries[0]
        return (200, body)
      case "/api/v6/account/collection-request":
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data(#"{"protocol_version":6}"#.utf8))
        return collection
      default:
        return nil
      }
    }
    guard let (status, body) = answer else { throw HTTPTransportError.unavailable }
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    return (body, response)
  }
}

private struct ScriptedCollector: ProviderWebCollector {
  static var provider: ProviderID { .claude }
  let answer: @Sendable () async throws -> QuotaSnapshot

  func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    ValidatedBrowserSession(accountFingerprint: "claude_fp", accountLabel: nil)
  }

  func collect(cookieHeader: String) async throws -> QuotaSnapshot {
    try await answer()
  }
}

private func requestAnswer() -> Data {
  Data(#"{"protocol_version":6,"requested_at":"2026-08-14T16:00:05Z","accepted":true}"#.utf8)
}

private func stale() throws -> Data {
  try WireCodec.encode(
    accountSummary(subscriptions: [
      subscription("claude_sub", sources: [(macID, now.addingTimeInterval(-600))])
    ]))
}

private func answered() throws -> Data {
  try WireCodec.encode(
    accountSummary(subscriptions: [
      subscription("claude_sub", sources: [(macID, requestedAt.addingTimeInterval(25))])
    ]))
}

private func accountSummary(subscriptions: [QuotaSubscription]) throws -> AccountSummary {
  let base = try WireCodec.decode(AccountSummary.self, from: try Fixtures.accountSummaryJSON())
  let devices = [
    AccountDevice(
      id: macID, displayName: "Studio Mac", platform: .macos, lastSeenAt: now,
      lastObservedAt: now),
    AccountDevice(
      id: "device_mac_2", displayName: "Kitchen Mac", platform: .macos, lastSeenAt: now,
      lastObservedAt: now),
    AccountDevice(
      id: phoneID, displayName: "iPhone", platform: .ios, lastSeenAt: now, lastObservedAt: now),
  ]
  return AccountSummary(
    account: base.account,
    devices: devices,
    subscriptions: subscriptions,
    usage: base.usage,
    pricingRevision: base.pricingRevision,
    modelCatalogRevision: base.modelCatalogRevision
  )
}

private func subscription(
  _ key: String, provider: ProviderID = .claude, sources: [(String, Date)]
) -> QuotaSubscription {
  let newest = sources.map(\.1).max() ?? now
  let reading = snapshot(provider: provider, fingerprint: key, observedAt: newest)
  return QuotaSubscription(
    key: key,
    provider: provider,
    snapshot: reading,
    sources: sources.map {
      QuotaSubscriptionSource(deviceID: $0.0, observedAt: $0.1, snapshot: reading)
    }
  )
}

private func snapshot(provider: ProviderID, fingerprint: String, observedAt: Date) -> QuotaSnapshot
{
  QuotaSnapshot(
    provider: provider,
    account: QuotaAccount(fingerprint: fingerprint, fingerprintScope: .global),
    windows: [
      QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 20, durationSeconds: 604_800)
    ],
    status: .available,
    observedAt: observedAt
  )
}

private func storedSession() -> StoredProviderSession {
  StoredProviderSession(
    provider: .claude,
    accountFingerprint: "claude_fp",
    cookieHeader: "sessionKey=synthetic",
    accountLabel: nil,
    storedAt: now.addingTimeInterval(-86_400),
    lastValidatedAt: now.addingTimeInterval(-3_600)
  )
}

/// What this phone read before: the rate-limited Claude session's reading.
private func collectionHolding(_ collection: LocalCollection) -> LocalCollection {
  var held = collection
  held.snapshots = [
    snapshot(provider: .claude, fingerprint: "claude_fp", observedAt: collection.collectedAt)
  ]
  return held
}
