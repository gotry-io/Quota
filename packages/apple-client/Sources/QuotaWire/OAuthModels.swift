import Foundation

public struct SessionToken: Codable, Equatable, Sendable {
  public let accessToken: String
  public let accessExpiresAt: Date
  public let refreshToken: String
  public let refreshExpiresAt: Date

  public init(
    accessToken: String,
    accessExpiresAt: Date,
    refreshToken: String,
    refreshExpiresAt: Date
  ) {
    self.accessToken = accessToken
    self.accessExpiresAt = accessExpiresAt
    self.refreshToken = refreshToken
    self.refreshExpiresAt = refreshExpiresAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accessToken = try container.decode(String.self, forKey: .accessToken)
    accessExpiresAt = try container.decode(Date.self, forKey: .accessExpiresAt)
    refreshToken = try container.decode(String.self, forKey: .refreshToken)
    refreshExpiresAt = try container.decode(Date.self, forKey: .refreshExpiresAt)
    guard WireValidation.isSecret(accessToken), WireValidation.isSecret(refreshToken) else {
      throw DecodingError.dataCorruptedError(
        forKey: .accessToken,
        in: container,
        debugDescription: "Invalid session token."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case accessToken
    case accessExpiresAt
    case refreshToken
    case refreshExpiresAt
  }
}

/// What signing in answers with: the Account, and the one session that reads it.
public struct IosOAuthTokenResponse: Decodable, Equatable, Sendable {
  public let protocolVersion: Int
  public let tokenType: String
  public let accountID: String
  public let session: SessionToken

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    tokenType = try container.decode(String.self, forKey: .tokenType)
    accountID = try container.decode(String.self, forKey: .accountID)
    session = try container.decode(SessionToken.self, forKey: .session)
    guard protocolVersion == WireCodec.oauthProtocolVersion,
      tokenType == "Bearer",
      WireValidation.isOpaqueID(accountID),
      WireValidation.isIOSAccessToken(session.accessToken),
      WireValidation.isIOSRefreshToken(session.refreshToken)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .session,
        in: container,
        debugDescription: "Invalid iOS account token response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case tokenType
    case accountID = "accountId"
    case session
  }
}

public struct IosLoginExchangeRequest: Encodable, Equatable, Sendable {
  public let protocolVersion = WireCodec.oauthProtocolVersion
  public let grantType = "authorization_code"
  public let clientID = QuotaIOSOAuth.clientID
  public let code: String
  public let codeVerifier: String
  public let redirectURI = QuotaIOSOAuth.redirectURI

  public init(code: String, codeVerifier: String) {
    self.code = code
    self.codeVerifier = codeVerifier
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(grantType, forKey: .grantType)
    try container.encode(clientID, forKey: .clientID)
    try container.encode(code, forKey: .code)
    try container.encode(codeVerifier, forKey: .codeVerifier)
    try container.encode(redirectURI, forKey: .redirectURI)
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case grantType
    case clientID = "clientId"
    case code
    case codeVerifier
    case redirectURI = "redirectUri"
  }
}

public struct IosSessionRefreshRequest: Encodable, Equatable, Sendable {
  public let protocolVersion = WireCodec.oauthProtocolVersion
  public let grantType = "refresh_token"
  public let clientID = QuotaIOSOAuth.clientID
  public let refreshToken: String

  public init(refreshToken: String) {
    self.refreshToken = refreshToken
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(grantType, forKey: .grantType)
    try container.encode(clientID, forKey: .clientID)
    try container.encode(refreshToken, forKey: .refreshToken)
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case grantType
    case clientID = "clientId"
    case refreshToken
  }
}

/// A rotated session. There is one, so nothing here says which one it is.
public struct SessionRefreshResponse: Decodable, Equatable, Sendable {
  public let protocolVersion: Int
  public let tokenType: String
  public let accountID: String
  public let session: SessionToken

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    tokenType = try container.decode(String.self, forKey: .tokenType)
    accountID = try container.decode(String.self, forKey: .accountID)
    session = try container.decode(SessionToken.self, forKey: .session)
    guard protocolVersion == WireCodec.oauthProtocolVersion,
      tokenType == "Bearer",
      WireValidation.isOpaqueID(accountID),
      WireValidation.isIOSAccessToken(session.accessToken),
      WireValidation.isIOSRefreshToken(session.refreshToken)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .session,
        in: container,
        debugDescription: "Invalid iOS account refresh response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case tokenType
    case accountID = "accountId"
    case session
  }
}

public struct AccountSession: Codable, Equatable, Sendable {
  public let accountID: String
  public let accessToken: String
  public let accessExpiresAt: Date
  public let refreshToken: String
  public let refreshExpiresAt: Date

  public init(
    accountID: String,
    accessToken: String,
    accessExpiresAt: Date,
    refreshToken: String,
    refreshExpiresAt: Date
  ) {
    self.accountID = accountID
    self.accessToken = accessToken
    self.accessExpiresAt = accessExpiresAt
    self.refreshToken = refreshToken
    self.refreshExpiresAt = refreshExpiresAt
  }

  public init(accountID: String, token: SessionToken) {
    self.init(
      accountID: accountID,
      accessToken: token.accessToken,
      accessExpiresAt: token.accessExpiresAt,
      refreshToken: token.refreshToken,
      refreshExpiresAt: token.refreshExpiresAt
    )
  }

  public init(_ response: IosOAuthTokenResponse) {
    self.init(accountID: response.accountID, token: response.session)
  }

  public init(_ response: SessionRefreshResponse) {
    self.init(accountID: response.accountID, token: response.session)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(String.self, forKey: .accountID)
    accessToken = try container.decode(String.self, forKey: .accessToken)
    accessExpiresAt = try container.decode(Date.self, forKey: .accessExpiresAt)
    refreshToken = try container.decode(String.self, forKey: .refreshToken)
    refreshExpiresAt = try container.decode(Date.self, forKey: .refreshExpiresAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .accessToken,
        in: container,
        debugDescription: "Invalid persisted account session."
      )
    }
  }

  public var isValid: Bool {
    WireValidation.isOpaqueID(accountID)
      && WireValidation.isIOSAccessToken(accessToken)
      && WireValidation.isIOSRefreshToken(refreshToken)
  }

  private enum CodingKeys: String, CodingKey {
    case accountID = "accountId"
    case accessToken
    case accessExpiresAt
    case refreshToken
    case refreshExpiresAt
  }
}

extension AccountSession: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "AccountSession(accountID: \(accountID), accessToken: [redacted], refreshToken: [redacted])"
  }

  public var debugDescription: String { description }
}
