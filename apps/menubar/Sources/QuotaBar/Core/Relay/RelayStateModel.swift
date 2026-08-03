import Foundation
import Observation

protocol RelayOwnerClientServing: Sendable {
  func discover(baseURL: URL) async throws -> RelayInfo
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
}

extension RelayOwnerCredentialStore: RelayOwnerCredentialPersisting {}

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

  init(
    client: any RelayOwnerClientServing = RelayClient(),
    profileStore: any RelayProfilePersisting = RelayProfileStore(),
    credentialStore: any RelayOwnerCredentialPersisting = RelayOwnerCredentialStore(),
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
      globalIssue = nil
    } catch {
      profiles = []
      profileStates = [:]
      globalIssue = Self.issue(for: error)
    }
  }

  deinit {
    pollingTask?.cancel()
  }

  func state(for profileID: UUID) -> RelayProfileState? {
    profileStates[profileID]
  }

  @discardableResult
  func addSelfHostedProfile(
    name: String,
    origin: String,
    ownerBearer: String
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
        message: "Only self-hosted Relays can be added with an owner bearer."
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
      try credentialStore.save(ownerBearer, reference: profile.credentialReference)
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
          message: "QuotaBar could not remove the Relay owner credential after profile storage failed."
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

  func deleteProfile(_ profileID: UUID) throws {
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      throw Self.profileNotFoundError
    }
    let profile = profiles[index]

    do {
      try credentialStore.delete(reference: profile.credentialReference)
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: profileID)
      throw RelayStateModelError(issue: issue)
    }

    var remainingProfiles = profiles
    remainingProfiles.remove(at: index)
    if profile.isDefault, !remainingProfiles.isEmpty {
      remainingProfiles[0].isDefault = true
    }
    do {
      try profileStore.save(remainingProfiles)
    } catch {
      let issue = Self.issue(for: error)
      setOperationIssue(issue, for: profileID)
      throw RelayStateModelError(issue: issue)
    }

    profiles = remainingProfiles
    profileStates[profileID] = nil
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
      await self?.refreshAllProfiles()
      while !Task.isCancelled {
        do {
          try await sleep(interval)
        } catch {
          break
        }
        guard !Task.isCancelled else { break }
        await self?.refreshAllProfiles()
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
    if let credentialError = error as? RelayOwnerCredentialStoreError {
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
