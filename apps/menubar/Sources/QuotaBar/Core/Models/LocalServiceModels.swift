import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaWire

enum LocalServiceComponentStatus: String, Decodable, Sendable {
  case ready
  case stale
  case authRequired = "auth_required"
  case unavailable
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

/// What the service says about the disposable half of its local state.
///
/// `rebuilding` means the cache was thrown away and this Mac has not finished one full Usage
/// scan since, so local history is still filling in.
struct LocalServiceCacheState: Decodable, Equatable, Sendable {
  let rebuilding: Bool
  let resetAt: Date?

  static let settled = LocalServiceCacheState(rebuilding: false, resetAt: nil)

  private enum CodingKeys: String, CodingKey {
    case rebuilding
    case resetAt
  }

  init(rebuilding: Bool, resetAt: Date?) {
    self.rebuilding = rebuilding
    self.resetAt = resetAt
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["rebuilding", "resetAt"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rebuilding = try container.decode(Bool.self, forKey: .rebuilding)
    resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
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

/// The four periods `get_state` carries, keyed the way the private IPC state keys them.
enum UsagePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
  case today
  case last7Days = "last_7_days"
  case last30Days = "last_30_days"
  case all

  var id: Self { self }

  init(summaryKey: UsageSummaryPeriodKey) {
    switch summaryKey {
    case .today: self = .today
    case .last7Days: self = .last7Days
    case .last30Days: self = .last30Days
    case .all: self = .all
    }
  }
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

/// What this Mac knows about the account it is signed in to.
///
/// `displayLabel` is what the sign-in itself said the account is called. It arrives with the
/// session, long before `accountSummary` — a whole account read — can, so it is what names the
/// account in the window while the first read is still running.
struct LocalServiceAccountState: Decodable, Sendable {
  let authStatus: LocalServiceAuthStatus
  let accountID: String?
  let displayLabel: String?
  let deviceID: String?
  let deviceGeneration: Int?
  let accountSummary: AccountSummary?

  private enum CodingKeys: String, CodingKey {
    case authStatus
    case accountID = "accountId"
    case displayLabel
    case deviceID = "deviceId"
    case deviceGeneration
    case accountSummary
  }

}

extension LocalServiceAccountState {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "authStatus", "accountId", "displayLabel", "deviceId", "deviceGeneration", "accountSummary",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authStatus = try container.decode(LocalServiceAuthStatus.self, forKey: .authStatus)
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    displayLabel = try container.decodeIfPresent(String.self, forKey: .displayLabel)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    deviceGeneration = try container.decodeIfPresent(Int.self, forKey: .deviceGeneration)
    accountSummary = try container.decodeIfPresent(AccountSummary.self, forKey: .accountSummary)
  }
}

struct LocalServiceProviderStatus: Decodable, Equatable, Sendable {
  let provider: ProviderID
  let indicator: ProviderServiceStatusIndicator
  let description: String
  let checkedAt: Date

  private enum CodingKeys: String, CodingKey {
    case provider
    case indicator
    case description
    case checkedAt
  }
}

extension LocalServiceProviderStatus {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["provider", "indicator", "description", "checkedAt"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    indicator = try container.decode(ProviderServiceStatusIndicator.self, forKey: .indicator)
    description = try container.decode(String.self, forKey: .description)
    checkedAt = try container.decode(Date.self, forKey: .checkedAt)
  }

  var settingsLine: String {
    ProviderServiceStatusCopy.settingsLine(indicator: indicator, description: description)
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

  /// The local opaque key samples and `quota_history` use for this subscription.
  var subscriptionSelector: String {
    SubscriptionSelector.make(
      provider: provider.rawValue,
      fingerprint: fingerprint,
      fingerprintScope: scope.rawValue,
      sourceID: sourceID
    )
  }

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
  let snapshot: QuotaSnapshot?

  init(
    sourceID: String,
    kind: LocalServiceOverviewSourceKind,
    deviceID: String?,
    displayName: String,
    observedAt: Date,
    isStale: Bool,
    snapshot: QuotaSnapshot? = nil
  ) {
    self.sourceID = sourceID
    self.kind = kind
    self.deviceID = deviceID
    self.displayName = displayName
    self.observedAt = observedAt
    self.isStale = isStale
    self.snapshot = snapshot
  }

  private enum CodingKeys: String, CodingKey {
    case sourceID = "sourceId"
    case kind
    case deviceID = "deviceId"
    case displayName
    case observedAt
    case isStale
    case snapshot
  }

  var observationSource: QuotaObservationSource? {
    switch kind {
    case .local:
      .local
    case .device:
      deviceID.map(QuotaObservationSource.device)
    }
  }

  var symbolName: String { kind == .local ? "laptopcomputer" : "desktopcomputer" }
}

extension LocalServiceOverviewSource {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "sourceId", "kind", "deviceId", "displayName", "observedAt", "isStale", "snapshot",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceID = try container.decode(String.self, forKey: .sourceID)
    kind = try container.decode(LocalServiceOverviewSourceKind.self, forKey: .kind)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    displayName = try container.decode(String.self, forKey: .displayName)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    isStale = try container.decode(Bool.self, forKey: .isStale)
    snapshot = try container.decodeIfPresent(QuotaSnapshot.self, forKey: .snapshot)
  }
}

struct LocalServiceOverviewItem: Decodable, Sendable {
  let identity: LocalServiceOverviewIdentity
  let snapshot: QuotaSnapshot
  let sources: [LocalServiceOverviewSource]
  let selectedSourceID: String
  let selectedSourceDisplayName: String
  let automaticSourceID: String
  let automaticSourceDisplayName: String
  let isStale: Bool
  let sourcePin: String?

  var pinIdentityKey: String {
    "\(identity.provider.rawValue)|\(identity.fingerprint)|\(identity.scope.rawValue)|\(identity.sourceID ?? "")"
  }

  init(
    identity: LocalServiceOverviewIdentity,
    snapshot: QuotaSnapshot,
    sources: [LocalServiceOverviewSource],
    selectedSourceID: String,
    selectedSourceDisplayName: String,
    automaticSourceID: String,
    automaticSourceDisplayName: String,
    isStale: Bool,
    sourcePin: String? = nil
  ) {
    self.identity = identity
    self.snapshot = snapshot
    self.sources = sources
    self.selectedSourceID = selectedSourceID
    self.selectedSourceDisplayName = selectedSourceDisplayName
    self.automaticSourceID = automaticSourceID
    self.automaticSourceDisplayName = automaticSourceDisplayName
    self.isStale = isStale
    self.sourcePin = sourcePin
  }

  private enum CodingKeys: String, CodingKey {
    case identity
    case snapshot
    case sources
    case selectedSourceID = "selectedSourceId"
    case selectedSourceDisplayName
    case automaticSourceID = "automaticSourceId"
    case automaticSourceDisplayName
    case isStale
    case sourcePin
  }

}

extension LocalServiceOverviewItem {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "identity", "snapshot", "sources", "selectedSourceId", "selectedSourceDisplayName",
      "automaticSourceId", "automaticSourceDisplayName", "isStale", "sourcePin",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identity = try container.decode(LocalServiceOverviewIdentity.self, forKey: .identity)
    snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
    sources = try container.decode([LocalServiceOverviewSource].self, forKey: .sources)
    selectedSourceID = try container.decode(String.self, forKey: .selectedSourceID)
    selectedSourceDisplayName = try container.decode(
      String.self, forKey: .selectedSourceDisplayName)
    automaticSourceID = try container.decode(String.self, forKey: .automaticSourceID)
    automaticSourceDisplayName = try container.decode(
      String.self, forKey: .automaticSourceDisplayName)
    isStale = try container.decode(Bool.self, forKey: .isStale)
    sourcePin = try container.decodeIfPresent(String.self, forKey: .sourcePin)
  }
}

struct LocalServiceState: Decodable, Sendable {
  /// The one private IPC version this app speaks. The two ship together, so a helper that
  /// announces anything else is not the one in this bundle.
  static let supportedIPCVersion = 5

  let ipcVersion: Int
  let revision: Int
  let usageUploadEnabled: Bool
  let groupUsageByProject: Bool
  let quotaRefreshIntervalSeconds: Int
  let usagePeriods: LocalServiceUsagePeriodCache
  let quota: LocalServiceComponent<QuotaCollectionReport>
  let usage: LocalServiceComponent<LocalUsageReport>
  let account: LocalServiceComponent<LocalServiceAccountState>
  /// Present only while signed in and the helper has already read the document. Signed out, the
  /// key is absent, not `null`.
  let accountSettings: LocalServiceAccountSettingsState?
  /// Present only while signed in. Signed out, the key is absent, not `null`.
  let historySync: LocalServiceHistorySync?
  let pricing: LocalServiceComponent<PricingCatalog>
  let providers: [LocalServiceProviderConfig]
  var providerStatus: [LocalServiceProviderStatus] = []
  let providerBrowserSessions: [LocalServiceProviderBrowserSession]
  let browserScanEnabled: [ProviderID]
  let overview: [LocalServiceOverviewItem]
  let cache: LocalServiceCacheState

  init(
    ipcVersion: Int,
    revision: Int,
    usageUploadEnabled: Bool,
    groupUsageByProject: Bool,
    quotaRefreshIntervalSeconds: Int,
    usagePeriods: LocalServiceUsagePeriodCache,
    quota: LocalServiceComponent<QuotaCollectionReport>,
    usage: LocalServiceComponent<LocalUsageReport>,
    account: LocalServiceComponent<LocalServiceAccountState>,
    accountSettings: LocalServiceAccountSettingsState? = nil,
    historySync: LocalServiceHistorySync? = nil,
    pricing: LocalServiceComponent<PricingCatalog>,
    providers: [LocalServiceProviderConfig],
    providerStatus: [LocalServiceProviderStatus] = [],
    providerBrowserSessions: [LocalServiceProviderBrowserSession],
    browserScanEnabled: [ProviderID],
    overview: [LocalServiceOverviewItem],
    cache: LocalServiceCacheState
  ) {
    self.ipcVersion = ipcVersion
    self.revision = revision
    self.usageUploadEnabled = usageUploadEnabled
    self.groupUsageByProject = groupUsageByProject
    self.quotaRefreshIntervalSeconds = quotaRefreshIntervalSeconds
    self.usagePeriods = usagePeriods
    self.quota = quota
    self.usage = usage
    self.account = account
    self.accountSettings = accountSettings
    self.historySync = historySync
    self.pricing = pricing
    self.providers = providers
    self.providerStatus = providerStatus
    self.providerBrowserSessions = providerBrowserSessions
    self.browserScanEnabled = browserScanEnabled
    self.overview = overview
    self.cache = cache
  }

  private enum CodingKeys: String, CodingKey {
    case ipcVersion
    case revision
    case usageUploadEnabled
    case groupUsageByProject
    case quotaRefreshIntervalSeconds
    case usagePeriods
    case quota
    case usage
    case account
    case accountSettings
    case historySync
    case pricing
    case providers
    case providerStatus
    case providerBrowserSessions
    case browserScanEnabled
    case overview
    case cache
  }

  var isValid: Bool {
    let overviewIDs = overview.map { item in
      "\(item.identity.provider.rawValue)|\(item.identity.fingerprint)|"
        + "\(item.identity.scope.rawValue)|\(item.identity.sourceID ?? "")"
    }
    guard ipcVersion == Self.supportedIPCVersion, revision >= 0,
      QuotaRefreshInterval(rawValue: quotaRefreshIntervalSeconds) != nil,
      providers.count <= ProviderID.allCases.count,
      Set(providers.map(\.provider)).count == providers.count,
      providers.allSatisfy({ config in
        config.provider.isConfigurable
          && (!config.configured || config.maskedAPIKey?.isEmpty == false)
      }),
      providerStatus.count <= ProviderID.allCases.count,
      Set(providerStatus.map(\.provider)).count == providerStatus.count,
      providerBrowserSessions.count <= 256,
      providerBrowserSessions.allSatisfy(\.isValid),
      browserScanEnabled.count <= ProviderID.allCases.count,
      Set(browserScanEnabled).count == browserScanEnabled.count,
      browserScanEnabled.allSatisfy({ $0.browserSession != nil }),
      overview.count <= 2_048,
      Set(overviewIDs).count == overviewIDs.count
    else { return false }

    return overview.allSatisfy { item in
      let sourceIDs = item.sources.map(\.sourceID)
      let selectedSource = item.sources.first { $0.sourceID == item.selectedSourceID }
      let automaticSource = item.sources.first { $0.sourceID == item.automaticSourceID }
      return item.identity.provider == item.snapshot.provider
        && item.identity.fingerprint == item.snapshot.account.fingerprint
        && !item.identity.fingerprint.isEmpty
        && !item.sources.isEmpty
        && item.sources.count <= 256
        && Set(sourceIDs).count == sourceIDs.count
        && sourceIDs.contains(item.selectedSourceID)
        && sourceIDs.contains(item.automaticSourceID)
        && selectedSource?.displayName == item.selectedSourceDisplayName
        && automaticSource?.displayName == item.automaticSourceDisplayName
        && (item.sourcePin == nil
          ? item.selectedSourceID == item.automaticSourceID
          : item.sourcePin == item.selectedSourceID && sourceIDs.contains(item.sourcePin ?? ""))
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
      "ipcVersion", "revision", "usageUploadEnabled", "groupUsageByProject",
      "quotaRefreshIntervalSeconds",
      "usagePeriods", "quota", "usage",
      "account", "accountSettings", "historySync", "pricing", "providers", "providerStatus",
      "providerBrowserSessions",
      "browserScanEnabled",
      "overview", "cache",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ipcVersion = try container.decode(Int.self, forKey: .ipcVersion)
    revision = try container.decode(Int.self, forKey: .revision)
    usageUploadEnabled = try container.decode(Bool.self, forKey: .usageUploadEnabled)
    groupUsageByProject = try container.decode(Bool.self, forKey: .groupUsageByProject)
    quotaRefreshIntervalSeconds = try container.decode(Int.self, forKey: .quotaRefreshIntervalSeconds)
    usagePeriods = try container.decode(LocalServiceUsagePeriodCache.self, forKey: .usagePeriods)
    quota = try container.decode(LocalServiceComponent<QuotaCollectionReport>.self, forKey: .quota)
    usage = try container.decode(LocalServiceComponent<LocalUsageReport>.self, forKey: .usage)
    account = try container.decode(
      LocalServiceComponent<LocalServiceAccountState>.self, forKey: .account)
    accountSettings = try container.decodeIfPresent(
      LocalServiceAccountSettingsState.self, forKey: .accountSettings)
    historySync = try container.decodeIfPresent(LocalServiceHistorySync.self, forKey: .historySync)
    pricing = try container.decode(LocalServiceComponent<PricingCatalog>.self, forKey: .pricing)
    providers = try container.decode([LocalServiceProviderConfig].self, forKey: .providers)
    providerStatus = try container.decode(
      [LocalServiceProviderStatus].self, forKey: .providerStatus)
    providerBrowserSessions = try container.decode(
      [LocalServiceProviderBrowserSession].self, forKey: .providerBrowserSessions)
    browserScanEnabled = try container.decode([ProviderID].self, forKey: .browserScanEnabled)
    overview = try container.decode([LocalServiceOverviewItem].self, forKey: .overview)
    cache = try container.decode(LocalServiceCacheState.self, forKey: .cache)
  }
}

/// The Account settings document as `get_state` and `refresh_account_settings` carry it.
struct LocalServiceAccountSettingsState: Decodable, Equatable, Sendable {
  let document: AccountSettingsDocument
  let revision: Int

  init(document: AccountSettingsDocument, revision: Int) {
    self.document = document
    self.revision = revision
  }

  /// The `If-Match` value a later write states: `"<revision>"`, including the quotes.
  var ifMatch: String { Self.ifMatch(revision) }

  static func ifMatch(_ revision: Int) -> String { "\"\(revision)\"" }
}

/// `get_state.history_sync`. Absent when signed out. The status line under the history switch.
struct LocalServiceHistorySync: Decodable, Equatable, Sendable {
  let enabled: Bool
  let lastUploadAt: Date?
  let lastError: String?

  /// The last error, or "Last uploaded …" in the shared freshness phrasing. Nil when neither
  /// has happened.
  func statusLine(now: Date = Date()) -> String? {
    if let lastError, !lastError.isEmpty { return Self.phrase(forError: lastError) }
    guard let lastUploadAt else { return nil }
    return "Last uploaded \(FreshnessCopy.age(since: lastUploadAt, now: now))"
  }

  /// The helper reports a code, not a sentence.
  static func phrase(forError code: String) -> String {
    switch code {
    case "network": return "Could not reach your Account."
    case "invalid_response": return "Your Account gave an unexpected answer."
    case "history_sync_off": return "Sharing is off for this Account."
    case "quota_history_full": return "Your Account holds as much history as it can."
    case "unauthorized", "session_expired": return "Sign in again to keep sharing."
    default: return "Sharing paused: \(code)."
    }
  }
}

extension LocalServiceHistorySync {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["enabled", "lastUploadAt", "lastError"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    lastUploadAt = try container.decodeIfPresent(Date.self, forKey: .lastUploadAt)
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case lastUploadAt
    case lastError
  }
}

/// What `set_account_settings` answers: the document Relay now holds, and whether this write
/// landed or must be re-applied onto it.
enum LocalServiceAccountSettingsWriteResult: Equatable, Sendable {
  case written(AccountSettingsDocument)
  case conflict(AccountSettingsDocument)

  var document: AccountSettingsDocument {
    switch self {
    case .written(let document), .conflict(let document): document
    }
  }
}

struct LocalServiceAccountSettingsMutationResult: Decodable, Sendable {
  let outcome: Outcome
  let document: AccountSettingsDocument
  let revision: Int

  enum Outcome: String, Decodable, Sendable {
    case written
    case conflict
  }

  var result: LocalServiceAccountSettingsWriteResult {
    switch outcome {
    case .written: .written(document)
    case .conflict: .conflict(document)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case outcome
    case document
    case revision
  }
}

extension LocalServiceAccountSettingsState {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["document", "revision"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    document = try decodeIPCAccountSettingsDocument(from: container, forKey: .document)
    revision = try container.decode(Int.self, forKey: .revision)
  }

  private enum CodingKeys: String, CodingKey {
    case document
    case revision
  }
}

extension LocalServiceAccountSettingsMutationResult {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["outcome", "document", "revision"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    outcome = try container.decode(Outcome.self, forKey: .outcome)
    document = try decodeIPCAccountSettingsDocument(from: container, forKey: .document)
    revision = try container.decode(Int.self, forKey: .revision)
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
  let authorizeURL: String?

  private enum CodingKeys: String, CodingKey {
    case status
    case accountID = "accountId"
    case deviceID = "deviceId"
    case deviceGeneration
    case authorizeURL = "authorizeUrl"
  }

}

extension LocalServiceLoginResult {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "status", "accountId", "deviceId", "deviceGeneration", "authorizeUrl",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(LocalServiceAuthStatus.self, forKey: .status)
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    deviceGeneration = try container.decodeIfPresent(Int.self, forKey: .deviceGeneration)
    authorizeURL = try container.decodeIfPresent(String.self, forKey: .authorizeURL)
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

struct LocalServiceGroupUsageByProjectSetting: Decodable, Sendable {
  let enabled: Bool

  private enum CodingKeys: String, CodingKey {
    case enabled
  }
}

extension LocalServiceGroupUsageByProjectSetting {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["enabled"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decode(Bool.self, forKey: .enabled)
  }
}

struct LocalServiceQuotaRefreshIntervalSetting: Decodable, Sendable {
  let intervalSeconds: Int

  private enum CodingKeys: String, CodingKey {
    case intervalSeconds
  }
}

struct LocalServiceOverviewSourcePinSetting: Decodable, Sendable {
  let identityKey: String
  let pin: String?

  init(identityKey: String, pin: String?) {
    self.identityKey = identityKey
    self.pin = pin
  }

  private enum CodingKeys: String, CodingKey {
    case identityKey
    case pin
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["identityKey", "pin"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identityKey = try container.decode(String.self, forKey: .identityKey)
    pin = try container.decodeIfPresent(String.self, forKey: .pin)
  }
}

/// Hour-grid bounds of a period, as `usage_period` passes them through from Relay or this Mac.
struct UsagePeriodBounds: Decodable, Equatable, Sendable {
  let start: String
  let end: String
  let grid: String

  init(start: String, end: String, grid: String) {
    self.start = start
    self.end = end
    self.grid = grid
  }

  private enum CodingKeys: String, CodingKey {
    case start
    case end
    case grid
  }
}

extension UsagePeriodBounds {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["start", "end", "grid"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    start = try container.decode(String.self, forKey: .start)
    end = try container.decode(String.self, forKey: .end)
    grid = try container.decode(String.self, forKey: .grid)
  }
}

/// Account period revision, as `usage_period` passes it through from Relay.
struct UsagePeriodRevision: Decodable, Equatable, Sendable {
  let usageRevision: Int
  let deviceGeneration: Int
  let accountUpdatedAt: String?
  let pricingRevision: String
  let modelCatalogRevision: String
  let foldVersion: Int

  init(
    usageRevision: Int,
    deviceGeneration: Int,
    accountUpdatedAt: String?,
    pricingRevision: String,
    modelCatalogRevision: String,
    foldVersion: Int
  ) {
    self.usageRevision = usageRevision
    self.deviceGeneration = deviceGeneration
    self.accountUpdatedAt = accountUpdatedAt
    self.pricingRevision = pricingRevision
    self.modelCatalogRevision = modelCatalogRevision
    self.foldVersion = foldVersion
  }

  private enum CodingKeys: String, CodingKey {
    case usageRevision
    case deviceGeneration
    case accountUpdatedAt
    case pricingRevision
    case modelCatalogRevision
    case foldVersion
  }
}

extension UsagePeriodRevision {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "usageRevision", "deviceGeneration", "accountUpdatedAt", "pricingRevision",
      "modelCatalogRevision", "foldVersion",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    usageRevision = try container.decode(Int.self, forKey: .usageRevision)
    deviceGeneration = try container.decode(Int.self, forKey: .deviceGeneration)
    accountUpdatedAt = try container.decode(String?.self, forKey: .accountUpdatedAt)
    pricingRevision = try container.decode(String.self, forKey: .pricingRevision)
    modelCatalogRevision = try container.decode(String.self, forKey: .modelCatalogRevision)
    foldVersion = try container.decode(Int.self, forKey: .foldVersion)
  }
}

/// How much of an Account period Relay still holds, as `usage_period` answers it.
struct LocalServiceUsageCoverage: Decodable, Equatable, Sendable {
  let partial: Bool
  let dailyRetainedFrom: String?
  let hourlyRetainedFrom: String?
  let truncatedByRetention: Bool

  init(
    partial: Bool,
    dailyRetainedFrom: String? = nil,
    hourlyRetainedFrom: String? = nil,
    truncatedByRetention: Bool
  ) {
    self.partial = partial
    self.dailyRetainedFrom = dailyRetainedFrom
    self.hourlyRetainedFrom = hourlyRetainedFrom
    self.truncatedByRetention = truncatedByRetention
  }

  private enum CodingKeys: String, CodingKey {
    case partial
    case dailyRetainedFrom
    case hourlyRetainedFrom
    case truncatedByRetention
  }
}

extension LocalServiceUsageCoverage {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "partial", "dailyRetainedFrom", "hourlyRetainedFrom", "truncatedByRetention",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    partial = try container.decode(Bool.self, forKey: .partial)
    dailyRetainedFrom = try container.decode(String?.self, forKey: .dailyRetainedFrom)
    hourlyRetainedFrom = try container.decode(String?.self, forKey: .hourlyRetainedFrom)
    truncatedByRetention = try container.decode(Bool.self, forKey: .truncatedByRetention)
  }
}

struct LocalServiceUsageDetail: Decodable, Equatable, Sendable {
  let range: UsageDateRange
  let usage: LocalUsagePeriodSummary
  let incomplete: Bool
  let detailsTruncated: Bool
  let coverage: LocalServiceUsageCoverage?
  let timezone: String?
  let bounds: UsagePeriodBounds?
  let revision: UsagePeriodRevision?

  init(
    range: UsageDateRange,
    usage: LocalUsagePeriodSummary,
    incomplete: Bool,
    detailsTruncated: Bool,
    coverage: LocalServiceUsageCoverage? = nil,
    timezone: String? = nil,
    bounds: UsagePeriodBounds? = nil,
    revision: UsagePeriodRevision? = nil
  ) {
    self.range = range
    self.usage = usage
    self.incomplete = incomplete
    self.detailsTruncated = detailsTruncated
    self.coverage = coverage
    self.timezone = timezone
    self.bounds = bounds
    self.revision = revision
  }

  private enum CodingKeys: String, CodingKey {
    case range
    case usage
    case incomplete
    case detailsTruncated
    case coverage
    case timezone
    case bounds
    case revision
  }

  var isValid: Bool {
    range.isValid && usage.isValid
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

/// This Mac's stored quota samples, as `quota_history` returns them.
///
/// Dashboard folds these with ``QuotaHistory``. The state push keeps the current-window slice
/// Overview already draws (ADR 0051). Samples are keyed by the local subscription selector,
/// so two accounts of one provider stay apart.
struct LocalServiceQuotaHistory: Decodable, Equatable, Sendable {
  let samplesBySubscription: [String: [String: [QuotaSample]]]
  let utcOffsetSeconds: Int

  init(
    samplesBySubscription: [String: [String: [QuotaSample]]] = [:],
    utcOffsetSeconds: Int = 0
  ) {
    self.samplesBySubscription = samplesBySubscription
    self.utcOffsetSeconds = utcOffsetSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case samplesBySubscription
    case utcOffsetSeconds
  }
}

extension LocalServiceQuotaHistory {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["samplesBySubscription", "utcOffsetSeconds"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    samplesBySubscription = try container.decode(
      [String: [String: [QuotaSample]]].self, forKey: .samplesBySubscription)
    utcOffsetSeconds = try container.decode(Int.self, forKey: .utcOffsetSeconds)
  }
}

extension LocalServiceUsageDetail {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "range", "usage", "incomplete", "detailsTruncated", "coverage", "timezone", "bounds",
      "revision",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    range = try container.decode(UsageDateRange.self, forKey: .range)
    usage = try container.decode(LocalUsagePeriodSummary.self, forKey: .usage)
    incomplete = try container.decode(Bool.self, forKey: .incomplete)
    detailsTruncated = try container.decode(Bool.self, forKey: .detailsTruncated)
    coverage = try container.decodeIfPresent(LocalServiceUsageCoverage.self, forKey: .coverage)
    timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
    bounds = try container.decodeIfPresent(UsagePeriodBounds.self, forKey: .bounds)
    revision = try container.decodeIfPresent(UsagePeriodRevision.self, forKey: .revision)
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

/// The IPC envelope is decoded with `convertFromSnakeCase`. The Account settings document's keys
/// are literal snake_case, so the nested object is captured and decoded with
/// `AccountSettingsDocument.decode` (a tolerant read). Unknown document keys are ignored.
private func decodeIPCAccountSettingsDocument<Key: CodingKey>(
  from container: KeyedDecodingContainer<Key>,
  forKey key: Key
) throws -> AccountSettingsDocument {
  let nested = try container.decode(IPCJSONValue.self, forKey: key)
  let data = try JSONSerialization.data(withJSONObject: nested.snakeCasedJSONObject())
  return try AccountSettingsDocument.decode(data)
}

/// Untyped JSON as the IPC decoder presents it, so a nested document can be re-encoded with the
/// snake_case keys `AccountSettingsDocument.decode` reads.
private enum IPCJSONValue: Decodable {
  case object([String: IPCJSONValue])
  case array([IPCJSONValue])
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let object = try? container.decode([String: IPCJSONValue].self) {
      self = .object(object)
    } else if let array = try? container.decode([IPCJSONValue].self) {
      self = .array(array)
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let int = try? container.decode(Int.self) {
      self = .int(int)
    } else if let double = try? container.decode(Double.self) {
      self = .double(double)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON in the Account settings document."
      )
    }
  }

  func snakeCasedJSONObject() -> Any {
    switch self {
    case .object(let object):
      Dictionary(
        uniqueKeysWithValues: object.map { key, value in
          (Self.convertToSnakeCase(key), value.snakeCasedJSONObject())
        }
      )
    case .array(let array):
      array.map { $0.snakeCasedJSONObject() }
    case .string(let value):
      value
    case .int(let value):
      value
    case .double(let value):
      value
    case .bool(let value):
      value
    case .null:
      NSNull()
    }
  }

  /// Matches `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase`.
  private static func convertToSnakeCase(_ stringKey: String) -> String {
    guard !stringKey.isEmpty else { return stringKey }
    var words: [Range<String.Index>] = []
    var wordStart = stringKey.startIndex
    var searchRange = stringKey.startIndex..<stringKey.endIndex
    while let upperCaseRange = stringKey.rangeOfCharacter(
      from: .uppercaseLetters, options: [], range: searchRange)
    {
      words.append(wordStart..<upperCaseRange.lowerBound)
      searchRange = upperCaseRange.lowerBound..<searchRange.upperBound
      guard
        let lowerCaseRange = stringKey.rangeOfCharacter(
          from: .lowercaseLetters, options: [], range: searchRange)
      else {
        wordStart = searchRange.lowerBound
        break
      }
      let nextAfterCapital = stringKey.index(after: upperCaseRange.lowerBound)
      if lowerCaseRange.lowerBound == nextAfterCapital {
        wordStart = upperCaseRange.lowerBound
      } else {
        let beforeLower = stringKey.index(before: lowerCaseRange.lowerBound)
        words.append(upperCaseRange.lowerBound..<beforeLower)
        wordStart = beforeLower
      }
      searchRange = lowerCaseRange.upperBound..<searchRange.upperBound
    }
    words.append(wordStart..<stringKey.endIndex)
    return words.map { stringKey[$0].lowercased() }.filter { !$0.isEmpty }.joined(separator: "_")
  }
}
