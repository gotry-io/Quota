import Foundation

/// Every channel an Account can be reached through.
///
/// An Account owns its identities rather than being one
/// ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)). `unknown`
/// is what a tolerant read keeps for a channel a newer Relay offers and this build cannot name.
public enum IdentityProvider: String, Codable, Sendable, TolerantWireEnum {
  case github
  case apple
  case email
  case unknown

  /// The channels a client offers a way in through, in the order every Quota surface lists them.
  public static let offered: [IdentityProvider] = [.apple, .github, .email]

  /// What a person calls the channel, wherever one is named to them. The same words the website
  /// prints, so one Account reads the same on both.
  public var displayName: String {
    switch self {
    case .github: "GitHub"
    case .apple: "Apple"
    case .email: "Email"
    case .unknown: "Other"
    }
  }
}

/// One channel bound to an Account: which it is, what it calls this person, and when it was bound.
///
/// The subject the provider proved is never on the wire — Relay stores only its HMAC — so there
/// is nothing here that identifies the account at the provider.
public struct AccountIdentity: Codable, Equatable, Sendable {
  public let provider: IdentityProvider
  public let label: String?
  public let linkedAt: Date

  public init(provider: IdentityProvider, label: String?, linkedAt: Date) {
    self.provider = provider
    self.label = label
    self.linkedAt = linkedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(IdentityProvider.self, forKey: .provider)
    label = try container.decode(String?.self, forKey: .label)
    linkedAt = try container.decode(Date.self, forKey: .linkedAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .provider,
        in: container,
        debugDescription: "Invalid account identity."
      )
    }
  }

  public var isValid: Bool {
    label.map { WireValidation.isTrimmedText($0, maximum: 128) } ?? true
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case label
    case linkedAt
  }
}

/// The Account read that answers which channels reach this Account.
///
/// `GET /api/v2/account` also carries the Account itself, its entitlement, and where paid sync is
/// bought; this app already reads those from the Account summary, so this tolerant read takes the
/// one thing only this route answers and ignores the rest
/// ([ADR 0023](../../../../docs/decisions/0023-strict-writes-tolerant-reads.md)).
public struct AccountIdentitiesResponse: Decodable, Equatable, Sendable {
  public let protocolVersion: Int
  /// Oldest first, and never empty: an Account always keeps at least one way to sign in to it.
  public let identities: [AccountIdentity]

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    identities = try container.decode([AccountIdentity].self, forKey: .identities)
    guard protocolVersion == WireCodec.oauthProtocolVersion,
      !identities.isEmpty,
      identities.count <= 16
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .identities,
        in: container,
        debugDescription: "Invalid account identities."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case identities
  }
}

/// What binding a channel to the Account a session already names answers with.
///
/// `alreadyLinked` is the same channel on the same Account, which is what a repeated bind is and
/// is not a failure. A refusal is a rejected status, not a member here.
public struct IdentityLinkResponse: Decodable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable, TolerantWireEnum {
    case linked
    case alreadyLinked = "already_linked"
    case unknown
  }

  public let protocolVersion: Int
  public let provider: IdentityProvider
  public let status: Status

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    provider = try container.decode(IdentityProvider.self, forKey: .provider)
    status = try container.decode(Status.self, forKey: .status)
    guard protocolVersion == WireCodec.oauthProtocolVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid identity link response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case provider
    case status
  }
}
