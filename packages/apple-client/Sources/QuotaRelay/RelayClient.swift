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
    case .accountSummary: "/api/v3/account/summary"
    }
  }

  public var usesBearer: Bool {
    switch self {
    case .token: false
    case .revoke, .accountSummary: true
    }
  }
}

public struct RelayClient: Sendable {
  public static let origin = URL(string: "https://quota.gotry.io")!
  public static let requestTimeout = Duration.seconds(20)
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

  public func refreshAccountSession(refreshToken: String) async throws
    -> AccountSessionRefreshResponse
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
      decode: AccountSessionRefreshResponse.self
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

  public func fetchAccountSummary(from: String, to: String, accessToken: String) async throws
    -> AccountSummary
  {
    guard WireValidation.isCalendarDate(from), WireValidation.isCalendarDate(to), from <= to else {
      throw RelayClientError.invalidResponse
    }
    guard WireValidation.isIOSAccessToken(accessToken) else {
      throw RelayClientError.unauthorized
    }
    return try await send(
      route: .accountSummary,
      query: [
        ("from", from),
        ("to", to),
        ("cost_mode", "calculate"),
        ("usage_agents", "all"),
        ("usage_clients", "1"),
        ("model_catalog", "1"),
        ("device_health", "1"),
      ],
      body: nil,
      bearer: accessToken,
      expectedStatus: 200,
      decode: AccountSummary.self
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
    let data = try await perform(
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

  private func perform(
    route: RelayRoute,
    query: [(String, String)],
    body: Data?,
    bearer: String?,
    expectedStatus: Int
  ) async throws -> Data {
    let request = try makeRequest(route: route, query: query, body: body, bearer: bearer)
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

    if (300...399).contains(response.statusCode) {
      throw RelayClientError.redirectRefused
    }
    if data.count > Self.maximumResponseBytes {
      throw RelayClientError.responseTooLarge
    }

    if response.statusCode == expectedStatus {
      return data
    }
    throw mapStatus(response.statusCode, body: data)
  }

  private func makeRequest(
    route: RelayRoute,
    query: [(String, String)],
    body: Data?,
    bearer: String?
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
