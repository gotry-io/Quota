import Foundation

/// What this device uploads: the readings it took, at the generation its session was opened at.
///
/// The token names the Device, so the body names neither an id the caller could get wrong nor a
/// sequence Relay would have to keep for it: a reading is placed by provider and account
/// fingerprint, and ordered by the instant it was observed.
public struct QuotaSnapshotEnvelope: Encodable, Equatable, Sendable {
  /// What one upload may carry. It is the contract's cap, not a policy of this client's.
  public static let maximumSnapshots = 32

  public let protocolVersion = WireCodec.managedDataProtocolVersion
  public let generation: Int
  public let snapshots: [QuotaSnapshot]

  public init(generation: Int, snapshots: [QuotaSnapshot]) {
    self.generation = generation
    self.snapshots = snapshots
  }

  public var isValid: Bool {
    generation > 0 && snapshots.count <= Self.maximumSnapshots
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case generation
    case snapshots
  }
}

/// What Relay answers an upload with: which readings it took, and which it already had newer.
public struct QuotaSnapshotUploadResponse: Decodable, Equatable, Sendable {
  public let protocolVersion: Int
  public let deviceID: String
  public let deviceGeneration: Int
  public let accepted: [ProviderID]
  public let ignored: [ProviderID]

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    deviceGeneration = try container.decode(Int.self, forKey: .deviceGeneration)
    accepted = try container.decode([ProviderID].self, forKey: .accepted)
    ignored = try container.decode([ProviderID].self, forKey: .ignored)
    guard protocolVersion == WireCodec.managedDataProtocolVersion,
      WireValidation.isOpaqueID(deviceID),
      deviceGeneration > 0
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID,
        in: container,
        debugDescription: "Invalid snapshot upload response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case deviceID = "deviceId"
    case deviceGeneration
    case accepted
    case ignored
  }
}

/// The Device's own control document: what generation it is at, and what an upload must name.
///
/// Reading it is the first half of an upload, and it is also where a phone is told sync is not
/// paid for: the route answers 402 before it answers a generation
/// ([ADR 0033](../../../../docs/decisions/0033-entitlement-is-read-from-revenuecat.md)).
public struct DeviceSyncResponse: Decodable, Equatable, Sendable {
  public let protocolVersion: Int
  public let accountID: String
  public let deviceID: String
  public let deviceGeneration: Int

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    accountID = try container.decode(String.self, forKey: .accountID)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    deviceGeneration = try container.decode(Int.self, forKey: .deviceGeneration)
    guard protocolVersion == WireCodec.oauthProtocolVersion,
      WireValidation.isOpaqueID(accountID),
      WireValidation.isOpaqueID(deviceID),
      deviceGeneration > 0
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID,
        in: container,
        debugDescription: "Invalid device sync response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case accountID = "accountId"
    case deviceID = "deviceId"
    case deviceGeneration
  }
}
