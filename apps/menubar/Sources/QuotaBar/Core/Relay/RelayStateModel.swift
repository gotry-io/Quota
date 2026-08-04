import Foundation
import Observation

protocol RelayOwnerClientServing: Sendable {
  func discover(baseURL: URL) async throws -> RelayInfo
  func registerOwner(baseURL: URL) async throws -> OwnerRegistrationResponse
  func approvePairing(
    userCode: String,
    profile: RelayProfile,
    ownerBearer: String
  ) async throws
  func denyPairing(
    userCode: String,
    profile: RelayProfile,
    ownerBearer: String
  ) async throws
  func fetchLatestSnapshots(
    profile: RelayProfile,
    ownerBearer: String
  ) async throws -> OwnerSnapshotListResponse
  func listDevices(
    profile: RelayProfile,
    ownerBearer: String
  ) async throws -> DeviceListResponse
  func revokeDevice(
    deviceID: String,
    profile: RelayProfile,
    ownerBearer: String
  ) async throws
  func deleteOwner(
    profile: RelayProfile,
    ownerBearer: String
  ) async throws
}

extension RelayClient: RelayOwnerClientServing {}

@MainActor
protocol RelayProfilePersisting {
  func load() throws -> [RelayProfile]
  func save(_ profiles: [RelayProfile]) throws
}

extension RelayProfileStore: RelayProfilePersisting {}

protocol RelayOwnerCredentialPersisting: Sendable {
  func save(_ ownerBearer: String, reference: String) throws
  func load(reference: String) throws -> String
  func delete(reference: String) throws
  func reconcile(retaining references: Set<String>) throws
  func deleteAll() throws
}

extension RelayOwnerCredentialStore: RelayOwnerCredentialPersisting {}

@MainActor
protocol QuotaBarDefaultsResetting {
  func deleteAll()
}

@MainActor
struct QuotaBarDefaultsResetter: QuotaBarDefaultsResetting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func deleteAll() {
    for key in Self.keys {
      defaults.removeObject(forKey: key)
    }
  }

  private static let keys = [
    RelayProfileStore.storageKey,
    LocalQuotaReportCache.storageKey,
    "provider.codex.visible",
    "provider.claude.visible",
    "provider.grok.visible",
  ]
}

/// Official managed Relay endpoint. Used as the Pair Device default; never a user credential.
struct OfficialRelayEndpoint: Equatable, Sendable {
  let displayName: String
  let baseURL: URL

  static let production = OfficialRelayEndpoint(
    displayName: "Quota Relay",
    baseURL: URL(string: "https://quota.gotry.io")!
  )
}

/// Device owned by this QuotaBar, aggregated across internal endpoint records.
struct OwnedRemoteDevice: Equatable, Identifiable, Sendable {
  let profileID: UUID
  let device: RelayDevice
  let endpointLabel: String

  var id: String { "\(profileID.uuidString):\(device.deviceID)" }
}

enum RelayStateIssueCategory: String, Equatable, Sendable {
  case configuration
  case unsupported
  case credentialMissing = "credential_missing"
  case authentication
  case authorization
  case unavailable
  case malformedData = "malformed_data"
  case persistence
}

struct RelayStateIssue: Equatable, Sendable {
  let category: RelayStateIssueCategory
  let message: String
}

struct RelayStateModelError: LocalizedError, Equatable, Sendable {
  let issue: RelayStateIssue

  var errorDescription: String? { issue.message }
}

struct RelayProfileState: Equatable, Sendable {
  var observations: [OwnerSnapshotObservation] = []
  var devices: [RelayDevice] = []
  var lastSuccessfulRefreshAt: Date?
  var isRefreshing = false
  var refreshIssue: RelayStateIssue?
  var operationIssue: RelayStateIssue?

  var issue: RelayStateIssue? {
    operationIssue ?? refreshIssue
  }

  var isStale: Bool {
    lastSuccessfulRefreshAt != nil && refreshIssue != nil
  }
}

@MainActor
@Observable
final class RelayStateModel {
  private(set) var profiles: [RelayProfile]
  private(set) var profileStates: [UUID: RelayProfileState]
  private(set) var globalIssue: RelayStateIssue?
  private(set) var isPolling = false

  @ObservationIgnored
  private let client: any RelayOwnerClientServing

  @ObservationIgnored
  private let profileStore: any RelayProfilePersisting

  @ObservationIgnored
  private let credentialStore: any RelayOwnerCredentialPersisting

  @ObservationIgnored
  private let defaultsResetter: any QuotaBarDefaultsResetting

  @ObservationIgnored
  private let officialRelay: OfficialRelayEndpoint?

  @ObservationIgnored
  private let pollInterval: Duration

  @ObservationIgnored
  private let sleep: @Sendable (Duration) async throws -> Void

  @ObservationIgnored
  private let now: () -> Date

  @ObservationIgnored
  private let makeProfileID: () -> UUID

  @ObservationIgnored
  private var pollingTask: Task<Void, Never>?

  @ObservationIgnored
  private var pollingGeneration = 0

  @ObservationIgnored
  private var ensuringEndpointURLs = Set<String>()

  /// Per-profile refresh chain so concurrent callers await and then run a fresh pass
  /// instead of silently dropping the later request (e.g. post-pair vs background poll).
  @ObservationIgnored
  private var profileRefreshTail: [UUID: Task<Void, Never>] = [:]

  init(
    client: any RelayOwnerClientServing = RelayClient(),
    profileStore: any RelayProfilePersisting = RelayProfileStore(),
    credentialStore: any RelayOwnerCredentialPersisting = RelayOwnerCredentialStore(),
    defaultsResetter: any QuotaBarDefaultsResetting = QuotaBarDefaultsResetter(),
    officialRelay: OfficialRelayEndpoint? = .production,
    pollInterval: Duration = .seconds(300),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    },
    now: @escaping () -> Date = Date.init,
    makeProfileID: @escaping () -> UUID = UUID.init
  ) {
    self.client = client
    self.profileStore = profileStore
    self.credentialStore = credentialStore
    self.defaultsResetter = defaultsResetter
    self.officialRelay = officialRelay
    self.pollInterval = pollInterval
    self.sleep = sleep
    self.now = now
    self.makeProfileID = makeProfileID

    do {
      let loadedProfiles = try profileStore.load()
      profiles = loadedProfiles
      profileStates = Dictionary(
        uniqueKeysWithValues: loadedProfiles.map { ($0.id, RelayProfileState()) }
      )
      do {
        try credentialStore.reconcile(
          retaining: Set(loadedProfiles.map(\.credentialReference))
        )
        globalIssue = nil
      } catch {
        globalIssue = Self.issue(for: error)
      }
    } catch {
      profiles = []
      profileStates = [:]
      globalIssue = Self.issue(for: error)
    }
  }

  deinit {
    pollingTask?.cancel()
  }

  static func live() -> RelayStateModel {
    RelayStateModel()
  }

  func state(for profileID: UUID) -> RelayProfileState? {
    profileStates[profileID]
  }

  /// Active devices this QuotaBar owns across all internal endpoint records.
  var ownedDevices: [OwnedRemoteDevice] {
    var owned: [OwnedRemoteDevice] = []
    for profile in profiles {
      let devices = profileStates[profile.id]?.devices ?? []
      for device in devices where device.revokedAt == nil {
        owned.append(
          OwnedRemoteDevice(
            profileID: profile.id,
            device: device,
            endpointLabel: profile.baseURL.absoluteString
          )
        )
      }
    }
    owned.sort { left, right in
      left.device.displayName.localizedStandardCompare(right.device.displayName)
        == .orderedAscending
    }
    return owned
  }

  var remoteDeviceSummary: String {
    let count = ownedDevices.count
    if count == 0 { return "No devices" }
    if count == 1 { return "1 device" }
    return "\(count) devices"
  }

  var showsEndpointLabelOnDevices: Bool {
    Set(ownedDevices.map(\.profileID)).count > 1
  }

  var knownEndpointURLs: [URL] {
    var seen = Set<String>()
    var urls: [URL] = []
    if let official = officialRelay?.baseURL {
      seen.insert(official.absoluteString)
      urls.append(official)
    }
    for profile in profiles {
      let key = profile.baseURL.absoluteString
      if seen.insert(key).inserted {
        urls.append(profile.baseURL)
      }
    }
    return urls
  }

  var officialRelayBaseURL: URL? {
    officialRelay?.baseURL
  }

  /// Ensures this QuotaBar has a private owner capability for the Relay at `origin`.
  /// Reuses an existing endpoint record for the same canonical base URL.
  @discardableResult
  func ensureEndpoint(origin: String) async throws -> RelayProfile {
    let canonicalURL: URL
    do {
      canonicalURL = try RelayOrigin.canonicalURL(from: origin)
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    let urlKey = canonicalURL.absoluteString
    guard !ensuringEndpointURLs.contains(urlKey) else {
      throw Self.modelError(
        category: .unavailable,
        message: "QuotaBar is already preparing this Relay endpoint."
      )
    }
    ensuringEndpointURLs.insert(urlKey)
    defer { ensuringEndpointURLs.remove(urlKey) }

    if let existingIndex = profiles.firstIndex(where: { $0.baseURL == canonicalURL }) {
      let existing = profiles[existingIndex]
      do {
        let ownerBearer = try credentialStore.load(
          reference: existing.credentialReference
        )
        let devices = try await client.listDevices(
          profile: existing,
          ownerBearer: ownerBearer
        )
        try Task.checkCancellation()
        updateState(for: existing.id) { state in
          state.devices = devices.devices
          state.operationIssue = nil
        }
        globalIssue = nil
        return existing
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard Self.requiresOwnerReenrollment(after: error) else {
          let issue = Self.issue(for: error)
          globalIssue = issue
          throw RelayStateModelError(issue: issue)
        }

        // Pair Device is an explicit enrollment action. If the local owner credential or remote
        // ephemeral owner has expired, discard only the unusable local endpoint record and create
        // a new isolated owner below. The inaccessible remote group remains bounded by Relay GC.
        try deleteLocalProfile(at: existingIndex)
      }
    }

    let relayInfo: RelayInfo
    do {
      relayInfo = try await client.discover(baseURL: canonicalURL)
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    guard relayInfo.capabilities.multiTenant,
      relayInfo.capabilities.persistentSnapshots,
      relayInfo.capabilities.instantDeviceRevocation
    else {
      let error = Self.modelError(
        category: .unsupported,
        message: "This Relay does not support isolated remote devices."
      )
      globalIssue = error.issue
      throw error
    }

    let registration: OwnerRegistrationResponse
    do {
      registration = try await client.registerOwner(baseURL: canonicalURL)
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    let profile: RelayProfile
    do {
      profile = try RelayProfile(
        id: makeProfileID(),
        name: Self.displayName(for: canonicalURL, official: officialRelay),
        baseURL: canonicalURL,
        instanceID: relayInfo.instanceID,
        mode: relayInfo.mode,
        capabilities: relayInfo.capabilities
      )
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    do {
      try credentialStore.save(
        registration.ownerToken,
        reference: profile.credentialReference
      )
      try profileStore.save(profiles + [profile])
    } catch {
      let persistenceError = error
      do {
        try await client.deleteOwner(
          profile: profile,
          ownerBearer: registration.ownerToken
        )
        try credentialStore.delete(reference: profile.credentialReference)
      } catch {
        let rollbackError = Self.modelError(
          category: .persistence,
          message: "QuotaBar could not roll back the Relay endpoint after local persistence failed."
        )
        globalIssue = rollbackError.issue
        throw rollbackError
      }
      let issue = Self.issue(for: persistenceError)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    profiles.append(profile)
    profileStates[profile.id] = RelayProfileState()
    globalIssue = nil
    return profile
  }

  func deleteProfile(_ profileID: UUID) async throws {
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    let profile = profiles[index]

    do {
      try await deleteRemoteOwner(for: profile)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: profileID)
      throw RelayStateModelError(issue: issue)
    }

    try deleteLocalProfile(at: index)
  }

  func deleteProfileLocally(_ profileID: UUID) throws {
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    try deleteLocalProfile(at: index)
  }

  func deleteAllQuotaBarData() async throws {
    do {
      for profile in profiles {
        try Task.checkCancellation()
        try await deleteRemoteOwner(for: profile)
      }
      try deleteAllLocalData()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }
  }

  func deleteAllQuotaBarDataLocally() throws {
    do {
      try deleteAllLocalData()
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }
  }

  func approvePairing(profileID: UUID, userCode: String) async throws {
    try await decidePairing(profileID: profileID, userCode: userCode, approve: true)
  }

  func denyPairing(profileID: UUID, userCode: String) async throws {
    try await decidePairing(profileID: profileID, userCode: userCode, approve: false)
  }

  func refreshProfile(_ profileID: UUID) async {
    guard profiles.contains(where: { $0.id == profileID }) else { return }

    let previous = profileRefreshTail[profileID]
    let task = Task { @MainActor in
      await previous?.value
      guard !Task.isCancelled else { return }
      await self.executeRefreshProfile(profileID)
    }
    profileRefreshTail[profileID] = task
    await task.value
    if profileRefreshTail[profileID] == task {
      profileRefreshTail[profileID] = nil
    }
  }

  func refreshAllProfiles() async {
    for profileID in profiles.map(\.id) {
      guard !Task.isCancelled else { return }
      await refreshProfile(profileID)
    }
  }

  /// Waits until QuotaCLI consumes the approved session and a new device appears.
  /// Approval alone is not success. Uses injected `sleep` so tests need no wall clock.
  @discardableResult
  func waitForJoinedDevice(
    profileID: UUID,
    excludingDeviceIDs: Set<String> = [],
    timeout: Duration = .seconds(30),
    interval: Duration = .seconds(1)
  ) async throws -> RelayDevice {
    guard profiles.contains(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }

    var elapsed: Duration = .zero
    while !Task.isCancelled {
      await refreshProfile(profileID)
      if let joined = profileStates[profileID]?.devices.first(where: {
        $0.revokedAt == nil && !excludingDeviceIDs.contains($0.deviceID)
      }) {
        return joined
      }
      if elapsed >= timeout { break }

      let sleepFor = min(interval, timeout - elapsed)
      guard sleepFor > .zero else { break }
      do {
        try await sleep(sleepFor)
      } catch {
        throw CancellationError()
      }
      elapsed += sleepFor
    }

    if Task.isCancelled { throw CancellationError() }
    throw Self.modelError(
      category: .unavailable,
      message:
        "The device did not finish joining. Keep QuotaCLI running, then enter a new pairing code."
    )
  }

  private func executeRefreshProfile(_ profileID: UUID) async {
    guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
    updateState(for: profileID) { $0.isRefreshing = true }
    defer { updateState(for: profileID) { $0.isRefreshing = false } }

    do {
      let ownerBearer = try credentialStore.load(reference: profile.credentialReference)
      let observations = try await client.fetchLatestSnapshots(
        profile: profile,
        ownerBearer: ownerBearer
      )
      try Task.checkCancellation()
      let devices = try await client.listDevices(
        profile: profile,
        ownerBearer: ownerBearer
      )
      try Task.checkCancellation()
      updateState(for: profileID) { state in
        state.observations = observations.observations
        state.devices = devices.devices
        state.lastSuccessfulRefreshAt = now()
        state.refreshIssue = nil
      }
    } catch is CancellationError {
      return
    } catch {
      setRefreshIssue(Self.issue(for: error), for: profileID)
    }
  }

  func revokeDevice(profileID: UUID, deviceID: String) async throws {
    guard let profile = profiles.first(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    do {
      let ownerBearer = try credentialStore.load(reference: profile.credentialReference)
      try await client.revokeDevice(
        deviceID: deviceID,
        profile: profile,
        ownerBearer: ownerBearer
      )
      try Task.checkCancellation()
      let devices = try await client.listDevices(
        profile: profile,
        ownerBearer: ownerBearer
      )
      try Task.checkCancellation()
      updateState(for: profileID) { state in
        state.devices = devices.devices
        state.operationIssue = nil
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: profileID)
      throw RelayStateModelError(issue: issue)
    }
  }

  func startPolling() {
    guard pollingTask == nil else { return }
    pollingGeneration += 1
    let generation = pollingGeneration
    let interval = pollInterval
    let sleep = sleep
    isPolling = true
    pollingTask = Task { @MainActor [weak self] in
      await self?.runPollingCycle()
      while !Task.isCancelled {
        do {
          try await sleep(interval)
        } catch {
          break
        }
        guard !Task.isCancelled else { break }
        await self?.runPollingCycle()
      }
      self?.pollingDidFinish(generation: generation)
    }
  }

  func stopPolling() {
    pollingTask?.cancel()
    pollingTask = nil
    isPolling = false
  }

  private func decidePairing(
    profileID: UUID,
    userCode: String,
    approve: Bool
  ) async throws {
    guard let profile = profiles.first(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    do {
      let ownerBearer = try credentialStore.load(reference: profile.credentialReference)
      if approve {
        try await client.approvePairing(
          userCode: userCode,
          profile: profile,
          ownerBearer: ownerBearer
        )
      } else {
        try await client.denyPairing(
          userCode: userCode,
          profile: profile,
          ownerBearer: ownerBearer
        )
      }
      updateState(for: profileID) { $0.operationIssue = nil }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: profileID)
      throw RelayStateModelError(issue: issue)
    }
  }

  private func runPollingCycle() async {
    await refreshAllProfiles()
  }

  private func deleteAllLocalData() throws {
    try credentialStore.deleteAll()
    defaultsResetter.deleteAll()
    stopPolling()
    profiles = []
    profileStates = [:]
    globalIssue = nil
  }

  private func deleteRemoteOwner(for profile: RelayProfile) async throws {
    let ownerBearer = try credentialStore.load(reference: profile.credentialReference)
    try await client.deleteOwner(
      profile: profile,
      ownerBearer: ownerBearer
    )
  }

  private func deleteLocalProfile(at index: Int) throws {
    let profile = profiles[index]
    var remainingProfiles = profiles
    remainingProfiles.remove(at: index)
    do {
      try profileStore.save(remainingProfiles)
      try credentialStore.delete(reference: profile.credentialReference)
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: profile.id)
      throw RelayStateModelError(issue: issue)
    }

    profiles = remainingProfiles
    profileStates[profile.id] = nil
  }

  private static func displayName(for url: URL, official: OfficialRelayEndpoint?) -> String {
    if let official, url == official.baseURL {
      return official.displayName
    }
    return url.host() ?? url.absoluteString
  }

  private static func requiresOwnerReenrollment(after error: Error) -> Bool {
    if let credentialError = error as? RelayOwnerCredentialStoreError {
      switch credentialError {
      case .invalidCredential, .missingCredential, .corruptCredential:
        return true
      case .couldNotRead, .couldNotStore, .couldNotDelete:
        return false
      }
    }
    if let clientError = error as? RelayClientError {
      switch clientError {
      case .credentialRejected, .permissionDenied, .instanceMismatch:
        return true
      default:
        return false
      }
    }
    return false
  }

  private func updateState(
    for profileID: UUID,
    update: (inout RelayProfileState) -> Void
  ) {
    guard var state = profileStates[profileID] else { return }
    update(&state)
    profileStates[profileID] = state
  }

  private func setRefreshIssue(_ issue: RelayStateIssue, for profileID: UUID) {
    updateState(for: profileID) { $0.refreshIssue = issue }
  }

  private func setOperationIssue(_ issue: RelayStateIssue, for profileID: UUID) {
    updateState(for: profileID) { $0.operationIssue = issue }
  }

  private func pollingDidFinish(generation: Int) {
    guard generation == pollingGeneration else { return }
    pollingTask = nil
    isPolling = false
  }

  private static let profileNotFoundError = modelError(
    category: .configuration,
    message: "The Relay endpoint was not found."
  )

  private static func modelError(
    category: RelayStateIssueCategory,
    message: String
  ) -> RelayStateModelError {
    RelayStateModelError(issue: RelayStateIssue(category: category, message: message))
  }

  private static func issue(for error: Error) -> RelayStateIssue {
    if let relayError = error as? RelayClientError {
      let category: RelayStateIssueCategory = switch relayError.category {
      case .configuration: .configuration
      case .unsupported: .unsupported
      case .authentication: .authentication
      case .authorization: .authorization
      case .unavailable: .unavailable
      case .malformedData: .malformedData
      }
      return RelayStateIssue(
        category: category,
        message: relayError.errorDescription ?? "QuotaBar could not complete the Relay request."
      )
    }
    if let credentialError = error as? RelayOwnerCredentialStoreError {
      let category: RelayStateIssueCategory = switch credentialError {
      case .missingCredential: .credentialMissing
      case .invalidCredential, .corruptCredential: .authentication
      case .couldNotRead, .couldNotStore, .couldNotDelete: .persistence
      }
      return RelayStateIssue(
        category: category,
        message: credentialError.errorDescription ?? "QuotaBar could not use its private Relay access."
      )
    }
    if let profileError = error as? RelayProfileStoreError {
      return RelayStateIssue(
        category: .persistence,
        message: profileError.errorDescription ?? "QuotaBar could not access its saved Relay endpoints."
      )
    }
    if let originError = error as? RelayOriginError {
      return RelayStateIssue(
        category: .configuration,
        message: originError.errorDescription ?? "The Relay address is invalid."
      )
    }
    if let profileError = error as? RelayProfileError {
      return RelayStateIssue(
        category: .configuration,
        message: profileError.errorDescription ?? "The Relay endpoint is invalid."
      )
    }
    return RelayStateIssue(
      category: .unavailable,
      message: "QuotaBar could not complete the Relay operation."
    )
  }
}

#if DEBUG
  extension RelayStateModel {
    static func visualFixture(
      profiles: [RelayProfile],
      profileStates: [UUID: RelayProfileState]
    ) -> RelayStateModel {
      let model = RelayStateModel(
        client: VisualFixtureRelayClient(),
        profileStore: VisualFixtureRelayProfileStore(profiles: profiles),
        credentialStore: VisualFixtureRelayCredentialStore(),
        defaultsResetter: VisualFixtureDefaultsResetter(),
        officialRelay: nil
      )
      model.profileStates = profileStates
      return model
    }
  }

  private struct VisualFixtureRelayClient: RelayOwnerClientServing {
    func discover(baseURL: URL) async throws -> RelayInfo { throw RelayClientError.unavailable }

    func registerOwner(baseURL: URL) async throws -> OwnerRegistrationResponse {
      throw RelayClientError.unavailable
    }

    func approvePairing(
      userCode: String,
      profile: RelayProfile,
      ownerBearer: String
    ) async throws {
      throw RelayClientError.unavailable
    }

    func denyPairing(
      userCode: String,
      profile: RelayProfile,
      ownerBearer: String
    ) async throws {
      throw RelayClientError.unavailable
    }

    func fetchLatestSnapshots(
      profile: RelayProfile,
      ownerBearer: String
    ) async throws -> OwnerSnapshotListResponse {
      throw RelayClientError.unavailable
    }

    func listDevices(
      profile: RelayProfile,
      ownerBearer: String
    ) async throws -> DeviceListResponse {
      throw RelayClientError.unavailable
    }

    func revokeDevice(
      deviceID: String,
      profile: RelayProfile,
      ownerBearer: String
    ) async throws {
      throw RelayClientError.unavailable
    }

    func deleteOwner(
      profile: RelayProfile,
      ownerBearer: String
    ) async throws {
      throw RelayClientError.unavailable
    }
  }

  @MainActor
  private struct VisualFixtureRelayProfileStore: RelayProfilePersisting {
    let profiles: [RelayProfile]

    func load() throws -> [RelayProfile] { profiles }
    func save(_ profiles: [RelayProfile]) throws { throw RelayProfileStoreError.couldNotSave }
  }

  private struct VisualFixtureRelayCredentialStore: RelayOwnerCredentialPersisting {
    func save(_ ownerBearer: String, reference: String) throws {
      throw RelayOwnerCredentialStoreError.couldNotStore
    }

    func load(reference: String) throws -> String {
      throw RelayOwnerCredentialStoreError.missingCredential
    }

    func delete(reference: String) throws {
      throw RelayOwnerCredentialStoreError.couldNotDelete
    }

    func reconcile(retaining references: Set<String>) throws {}

    func deleteAll() throws {
      throw RelayOwnerCredentialStoreError.couldNotDelete
    }
  }

  @MainActor
  private struct VisualFixtureDefaultsResetter: QuotaBarDefaultsResetting {
    func deleteAll() {}
  }
#endif
