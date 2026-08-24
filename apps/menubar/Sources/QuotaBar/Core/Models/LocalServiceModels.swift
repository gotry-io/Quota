import Foundation
import QuotaWire

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
  case repair
}

enum LocalServiceRepairStatus: String, Decodable, Equatable, Sendable {
  case idle
  case checking
  case repairing
  case stuck
  case failed
  case completed
}

enum LocalServiceRepairSeverity: String, Decodable, Equatable, Sendable {
  case none
  case derived
  case durable
}

enum LocalServiceRepairPhase: String, Decodable, Equatable, Sendable {
  case preservingAccount = "preserving_account"
  case rebuildingStorage = "rebuilding_storage"
  case reindexingUsage = "reindexing_usage"
  case verifying
  case restoringLastGood = "restoring_last_good"
}

enum LocalServiceRepairRecoveryAction: String, Decodable, Equatable, Sendable {
  case retry
  case reinstall
}

struct LocalServiceRepairSession: Decodable, Equatable, Sendable {
  let status: LocalServiceRepairStatus
  let severity: LocalServiceRepairSeverity
  let phase: LocalServiceRepairPhase?
  let title: String?
  let guidance: String?
  let activity: String?
  let startedAt: Date?
  let heartbeatAt: Date?
  let progressCurrent: Int?
  let progressTotal: Int?
  let stuck: Bool
  let blocksQuit: Bool
  let recoveryAction: LocalServiceRepairRecoveryAction?

  private enum CodingKeys: String, CodingKey {
    case status
    case severity
    case phase
    case title
    case guidance
    case activity
    case startedAt
    case heartbeatAt
    case progressCurrent
    case progressTotal
    case stuck
    case blocksQuit
    case recoveryAction
  }

  static var idle: LocalServiceRepairSession {
    LocalServiceRepairSession(
      status: .idle,
      severity: .none,
      phase: nil,
      title: nil,
      guidance: nil,
      activity: nil,
      startedAt: nil,
      heartbeatAt: nil,
      progressCurrent: nil,
      progressTotal: nil,
      stuck: false,
      blocksQuit: false,
      recoveryAction: nil
    )
  }

  var isValid: Bool {
    guard controlFree(title, max: 64), controlFree(guidance, max: 160),
      controlFree(activity, max: 64)
    else { return false }
    switch (progressCurrent, progressTotal) {
    case (nil, nil):
      break
    case (let current?, let total?) where (1...1_000_000).contains(total) && current >= 0
      && current <= total:
      break
    default:
      return false
    }
    if blocksQuit && !(severity == .durable && status == .repairing) { return false }
    if status == .idle {
      return severity == .none && phase == nil && title == nil && guidance == nil
        && activity == nil && startedAt == nil && heartbeatAt == nil && progressCurrent == nil
        && progressTotal == nil && !stuck && !blocksQuit && recoveryAction == nil
    }
    if startedAt == nil || heartbeatAt == nil { return false }
    if recoveryAction != nil && status != .stuck && status != .failed { return false }
    if stuck && status != .stuck && status != .failed { return false }
    return true
  }

  private func controlFree(_ value: String?, max: Int) -> Bool {
    guard let value else { return true }
    return value.count <= max && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }
}

extension LocalServiceRepairSession {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "status", "severity", "phase", "title", "guidance", "activity", "startedAt", "heartbeatAt",
      "progressCurrent", "progressTotal", "stuck", "blocksQuit", "recoveryAction",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(LocalServiceRepairStatus.self, forKey: .status)
    severity = try container.decode(LocalServiceRepairSeverity.self, forKey: .severity)
    phase = try container.decodeIfPresent(LocalServiceRepairPhase.self, forKey: .phase)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    guidance = try container.decodeIfPresent(String.self, forKey: .guidance)
    activity = try container.decodeIfPresent(String.self, forKey: .activity)
    startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
    heartbeatAt = try container.decodeIfPresent(Date.self, forKey: .heartbeatAt)
    progressCurrent = try container.decodeIfPresent(Int.self, forKey: .progressCurrent)
    progressTotal = try container.decodeIfPresent(Int.self, forKey: .progressTotal)
    stuck = try container.decode(Bool.self, forKey: .stuck)
    blocksQuit = try container.decode(Bool.self, forKey: .blocksQuit)
    recoveryAction = try container.decodeIfPresent(
      LocalServiceRepairRecoveryAction.self, forKey: .recoveryAction)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid repair session."
      )
    }
  }
}

enum RepairPresentationKind: Equatable, Sendable {
  case overview
  case derivedNotice
  case fullPage
}

enum RepairPresentation {
  static func kind(for session: LocalServiceRepairSession) -> RepairPresentationKind {
    switch session.status {
    case .idle, .checking:
      return .overview
    case .repairing, .stuck, .failed, .completed:
      switch session.severity {
      case .durable: return .fullPage
      case .derived: return .derivedNotice
      case .none: return .overview
      }
    }
  }

  static func headerTitle(for session: LocalServiceRepairSession) -> String {
    switch session.status {
    case .stuck: "Repair stopped"
    case .failed: "Repair failed"
    default: "Repairing"
    }
  }
}

enum LocalServiceAuthStatus: String, Decodable, Sendable {
  case signedOut = "signed_out"
  case loggingIn = "logging_in"
  case signedIn = "signed_in"
  case logoutPending = "logout_pending"
}

enum UsageSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case local
  case account

  var id: Self { self }
}

enum UsagePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
  case today
  case last7Days = "last_7_days"
  case last30Days = "last_30_days"
  case all

  var id: Self { self }
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

struct LocalServiceProviderBrowserSession: Decodable, Equatable, Sendable {
  let provider: ProviderID
  let configured: Bool
  let accountFingerprint: String?
  let accountLabel: String?

  private enum CodingKeys: String, CodingKey {
    case provider
    case configured
    case accountFingerprint
    case accountLabel
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "provider", "configured", "accountFingerprint", "accountLabel",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    configured = try container.decode(Bool.self, forKey: .configured)
    accountFingerprint = try container.decodeIfPresent(String.self, forKey: .accountFingerprint)
    accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
  }

  var isValid: Bool {
    guard provider.browserSession != nil else { return false }
    if !configured { return accountFingerprint == nil && accountLabel == nil }
    guard let accountFingerprint else { return false }
    return accountFingerprint.count == 64
      && accountFingerprint.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
      && accountLabel.map {
        !$0.isEmpty && $0.utf8.count <= 128
          && !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
      } != false
  }
}

struct LocalServiceProviderBrowserSessionCandidate: Decodable, Equatable, Sendable {
  let provider: ProviderID
  let accountFingerprint: String
  let accountLabel: String?

  private enum CodingKeys: String, CodingKey {
    case provider
    case accountFingerprint
    case accountLabel
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["provider", "accountFingerprint", "accountLabel"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    accountFingerprint = try container.decode(String.self, forKey: .accountFingerprint)
    accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
  }

  init(provider: ProviderID, accountFingerprint: String, accountLabel: String?) {
    self.provider = provider
    self.accountFingerprint = accountFingerprint
    self.accountLabel = accountLabel
  }

  var isValid: Bool {
    LocalServiceProviderBrowserSession(
      provider: provider,
      configured: true,
      accountFingerprint: accountFingerprint,
      accountLabel: accountLabel
    ).isValid
  }
}

extension LocalServiceProviderBrowserSession {
  init(provider: ProviderID, configured: Bool, accountFingerprint: String?, accountLabel: String?) {
    self.provider = provider
    self.configured = configured
    self.accountFingerprint = accountFingerprint
    self.accountLabel = accountLabel
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
  let usageUploadEnabled: Bool
  let usagePeriods: LocalServiceUsagePeriodCache
  let quota: LocalServiceComponent<QuotaCollectionReport>
  let usage: LocalServiceComponent<LocalUsageReport>
  let account: LocalServiceComponent<LocalServiceAccountState>
  let pricing: LocalServiceComponent<PricingCatalog>
  let providers: [LocalServiceProviderConfig]
  let providerBrowserSessions: [LocalServiceProviderBrowserSession]
  let overview: [LocalServiceOverviewItem]
  let repair: LocalServiceRepairSession

  private enum CodingKeys: String, CodingKey {
    case ipcVersion
    case revision
    case usageUploadEnabled
    case usagePeriods
    case quota
    case usage
    case account
    case pricing
    case providers
    case providerBrowserSessions
    case overview
    case repair
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
      providerBrowserSessions.count <= ProviderID.allCases.count,
      Set(providerBrowserSessions.map(\.provider)).count == providerBrowserSessions.count,
      providerBrowserSessions.allSatisfy(\.isValid),
      overview.count <= 2_048,
      Set(overviewIDs).count == overviewIDs.count,
      repair.isValid
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
      "ipcVersion", "revision", "usageUploadEnabled", "usagePeriods", "quota", "usage",
      "account", "pricing", "providers", "providerBrowserSessions", "overview", "repair",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ipcVersion = try container.decode(Int.self, forKey: .ipcVersion)
    revision = try container.decode(Int.self, forKey: .revision)
    usageUploadEnabled = try container.decode(Bool.self, forKey: .usageUploadEnabled)
    usagePeriods = try container.decode(LocalServiceUsagePeriodCache.self, forKey: .usagePeriods)
    quota = try container.decode(LocalServiceComponent<QuotaCollectionReport>.self, forKey: .quota)
    usage = try container.decode(LocalServiceComponent<LocalUsageReport>.self, forKey: .usage)
    account = try container.decode(
      LocalServiceComponent<LocalServiceAccountState>.self, forKey: .account)
    pricing = try container.decode(LocalServiceComponent<PricingCatalog>.self, forKey: .pricing)
    providers = try container.decode([LocalServiceProviderConfig].self, forKey: .providers)
    providerBrowserSessions = try container.decode(
      [LocalServiceProviderBrowserSession].self, forKey: .providerBrowserSessions)
    overview = try container.decode([LocalServiceOverviewItem].self, forKey: .overview)
    repair = try container.decode(LocalServiceRepairSession.self, forKey: .repair)
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

struct LocalServiceUsageUploadSetting: Decodable, Sendable {
  let enabled: Bool

  private enum CodingKeys: String, CodingKey {
    case enabled
  }
}

struct LocalServiceUsageDetail: Decodable, Equatable, Sendable {
  let range: UsageDateRange
  let usage: LocalUsagePeriodSummary
  let fallbackModels: [LocalUsageModelSummary]
  let incomplete: Bool
  let detailsTruncated: Bool

  private enum CodingKeys: String, CodingKey {
    case range
    case usage
    case fallbackModels
    case incomplete
    case detailsTruncated
  }

  var isValid: Bool {
    range.isValid && usage.isValid && fallbackModels.count <= 1_000
      && fallbackModels.allSatisfy(\.isValid)
      && (usage.clients.isEmpty || fallbackModels.isEmpty)
  }
}

struct LocalServiceUsagePeriodCache: Decodable, Equatable, Sendable {
  let local: LocalServiceUsagePeriodValues
  let account: LocalServiceUsagePeriodValues

  private enum CodingKeys: String, CodingKey {
    case local
    case account
  }

  func detail(source: UsageSource, period: UsagePeriod) -> LocalServiceUsageDetail? {
    let values = source == .local ? local : account
    return switch period {
    case .today: values.today
    case .last7Days: values.last7Days
    case .last30Days: values.last30Days
    case .all: values.all
    }
  }
}

struct LocalServiceUsagePeriodValues: Decodable, Equatable, Sendable {
  let today: LocalServiceUsageDetail?
  let last7Days: LocalServiceUsageDetail?
  let last30Days: LocalServiceUsageDetail?
  let all: LocalServiceUsageDetail?

  private enum CodingKeys: String, CodingKey {
    case today
    case last7Days
    case last30Days
    case all
  }
}

extension LocalServiceUsagePeriodCache {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["local", "account"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    local = try container.decode(LocalServiceUsagePeriodValues.self, forKey: .local)
    account = try container.decode(LocalServiceUsagePeriodValues.self, forKey: .account)
  }
}

extension LocalServiceUsagePeriodValues {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["today", "last7Days", "last30Days", "all"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    today = try container.decodeIfPresent(LocalServiceUsageDetail.self, forKey: .today)
    last7Days = try container.decodeIfPresent(LocalServiceUsageDetail.self, forKey: .last7Days)
    last30Days = try container.decodeIfPresent(LocalServiceUsageDetail.self, forKey: .last30Days)
    all = try container.decodeIfPresent(LocalServiceUsageDetail.self, forKey: .all)
  }
}

extension LocalServiceUsageDetail {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "range", "usage", "fallbackModels", "incomplete", "detailsTruncated",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    range = try container.decode(UsageDateRange.self, forKey: .range)
    usage = try container.decode(LocalUsagePeriodSummary.self, forKey: .usage)
    fallbackModels = try container.decode([LocalUsageModelSummary].self, forKey: .fallbackModels)
    incomplete = try container.decode(Bool.self, forKey: .incomplete)
    detailsTruncated = try container.decode(Bool.self, forKey: .detailsTruncated)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .usage,
        in: container,
        debugDescription: "Invalid local service Usage detail."
      )
    }
  }
}

extension LocalServiceUsageUploadSetting {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["enabled"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decode(Bool.self, forKey: .enabled)
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
