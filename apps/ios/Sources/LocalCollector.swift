import Foundation
import QuotaProviderSessions
import QuotaProviderWeb
import QuotaWire

/// One local collection pass: every provider session this phone signed in for is asked for a
/// reading of its own account.
///
/// This is the whole of what [ADR 0034](../../../docs/decisions/0034-ios-collects-for-itself.md)
/// lets the phone do with a session it holds — read the provider, on this device, for this
/// reader. Nothing collected here is uploaded.
struct LocalCollector: Sendable {
  /// What a pull-to-refresh will wait for. Each reading reaches the screen as it arrives, so this
  /// bounds only how long the slowest provider is waited on.
  static let foregroundBudget: Duration = .seconds(30)

  /// What a `BGAppRefreshTask` will wait for. The system grants seconds, not minutes, and a pass
  /// that runs past this leaves the last reading in place rather than nothing at all.
  static let backgroundBudget: Duration = .seconds(20)

  /// Which collector answers for a provider. Injected so a test can state what a provider
  /// answered without standing up one provider's exchanges to say it.
  typealias CollectorFactory = @Sendable (ProviderID, Date) -> (any ProviderWebCollector)?

  private let sessions: any ProviderSessionStoring
  private let collectors: CollectorFactory
  private let backoff: any ProviderBackoffStoring
  private let now: @Sendable () -> Date

  init(
    sessions: any ProviderSessionStoring,
    transport: any ProviderWebTransport = URLSessionProviderWebTransport(),
    clientVersion: String = ProviderWebLogin.clientVersion(),
    backoff: any ProviderBackoffStoring = UserDefaultsProviderBackoffStore(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      sessions: sessions,
      collectors: { provider, moment in
        ProviderWebLogin.collector(
          for: provider,
          transport: transport,
          clientVersion: clientVersion,
          now: moment
        )
      },
      backoff: backoff,
      now: now
    )
  }

  init(
    sessions: any ProviderSessionStoring,
    collectors: @escaping CollectorFactory,
    backoff: any ProviderBackoffStoring = MemoryProviderBackoffStore(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sessions = sessions
    self.collectors = collectors
    self.backoff = backoff
    self.now = now
  }

  /// One provider session's answer in a pass.
  struct Answer: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      case reading(QuotaSnapshot)
      /// The provider refused the cookie. Only a fresh sign-in fixes it.
      case needsSignIn
      /// The provider could not be reached, which says nothing about the session.
      case unanswered
      /// The provider answered 429 to this read. It is backed off, and its last reading stands.
      case rateLimited(retryAfterSeconds: Int?)
      /// Not asked: the provider is still backed off from an earlier 429. Its last reading stands.
      case held
    }

    let sessionKey: String
    let kind: Kind
  }

  /// What one pass read, and whether every session it asked answered before the budget ran out.
  struct Pass: Equatable, Sendable {
    var collection: LocalCollection
    /// Every session this pass asked, answered or not.
    var sessionKeys: [String]
    var isComplete: Bool
    /// Sessions a provider asked to be left alone for: rate limited now, or still backed off.
    /// Their last reading is kept rather than dropped.
    var heldSessionKeys: [String] = []
  }

  /// The key of the stored session a reading answers for: the provider and the account the
  /// provider named, which is what the session was stored under when it was validated.
  static func sessionKey(for snapshot: QuotaSnapshot) -> String {
    "\(snapshot.provider.rawValue):\(snapshot.account.fingerprint)"
  }

  /// One pass: every stored session is read in parallel, because sessions are independent
  /// accounts and one slow provider must not hold up the rest. Each answer is handed to
  /// `onAnswer` the moment it arrives, so the screen can show it before the slowest provider
  /// finishes.
  ///
  /// The pass is abandoned at `budget`. A pass cut short keeps the answers that did arrive and
  /// says it is incomplete: a phone that was woken briefly should show what it managed to read,
  /// and the last quota it knows for the rest, not none.
  ///
  /// A provider that answered 429 is not asked again until its backoff runs out
  /// ([ADR 0063](../../../docs/decisions/0063-collection-follows-demand-and-activity.md)).
  /// A `manual` pass — pull to refresh, the refresh button — may ask it anyway, once a minute.
  func collect(
    within budget: Duration,
    manual: Bool = false,
    onAnswer: @escaping @Sendable (Answer) async -> Void = { _ in }
  ) async -> Pass {
    let stored = (try? sessions.list()) ?? []
    let moment = now()
    var collection = LocalCollection(collectedAt: moment)
    var answered = 0
    var schedule = backoff.load()
    var asked: [StoredProviderSession] = []
    var held: [String] = []
    for session in stored {
      if schedule.admits(session.key, now: moment, manual: manual) {
        asked.append(session)
      } else {
        held.append(session.key)
      }
    }
    for key in held {
      answered += 1
      await onAnswer(Answer(sessionKey: key, kind: .held))
    }
    await withTaskGroup(of: Answer?.self) { group in
      for session in asked {
        group.addTask { await read(session, at: moment) }
      }
      group.addTask {
        try? await Task.sleep(for: budget)
        return nil
      }
      while answered < stored.count, let next = await group.next() {
        // The budget ran out first.
        guard let answer = next else { break }
        answered += 1
        switch answer.kind {
        case .reading(let snapshot):
          collection.snapshots.append(snapshot)
          schedule.answered(answer.sessionKey)
        case .needsSignIn: collection.needsSignIn.append(answer.sessionKey)
        case .rateLimited(let retryAfterSeconds):
          schedule.rateLimited(
            answer.sessionKey, retryAfterSeconds: retryAfterSeconds, now: moment)
          held.append(answer.sessionKey)
        case .unanswered, .held: break
        }
        await onAnswer(answer)
      }
      group.cancelAll()
    }
    backoff.save(schedule)
    collection.snapshots.sort { $0.account.fingerprint < $1.account.fingerprint }
    collection.needsSignIn.sort()
    return Pass(
      collection: collection,
      sessionKeys: stored.map(\.key),
      isComplete: answered == stored.count,
      heldSessionKeys: held.sorted()
    )
  }

  private func read(_ session: StoredProviderSession, at moment: Date) async -> Answer {
    guard let collector = collectors(session.provider, moment) else {
      return Answer(sessionKey: session.key, kind: .unanswered)
    }
    do {
      let snapshot = try await collector.collect(cookieHeader: session.cookieHeader)
      // The provider answered for this cookie, so Settings can say when it last did. Without
      // this the Providers list would say "Checked" as of the sign-in, forever.
      try? sessions.upsert(
        StoredProviderSession(
          provider: session.provider,
          accountFingerprint: session.accountFingerprint,
          cookieHeader: session.cookieHeader,
          accountLabel: session.accountLabel,
          storedAt: session.storedAt,
          lastValidatedAt: moment
        )
      )
      return Answer(sessionKey: session.key, kind: .reading(snapshot))
    } catch let error as ProviderWebError where error.category == .authRequired {
      return Answer(sessionKey: session.key, kind: .needsSignIn)
    } catch let error as ProviderWebError where error.rateLimit != nil {
      return Answer(
        sessionKey: session.key,
        kind: .rateLimited(retryAfterSeconds: error.rateLimit?.retryAfterSeconds))
    } catch {
      return Answer(sessionKey: session.key, kind: .unanswered)
    }
  }
}
