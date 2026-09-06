import Foundation
import QuotaProviderSessions
import QuotaProviderWeb
import QuotaWire
import Testing

@testable import Quota

/// One provider, stated as what it answers rather than as a queue of HTTP exchanges. What each
/// collector reads off the wire is `provider-web-conformance.json`'s business.
private struct StubCollector: ProviderWebCollector {
  static var provider: ProviderID { .codex }

  let answer: @Sendable (String) async throws -> QuotaSnapshot

  func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    ValidatedBrowserSession(accountFingerprint: "fp", accountLabel: nil)
  }

  func collect(cookieHeader: String) async throws -> QuotaSnapshot {
    try await answer(cookieHeader)
  }
}

private let now = Date(timeIntervalSince1970: 1_786_723_200)

private func snapshot(
  provider: ProviderID = .codex,
  fingerprint: String,
  usedPercent: Double = 20,
  observedAt: Date = now
) -> QuotaSnapshot {
  QuotaSnapshot(
    provider: provider,
    account: QuotaAccount(fingerprint: fingerprint, fingerprintScope: .global),
    windows: [
      QuotaWindow(
        id: "weekly",
        title: "Weekly",
        usedPercent: usedPercent,
        durationSeconds: 604_800
      )
    ],
    status: .available,
    observedAt: observedAt
  )
}

private func session(
  _ provider: ProviderID,
  _ fingerprint: String,
  validatedAt: Date = now.addingTimeInterval(-86_400)
) -> StoredProviderSession {
  StoredProviderSession(
    provider: provider,
    accountFingerprint: fingerprint,
    cookieHeader: "session=\(fingerprint)",
    accountLabel: nil,
    storedAt: now.addingTimeInterval(-172_800),
    lastValidatedAt: validatedAt
  )
}

struct LocalCollectorTests {
  @Test
  func readsEverySessionAndStampsTheOnesThatAnswered() async throws {
    let store = MemoryProviderSessionStore(
      sessions: [session(.codex, "one"), session(.claude, "two")]
    )
    let collector = LocalCollector(
      sessions: store,
      collectors: { provider, _ in
        StubCollector { header in
          snapshot(provider: provider, fingerprint: header.contains("one") ? "one" : "two")
        }
      },
      now: { now }
    )

    let collection = await collector.collect()

    #expect(collection.collectedAt == now)
    #expect(collection.snapshots.map(\.account.fingerprint) == ["one", "two"])
    #expect(collection.needsSignIn.isEmpty)
    // Without this, the Providers list would keep saying "Checked" as of the sign-in forever.
    #expect(try store.list().map(\.lastValidatedAt) == [now, now])
  }

  /// Only a fresh sign-in fixes a refused cookie, so that session is named. A provider that could
  /// not be reached says nothing about the session and leaves no mark.
  @Test
  func namesOnlyTheSessionsTheProviderRefused() async throws {
    let store = MemoryProviderSessionStore(
      sessions: [session(.codex, "refused"), session(.claude, "offline")]
    )
    let collector = LocalCollector(
      sessions: store,
      collectors: { provider, _ in
        StubCollector { _ in
          throw ProviderWebError(
            provider == .codex ? .authRequired : .unavailable, "stub")
        }
      },
      now: { now }
    )

    let collection = await collector.collect()

    #expect(collection.snapshots.isEmpty)
    #expect(collection.needsSignIn == ["codex:refused"])
    // A refused read is not a successful one, so neither session's "Checked" age moves.
    #expect(try store.list().allSatisfy { $0.lastValidatedAt == now.addingTimeInterval(-86_400) })
  }

  /// A background window is seconds long. A pass that outlives its budget answers nothing, and
  /// the caller keeps the readings it already had rather than showing none.
  @Test
  func aPassPastItsBudgetAnswersNothing() async throws {
    let collector = LocalCollector(
      sessions: MemoryProviderSessionStore(sessions: [session(.codex, "slow")]),
      collectors: { provider, _ in
        StubCollector { _ in
          try? await Task.sleep(for: .seconds(30))
          return snapshot(provider: provider, fingerprint: "slow")
        }
      },
      now: { now }
    )

    let collection = await collector.collect(within: Duration.milliseconds(50))
    #expect(collection == nil)
  }
}

struct LocalObservationMergeTests {
  private let studio = "device_studio"
  private let kitchen = "device_kitchen"

  /// With no account, this phone's readings are the whole list, attributed to this phone.
  @Test
  func aLocalOnlyReadingBecomesItsOwnSubscription() throws {
    let merged = LocalObservationMerge.subscriptions(
      local: [snapshot(fingerprint: "fp")],
      resolved: [],
      now: now
    )
    #expect(merged.count == 1)
    #expect(merged[0].key == "codex|fp|global|")
    #expect(merged[0].sources.map(\.deviceID) == [ThisDevice.sourceID])
  }

  /// The same account read on a Mac and on this phone is one subscription, not two cards.
  @Test
  func theSameAccountReadTwiceIsOneRowWithBothSources() throws {
    let older = snapshot(
      fingerprint: "fp", usedPercent: 40, observedAt: now.addingTimeInterval(-600))
    let newer = snapshot(
      fingerprint: "fp", usedPercent: 41, observedAt: now.addingTimeInterval(-60))
    let merged = LocalObservationMerge.subscriptions(
      local: [newer],
      resolved: [resolved(snapshot: older, deviceIDs: [studio])],
      now: now
    )
    #expect(merged.count == 1)
    #expect(merged[0].snapshot == newer)
    #expect(merged[0].sources.map(\.deviceID).sorted() == [studio, ThisDevice.sourceID].sorted())
  }

  /// Relay's key is the one every client addresses a subscription by, including a deep link, so
  /// merging must not rename the row.
  @Test
  func aResolvedRowKeepsTheKeyRelayWrote() throws {
    let reading = snapshot(fingerprint: "fp")
    let merged = LocalObservationMerge.subscriptions(
      local: [],
      resolved: [resolved(snapshot: reading, deviceIDs: [studio, kitchen])],
      now: now
    )
    #expect(merged.map(\.key) == ["codex|fp|global|"])
    #expect(merged[0].sources.count == 2)
  }

  private func resolved(snapshot: QuotaSnapshot, deviceIDs: [String]) -> QuotaSubscription {
    QuotaSubscription(
      key: "codex|\(snapshot.account.fingerprint)|global|",
      provider: snapshot.provider,
      snapshot: snapshot,
      sources: deviceIDs.map {
        QuotaSubscriptionSource(deviceID: $0, observedAt: snapshot.observedAt, snapshot: snapshot)
      }
    )
  }
}

@MainActor
struct LocalModeAppModelTests {
  /// A phone with a provider sign-in and no Quota account is a working app: it refreshes, it has
  /// subscriptions, it publishes a widget snapshot, and it asks to be woken again.
  @Test
  func refreshWithoutAnAccountCollectsLocallyAndPublishes() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let scheduler = RecordingBackgroundRefreshScheduler()
    let sessions = MemoryProviderSessionStore(sessions: [session(.codex, "fp")])
    let model = makeModel(
      session: nil,
      cache: nil,
      exchanges: [],
      widgetPublisher: publisher,
      backgroundRefresh: scheduler,
      providerSessions: sessions,
      localCollector: LocalCollector(
        sessions: sessions,
        collectors: { provider, _ in
          StubCollector { _ in snapshot(provider: provider, fingerprint: "fp") }
        },
        now: { now }
      ),
      now: { now }
    )

    #expect(await model.refresh())
    #expect(model.phase == .signedOut)
    #expect(model.hasAccountSession == false)
    #expect(model.subscriptions.map(\.key) == ["codex|fp|global|"])
    #expect(model.overviewSources == OverviewSources(hasLocal: true, hasAccount: false))
    #expect(publisher.publishCount == 1)
    #expect(publisher.clearCount == 0)
    // Today is the Account's fold; this phone measured none.
    #expect(publisher.lastPublished?.today.cost.status == .unavailable)
    // There is something to read, so there is something to be woken for.
    #expect(scheduler.scheduleCount == 1)
    #expect(scheduler.cancelCount == 0)
  }

  /// The provider sign-ins are not the account's, so losing the account loses neither them nor
  /// the readings they produced.
  @Test
  func loggingOutKeepsWhatThisPhoneReadAndItsBackgroundWindow() async throws {
    let scheduler = RecordingBackgroundRefreshScheduler()
    let sessions = MemoryProviderSessionStore(sessions: [session(.codex, "fp")])
    let model = makeModel(
      session: nil,
      cache: nil,
      exchanges: [],
      backgroundRefresh: scheduler,
      providerSessions: sessions,
      localCollector: LocalCollector(
        sessions: sessions,
        collectors: { provider, _ in
          StubCollector { _ in snapshot(provider: provider, fingerprint: "fp") }
        },
        now: { now }
      ),
      now: { now }
    )
    #expect(await model.refresh())

    await model.logout()

    #expect(model.subscriptions.count == 1)
    #expect(scheduler.cancelCount == 0)
    #expect(scheduler.scheduleCount == 2)
  }

  /// A refused cookie is only fixed by signing in again, so Settings is told which session it is.
  @Test
  func aRefusedSessionIsMarkedForSignIn() async throws {
    let sessions = MemoryProviderSessionStore(sessions: [session(.codex, "fp")])
    let model = makeModel(
      session: nil,
      cache: nil,
      exchanges: [],
      providerSessions: sessions,
      localCollector: LocalCollector(
        sessions: sessions,
        collectors: { _, _ in
          StubCollector { _ in throw ProviderWebError(.authRequired, "stub") }
        },
        now: { now }
      ),
      now: { now }
    )

    await model.refresh()

    #expect(model.subscriptions.isEmpty)
    #expect(model.providers.needsSignIn(session(.codex, "fp")))
  }

  /// The system grants a background task seconds. Anything longer is a pass that gets killed
  /// mid-flight rather than one that leaves the last reading in place.
  @Test
  func theBackgroundBudgetFitsInsideABackgroundTask() {
    #expect(LocalCollector.backgroundBudget <= .seconds(20))
  }
}
