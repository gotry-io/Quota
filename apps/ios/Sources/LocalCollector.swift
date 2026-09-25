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
  private let now: @Sendable () -> Date

  init(
    sessions: any ProviderSessionStoring,
    transport: any ProviderWebTransport = URLSessionProviderWebTransport(),
    clientVersion: String = ProviderWebLogin.clientVersion(),
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
      now: now
    )
  }

  init(
    sessions: any ProviderSessionStoring,
    collectors: @escaping CollectorFactory,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sessions = sessions
    self.collectors = collectors
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
  func collect(
    within budget: Duration,
    onAnswer: @escaping @Sendable (Answer) async -> Void = { _ in }
  ) async -> Pass {
    let stored = (try? sessions.list()) ?? []
    let moment = now()
    var collection = LocalCollection(collectedAt: moment)
    var answered = 0
    await withTaskGroup(of: Answer?.self) { group in
      for session in stored {
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
        case .reading(let snapshot): collection.snapshots.append(snapshot)
        case .needsSignIn: collection.needsSignIn.append(answer.sessionKey)
        case .unanswered: break
        }
        await onAnswer(answer)
      }
      group.cancelAll()
    }
    collection.snapshots.sort { $0.account.fingerprint < $1.account.fingerprint }
    collection.needsSignIn.sort()
    return Pass(
      collection: collection,
      sessionKeys: stored.map(\.key),
      isComplete: answered == stored.count
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
    } catch {
      return Answer(sessionKey: session.key, kind: .unanswered)
    }
  }
}
