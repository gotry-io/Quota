import Foundation

struct OwnerSnapshotListResponse: Decodable, Equatable, Sendable {
  let observations: [OwnerSnapshotObservation]
}

struct OwnerSnapshotObservation: Decodable, Equatable, Sendable {
  let deviceID: String
  let sequence: Int
  let capturedAt: Date
  let snapshot: QuotaSnapshot
  let updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case sequence
    case capturedAt
    case snapshot
    case updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    sequence = try container.decode(Int.self, forKey: .sequence)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)

    guard !deviceID.isEmpty, sequence >= 0, snapshot.isValidWireSnapshot else {
      throw DecodingError.dataCorruptedError(
        forKey: .snapshot,
        in: container,
        debugDescription: "Invalid Relay snapshot observation."
      )
    }
  }
}

struct DeviceListResponse: Decodable, Equatable, Sendable {
  let devices: [RelayDevice]
}

struct RelayDevice: Decodable, Equatable, Identifiable, Sendable {
  let deviceID: String
  let displayName: String
  let createdAt: Date
  let lastSeenAt: Date?
  let lastSequence: Int
  let revokedAt: Date?

  var id: String { deviceID }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case displayName
    case createdAt
    case lastSeenAt
    case lastSequence
    case revokedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    displayName = try container.decode(String.self, forKey: .displayName)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
    lastSequence = try container.decode(Int.self, forKey: .lastSequence)
    revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)

    guard !deviceID.isEmpty, !displayName.isEmpty, lastSequence >= -1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID,
        in: container,
        debugDescription: "Invalid Relay device."
      )
    }
  }
}

private extension QuotaSnapshot {
  var isValidWireSnapshot: Bool {
    !account.fingerprint.isEmpty
      && (account.label == nil || account.label?.isEmpty == false)
      && (account.plan == nil || account.plan?.isEmpty == false)
      && !source.isEmpty
      && windows.allSatisfy { window in
        !window.id.isEmpty
          && !window.title.isEmpty
          && (0...100).contains(window.usedPercent)
          && (window.durationSeconds.map { $0 >= 0 } ?? true)
      }
  }
}
