import Foundation

enum RelayMode: String, Codable, Sendable {
  case managed
  case selfHosted = "self_hosted"
}

struct RelayCapabilities: Codable, Equatable, Sendable {
  let realtime: Bool
  let persistentSnapshots: Bool
  let instantDeviceRevocation: Bool
  let history: Bool
  let multiTenant: Bool
}

struct RelayInfo: Codable, Equatable, Sendable {
  let instanceID: String
  let mode: RelayMode
  let version: String
  let apiVersions: [Int]
  let authMethods: [String]
  let capabilities: RelayCapabilities

  private enum CodingKeys: String, CodingKey {
    case instanceID = "instanceId"
    case mode
    case version
    case apiVersions
    case authMethods
    case capabilities
  }
}

struct RelayProfile: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var name: String
  let baseURL: URL
  let instanceID: String
  let mode: RelayMode
  let capabilities: RelayCapabilities
  let credentialReference: String
  var isDefault: Bool

  init(
    id: UUID = UUID(),
    name: String,
    baseURL: URL,
    instanceID: String,
    mode: RelayMode,
    capabilities: RelayCapabilities,
    isDefault: Bool = false
  ) throws {
    let canonicalURL = try RelayOrigin.canonicalURL(from: baseURL)
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !instanceID.isEmpty,
      capabilities.persistentSnapshots,
      capabilities.instantDeviceRevocation
    else {
      throw RelayProfileError.invalidProfile
    }

    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.baseURL = canonicalURL
    self.instanceID = instanceID
    self.mode = mode
    self.capabilities = capabilities
    self.credentialReference = Self.credentialReference(for: id)
    self.isDefault = isDefault
  }

  static func credentialReference(for id: UUID) -> String {
    "relay-owner:\(id.uuidString.lowercased())"
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case baseURL = "baseUrl"
    case instanceID = "instanceId"
    case mode
    case capabilities
    case credentialReference
    case isDefault
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawBaseURL = try container.decode(String.self, forKey: .baseURL)
    guard let canonicalURL = try? RelayOrigin.canonicalURL(from: rawBaseURL),
      canonicalURL.absoluteString == rawBaseURL
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .baseURL,
        in: container,
        debugDescription: "Invalid Relay profile."
      )
    }

    do {
      let id = try container.decode(UUID.self, forKey: .id)
      let savedCredentialReference = try container.decode(
        String.self,
        forKey: .credentialReference
      )
      guard savedCredentialReference == Self.credentialReference(for: id) else {
        throw RelayProfileError.invalidProfile
      }
      let savedName = try container.decode(String.self, forKey: .name)
      try self.init(
        id: id,
        name: savedName,
        baseURL: canonicalURL,
        instanceID: container.decode(String.self, forKey: .instanceID),
        mode: container.decode(RelayMode.self, forKey: .mode),
        capabilities: container.decode(RelayCapabilities.self, forKey: .capabilities),
        isDefault: container.decode(Bool.self, forKey: .isDefault)
      )
      guard name == savedName else {
        throw RelayProfileError.invalidProfile
      }
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .baseURL,
        in: container,
        debugDescription: "Invalid Relay profile."
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(baseURL.absoluteString, forKey: .baseURL)
    try container.encode(instanceID, forKey: .instanceID)
    try container.encode(mode, forKey: .mode)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encode(credentialReference, forKey: .credentialReference)
    try container.encode(isDefault, forKey: .isDefault)
  }
}

enum RelayProfileError: LocalizedError, Equatable, Sendable {
  case invalidProfile

  var errorDescription: String? { "The saved Relay profile is invalid." }
}
