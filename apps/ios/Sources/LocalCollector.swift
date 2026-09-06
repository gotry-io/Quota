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
  /// What a pull-to-refresh will wait for. The reader is watching, and three providers answering
  /// in series can take a few seconds each.
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

  /// One pass, abandoned at `budget`. A pass that does not finish answers `nil`, and the caller
  /// keeps the readings it already had: a phone that was woken briefly should show the last
  /// quota it knows, not none.
  func collect(within budget: Duration) async -> LocalCollection? {
    await withTaskGroup(of: LocalCollection?.self) { group in
      group.addTask { await collect() }
      group.addTask {
        try? await Task.sleep(for: budget)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  /// Reads every stored session, in parallel, and answers what this phone can say about its own
  /// providers. Sessions are independent accounts, so one provider being slow does not hold up
  /// the rest of the pass.
  func collect() async -> LocalCollection {
    let stored = (try? sessions.list()) ?? []
    let moment = now()
    var collection = LocalCollection(collectedAt: moment)
    await withTaskGroup(of: Outcome.self) { group in
      for session in stored {
        group.addTask { await read(session, at: moment) }
      }
      for await outcome in group {
        switch outcome {
        case .reading(let snapshot): collection.snapshots.append(snapshot)
        case .needsSignIn(let key): collection.needsSignIn.append(key)
        case .unanswered: break
        }
      }
    }
    collection.snapshots.sort { $0.account.fingerprint < $1.account.fingerprint }
    collection.needsSignIn.sort()
    return collection
  }

  private func read(_ session: StoredProviderSession, at moment: Date) async -> Outcome {
    guard let collector = collectors(session.provider, moment) else { return .unanswered }
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
      return .reading(snapshot)
    } catch let error as ProviderWebError where error.category == .authRequired {
      return .needsSignIn(session.key)
    } catch {
      return .unanswered
    }
  }

  private enum Outcome: Sendable {
    case reading(QuotaSnapshot)
    case needsSignIn(String)
    case unanswered
  }
}
