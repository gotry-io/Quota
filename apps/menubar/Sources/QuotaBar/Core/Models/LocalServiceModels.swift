import Foundation

enum LocalServiceComponentStatus: String, Decodable, Sendable {
  case ready
  case stale
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
  case signedOut = "signed_out"
}

enum LocalServiceComponentName: String, Decodable, Sendable {
  case quota
  case usage
  case account
  case pricing
  case providers
}

enum LocalServiceAuthStatus: String, Decodable, Sendable {
  case signedOut = "signed_out"
  case loggingIn = "logging_in"
  case signedIn = "signed_in"
  case logoutPending = "logout_pending"
}

enum LocalServiceErrorCode: String, Decodable, Sendable {
  case invalidRequest = "invalid_request"
  case unsupportedOperation = "unsupported_operation"
  case invalidState = "invalid_state"
  case clientUpgradeRequired = "client_upgrade_required"
  case busy
  case cancelled
  case authenticationRequired = "authentication_required"
  case deviceDeleted = "device_deleted"
  case staleGeneration = "stale_generation"
  case unavailable
  case providerError = "provider_error"
  case networkError = "network_error"
  case invalidResponse = "invalid_response"
  case internalError = "internal"
}

enum LocalServiceRecoveryAction: String, Decodable, Sendable {
  case none
  case retry
  case login
  case configureProvider = "configure_provider"
  case upgrade
  case reinstall
}

struct LocalServiceRemoteError: Decodable, Equatable, Sendable {
  let code: LocalServiceErrorCode
  let recoveryAction: LocalServiceRecoveryAction

  private enum CodingKeys: String, CodingKey {
    case code
    case recoveryAction
  }

}

extension LocalServiceRemoteError {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["code", "recoveryAction"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(LocalServiceErrorCode.self, forKey: .code)
    recoveryAction = try container.decode(LocalServiceRecoveryAction.self, forKey: .recoveryAction)
  }
}

struct LocalServiceComponent<Value: Decodable & Sendable>: Decodable, Sendable {
  let status: LocalServiceComponentStatus
  let value: Value?
  let updatedAt: Date?
  let lastError: LocalServiceRemoteError?
  let refreshing: Bool

  private enum CodingKeys: String, CodingKey {
    case status
    case value
    case updatedAt
    case lastError
    case refreshing
  }

}

extension LocalServiceComponent {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["status", "value", "updatedAt", "lastError", "refreshing"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(LocalServiceComponentStatus.self, forKey: .status)
    value = try container.decodeIfPresent(Value.self, forKey: .value)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    lastError = try container.decodeIfPresent(LocalServiceRemoteError.self, forKey: .lastError)
    refreshing = try container.decode(Bool.self, forKey: .refreshing)
  }
}

struct LocalServiceAccountState: Decodable, Sendable {
  let authStatus: LocalServiceAuthStatus
  let accountID: String?
  let deviceID: String?
  let deviceGeneration: Int?
  let accountSummary: AccountSummary?

  private enum CodingKeys: String, CodingKey {
    case authStatus
    case accountID = "accountId"
    case deviceID = "deviceId"
    case deviceGeneration
    case accountSummary
  }

}

extension LocalServiceAccountState {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "authStatus", "accountId", "deviceId", "deviceGeneration", "accountSummary",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authStatus = try container.decode(LocalServiceAuthStatus.self, forKey: .authStatus)
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    deviceGeneration = try container.decodeIfPresent(Int.self, forKey: .deviceGeneration)
    accountSummary = try container.decodeIfPresent(AccountSummary.self, forKey: .accountSummary)
  }
}

struct LocalServiceProviderConfig: Decodable, Equatable, Sendable {
  let provider: ProviderID
  let configured: Bool
  let maskedAPIKey: String?
  let baseURL: String?

  private enum CodingKeys: String, CodingKey {
    case provider
    case configured
    case maskedAPIKey = "maskedApiKey"
    case baseURL = "baseUrl"
  }

}

extension LocalServiceProviderConfig {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["provider", "configured", "maskedApiKey", "baseUrl"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    configured = try container.decode(Bool.self, forKey: .configured)
    maskedAPIKey = try container.decodeIfPresent(String.self, forKey: .maskedAPIKey)
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
  }
}

enum LocalServiceOverviewScope: String, Decodable, Sendable {
  case global
  case source
}

enum LocalServiceOverviewSourceKind: String, Decodable, Sendable {
  case local
  case device
}

struct LocalServiceOverviewIdentity: Decodable, Sendable {
  let provider: ProviderID
  let fingerprint: String
  let scope: LocalServiceOverviewScope
  let sourceID: String?

  private enum CodingKeys: String, CodingKey {
    case provider
    case fingerprint
    case scope
    case sourceID = "sourceId"
  }

}

extension LocalServiceOverviewIdentity {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["provider", "fingerprint", "scope", "sourceId"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    fingerprint = try container.decode(String.self, forKey: .fingerprint)
    scope = try container.decode(LocalServiceOverviewScope.self, forKey: .scope)
    sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
  }
}

struct LocalServiceOverviewSource: Decodable, Sendable {
  let sourceID: String
  let kind: LocalServiceOverviewSourceKind
  let deviceID: String?
  let displayName: String
  let observedAt: Date
  let isStale: Bool

  private enum CodingKeys: String, CodingKey {
    case sourceID = "sourceId"
    case kind
    case deviceID = "deviceId"
    case displayName
    case observedAt
    case isStale
  }

  var observationSource: QuotaObservationSource? {
    switch kind {
    case .local:
      .local
    case .device:
      deviceID.map(QuotaObservationSource.device)
    }
  }
}

extension LocalServiceOverviewSource {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "sourceId", "kind", "deviceId", "displayName", "observedAt", "isStale",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceID = try container.decode(String.self, forKey: .sourceID)
    kind = try container.decode(LocalServiceOverviewSourceKind.self, forKey: .kind)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    displayName = try container.decode(String.self, forKey: .displayName)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    isStale = try container.decode(Bool.self, forKey: .isStale)
  }
}

struct LocalServiceOverviewItem: Decodable, Sendable {
  let identity: LocalServiceOverviewIdentity
  let snapshot: QuotaSnapshot
  let sources: [LocalServiceOverviewSource]
  let selectedSourceID: String
  let selectedSourceDisplayName: String
  let isStale: Bool

  private enum CodingKeys: String, CodingKey {
    case identity
    case snapshot
    case sources
    case selectedSourceID = "selectedSourceId"
    case selectedSourceDisplayName
    case isStale
  }

}

extension LocalServiceOverviewItem {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "identity", "snapshot", "sources", "selectedSourceId", "selectedSourceDisplayName", "isStale",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identity = try container.decode(LocalServiceOverviewIdentity.self, forKey: .identity)
    snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
    sources = try container.decode([LocalServiceOverviewSource].self, forKey: .sources)
    selectedSourceID = try container.decode(String.self, forKey: .selectedSourceID)
    selectedSourceDisplayName = try container.decode(
      String.self, forKey: .selectedSourceDisplayName)
    isStale = try container.decode(Bool.self, forKey: .isStale)
  }
}

struct LocalServiceState: Decodable, Sendable {
  let ipcVersion: Int
  let revision: Int
  let quota: LocalServiceComponent<QuotaCollectionReport>
  let usage: LocalServiceComponent<LocalUsageReport>
  let account: LocalServiceComponent<LocalServiceAccountState>
  let pricing: LocalServiceComponent<PricingCatalog>
  let providers: [LocalServiceProviderConfig]
  let overview: [LocalServiceOverviewItem]

  private enum CodingKeys: String, CodingKey {
    case ipcVersion
    case revision
    case quota
    case usage
    case account
    case pricing
    case providers
    case overview
  }

  var isValid: Bool {
    let overviewIDs = overview.map { item in
      "\(item.identity.provider.rawValue)|\(item.identity.fingerprint)|"
        + "\(item.identity.scope.rawValue)|\(item.identity.sourceID ?? "")"
    }
    guard ipcVersion == 1, revision >= 0,
      providers.count <= ProviderID.allCases.count,
      Set(providers.map(\.provider)).count == providers.count,
      providers.allSatisfy({ config in
        config.provider.isConfigurable
          && (!config.configured || config.maskedAPIKey?.isEmpty == false)
      }),
      overview.count <= 2_048,
      Set(overviewIDs).count == overviewIDs.count
    else { return false }

    return overview.allSatisfy { item in
      let sourceIDs = item.sources.map(\.sourceID)
      let selectedSource = item.sources.first { $0.sourceID == item.selectedSourceID }
      return item.identity.provider == item.snapshot.provider
        && item.identity.fingerprint == item.snapshot.account.fingerprint
        && !item.identity.fingerprint.isEmpty
        && !item.sources.isEmpty
        && item.sources.count <= 256
        && Set(sourceIDs).count == sourceIDs.count
        && sourceIDs.contains(item.selectedSourceID)
        && selectedSource?.displayName == item.selectedSourceDisplayName
        && (item.identity.scope == .global
          ? item.identity.sourceID == nil
          : item.identity.sourceID.map(sourceIDs.contains) == true)
        && item.sources.allSatisfy { source in
          !source.sourceID.isEmpty && !source.displayName.isEmpty
            && (source.kind == .local ? source.deviceID == nil : source.deviceID?.isEmpty == false)
        }
    }
  }
}

extension LocalServiceState {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "ipcVersion", "revision", "quota", "usage", "account", "pricing", "providers", "overview",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ipcVersion = try container.decode(Int.self, forKey: .ipcVersion)
    revision = try container.decode(Int.self, forKey: .revision)
    quota = try container.decode(LocalServiceComponent<QuotaCollectionReport>.self, forKey: .quota)
    usage = try container.decode(LocalServiceComponent<LocalUsageReport>.self, forKey: .usage)
    account = try container.decode(
      LocalServiceComponent<LocalServiceAccountState>.self, forKey: .account)
    pricing = try container.decode(LocalServiceComponent<PricingCatalog>.self, forKey: .pricing)
    providers = try container.decode([LocalServiceProviderConfig].self, forKey: .providers)
    overview = try container.decode([LocalServiceOverviewItem].self, forKey: .overview)
  }
}

struct LocalServiceRefreshResult: Decodable, Sendable {
  let accepted: Bool
  let pending: Bool
  let revision: Int

  private enum CodingKeys: String, CodingKey {
    case accepted
    case pending
    case revision
  }

}

extension LocalServiceRefreshResult {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["accepted", "pending", "revision"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accepted = try container.decode(Bool.self, forKey: .accepted)
    pending = try container.decode(Bool.self, forKey: .pending)
    revision = try container.decode(Int.self, forKey: .revision)
  }
}

struct LocalServiceLoginResult: Decodable, Sendable {
  let status: LocalServiceAuthStatus
  let accountID: String?
  let deviceID: String?
  let deviceGeneration: Int?

  private enum CodingKeys: String, CodingKey {
    case status
    case accountID = "accountId"
    case deviceID = "deviceId"
    case deviceGeneration
  }

}

extension LocalServiceLoginResult {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["status", "accountId", "deviceId", "deviceGeneration"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(LocalServiceAuthStatus.self, forKey: .status)
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    deviceGeneration = try container.decodeIfPresent(Int.self, forKey: .deviceGeneration)
  }
}

struct LocalServiceLogoutResult: Decodable, Sendable {
  let status: LocalServiceAuthStatus

  private enum CodingKeys: String, CodingKey {
    case status
  }

}

extension LocalServiceLogoutResult {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["status"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(LocalServiceAuthStatus.self, forKey: .status)
  }
}

struct LocalServiceEvent: Decodable, Sendable {
  let type: String
  let event: String
  let revision: Int
  let changedComponents: [LocalServiceComponentName]

  private enum CodingKeys: String, CodingKey {
    case type
    case event
    case revision
    case changedComponents
  }

}

extension LocalServiceEvent {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["type", "event", "revision", "changedComponents"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    event = try container.decode(String.self, forKey: .event)
    revision = try container.decode(Int.self, forKey: .revision)
    changedComponents = try container.decode(
      [LocalServiceComponentName].self, forKey: .changedComponents)
  }
}
