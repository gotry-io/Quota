import Foundation
import QuotaWire

public enum RelayClientError: Error, Equatable, Sendable {
  case unauthorized
  case invalidGrant
  case rejected(code: String, status: Int)
  case invalidResponse
  case responseTooLarge
  case timeout
  case redirectRefused
  case unavailable
  case invalidOrigin
}

public enum RelayRoute: String, CaseIterable, Sendable {
  case token
  case revoke
  case accountSummary

  public var method: String {
    switch self {
    case .token, .revoke: "POST"
    case .accountSummary: "GET"
    }
  }

  public var path: String {
    switch self {
    case .token: "/oauth/v2/token"
    case .revoke: "/oauth/v2/revoke"
    case .accountSummary: "/api/v6/account/summary"
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

  public func exchangeAuthorizationCode(code: String, verifier: String) async throws
    -> IosOAuthTokenResponse
  {
    guard WireValidation.isSecret(code), WireValidation.isPKCEVerifier(verifier) else {
      throw RelayClientError.invalidResponse
    }
    let body = try WireCodec.encodeRequest(
      IosLoginExchangeRequest(code: code, codeVerifier: verifier))
    return try await send(
      route: .token,
      query: [],
      body: body,
      bearer: nil,
      expectedStatus: 200,
      decode: IosOAuthTokenResponse.self
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
    ifNoneMatch: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    let request = try makeRequest(
      route: route,
      query: query,
      body: body,
      bearer: bearer,
      ifNoneMatch: ifNoneMatch
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

    if response.statusCode == expectedStatus || notModified {
      return (data, response)
    }
    throw mapStatus(response.statusCode, body: data)
  }

  private static func entityTag(_ response: HTTPURLResponse) -> String? {
    guard let value = response.value(forHTTPHeaderField: "ETag"),
      !value.isEmpty,
      value.count <= 256,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return nil
    }
    return value
  }

  private func makeRequest(
    route: RelayRoute,
    query: [(String, String)],
    body: Data?,
    bearer: String?,
    ifNoneMatch: String? = nil
  ) throws -> URLRequest {
    guard var components = URLComponents(url: Self.origin, resolvingAgainstBaseURL: false) else {
      throw RelayClientError.invalidOrigin
    }
    components.path = route.path
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
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
    if let ifNoneMatch, !ifNoneMatch.isEmpty, ifNoneMatch.count <= 256 {
      request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
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
