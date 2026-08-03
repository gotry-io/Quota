import Foundation
import Observation

protocol RelayControllerClientServing: Sendable {
  func discover(baseURL: URL) async throws -> RelayInfo
  func registerController(baseURL: URL) async throws -> ControllerRegistrationResponse
  func approvePairing(
    userCode: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws
  func denyPairing(
    userCode: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws
  func fetchLatestSnapshots(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws -> ControllerSnapshotListResponse
  func listDevices(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws -> DeviceListResponse
  func revokeDevice(
    deviceID: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws
  func deleteController(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws
}

extension RelayClient: RelayControllerClientServing {}

@MainActor
protocol RelayProfilePersisting {
  func load() throws -> [RelayProfile]
  func save(_ profiles: [RelayProfile]) throws
}

extension RelayProfileStore: RelayProfilePersisting {}

protocol RelayControllerCredentialPersisting: Sendable {
  func save(_ controllerBearer: String, reference: String) throws
  func load(reference: String) throws -> String
  func delete(reference: String) throws
  func reconcile(retaining references: Set<String>) throws
  func deleteAll() throws
}

extension RelayControllerCredentialStore: RelayControllerCredentialPersisting {}

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

@MainActor
protocol ManagedRelayEnrollmentPersisting {
  var isDisabled: Bool { get }
  func setDisabled(_ disabled: Bool)
}

@MainActor
struct ManagedRelayEnrollmentStore: ManagedRelayEnrollmentPersisting {
  static let storageKey = "relay.managedEnrollmentDisabled"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isDisabled: Bool {
    defaults.bool(forKey: Self.storageKey)
  }

  func setDisabled(_ disabled: Bool) {
    defaults.set(disabled, forKey: Self.storageKey)
  }
}

@MainActor
final class EphemeralManagedRelayEnrollmentStore: ManagedRelayEnrollmentPersisting {
  private(set) var isDisabled = false

  func setDisabled(_ disabled: Bool) {
    isDisabled = disabled
  }
}

struct ManagedRelayConfiguration: Equatable, Sendable {
  let name: String
  let baseURL: URL

  static let production = ManagedRelayConfiguration(
    name: "Quota Relay",
    baseURL: URL(string: "https://quota.gotry.io")!
  )
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
  var observations: [ControllerSnapshotObservation] = []
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
  private(set) var managedEnrollmentDisabled: Bool

  @ObservationIgnored
  private let client: any RelayControllerClientServing

  @ObservationIgnored
  private let profileStore: any RelayProfilePersisting

  @ObservationIgnored
  private let credentialStore: any RelayControllerCredentialPersisting

  @ObservationIgnored
  private let defaultsResetter: any QuotaBarDefaultsResetting

  @ObservationIgnored
  private let managedEnrollmentStore: any ManagedRelayEnrollmentPersisting

  @ObservationIgnored
  private let managedRelayConfiguration: ManagedRelayConfiguration?

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
  private var isRegisteringManagedProfile = false

  init(
    client: any RelayControllerClientServing = RelayClient(),
    profileStore: any RelayProfilePersisting = RelayProfileStore(),
    credentialStore: any RelayControllerCredentialPersisting = RelayControllerCredentialStore(),
    defaultsResetter: any QuotaBarDefaultsResetting = QuotaBarDefaultsResetter(),
    managedEnrollmentStore: any ManagedRelayEnrollmentPersisting = EphemeralManagedRelayEnrollmentStore(),
    managedRelayConfiguration: ManagedRelayConfiguration? = .production,
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
    self.managedEnrollmentStore = managedEnrollmentStore
    managedEnrollmentDisabled = managedEnrollmentStore.isDisabled
    self.managedRelayConfiguration = managedRelayConfiguration
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
    RelayStateModel(managedEnrollmentStore: ManagedRelayEnrollmentStore())
  }

  func state(for profileID: UUID) -> RelayProfileState? {
    profileStates[profileID]
  }

  @discardableResult
  func addSelfHostedProfile(
    name: String,
    origin: String,
    controllerBearer: String
  ) async throws -> RelayProfile {
    let canonicalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonicalName.isEmpty else {
      throw Self.modelError(
        category: .configuration,
        message: "Enter a Relay profile name."
      )
    }

    let canonicalURL: URL
    do {
      canonicalURL = try RelayOrigin.canonicalURL(from: origin)
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    let relayInfo: RelayInfo
    do {
      relayInfo = try await client.discover(baseURL: canonicalURL)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }
    guard relayInfo.mode == .selfHosted else {
      let error = Self.modelError(
        category: .unsupported,
        message: "Only self-hosted Relays can be added with a controller bearer."
      )
      globalIssue = error.issue
      throw error
    }

    let profile: RelayProfile
    do {
      profile = try RelayProfile(
        id: makeProfileID(),
        name: canonicalName,
        baseURL: canonicalURL,
        instanceID: relayInfo.instanceID,
        mode: relayInfo.mode,
        capabilities: relayInfo.capabilities,
        isDefault: profiles.isEmpty
      )
      try credentialStore.save(controllerBearer, reference: profile.credentialReference)
    } catch {
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    do {
      try profileStore.save(profiles + [profile])
    } catch {
      do {
        try credentialStore.delete(reference: profile.credentialReference)
      } catch {
        let rollbackError = Self.modelError(
          category: .persistence,
          message: "QuotaBar could not remove the Relay controller credential after profile storage failed."
        )
        globalIssue = rollbackError.issue
        throw rollbackError
      }
      let issue = Self.issue(for: error)
      globalIssue = issue
      throw RelayStateModelError(issue: issue)
    }

    profiles.append(profile)
    profileStates[profile.id] = RelayProfileState()
    globalIssue = nil
    return profile
  }

  /// Replaces the Keychain controller bearer for an existing self-hosted profile.
  func updateControllerCredential(profileID: UUID, controllerBearer: String) throws {
    guard let profile = profiles.first(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    guard profile.mode == .selfHosted else {
      throw Self.modelError(
        category: .unsupported,
        message: "Only self-hosted Relays store a controller bearer."
      )
    }
    guard !controllerBearer.isEmpty,
      controllerBearer == controllerBearer.trimmingCharacters(in: .whitespacesAndNewlines),
      controllerBearer.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
    else {
      throw Self.modelError(
        category: .configuration,
        message: "Enter a valid Relay controller credential."
      )
    }
    do {
      try credentialStore.save(controllerBearer, reference: profile.credentialReference)
      if var state = profileStates[profileID] {
        state.operationIssue = nil
        profileStates[profileID] = state
      }
      globalIssue = nil
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: profileID)
      throw RelayStateModelError(issue: issue)
    }
  }

  func ensureManagedControllerProfile() async {
    guard let configuration = managedRelayConfiguration,
      !managedEnrollmentDisabled,
      !profiles.contains(where: { $0.mode == .managed }),
      !isRegisteringManagedProfile
    else {
      return
    }

    isRegisteringManagedProfile = true
    defer { isRegisteringManagedProfile = false }

    do {
      let relayInfo = try await client.discover(baseURL: configuration.baseURL)
      try Task.checkCancellation()
      guard relayInfo.mode == .managed, relayInfo.capabilities.multiTenant else {
        throw RelayClientError.unsupportedRelay
      }

      let registration = try await client.registerController(baseURL: configuration.baseURL)
      let profile = try RelayProfile(
        id: makeProfileID(),
        name: configuration.name,
        baseURL: configuration.baseURL,
        instanceID: relayInfo.instanceID,
        mode: relayInfo.mode,
        capabilities: relayInfo.capabilities,
        isDefault: profiles.isEmpty
      )

      do {
        try credentialStore.save(
          registration.controllerToken,
          reference: profile.credentialReference
        )
        try profileStore.save(profiles + [profile])
      } catch {
        let persistenceError = error
        do {
          try await client.deleteController(
            profile: profile,
            controllerBearer: registration.controllerToken
          )
          try credentialStore.delete(reference: profile.credentialReference)
        } catch {
          throw Self.modelError(
            category: .persistence,
            message: "QuotaBar could not roll back the managed Relay after local persistence failed."
          )
        }
        throw persistenceError
      }

      profiles.append(profile)
      profileStates[profile.id] = RelayProfileState()
      globalIssue = nil
    } catch is CancellationError {
    } catch {
      globalIssue = Self.issue(for: error)
    }
  }

  func enableManagedControllerProfile() async {
    managedEnrollmentStore.setDisabled(false)
    managedEnrollmentDisabled = false
    await ensureManagedControllerProfile()
    if let profileID = profiles.first(where: { $0.mode == .managed })?.id {
      await refreshProfile(profileID)
    }
  }

  func deleteProfile(_ profileID: UUID) async throws {
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    let profile = profiles[index]

    if profile.mode == .managed {
      do {
        try await deleteManagedController(for: profile)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let issue = Self.issue(for: error)
        setOperationIssue(issue, for: profileID)
        throw RelayStateModelError(issue: issue)
      }
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
      for profile in profiles where profile.mode == .managed {
        try Task.checkCancellation()
        try await deleteManagedController(for: profile)
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

  func setDefaultProfile(_ profileID: UUID) throws {
    guard profiles.contains(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    var updatedProfiles = profiles
    for index in updatedProfiles.indices {
      updatedProfiles[index].isDefault = updatedProfiles[index].id == profileID
    }
    try saveProfileMutation(updatedProfiles, affectedProfileID: profileID)
  }

  func renameProfile(_ profileID: UUID, to name: String) throws {
    let canonicalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonicalName.isEmpty else {
      throw Self.modelError(
        category: .configuration,
        message: "Enter a Relay profile name."
      )
    }
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    var updatedProfiles = profiles
    updatedProfiles[index].name = canonicalName
    try saveProfileMutation(updatedProfiles, affectedProfileID: profileID)
  }

  func approvePairing(profileID: UUID, userCode: String) async throws {
    try await decidePairing(profileID: profileID, userCode: userCode, approve: true)
  }

  func denyPairing(profileID: UUID, userCode: String) async throws {
    try await decidePairing(profileID: profileID, userCode: userCode, approve: false)
  }

  func refreshProfile(_ profileID: UUID) async {
    guard let profile = profiles.first(where: { $0.id == profileID }),
      profileStates[profileID]?.isRefreshing != true
    else {
      return
    }
    updateState(for: profileID) { $0.isRefreshing = true }
    defer { updateState(for: profileID) { $0.isRefreshing = false } }

    do {
      let controllerBearer = try credentialStore.load(reference: profile.credentialReference)
      let observations = try await client.fetchLatestSnapshots(
        profile: profile,
        controllerBearer: controllerBearer
      )
      try Task.checkCancellation()
      let devices = try await client.listDevices(
        profile: profile,
        controllerBearer: controllerBearer
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

  func refreshAllProfiles() async {
    for profileID in profiles.map(\.id) {
      guard !Task.isCancelled else { return }
      await refreshProfile(profileID)
    }
  }

  func revokeDevice(profileID: UUID, deviceID: String) async throws {
    guard let profile = profiles.first(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    do {
      let controllerBearer = try credentialStore.load(reference: profile.credentialReference)
      try await client.revokeDevice(
        deviceID: deviceID,
        profile: profile,
        controllerBearer: controllerBearer
      )
      try Task.checkCancellation()
      let devices = try await client.listDevices(
        profile: profile,
        controllerBearer: controllerBearer
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
      let controllerBearer = try credentialStore.load(reference: profile.credentialReference)
      if approve {
        try await client.approvePairing(
          userCode: userCode,
          profile: profile,
          controllerBearer: controllerBearer
        )
      } else {
        try await client.denyPairing(
          userCode: userCode,
          profile: profile,
          controllerBearer: controllerBearer
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
    await ensureManagedControllerProfile()
    guard !Task.isCancelled else { return }
    await refreshAllProfiles()
  }

  private func deleteAllLocalData() throws {
    try credentialStore.deleteAll()
    defaultsResetter.deleteAll()
    managedEnrollmentStore.setDisabled(true)
    managedEnrollmentDisabled = true
    stopPolling()
    profiles = []
    profileStates = [:]
    globalIssue = nil
  }

  private func deleteManagedController(for profile: RelayProfile) async throws {
    let controllerBearer = try credentialStore.load(reference: profile.credentialReference)
    try await client.deleteController(
      profile: profile,
      controllerBearer: controllerBearer
    )
  }

  private func deleteLocalProfile(at index: Int) throws {
    let profile = profiles[index]
    var remainingProfiles = profiles
    remainingProfiles.remove(at: index)
    if profile.isDefault, !remainingProfiles.isEmpty {
      remainingProfiles[0].isDefault = true
    }
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
    if profile.mode == .managed {
      managedEnrollmentStore.setDisabled(true)
      managedEnrollmentDisabled = true
    }
  }

  private func saveProfileMutation(
    _ updatedProfiles: [RelayProfile],
    affectedProfileID: UUID
  ) throws {
    do {
      try profileStore.save(updatedProfiles)
      profiles = updatedProfiles
      updateState(for: affectedProfileID) { $0.operationIssue = nil }
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: affectedProfileID)
      throw RelayStateModelError(issue: issue)
    }
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
    message: "The Relay profile was not found."
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
    if let credentialError = error as? RelayControllerCredentialStoreError {
      let category: RelayStateIssueCategory = switch credentialError {
      case .missingCredential: .credentialMissing
      case .invalidCredential, .corruptCredential: .authentication
      case .couldNotRead, .couldNotStore, .couldNotDelete: .persistence
      }
      return RelayStateIssue(
        category: category,
        message: credentialError.errorDescription ?? "QuotaBar could not access the Relay credential."
      )
    }
    if let profileError = error as? RelayProfileStoreError {
      return RelayStateIssue(
        category: .persistence,
        message: profileError.errorDescription ?? "QuotaBar could not access the Relay profiles."
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
        message: profileError.errorDescription ?? "The Relay profile is invalid."
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
        managedRelayConfiguration: nil
      )
      model.profileStates = profileStates
      return model
    }
  }

  private struct VisualFixtureRelayClient: RelayControllerClientServing {
    func discover(baseURL: URL) async throws -> RelayInfo { throw RelayClientError.unavailable }

    func registerController(baseURL: URL) async throws -> ControllerRegistrationResponse {
      throw RelayClientError.unavailable
    }

    func approvePairing(
      userCode: String,
      profile: RelayProfile,
      controllerBearer: String
    ) async throws {
      throw RelayClientError.unavailable
    }

    func denyPairing(
      userCode: String,
      profile: RelayProfile,
      controllerBearer: String
    ) async throws {
      throw RelayClientError.unavailable
    }

    func fetchLatestSnapshots(
      profile: RelayProfile,
      controllerBearer: String
    ) async throws -> ControllerSnapshotListResponse {
      throw RelayClientError.unavailable
    }

    func listDevices(
      profile: RelayProfile,
      controllerBearer: String
    ) async throws -> DeviceListResponse {
      throw RelayClientError.unavailable
    }

    func revokeDevice(
      deviceID: String,
      profile: RelayProfile,
      controllerBearer: String
    ) async throws {
      throw RelayClientError.unavailable
    }

    func deleteController(
      profile: RelayProfile,
      controllerBearer: String
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

  private struct VisualFixtureRelayCredentialStore: RelayControllerCredentialPersisting {
    func save(_ controllerBearer: String, reference: String) throws {
      throw RelayControllerCredentialStoreError.couldNotStore
    }

    func load(reference: String) throws -> String {
      throw RelayControllerCredentialStoreError.missingCredential
    }

    func delete(reference: String) throws {
      throw RelayControllerCredentialStoreError.couldNotDelete
    }

    func reconcile(retaining references: Set<String>) throws {}

    func deleteAll() throws {
      throw RelayControllerCredentialStoreError.couldNotDelete
    }
  }

  @MainActor
  private struct VisualFixtureDefaultsResetter: QuotaBarDefaultsResetting {
    func deleteAll() {}
  }
#endif
