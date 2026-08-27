import Foundation
import QuotaRelay
import QuotaWire

public enum AccountClientError: Error, Equatable, Sendable {
  case notSignedIn
  case sessionExpired
  case cancelled
  case callbackMismatch
  case stateMismatch
  case missingAuthorizationCode
  case unexpectedCallbackToken
  case accountMismatch
  case relay(RelayClientError)
}

public struct AccountRefreshResult: Equatable, Sendable {
  public var summary: AccountSummary?
  public var fetchedAt: Date?
  public var fromCache: Bool
  public var error: AccountClientError?

  public init(
    summary: AccountSummary?,
    fetchedAt: Date?,
    fromCache: Bool,
    error: AccountClientError? = nil
  ) {
    self.summary = summary
    self.fetchedAt = fetchedAt
    self.fromCache = fromCache
    self.error = error
  }
}

public actor AccountClient {
  private let relay: RelayClient
  private let sessionStore: any AccountSessionStore
  private let summaryStore: any AccountSummaryStore
  private let calendar: Calendar
  private let now: @Sendable () -> Date
  private var refreshWaiters: [CheckedContinuation<AccountSession, Error>] = []
  private var isRefreshing = false

  public init(
    relay: RelayClient = RelayClient(),
    sessionStore: any AccountSessionStore,
    summaryStore: any AccountSummaryStore,
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.relay = relay
    self.sessionStore = sessionStore
    self.summaryStore = summaryStore
    self.calendar = calendar
    self.now = now
  }

  public func hasSession() throws -> Bool {
    try sessionStore.load() != nil
  }

  public func loadCachedSummary() throws -> CachedAccountSummary? {
    try loadBoundCachedSummary()
  }

  public func completeLogin(callback: URL, expected: AuthorizationAttempt) async throws
    -> AccountSession
  {
    let code: String
    do {
      code = try OAuthCallback.parse(callback, expected: expected)
    } catch let error as AuthorizationError {
      throw mapAuthorization(error)
    }
    do {
      let tokens = try await relay.exchangeAuthorizationCode(
        code: code,
        verifier: expected.verifier
      )
      let session = AccountSession(tokens)
      try persist(session)
      return session
    } catch let error as RelayClientError {
      throw AccountClientError.relay(error)
    }
  }

  public func fetchTodaySummary() async -> AccountRefreshResult {
    let cached = try? loadBoundCachedSummary()
    do {
      guard try sessionStore.load() != nil else {
        return AccountRefreshResult(
          summary: nil,
          fetchedAt: nil,
          fromCache: false,
          error: .notSignedIn
        )
      }
      let read = try await fetchSummary(cached: cached, allowRefresh: true)
      let fetchedAt = now()
      try summaryStore.save(
        CachedAccountSummary(summary: read.summary, fetchedAt: fetchedAt, etag: read.etag))
      return AccountRefreshResult(
        summary: read.summary,
        fetchedAt: fetchedAt,
        fromCache: false
      )
    } catch let error as AccountClientError {
      return failureResult(cached: cached, error: error)
    } catch let error as RelayClientError {
      return failureResult(cached: cached, error: .relay(error))
    } catch {
      return failureResult(cached: cached, error: .relay(.unavailable))
    }
  }

  private func loadBoundCachedSummary() throws -> CachedAccountSummary? {
    let cached = try summaryStore.load()
    guard let cached else { return nil }
    guard let session = try sessionStore.load() else {
      try? summaryStore.clear()
      return nil
    }
    guard cached.summary.account.accountID == session.accountID else {
      try? summaryStore.clear()
      return nil
    }
    return cached
  }

  private func failureResult(
    cached: CachedAccountSummary?,
    error: AccountClientError
  ) -> AccountRefreshResult {
    AccountRefreshResult(
      summary: cached?.summary,
      fetchedAt: cached?.fetchedAt,
      fromCache: cached != nil,
      error: error
    )
  }

  public func logout() async {
    let refreshToken = try? sessionStore.load()?.refreshToken
    try? sessionStore.clear()
    try? summaryStore.clear()
    if let refreshToken {
      try? await relay.revokeSession(refreshToken: refreshToken)
    }
  }

  /// The summary this read leaves current, and the validator it is current at.
  ///
  /// `cached` is the account-bound stored read, so its validator is only ever offered back for
  /// the account the session belongs to.
  private func fetchSummary(
    cached: CachedAccountSummary?,
    allowRefresh: Bool
  ) async throws -> (summary: AccountSummary, etag: String?) {
    guard let session = try sessionStore.load() else {
      throw AccountClientError.notSignedIn
    }
    let held = cached?.summary.account.accountID == session.accountID ? cached : nil
    let timeZone = calendar.timeZone.identifier
    do {
      let read = try await relay.fetchAccountSummary(
        timeZone: timeZone,
        accessToken: session.accessToken,
        etag: held?.etag
      )
      return try resolve(read, held: held, session: session)
    } catch RelayClientError.unauthorized where allowRefresh {
      let refreshed = try await refreshSessionAfterUnauthorized()
      let read = try await relay.fetchAccountSummary(
        timeZone: timeZone,
        accessToken: refreshed.accessToken,
        etag: held?.etag
      )
      return try resolve(read, held: held, session: refreshed)
    } catch let error as AccountClientError {
      throw error
    } catch let error as RelayClientError {
      throw AccountClientError.relay(error)
    }
  }

  private func resolve(
    _ read: AccountSummaryRead,
    held: CachedAccountSummary?,
    session: AccountSession
  ) throws -> (summary: AccountSummary, etag: String?) {
    switch read {
    case .modified(let summary, let etag):
      return (try bound(summary, to: session), etag)
    case .unchanged(let etag):
      // A 304 the caller cannot honour would be answering from nothing; it can only happen if
      // the stored read was dropped between offering its validator and reading the reply.
      guard let held else { throw AccountClientError.relay(.invalidResponse) }
      return (try bound(held.summary, to: session), etag)
    }
  }

  private func bound(_ summary: AccountSummary, to session: AccountSession) throws -> AccountSummary
  {
    guard summary.account.accountID == session.accountID else {
      throw AccountClientError.accountMismatch
    }
    return summary
  }

  private func refreshSessionAfterUnauthorized() async throws -> AccountSession {
    if isRefreshing {
      return try await withCheckedThrowingContinuation { continuation in
        refreshWaiters.append(continuation)
      }
    }
    isRefreshing = true
    defer {
      isRefreshing = false
    }
    do {
      let session = try await performRefresh()
      finishRefresh(returning: session)
      return session
    } catch {
      finishRefresh(throwing: error)
      throw error
    }
  }

  private func performRefresh() async throws -> AccountSession {
    guard let current = try sessionStore.load() else {
      throw AccountClientError.notSignedIn
    }
    do {
      let rotated = try await relay.refreshSession(refreshToken: current.refreshToken)
      guard rotated.accountID == current.accountID else {
        throw AccountClientError.accountMismatch
      }
      let session = AccountSession(rotated)
      try persist(session)
      return session
    } catch RelayClientError.invalidGrant {
      try? sessionStore.clear()
      try? summaryStore.clear()
      throw AccountClientError.sessionExpired
    } catch RelayClientError.unauthorized {
      try? sessionStore.clear()
      try? summaryStore.clear()
      throw AccountClientError.sessionExpired
    } catch let error as RelayClientError {
      throw AccountClientError.relay(error)
    }
  }

  private func persist(_ session: AccountSession) throws {
    guard session.isValid else { throw AccountStoreError.invalidSession }
    try sessionStore.save(session)
  }

  private func finishRefresh(returning session: AccountSession) {
    let waiters = refreshWaiters
    refreshWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: session)
    }
  }

  private func finishRefresh(throwing error: Error) {
    let waiters = refreshWaiters
    refreshWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(throwing: error)
    }
  }

  private func mapAuthorization(_ error: AuthorizationError) -> AccountClientError {
    switch error {
    case .cancelled: .cancelled
    case .callbackMismatch: .callbackMismatch
    case .stateMismatch: .stateMismatch
    case .missingAuthorizationCode: .missingAuthorizationCode
    case .unexpectedCallbackToken: .unexpectedCallbackToken
    default: .callbackMismatch
    }
  }
}
