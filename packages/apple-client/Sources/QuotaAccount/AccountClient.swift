import Foundation
import QuotaAlerts
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
  /// This session registered no Device, so there is nothing for it to write.
  case notADevice
  case relay(RelayClientError)

  init(_ error: RelayClientError) {
    self = .relay(error)
  }
}

public struct AccountRefreshResult: Equatable, Sendable {
  public var summary: AccountSummary?
  public var fetchedAt: Date?
  public var fromCache: Bool
  public var error: AccountClientError?
  /// The validator this body is current at, when the read that produced it carried one.
  public var etag: String?

  public init(
    summary: AccountSummary?,
    fetchedAt: Date?,
    fromCache: Bool,
    error: AccountClientError? = nil,
    etag: String? = nil
  ) {
    self.summary = summary
    self.fetchedAt = fetchedAt
    self.fromCache = fromCache
    self.error = error
    self.etag = etag
  }
}

/// An activity read's answer. A matching 304 returns the stored body.
public enum AccountActivityResult: Equatable, Sendable {
  case activity(AccountUsageActivityResponse)
  case failure(AccountClientError)
}

/// A period read's answer. Last-good on error is the caller's: this client keeps an ETag cache
/// so a matching 304 can return the body it already holds.
public enum AccountPeriodResult: Equatable, Sendable {
  case period(AccountUsagePeriodResponse)
  case failure(AccountClientError)
}

public actor AccountClient {
  public static let accessRefreshLead: TimeInterval = 60

  private let relay: RelayClient
  private let sessionStore: any AccountSessionStore
  private let summaryStore: any AccountSummaryStore
  private let settingsStore: any AccountSettingsStore
  private let usageStore: any AccountUsageStore
  private let calendar: Calendar
  private let now: @Sendable () -> Date
  private var refreshWaiters: [CheckedContinuation<AccountSession, Error>] = []
  private var isRefreshing = false
  /// Process-wide for this `AccountClient` (the app holds one). Filled on the first Keychain
  /// read, updated on persist, invalidated on logout / invalid_grant / account change.
  private var sessionMemo: AccountSession?
  private var sessionMemoValid = false
  /// A proactive refresh that still looks expired is clock skew, not a 15-minute token.
  private var proactiveRefreshDisabled = false
  /// In-memory period bodies keyed by `from|to|timezone|breakdown`. A matching 304 answers from here.
  private var periodCache: [String: CachedUsagePeriod] = [:]
  private var activityCache: CachedUsageActivity?
  private var snapshotUploadBusy = false
  private var snapshotUploadWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    relay: RelayClient = RelayClient(),
    sessionStore: any AccountSessionStore,
    summaryStore: any AccountSummaryStore,
    settingsStore: any AccountSettingsStore = MemoryAccountSettingsStore(),
    usageStore: any AccountUsageStore = MemoryAccountUsageStore(),
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.relay = relay
    self.sessionStore = sessionStore
    self.summaryStore = summaryStore
    self.settingsStore = settingsStore
    self.usageStore = usageStore
    self.calendar = calendar
    self.now = now
  }

  public func hasSession() throws -> Bool {
    try currentSession() != nil
  }

  public func loadSession() throws -> AccountSession? {
    try currentSession()
  }

  public func sessionPresence() -> AccountSessionPresence {
    do {
      if let session = try currentSession() {
        return .signedIn(session)
      }
      return .signedOut
    } catch AccountStoreError.unreadable {
      return .unknown
    } catch {
      return .unknown
    }
  }

  /// One Keychain read plus the caches bound to that session. A corrupt cache file is dropped
  /// and does not take the session with it.
  public func restoreLocalState() throws -> RestoredAccountState {
    let session = try currentSession()
    var summary: CachedAccountSummary?
    do {
      summary = try loadBoundCachedSummary()
    } catch {
      try? summaryStore.clear()
      summary = nil
    }
    var usage: CachedAccountUsage?
    do {
      usage = try loadBoundCachedUsage()
    } catch {
      try? usageStore.clear()
      usage = nil
    }
    if var usage {
      usage.capPeriods()
      hydrateUsageCache(usage)
    }
    return RestoredAccountState(session: session, summary: summary, usage: usage)
  }

  /// Continue is the only promotion from `pending` to `active`. Already-active is a no-op.
  public func activateSession() throws {
    guard let session = try currentSession() else {
      throw AccountClientError.notSignedIn
    }
    guard session.activation == .pending else { return }
    try persist(session.withActivation(.active))
  }

  public func loadCachedSummary() throws -> CachedAccountSummary? {
    try loadBoundCachedSummary()
  }

  /// The last settings document this session's Account answered, when one is stored.
  public func loadCachedSettings() throws -> CachedAccountSettings? {
    try loadBoundCachedSettings()
  }

  /// Finish a browser sign-in, presenting this device's installation when it has one.
  ///
  /// A phone that presents one gets a session naming a Device and may upload what it reads; one
  /// that presents none is the reader
  /// ([ADR 0041](../../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
  public func completeLogin(
    callback: URL,
    expected: AuthorizationAttempt,
    device: IosDeviceRegistration? = nil
  ) async throws -> AccountSession {
    let code: String
    do {
      code = try OAuthCallback.parse(callback, expected: expected)
    } catch let error as AuthorizationError {
      throw mapAuthorization(error)
    }
    do {
      let tokens = try await relay.exchangeAuthorizationCode(
        code: code,
        verifier: expected.verifier,
        device: device
      )
      let session = AccountSession(tokens)
      clearVolatileCaches()
      try persist(session)
      return session
    } catch let error as RelayClientError {
      throw AccountClientError(error)
    }
  }

  /// Sign in with what Apple proved on this device, and keep the session it answers with.
  ///
  /// The session it writes is `pending`, exactly as a browser sign-in's is: which Account this
  /// reached is still a question the person answers on the confirm screen.
  public func exchangeApple(
    identityToken: String,
    nonce: String,
    device: IosDeviceRegistration? = nil
  ) async throws -> AccountSession {
    do {
      let tokens = try await relay.exchangeAppleIdentityToken(
        identityToken: identityToken,
        nonce: nonce,
        device: device
      )
      let session = AccountSession(tokens)
      clearVolatileCaches()
      try persist(session)
      return session
    } catch let error as RelayClientError {
      throw AccountClientError.relay(error)
    }
  }

  /// Bind Apple to the Account this device is signed in to, with what Apple proved on the device.
  ///
  /// Nothing about the session changes: it already names the Account, and binding a channel adds
  /// a way back to it rather than opening a new one.
  public func linkApple(identityToken: String, nonce: String) async throws -> IdentityLinkResponse
  {
    do {
      return try await withAuthorizedSession { session in
        try await relay.linkAppleIdentityToken(
          identityToken: identityToken,
          nonce: nonce,
          accessToken: session.accessToken
        )
      }
    } catch let error as RelayClientError {
      throw AccountClientError(error)
    }
  }

  /// The channels that reach this Account. Nothing is stored: what may sign in to an Account is
  /// read when it is asked for, and there is no last-good copy of it to show.
  public func fetchIdentities() async throws -> [AccountIdentity] {
    do {
      return try await withAuthorizedSession { session in
        try await relay.fetchAccountIdentities(accessToken: session.accessToken).identities
      }
    } catch let error as RelayClientError {
      throw AccountClientError(error)
    }
  }

  public func fetchTodaySummary() async -> AccountRefreshResult {
    let cached = try? loadBoundCachedSummary()
    do {
      guard try currentSession() != nil else {
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
        fromCache: false,
        etag: read.etag
      )
    } catch let error as AccountClientError {
      return failureResult(cached: cached, error: error)
    } catch let error as RelayClientError {
      return failureResult(cached: cached, error: AccountClientError(error))
    } catch {
      return failureResult(cached: cached, error: .relay(.unavailable))
    }
  }

  /// Ask the Account's Macs for a fresh reading, and answer the instant their readings have to
  /// beat. Nothing here is a failure a person is told about: a Relay that predates the request
  /// answers 404, a busy session 429, and either way the readings on screen simply stay what
  /// they were, so every refusal is `nil`.
  public func requestCollection() async -> Date? {
    try? await withAuthorizedSession { session in
      try await relay.requestCollection(accessToken: session.accessToken).requestedAt
    }
  }

  /// Reads one inclusive local-date range. Offers If-None-Match when this process already holds
  /// that key. Does not write the summary cache.
  public func fetchUsagePeriod(
    from: String,
    to: String,
    timezone: String,
    breakdown: Bool = false
  ) async -> AccountPeriodResult {
    let key = Self.periodCacheKey(from: from, to: to, timezone: timezone, breakdown: breakdown)
    let held = periodCache[key]
    do {
      let read = try await withAuthorizedSession { session in
        try await relay.fetchAccountUsagePeriod(
          from: from,
          to: to,
          timezone: timezone,
          breakdown: breakdown,
          accessToken: session.accessToken,
          etag: held?.etag
        )
      }
      switch read {
      case .modified(let period, let etag):
        if let etag {
          let cached = CachedUsagePeriod(etag: etag, fetchedAt: now(), response: period)
          periodCache[key] = cached
          persistPeriod(key: key, cached: cached, accountID: try currentSession()?.accountID)
        }
        return .period(period)
      case .unchanged(let etag):
        guard let held else { return .failure(.relay(.invalidResponse)) }
        let cached = CachedUsagePeriod(
          etag: etag ?? held.etag, fetchedAt: now(), response: held.response)
        periodCache[key] = cached
        persistPeriod(key: key, cached: cached, accountID: try currentSession()?.accountID)
        return .period(held.response)
      }
    } catch let error as AccountClientError {
      return .failure(error)
    } catch let error as RelayClientError {
      return .failure(AccountClientError(error))
    } catch {
      return .failure(.relay(.unavailable))
    }
  }

  /// Reads the Account settings document. Offers If-None-Match when this Account's last-good
  /// copy is stored. A 304 answers that copy.
  public func fetchAccountSettings() async throws -> (document: AccountSettingsDocument, etag: String?) {
    try await withAuthorizedSession { session in
      let held = try loadBoundCachedSettings()
      let read = try await relay.fetchAccountSettings(
        accessToken: session.accessToken,
        etag: held?.etag
      )
      switch read {
      case .modified(let document, let etag):
        try persistSettings(
          CachedAccountSettings(accountID: session.accountID, etag: etag, document: document)
        )
        return (document, etag)
      case .unchanged(let etag):
        guard let held else { throw AccountClientError.relay(.invalidResponse) }
        if let etag, etag != held.etag {
          try persistSettings(
            CachedAccountSettings(
              accountID: session.accountID, etag: etag, document: held.document
            )
          )
        }
        return (held.document, etag ?? held.etag)
      }
    }
  }

  /// Writes the Account settings document under `If-Match`. A 412 is `conflict` with the
  /// current document, which this client also stores as last-good.
  public func writeAccountSettings(
    _ document: AccountSettingsDocument,
    ifMatch: String
  ) async throws -> AccountSettingsWrite {
    try await withAuthorizedSession { session in
      let result = try await relay.writeAccountSettings(
        document,
        accessToken: session.accessToken,
        ifMatch: ifMatch
      )
      switch result {
      case .written(let written, let etag):
        try persistSettings(
          CachedAccountSettings(accountID: session.accountID, etag: etag, document: written)
        )
      case .conflict(let current, let etag):
        try persistSettings(
          CachedAccountSettings(accountID: session.accountID, etag: etag, document: current)
        )
      }
      return result
    }
  }

  /// Reads UTC activity days. Does not write the summary cache.
  public func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail? = nil,
    timeZone: String? = nil
  ) async -> AccountActivityResult {
    let cachesPrimary = detail == nil && timeZone == nil
    let held = cachesPrimary ? activityCache : nil
    let matchingHeld =
      held.flatMap { cached in
        cached.from == from && cached.to == to ? cached : nil
      }
    do {
      let read = try await withAuthorizedSession { session in
        try await relay.fetchAccountUsageActivity(
          accessToken: session.accessToken,
          from: from,
          to: to,
          detail: detail,
          timeZone: timeZone,
          etag: matchingHeld?.etag
        )
      }
      switch read {
      case .modified(let activity, let etag):
        if cachesPrimary, let etag {
          let cached = CachedUsageActivity(
            from: from, to: to, etag: etag, fetchedAt: now(), response: activity)
          activityCache = cached
          persistActivity(cached, accountID: try currentSession()?.accountID)
        }
        return .activity(activity)
      case .unchanged(let etag):
        guard let matchingHeld else { return .failure(.relay(.invalidResponse)) }
        let cached = CachedUsageActivity(
          from: matchingHeld.from,
          to: matchingHeld.to,
          etag: etag ?? matchingHeld.etag,
          fetchedAt: now(),
          response: matchingHeld.response
        )
        activityCache = cached
        persistActivity(cached, accountID: try currentSession()?.accountID)
        return .activity(matchingHeld.response)
      }
    } catch let error as AccountClientError {
      return .failure(error)
    } catch let error as RelayClientError {
      return .failure(AccountClientError(error))
    } catch {
      return .failure(.relay(.unavailable))
    }
  }

  /// Send what this device read to the Account it belongs to.
  ///
  /// The control document is read first: it answers the generation the envelope must name.
  /// A session that names no Device has nothing to upload with and says so rather than asking.
  public func uploadSnapshots(_ snapshots: [QuotaSnapshot]) async -> AccountClientError? {
    while snapshotUploadBusy {
      await withCheckedContinuation { snapshotUploadWaiters.append($0) }
    }
    snapshotUploadBusy = true
    defer { finishSnapshotUploadLock() }
    do {
      _ = try await withAuthorizedSession { session in
        guard session.deviceID != nil else { throw AccountClientError.notADevice }
        let control = try await relay.fetchDeviceSync(accessToken: session.accessToken)
        return try await relay.uploadSnapshots(
          accessToken: session.accessToken,
          envelope: QuotaSnapshotEnvelope(
            generation: control.deviceGeneration,
            snapshots: snapshots
          )
        )
      }
      return nil
    } catch let error as AccountClientError {
      return error
    } catch let error as RelayClientError {
      return AccountClientError(error)
    } catch {
      return .relay(.unavailable)
    }
  }

  private func finishSnapshotUploadLock() {
    snapshotUploadBusy = false
    let waiters = snapshotUploadWaiters
    snapshotUploadWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// What one quota-history upload pass stored, and the error that stopped a later chunk.
  /// `cancelled` means the caller stopped the pass; chunks already accepted stay in `responses`.
  public struct QuotaHistoryUploadBatch: Equatable, Sendable {
    public var responses: [QuotaHistoryUploadResponse]
    public var error: RelayClientError?
    public var cancelled: Bool

    public init(
      responses: [QuotaHistoryUploadResponse],
      error: RelayClientError?,
      cancelled: Bool = false
    ) {
      self.responses = responses
      self.error = error
      self.cancelled = cancelled
    }
  }

  /// Upload downsampled buckets, one device-sync then each chunk. A failed chunk keeps the
  /// responses of the chunks that were accepted before it. A cancelled caller stops before the
  /// next chunk.
  public func uploadQuotaHistory(
    chunks: [[QuotaHistoryUploadRequest.Series]]
  ) async -> QuotaHistoryUploadBatch {
    if Task.isCancelled {
      return QuotaHistoryUploadBatch(responses: [], error: nil, cancelled: true)
    }
    while snapshotUploadBusy {
      await withCheckedContinuation { snapshotUploadWaiters.append($0) }
    }
    if Task.isCancelled {
      return QuotaHistoryUploadBatch(responses: [], error: nil, cancelled: true)
    }
    snapshotUploadBusy = true
    defer { finishSnapshotUploadLock() }
    let prepared = chunks.compactMap { series -> [QuotaHistoryUploadRequest.Series]? in
      let nonempty = series.filter { !$0.points.isEmpty }
      return nonempty.isEmpty ? nil : nonempty
    }
    guard !prepared.isEmpty else {
      return QuotaHistoryUploadBatch(responses: [], error: nil)
    }
    let generation: Int
    do {
      generation = try await withAuthorizedSession { session in
        guard session.deviceID != nil else { throw AccountClientError.notADevice }
        let control = try await relay.fetchDeviceSync(accessToken: session.accessToken)
        return control.deviceGeneration
      }
    } catch is CancellationError {
      return QuotaHistoryUploadBatch(responses: [], error: nil, cancelled: true)
    } catch let error as RelayClientError {
      return QuotaHistoryUploadBatch(responses: [], error: error)
    } catch let error as AccountClientError {
      return QuotaHistoryUploadBatch(responses: [], error: relayError(error))
    } catch {
      return QuotaHistoryUploadBatch(responses: [], error: .unavailable)
    }
    var responses: [QuotaHistoryUploadResponse] = []
    for series in prepared {
      if Task.isCancelled {
        return QuotaHistoryUploadBatch(responses: responses, error: nil, cancelled: true)
      }
      do {
        let response = try await withAuthorizedSession { session in
          guard session.deviceID != nil else { throw AccountClientError.notADevice }
          return try await relay.uploadQuotaHistory(
            accessToken: session.accessToken,
            request: QuotaHistoryUploadRequest(generation: generation, series: series)
          )
        }
        responses.append(response)
      } catch is CancellationError {
        return QuotaHistoryUploadBatch(responses: responses, error: nil, cancelled: true)
      } catch let error as RelayClientError {
        return QuotaHistoryUploadBatch(responses: responses, error: error)
      } catch let error as AccountClientError {
        return QuotaHistoryUploadBatch(responses: responses, error: relayError(error))
      } catch {
        return QuotaHistoryUploadBatch(responses: responses, error: .unavailable)
      }
    }
    return QuotaHistoryUploadBatch(responses: responses, error: nil)
  }

  /// One subscription's merged Account history. `etag` is the validator the caller already holds.
  public func fetchQuotaHistory(
    provider: ProviderID,
    fingerprint: String,
    since: Date,
    etag: String?
  ) async throws -> QuotaHistoryRead {
    try await withAuthorizedSession { session in
      try await relay.fetchQuotaHistory(
        accessToken: session.accessToken,
        provider: provider,
        fingerprint: fingerprint,
        since: since,
        etag: etag
      )
    }
  }

  private func relayError(_ error: AccountClientError) -> RelayClientError {
    if case .relay(let relayError) = error { return relayError }
    return .unavailable
  }

  private func loadBoundCachedSummary() throws -> CachedAccountSummary? {
    let cached = try summaryStore.load()
    guard let cached else { return nil }
    guard let session = try currentSession() else {
      try? summaryStore.clear()
      clearVolatileCaches()
      return nil
    }
    guard cached.summary.account.accountID == session.accountID else {
      try? summaryStore.clear()
      clearVolatileCaches()
      return nil
    }
    return cached
  }

  private func loadBoundCachedSettings() throws -> CachedAccountSettings? {
    let cached = try settingsStore.load()
    guard let cached else { return nil }
    guard let session = try currentSession() else {
      try? settingsStore.clear()
      return nil
    }
    guard cached.accountID == session.accountID else {
      try? settingsStore.clear()
      return nil
    }
    return cached
  }

  private func loadBoundCachedUsage() throws -> CachedAccountUsage? {
    let cached = try usageStore.load()
    guard let cached else { return nil }
    guard let session = try currentSession() else {
      try? usageStore.clear()
      periodCache.removeAll()
      activityCache = nil
      return nil
    }
    guard cached.accountID == session.accountID else {
      try? usageStore.clear()
      periodCache.removeAll()
      activityCache = nil
      return nil
    }
    return cached
  }

  private func persistSettings(_ value: CachedAccountSettings) throws {
    try settingsStore.save(value)
  }

  private func clearVolatileCaches() {
    periodCache.removeAll()
    activityCache = nil
    try? settingsStore.clear()
    try? usageStore.clear()
  }

  private func failureResult(
    cached: CachedAccountSummary?,
    error: AccountClientError
  ) -> AccountRefreshResult {
    AccountRefreshResult(
      summary: cached?.summary,
      fetchedAt: cached?.fetchedAt,
      fromCache: cached != nil,
      error: error,
      etag: cached?.etag
    )
  }

  public func logout() async {
    let refreshToken = try? currentSession()?.refreshToken
    invalidateSessionMemo()
    proactiveRefreshDisabled = false
    try? sessionStore.clear()
    try? summaryStore.clear()
    clearVolatileCaches()
    if let refreshToken {
      try? await relay.revokeSession(refreshToken: refreshToken)
    }
  }

  static func periodCacheKey(from: String, to: String, timezone: String, breakdown: Bool) -> String
  {
    "\(from)|\(to)|\(timezone)|\(breakdown ? "1" : "0")"
  }

  /// The summary this read leaves current, and the validator it is current at.
  ///
  /// `cached` is the account-bound stored read, so its validator is only ever offered back for
  /// the account the session belongs to.
  private func fetchSummary(
    cached: CachedAccountSummary?,
    allowRefresh: Bool
  ) async throws -> (summary: AccountSummary, etag: String?) {
    try await withAuthorizedSession(allowRefresh: allowRefresh) { session in
      let held = cached?.summary.account.accountID == session.accountID ? cached : nil
      let timeZone = calendar.timeZone.identifier
      let read = try await relay.fetchAccountSummary(
        timeZone: timeZone,
        accessToken: session.accessToken,
        etag: held?.etag
      )
      return try resolve(read, held: held, session: session)
    }
  }

  private func withAuthorizedSession<T>(
    allowRefresh: Bool = true,
    _ operation: (AccountSession) async throws -> T
  ) async throws -> T {
    guard var session = try currentSession() else {
      throw AccountClientError.notSignedIn
    }
    var refreshedThisCall = false
    if allowRefresh, !proactiveRefreshDisabled,
      session.accessExpiresAt.timeIntervalSince(now()) <= Self.accessRefreshLead
    {
      session = try await refreshSessionShared()
      refreshedThisCall = true
      if session.accessExpiresAt.timeIntervalSince(now()) <= Self.accessRefreshLead {
        proactiveRefreshDisabled = true
      }
    }
    do {
      return try await operation(session)
    } catch RelayClientError.unauthorized where allowRefresh && !refreshedThisCall {
      let refreshed = try await refreshSessionShared()
      do {
        return try await operation(refreshed)
      } catch let error as AccountClientError {
        throw error
      } catch let error as RelayClientError {
        throw AccountClientError(error)
      }
    } catch let error as AccountClientError {
      throw error
    } catch let error as RelayClientError {
      throw AccountClientError(error)
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

  private func refreshSessionShared() async throws -> AccountSession {
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
    guard let current = try currentSession() else {
      throw AccountClientError.notSignedIn
    }
    do {
      let rotated = try await relay.refreshSession(refreshToken: current.refreshToken)
      guard rotated.accountID == current.accountID else {
        throw AccountClientError.accountMismatch
      }
      let session = AccountSession(
        rotated, deviceID: current.deviceID, activation: current.activation)
      try persist(session)
      return session
    } catch RelayClientError.invalidGrant {
      invalidateSessionMemo()
      try? sessionStore.clear()
      try? summaryStore.clear()
      clearVolatileCaches()
      throw AccountClientError.sessionExpired
    } catch RelayClientError.unauthorized {
      invalidateSessionMemo()
      try? sessionStore.clear()
      try? summaryStore.clear()
      clearVolatileCaches()
      throw AccountClientError.sessionExpired
    } catch let error as RelayClientError {
      throw AccountClientError(error)
    }
  }

  private func persist(_ session: AccountSession) throws {
    guard session.isValid else { throw AccountStoreError.invalidSession }
    try sessionStore.save(session)
    sessionMemo = session
    sessionMemoValid = true
    if session.accessExpiresAt.timeIntervalSince(now()) > Self.accessRefreshLead {
      proactiveRefreshDisabled = false
    }
  }

  private func currentSession() throws -> AccountSession? {
    if sessionMemoValid {
      return sessionMemo
    }
    let session = try sessionStore.load()
    sessionMemo = session
    sessionMemoValid = true
    return session
  }

  private func invalidateSessionMemo() {
    sessionMemo = nil
    sessionMemoValid = false
  }

  private func hydrateUsageCache(_ usage: CachedAccountUsage) {
    var usage = usage
    usage.capPeriods()
    activityCache = usage.activity
    periodCache = usage.periods
  }

  private func persistPeriod(key: String, cached: CachedUsagePeriod, accountID: String?) {
    guard let accountID else { return }
    var usage = (try? usageStore.load()) ?? CachedAccountUsage(accountID: accountID)
    guard usage.accountID == accountID else { return }
    usage.periods[key] = cached
    usage.capPeriods()
    try? usageStore.save(usage)
  }

  private func persistActivity(_ cached: CachedUsageActivity, accountID: String?) {
    guard let accountID else { return }
    var usage = (try? usageStore.load()) ?? CachedAccountUsage(accountID: accountID)
    guard usage.accountID == accountID else { return }
    usage.activity = cached
    try? usageStore.save(usage)
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

extension AccountClientError {
  /// Copy a Connect Account failure can show. Cancel is handled before this is read.
  public var userFacingMessage: String {
    switch self {
    case .callbackMismatch, .stateMismatch, .missingAuthorizationCode, .unexpectedCallbackToken:
      AuthorizationError.unexpectedBrowserResponseMessage
    case .relay(.unavailable), .relay(.timeout):
      "Couldn't reach quota.gotry.io."
    case .relay(.invalidGrant), .relay(.unauthorized), .sessionExpired:
      AuthorizationError.expiredSignInMessage
    case .relay(.rejected(code: _, status: let status)) where (400...499).contains(status):
      AuthorizationError.expiredSignInMessage
    default:
      AuthorizationError.genericConnectFailureMessage
    }
  }
}
