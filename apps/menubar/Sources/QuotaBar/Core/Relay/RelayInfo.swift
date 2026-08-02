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
  var baseURL: URL
  var instanceID: String?
  var mode: RelayMode?
  var capabilities: RelayCapabilities?
  var credentialReference: String?
  var isDefault: Bool

  init(
    id: UUID = UUID(),
    name: String,
    baseURL: URL,
    instanceID: String? = nil,
    mode: RelayMode? = nil,
    capabilities: RelayCapabilities? = nil,
    credentialReference: String? = nil,
    isDefault: Bool = false
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.instanceID = instanceID
    self.mode = mode
    self.capabilities = capabilities
    self.credentialReference = credentialReference
    self.isDefault = isDefault
  }
}
