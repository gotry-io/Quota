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

/// The installation this phone presents when it is asking to be a Device.
///
/// The three parts travel together, because a Device with no name to list it under is not one
/// this Account could ever show
/// ([ADR 0041](../../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
public struct IosDeviceRegistration: Equatable, Sendable {
  public static let platform = "ios"

  public let installationID: String
  public let displayName: String

  public init(installationID: String, displayName: String) {
    self.installationID = installationID
    self.displayName = displayName
  }
}

/// What signing in answers with: the Account, its name, the Device this session speaks for when
/// it registered one, and the one session that reads them.
///
/// `displayLabel` is what the Account is called, the same value an Account read carries. It is
/// read tolerantly — an absent or null label is an Account with no name, not a refused sign-in.
/// `deviceID` and `deviceGeneration` are answered together or not at all: a session either names
/// the Device it speaks for, at the generation that Device had when it opened, or names none.
public struct IosOAuthTokenResponse: Decodable, Equatable, Sendable {
  public let protocolVersion: Int
  public let tokenType: String
  public let accountID: String
  public let displayLabel: String?
  public let deviceID: String?
  public let deviceGeneration: Int?
  public let session: SessionToken

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    tokenType = try container.decode(String.self, forKey: .tokenType)
    accountID = try container.decode(String.self, forKey: .accountID)
    displayLabel = try container.decodeIfPresent(String.self, forKey: .displayLabel)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    deviceGeneration = try container.decodeIfPresent(Int.self, forKey: .deviceGeneration)
    session = try container.decode(SessionToken.self, forKey: .session)
    guard protocolVersion == WireCodec.oauthProtocolVersion,
      tokenType == "Bearer",
      WireValidation.isOpaqueID(accountID),
      displayLabel.map({ WireValidation.isTrimmedText($0, maximum: 128) }) ?? true,
      (deviceID == nil) == (deviceGeneration == nil),
      deviceID.map(WireValidation.isOpaqueID) ?? true,
      deviceGeneration.map { $0 > 0 } ?? true,
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
    case displayLabel
    case deviceID = "deviceId"
    case deviceGeneration
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
  /// Absent when this phone is only reading the Account.
  public let device: IosDeviceRegistration?

  public init(code: String, codeVerifier: String, device: IosDeviceRegistration? = nil) {
    self.code = code
    self.codeVerifier = codeVerifier
    self.device = device
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(grantType, forKey: .grantType)
    try container.encode(clientID, forKey: .clientID)
    try container.encode(code, forKey: .code)
    try container.encode(codeVerifier, forKey: .codeVerifier)
    try container.encode(redirectURI, forKey: .redirectURI)
    if let device {
      try container.encode(device.installationID, forKey: .installationID)
      try container.encode(device.displayName, forKey: .deviceDisplayName)
      try container.encode(IosDeviceRegistration.platform, forKey: .platform)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case grantType
    case clientID = "clientId"
    case code
    case codeVerifier
    case redirectURI = "redirectUri"
    case installationID = "installationId"
    case deviceDisplayName
    case platform
  }
}

/// What Sign in with Apple posts from inside the app.
///
/// `ASAuthorizationAppleIDProvider` has already proved this identity on the device, so there is
/// no browser round trip: the token Apple signed goes straight to Relay, which checks it against
/// Apple's own keys. `nonce` is the value this device generated; Apple was handed its SHA-256, so
/// sending the value is what proves the token answers this request.
public struct AppleNativeSignInRequest: Encodable, Equatable, Sendable {
  public let protocolVersion = WireCodec.oauthProtocolVersion
  public let clientID = QuotaIOSOAuth.clientID
  public let identityToken: String
  public let nonce: String
  /// Absent when signing in. `link` binds Apple to the Account the session already names.
  public let intent: String?
  /// Absent when this phone is only reading the Account, and on a link, which opens no session.
  public let device: IosDeviceRegistration?

  public init(
    identityToken: String,
    nonce: String,
    intent: String? = nil,
    device: IosDeviceRegistration? = nil
  ) {
    self.identityToken = identityToken
    self.nonce = nonce
    self.intent = intent
    self.device = device
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(clientID, forKey: .clientID)
    try container.encode(identityToken, forKey: .identityToken)
    try container.encode(nonce, forKey: .nonce)
    try container.encodeIfPresent(intent, forKey: .intent)
    if let device {
      try container.encode(device.installationID, forKey: .installationID)
      try container.encode(device.displayName, forKey: .deviceDisplayName)
      try container.encode(IosDeviceRegistration.platform, forKey: .platform)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case clientID = "clientId"
    case identityToken
    case nonce
    case intent
    case installationID = "installationId"
    case deviceDisplayName
    case platform
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

/// Whether this device has confirmed the GitHub account the session belongs to.
///
/// `pending` is the record `completeLogin` writes: it may fetch the identifying summary, but it
/// is not a signed-in session. Only Continue promotes the same record to `active`.
public enum AccountSessionActivation: String, Codable, Equatable, Sendable {
  case pending
  case active
}

public struct AccountSession: Codable, Equatable, Sendable {
  public let accountID: String
  /// The Device this session speaks for, or nil when it registered none. A session that names
  /// one may write it; whether that write is accepted is the Account's entitlement to answer
  /// ([ADR 0041](../../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
  public let deviceID: String?
  public let accessToken: String
  public let accessExpiresAt: Date
  public let refreshToken: String
  public let refreshExpiresAt: Date
  public let activation: AccountSessionActivation

  public init(
    accountID: String,
    deviceID: String? = nil,
    accessToken: String,
    accessExpiresAt: Date,
    refreshToken: String,
    refreshExpiresAt: Date,
    activation: AccountSessionActivation
  ) {
    self.accountID = accountID
    self.deviceID = deviceID
    self.accessToken = accessToken
    self.accessExpiresAt = accessExpiresAt
    self.refreshToken = refreshToken
    self.refreshExpiresAt = refreshExpiresAt
    self.activation = activation
  }

  public init(
    accountID: String,
    deviceID: String? = nil,
    token: SessionToken,
    activation: AccountSessionActivation
  ) {
    self.init(
      accountID: accountID,
      deviceID: deviceID,
      accessToken: token.accessToken,
      accessExpiresAt: token.accessExpiresAt,
      refreshToken: token.refreshToken,
      refreshExpiresAt: token.refreshExpiresAt,
      activation: activation
    )
  }

  public init(_ response: IosOAuthTokenResponse) {
    self.init(
      accountID: response.accountID,
      deviceID: response.deviceID,
      token: response.session,
      activation: .pending
    )
  }

  /// A rotated session. Rotation answers the tokens, not the Device: the session speaks for the
  /// one it was opened for until it is replaced.
  public init(
    _ response: SessionRefreshResponse,
    deviceID: String?,
    activation: AccountSessionActivation
  ) {
    self.init(
      accountID: response.accountID,
      deviceID: deviceID,
      token: response.session,
      activation: activation
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(String.self, forKey: .accountID)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    accessToken = try container.decode(String.self, forKey: .accessToken)
    accessExpiresAt = try container.decode(Date.self, forKey: .accessExpiresAt)
    refreshToken = try container.decode(String.self, forKey: .refreshToken)
    refreshExpiresAt = try container.decode(Date.self, forKey: .refreshExpiresAt)
    activation = try container.decode(AccountSessionActivation.self, forKey: .activation)
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
      && deviceID.map(WireValidation.isOpaqueID) ?? true
      && WireValidation.isIOSAccessToken(accessToken)
      && WireValidation.isIOSRefreshToken(refreshToken)
  }

  public func withActivation(_ activation: AccountSessionActivation) -> AccountSession {
    AccountSession(
      accountID: accountID,
      deviceID: deviceID,
      accessToken: accessToken,
      accessExpiresAt: accessExpiresAt,
      refreshToken: refreshToken,
      refreshExpiresAt: refreshExpiresAt,
      activation: activation
    )
  }

  private enum CodingKeys: String, CodingKey {
    case accountID = "accountId"
    case deviceID = "deviceId"
    case accessToken
    case accessExpiresAt
    case refreshToken
    case refreshExpiresAt
    case activation
  }
}

extension AccountSession: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "AccountSession(accountID: \(accountID), activation: \(activation), accessToken: [redacted], refreshToken: [redacted])"
  }

  public var debugDescription: String { description }
}
