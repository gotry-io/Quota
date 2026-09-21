import Foundation
import QuotaAlerts
import QuotaWire

public enum RelayClientError: Error, Equatable, Sendable {
  case unauthorized
  case invalidGrant
  case rejected(code: String, status: Int)
  case invalidResponse
  case invalidQuery
  case responseTooLarge
  case timeout
  case redirectRefused
  case unavailable
  case invalidOrigin
}

/// Extra query the activity read may name: `detail=agents` on a single day, or `detail=hours`
/// on any range.
public enum ActivityDetail: String, Sendable {
  case agents
  case hours
}

public enum RelayRoute: CaseIterable, Sendable {
  case token
  case appleSignIn
  case revoke
  case accountIdentities
  case accountSummary
  case accountSettings
  case updateAccountSettings
  case accountUsageActivity(from: String, to: String, detail: ActivityDetail?, timeZone: String?)
  case accountUsagePeriod(from: String, to: String, timezone: String, breakdown: Bool)
  case deviceSync
  case deviceSnapshots
  case providersStatus

  public static var allCases: [RelayRoute] {
    [
      .token,
      .appleSignIn,
      .revoke,
      .accountIdentities,
      .accountSummary,
      .accountSettings,
      .updateAccountSettings,
      .accountUsageActivity(from: "1970-01-01", to: "1970-01-01", detail: nil, timeZone: nil),
      .accountUsagePeriod(from: "1970-01-01", to: "1970-01-01", timezone: "UTC", breakdown: false),
      .deviceSync,
      .deviceSnapshots,
      .providersStatus,
    ]
  }

  public var method: String {
    switch self {
    case .token, .appleSignIn, .revoke: "POST"
    case .accountIdentities, .accountSummary, .accountSettings, .accountUsageActivity,
      .accountUsagePeriod, .deviceSync, .providersStatus:
      "GET"
    case .updateAccountSettings, .deviceSnapshots: "PUT"
    }
  }

  public var path: String {
    switch self {
    case .token: "/oauth/v2/token"
    case .appleSignIn: "/oauth/v2/apple"
    case .revoke: "/oauth/v2/revoke"
    case .accountIdentities: "/api/v2/account"
    case .accountSummary: "/api/v6/account/summary"
    case .accountSettings, .updateAccountSettings: "/api/v2/account/settings"
    case .accountUsageActivity: "/api/v6/account/usage/activity"
    case .accountUsagePeriod: "/api/v6/account/usage/period"
    case .deviceSync: "/api/v2/device/sync"
    case .deviceSnapshots: "/api/v6/device/snapshots"
    case .providersStatus: "/api/v2/providers/status"
    }
  }

  /// Query keys the route itself names. Extra items such as summary `tz` are still passed to
  /// `perform`. Activity lists `from`, `to`, optionally `detail`, and `tz` when asking for hours.
  /// Period lists inclusive local `from`/`to`, required IANA `timezone`, and `breakdown=1`.
  public var query: [(String, String)] {
    switch self {
    case .accountUsageActivity(let from, let to, let detail, let timeZone):
      var items = [("from", from), ("to", to)]
      if let detail {
        items.append(("detail", detail.rawValue))
      }
      if let timeZone {
        items.append(("tz", timeZone))
      }
      return items
    case .accountUsagePeriod(let from, let to, let timezone, let breakdown):
      var items = [("from", from), ("to", to), ("timezone", timezone)]
      if breakdown {
        items.append(("breakdown", "1"))
      }
      return items
    case .token, .appleSignIn, .revoke, .accountIdentities, .accountSummary, .accountSettings,
      .updateAccountSettings, .deviceSync, .deviceSnapshots, .providersStatus:
      return []
    }
  }
}

/// The outcome of a conditional Account summary read.
///
/// `unchanged` is an answer, not a failure: the server has confirmed the caller's stored
/// summary is still current, and the caller keeps showing it.
public enum AccountSummaryRead: Sendable {
  case modified(AccountSummary, etag: String?)
  case unchanged(etag: String?)
}

/// The outcome of a conditional Account period read. `unchanged` is an answer, not a failure.
public enum AccountUsagePeriodRead: Sendable {
  case modified(AccountUsagePeriodResponse, etag: String?)
  case unchanged(etag: String?)
}

/// The outcome of a conditional Account activity read. `unchanged` keeps the cached body.
public enum AccountUsageActivityRead: Sendable {
  case modified(AccountUsageActivityResponse, etag: String?)
  case unchanged(etag: String?)
}

/// The outcome of a conditional Account settings read. `unchanged` keeps the cached document.
public enum AccountSettingsRead: Sendable {
  case modified(AccountSettingsDocument, etag: String?)
  case unchanged(etag: String?)
}

/// The outcome of `PUT /api/v2/account/settings`. A 412 body is the current document, not an
/// error envelope, so the caller can re-apply its one edit
/// ([ADR 0061](../../../../docs/decisions/0061-alert-policy-and-the-budget-follow-the-account.md)).
public enum AccountSettingsWrite: Sendable {
  case written(AccountSettingsDocument, etag: String?)
  case conflict(AccountSettingsDocument, etag: String?)
}

public struct RelayClient: Sendable {
  public static let origin = URL(string: "https://quota.gotry.io")!
  public static let maximumResponseBytes = WireCodec.maximumResponseBytes

  private let transport: any HTTPTransport

  public init() {
    self.init(transport: URLSessionHTTPTransport(timeout: 20))
  }

  public init(transport: any HTTPTransport) {
    self.transport = transport
  }

  /// Trade the authorization code for this app's one session, naming the Device it is to speak
  /// for when `device` is given.
  public func exchangeAuthorizationCode(
    code: String,
    verifier: String,
    device: IosDeviceRegistration? = nil
  ) async throws -> IosOAuthTokenResponse {
    guard WireValidation.isSecret(code), WireValidation.isPKCEVerifier(verifier) else {
      throw RelayClientError.invalidResponse
    }
    let body = try WireCodec.encodeRequest(
      IosLoginExchangeRequest(code: code, codeVerifier: verifier, device: device))
    return try await send(
      route: .token,
      query: [],
      body: body,
      bearer: nil,
      expectedStatus: 200,
      decode: IosOAuthTokenResponse.self
    )
  }

  /// Trade the identity token Apple signed on this device for this app's one session.
  public func exchangeAppleIdentityToken(
    identityToken: String,
    nonce: String,
    device: IosDeviceRegistration? = nil
  ) async throws -> IosOAuthTokenResponse {
    guard WireValidation.isCompactJWS(identityToken), WireValidation.isPKCEVerifier(nonce) else {
      throw RelayClientError.invalidResponse
    }
    let body = try WireCodec.encodeRequest(
      AppleNativeSignInRequest(identityToken: identityToken, nonce: nonce, device: device))
    return try await send(
      route: .appleSignIn,
      query: [],
      body: body,
      bearer: nil,
      expectedStatus: 200,
      decode: IosOAuthTokenResponse.self
    )
  }

  /// Bind Apple to the Account this session already names.
  ///
  /// The same route and the same proof as signing in with Apple; what makes it a bind rather than
  /// a sign-in is `intent` and the session it is sent under
  /// ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)).
  public func linkAppleIdentityToken(
    identityToken: String,
    nonce: String,
    accessToken: String
  ) async throws -> IdentityLinkResponse {
    guard WireValidation.isCompactJWS(identityToken), WireValidation.isPKCEVerifier(nonce) else {
      throw RelayClientError.invalidResponse
    }
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    let body = try WireCodec.encodeRequest(
      AppleNativeSignInRequest(identityToken: identityToken, nonce: nonce, intent: "link"))
    return try await send(
      route: .appleSignIn,
      query: [],
      body: body,
      bearer: accessToken,
      expectedStatus: 200,
      decode: IdentityLinkResponse.self
    )
  }

  /// The channels that reach this Account. Read on its own rather than folded into the summary:
  /// it changes when someone binds or unbinds one, not when a Mac reports.
  public func fetchAccountIdentities(accessToken: String) async throws
    -> AccountIdentitiesResponse
  {
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    return try await send(
      route: .accountIdentities,
      query: [],
      body: nil,
      bearer: accessToken,
      expectedStatus: 200,
      decode: AccountIdentitiesResponse.self
    )
  }

  public func refreshSession(refreshToken: String) async throws
    -> SessionRefreshResponse
  {
    guard WireValidation.isIOSRefreshToken(refreshToken) else {
      throw RelayClientError.invalidGrant
    }
    let body = try WireCodec.encodeRequest(IosSessionRefreshRequest(refreshToken: refreshToken))
    return try await send(
      route: .token,
      query: [],
      body: body,
      bearer: nil,
      expectedStatus: 200,
      decode: SessionRefreshResponse.self
    )
  }

  public func revokeSession(refreshToken: String) async throws {
    guard WireValidation.isIOSRefreshToken(refreshToken) else {
      throw RelayClientError.invalidGrant
    }
    _ = try await perform(
      route: .revoke,
      query: [],
      body: nil,
      bearer: refreshToken,
      expectedStatus: 204
    )
  }

  /// Reads the Account, offering the validator the caller already holds.
  ///
  /// One read answers the whole account: the devices, the resolved subscriptions, and the four
  /// periods in the calendar `timeZone` names. Passing `etag` turns the read conditional: an
  /// account that has not changed answers 304 and sends no body.
  public func fetchAccountSummary(
    timeZone: String,
    accessToken: String,
    etag: String? = nil
  ) async throws -> AccountSummaryRead {
    guard WireValidation.isTimezone(timeZone), TimeZone(identifier: timeZone) != nil else {
      throw RelayClientError.invalidResponse
    }
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    let (data, response) = try await perform(
      route: .accountSummary,
      query: [("tz", timeZone)],
      body: nil,
      bearer: accessToken,
      expectedStatus: 200,
      ifNoneMatch: etag
    )
    let nextETag = Self.entityTag(response)
    if response.statusCode == 304 {
      return .unchanged(etag: nextETag ?? etag)
    }
    do {
      return .modified(try WireCodec.decode(AccountSummary.self, from: data), etag: nextETag)
    } catch is WireLimitError {
      throw RelayClientError.responseTooLarge
    } catch {
      throw RelayClientError.invalidResponse
    }
  }

  /// Reads UTC activity days. Passing `etag` turns the read conditional: an unchanged body
  /// answers 304 and sends no body.
  public func fetchAccountUsageActivity(
    accessToken: String,
    from: String,
    to: String,
    detail: ActivityDetail? = nil,
    timeZone: String? = nil,
    etag: String? = nil
  ) async throws -> AccountUsageActivityRead {
    guard WireValidation.isCalendarDate(from), WireValidation.isCalendarDate(to) else {
      throw RelayClientError.invalidQuery
    }
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    let (data, response) = try await perform(
      route: .accountUsageActivity(from: from, to: to, detail: detail, timeZone: timeZone),
      query: [],
      body: nil,
      bearer: accessToken,
      expectedStatus: 200,
      ifNoneMatch: etag
    )
    let nextETag = Self.entityTag(response)
    if response.statusCode == 304 {
      return .unchanged(etag: nextETag ?? etag)
    }
    do {
      return .modified(
        try WireCodec.decode(AccountUsageActivityResponse.self, from: data),
        etag: nextETag
      )
    } catch is WireLimitError {
      throw RelayClientError.responseTooLarge
    } catch {
      throw RelayClientError.invalidResponse
    }
  }

  /// Public catalog status-page readings. No session ([ADR 0044](../../../../docs/decisions/0044-relay-publishes-provider-status.md)).
  public func fetchProviderStatus() async throws -> ProviderStatusResponse {
    let (data, _) = try await perform(
      route: .providersStatus,
      query: [],
      body: nil,
      bearer: nil,
      expectedStatus: 200
    )
    do {
      return try WireCodec.decode(ProviderStatusResponse.self, from: data)
    } catch is WireLimitError {
      throw RelayClientError.responseTooLarge
    } catch {
      throw RelayClientError.invalidResponse
    }
  }

  /// Reads one inclusive local-date range in a required IANA timezone.
  ///
  /// Passing `etag` turns the read conditional: an unchanged period answers 304 and sends no body.
  public func fetchAccountUsagePeriod(
    from: String,
    to: String,
    timezone: String,
    breakdown: Bool = false,
    accessToken: String,
    etag: String? = nil
  ) async throws -> AccountUsagePeriodRead {
    guard WireValidation.isCalendarDate(from), WireValidation.isCalendarDate(to), from <= to,
      let days = WireValidation.inclusiveDayCount(from: from, to: to),
      days <= WireCodec.maximumUsagePeriodDays
    else {
      throw RelayClientError.invalidQuery
    }
    guard WireValidation.isTimezone(timezone), TimeZone(identifier: timezone) != nil else {
      throw RelayClientError.invalidQuery
    }
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    let (data, response) = try await perform(
      route: .accountUsagePeriod(from: from, to: to, timezone: timezone, breakdown: breakdown),
      query: [],
      body: nil,
      bearer: accessToken,
      expectedStatus: 200,
      ifNoneMatch: etag
    )
    let nextETag = Self.entityTag(response)
    if response.statusCode == 304 {
      return .unchanged(etag: nextETag ?? etag)
    }
    do {
      return .modified(
        try WireCodec.decode(AccountUsagePeriodResponse.self, from: data),
        etag: nextETag
      )
    } catch is WireLimitError {
      throw RelayClientError.responseTooLarge
    } catch {
      throw RelayClientError.invalidResponse
    }
  }

  /// Reads the Account settings document, offering the validator the caller already holds.
  ///
  /// Passing `etag` turns the read conditional: an unchanged document answers 304 and sends no
  /// body. Decoding uses `AccountSettingsDocument.decode`, not `WireCodec` — this type's keys
  /// are the wire's own snake_case, and the package coder would fail them.
  public func fetchAccountSettings(
    accessToken: String,
    etag: String? = nil
  ) async throws -> AccountSettingsRead {
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    let (data, response) = try await perform(
      route: .accountSettings,
      query: [],
      body: nil,
      bearer: accessToken,
      expectedStatus: 200,
      ifNoneMatch: etag
    )
    let nextETag = Self.entityTag(response)
    if response.statusCode == 304 {
      return .unchanged(etag: nextETag ?? etag)
    }
    do {
      return .modified(try AccountSettingsDocument.decode(data), etag: nextETag)
    } catch {
      throw RelayClientError.invalidResponse
    }
  }

  /// Writes the Account settings document under `If-Match`.
  ///
  /// The body is `updateRequestJSON()`: `protocol_version`, `alerts`, and `budget`, and nothing
  /// else. A stale validator is `conflict` with the current document, not an error envelope.
  public func writeAccountSettings(
    _ document: AccountSettingsDocument,
    accessToken: String,
    ifMatch: String
  ) async throws -> AccountSettingsWrite {
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    guard Self.isValidator(ifMatch) else {
      throw RelayClientError.invalidResponse
    }
    let body: Data
    do {
      body = try document.updateRequestJSON()
    } catch {
      throw RelayClientError.invalidResponse
    }
    let (data, response) = try await perform(
      route: .updateAccountSettings,
      query: [],
      body: body,
      bearer: accessToken,
      expectedStatus: 200,
      acceptedStatuses: [412],
      ifMatch: ifMatch
    )
    let nextETag = Self.entityTag(response)
    let decoded: AccountSettingsDocument
    do {
      decoded = try AccountSettingsDocument.decode(data)
    } catch {
      throw RelayClientError.invalidResponse
    }
    if response.statusCode == 412 {
      return .conflict(decoded, etag: nextETag)
    }
    return .written(decoded, etag: nextETag)
  }

  /// The Device's control document, and the first half of an upload.
  ///
  /// It answers the generation the envelope must name. It is also the boundary that says paid
  /// sync is off, so a phone learns that before it sends a reading anywhere.
  public func fetchDeviceSync(accessToken: String) async throws -> DeviceSyncResponse {
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    return try await send(
      route: .deviceSync,
      query: [],
      body: nil,
      bearer: accessToken,
      expectedStatus: 200,
      decode: DeviceSyncResponse.self
    )
  }

  /// Upload what this device read. Nothing but the readings goes: no credential, and no Usage.
  public func uploadSnapshots(accessToken: String, envelope: QuotaSnapshotEnvelope) async throws
    -> QuotaSnapshotUploadResponse
  {
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    guard envelope.isValid else {
      throw RelayClientError.invalidResponse
    }
    return try await send(
      route: .deviceSnapshots,
      query: [],
      body: try WireCodec.encodeRequest(envelope),
      bearer: accessToken,
      expectedStatus: 200,
      decode: QuotaSnapshotUploadResponse.self
    )
  }

  private func send<T: Decodable>(
    route: RelayRoute,
    query: [(String, String)],
    body: Data?,
    bearer: String?,
    expectedStatus: Int,
    decode: T.Type
  ) async throws -> T {
    let (data, _) = try await perform(
      route: route,
      query: query,
      body: body,
      bearer: bearer,
      expectedStatus: expectedStatus
    )
    do {
      return try WireCodec.decode(decode, from: data)
    } catch is WireLimitError {
      throw RelayClientError.responseTooLarge
    } catch {
      throw RelayClientError.invalidResponse
    }
  }

  @discardableResult
  private func perform(
    route: RelayRoute,
    query: [(String, String)],
    body: Data?,
    bearer: String?,
    expectedStatus: Int,
    acceptedStatuses: Set<Int> = [],
    ifNoneMatch: String? = nil,
    ifMatch: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    let request = try makeRequest(
      route: route,
      query: query,
      body: body,
      bearer: bearer,
      ifNoneMatch: ifNoneMatch,
      ifMatch: ifMatch
    )
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.perform(request)
    } catch let error as HTTPTransportError {
      throw mapTransport(error)
    } catch let error as RelayClientError {
      throw error
    } catch {
      throw RelayClientError.unavailable
    }

    // 304 shares the 3xx range with the redirects this client refuses, but it is the answer to
    // the question this request asked rather than a request to go somewhere else.
    let notModified = response.statusCode == 304 && ifNoneMatch != nil
    if (300...399).contains(response.statusCode) && !notModified {
      throw RelayClientError.redirectRefused
    }
    if data.count > Self.maximumResponseBytes {
      throw RelayClientError.responseTooLarge
    }

    if response.statusCode == expectedStatus || notModified
      || acceptedStatuses.contains(response.statusCode)
    {
      return (data, response)
    }
    throw mapStatus(response.statusCode, body: data)
  }

  private static func entityTag(_ response: HTTPURLResponse) -> String? {
    guard let value = response.value(forHTTPHeaderField: "ETag"), isValidator(value) else {
      return nil
    }
    return value
  }

  /// An ETag / If-Match / If-None-Match value this client will send or keep.
  static func isValidator(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 256
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func makeRequest(
    route: RelayRoute,
    query: [(String, String)],
    body: Data?,
    bearer: String?,
    ifNoneMatch: String? = nil,
    ifMatch: String? = nil
  ) throws -> URLRequest {
    guard var components = URLComponents(url: Self.origin, resolvingAgainstBaseURL: false) else {
      throw RelayClientError.invalidOrigin
    }
    components.path = route.path
    let items = route.query + query
    if !items.isEmpty {
      components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
    guard let url = components.url else {
      throw RelayClientError.invalidOrigin
    }
    try Self.requireManagedOrigin(url)

    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = route.method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    if let ifNoneMatch, Self.isValidator(ifNoneMatch) {
      request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
    }
    if let ifMatch, Self.isValidator(ifMatch) {
      request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
    }

    if let bearer {
      try Self.attachBearer(&request, token: bearer)
    } else if request.value(forHTTPHeaderField: "Authorization") != nil {
      throw RelayClientError.invalidOrigin
    }
    return request
  }

  public static func requireManagedOrigin(_ url: URL) throws {
    guard url.scheme == "https",
      url.host == "quota.gotry.io",
      url.port == nil || url.port == 443,
      url.user == nil,
      url.password == nil
    else {
      throw RelayClientError.invalidOrigin
    }
  }

  public static func attachBearer(_ request: inout URLRequest, token: String) throws {
    guard let url = request.url else {
      throw RelayClientError.invalidOrigin
    }
    try requireManagedOrigin(url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }

  private func mapTransport(_ error: HTTPTransportError) -> RelayClientError {
    switch error {
    case .timeout: .timeout
    case .redirectRefused: .redirectRefused
    case .responseTooLarge: .responseTooLarge
    case .unavailable: .unavailable
    }
  }

  private func mapStatus(_ status: Int, body: Data) -> RelayClientError {
    if status == 401 {
      return .unauthorized
    }
    if (500...599).contains(status) {
      return .unavailable
    }
    if let envelope = try? WireCodec.decode(RelayErrorEnvelope.self, from: body) {
      if envelope.code == .invalidGrant {
        return .invalidGrant
      }
      return .rejected(code: envelope.code.rawValue, status: status)
    }
    if status == 400 {
      return .invalidGrant
    }
    return .rejected(code: "http_\(status)", status: status)
  }
}
