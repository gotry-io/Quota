import Foundation
import Testing

@testable import QuotaBar

@Suite
@MainActor
struct RelayStateModelTests {
  @Test
  func loadsProfilesAndReportsFixedLoadFailure() throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let loadedModel = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore()
    )

    #expect(loadedModel.profiles == [profile])
    #expect(loadedModel.state(for: profile.id) == RelayProfileState())
    #expect(loadedModel.globalIssue == nil)

    let failedModel = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .failure(.invalidData)),
      credentialStore: FakeRelayCredentialStore()
    )
    #expect(failedModel.profiles.isEmpty)
    #expect(failedModel.globalIssue?.category == .persistence)
    #expect(failedModel.globalIssue?.message == "The saved Relay endpoints are invalid.")
  }

  @Test
  func ensureEndpointRegistersAnonymousOwnerAndReusesSameURL() async throws {
    let operations = RelayPersistenceRecorder()
    let profileStore = FakeRelayProfileStore(operations: operations)
    let credentialStore = FakeRelayCredentialStore(operations: operations)
    let client = FakeRelayStateClient(
      discoveryResults: [.success(sampleRelayInfo())],
      registrationResults: [
        .success(OwnerRegistrationResponse(ownerToken: syntheticOwnerBearer))
      ]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore,
      officialRelay: nil,
      makeProfileID: { profileID1 }
    )

    let profile = try await model.ensureEndpoint(origin: "HTTPS://Relay.EXAMPLE:443/")
    let again = try await model.ensureEndpoint(origin: "https://relay.example")

    #expect(profile.id == profileID1)
    #expect(again.id == profileID1)
    #expect(profile.name == "relay.example")
    #expect(profile.baseURL.absoluteString == "https://relay.example")
    #expect(model.profiles == [profile])
    #expect(credentialStore.token(reference: profile.credentialReference) == syntheticOwnerBearer)
    #expect(await client.calls == [
      .discover("https://relay.example"),
      .register("https://relay.example"),
      .devices(profileID1, syntheticOwnerBearer),
    ])
  }

  @Test
  func explicitPairingReenrollsAnExpiredOwnerForAnExistingEndpoint() async throws {
    let expired = try sampleRelayProfile(id: profileID1)
    let profileStore = FakeRelayProfileStore(loadedProfiles: .success([expired]))
    let credentialStore = FakeRelayCredentialStore(
      tokens: [expired.credentialReference: "expired-owner-access"]
    )
    let client = FakeRelayStateClient(
      discoveryResults: [.success(sampleRelayInfo())],
      registrationResults: [
        .success(OwnerRegistrationResponse(ownerToken: syntheticOwnerBearer))
      ],
      deviceResults: [.failure(.credentialRejected)]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore,
      officialRelay: nil,
      makeProfileID: { profileID2 }
    )

    let replacement = try await model.ensureEndpoint(origin: "https://relay.example")

    #expect(replacement.id == profileID2)
    #expect(model.profiles == [replacement])
    #expect(model.state(for: expired.id) == nil)
    #expect(model.state(for: replacement.id) == RelayProfileState())
    #expect(credentialStore.token(reference: expired.credentialReference) == nil)
    #expect(
      credentialStore.token(reference: replacement.credentialReference)
        == syntheticOwnerBearer
    )
    #expect(profileStore.savedProfiles == [[], [replacement]])
    #expect(await client.calls == [
      .devices(expired.id, "expired-owner-access"),
      .discover("https://relay.example"),
      .register("https://relay.example"),
    ])
  }

  @Test
  func ensureEndpointRollsBackWhenLocalPersistenceFails() async throws {
    let profileStore = FakeRelayProfileStore(saveErrors: [.couldNotSave])
    let credentialStore = FakeRelayCredentialStore()
    let client = FakeRelayStateClient(
      discoveryResults: [.success(sampleRelayInfo())],
      registrationResults: [
        .success(OwnerRegistrationResponse(ownerToken: syntheticOwnerBearer))
      ]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore,
      officialRelay: nil,
      makeProfileID: { profileID1 }
    )

    do {
      _ = try await model.ensureEndpoint(origin: "https://relay.example")
      Issue.record("Expected persistence failure.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .persistence)
    }

    #expect(model.profiles.isEmpty)
    #expect(credentialStore.token(reference: RelayProfile.credentialReference(for: profileID1)) == nil)
    #expect(await client.calls == [
      .discover("https://relay.example"),
      .register("https://relay.example"),
      .deleteOwner(profileID1, syntheticOwnerBearer),
    ])
  }

  @Test
  func ensureEndpointRejectsRelaysWithoutIsolatedOwnerSupport() async throws {
    let unsupported = RelayInfo(
      instanceID: "unsupported",
      mode: .selfHosted,
      version: "0.0.1",
      apiVersions: [1],
      authMethods: ["bearer"],
      capabilities: RelayCapabilities(
        realtime: false,
        persistentSnapshots: true,
        instantDeviceRevocation: true,
        history: false,
        multiTenant: false
      )
    )
    let model = RelayStateModel(
      client: FakeRelayStateClient(discoveryResults: [.success(unsupported)]),
      profileStore: FakeRelayProfileStore(),
      credentialStore: FakeRelayCredentialStore(),
      officialRelay: nil
    )

    do {
      _ = try await model.ensureEndpoint(origin: "https://relay.example")
      Issue.record("Expected unsupported Relay.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .unsupported)
    }
    #expect(model.profiles.isEmpty)
  }

  @Test
  func startupReconcilesOwnerCredentialsAgainstLoadedProfiles() throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let credentialStore = FakeRelayCredentialStore()

    _ = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore
    )

    #expect(credentialStore.reconciledReferences == [profile.credentialReference])
  }

  @Test
  func deletesMetadataBeforeCredential() async throws {
    let first = try sampleRelayProfile(id: profileID1)
    let second = try sampleRelayProfile(id: profileID2, host: "relay-two.example")
    let operations = RelayPersistenceRecorder()
    let profileStore = FakeRelayProfileStore(
      loadedProfiles: .success([first, second]),
      operations: operations
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [
        first.credentialReference: syntheticOwnerBearer,
        second.credentialReference: "owner_second_synthetic",
      ],
      operations: operations
    )
    let client = FakeRelayStateClient()
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore
    )

    try await model.deleteProfile(first.id)

    #expect(credentialStore.token(reference: first.credentialReference) == nil)
    #expect(model.profiles.count == 1)
    #expect(model.profiles[0].id == second.id)
    #expect(model.state(for: first.id) == nil)
    #expect(operations.values == [
      .metadataSave,
      .credentialDelete(first.credentialReference),
    ])
    #expect(await client.calls == [
      .deleteOwner(first.id, syntheticOwnerBearer)
    ])
  }

  @Test
  func deletingAnyEndpointDeletesRemoteOwnerAndLocalState() async throws {
    let profile = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed
    )
    let client = FakeRelayStateClient()
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticOwnerBearer]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore,
      officialRelay: nil
    )

    try await model.deleteProfile(profile.id)

    #expect(model.profiles.isEmpty)
    #expect(credentialStore.token(reference: profile.credentialReference) == nil)
    #expect(await client.calls == [
      .deleteOwner(profile.id, syntheticOwnerBearer)
    ])
  }

  @Test
  func endpointCanBeExplicitlyDeletedLocallyAfterRemoteDeletionFails() async throws {
    let profile = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticOwnerBearer]
    )
    let model = RelayStateModel(
      client: FakeRelayStateClient(ownerDeleteResults: [.failure(.credentialRejected)]),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore,
      officialRelay: nil
    )

    await #expect(throws: RelayStateModelError.self) {
      try await model.deleteProfile(profile.id)
    }
    try model.deleteProfileLocally(profile.id)

    #expect(model.profiles.isEmpty)
    #expect(credentialStore.token(reference: profile.credentialReference) == nil)
  }

  @Test
  func fullResetDeletesAllOwnersStopsPollingAndClearsLocalData() async throws {
    let managed = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed
    )
    let selfHosted = try sampleRelayProfile(id: profileID2, host: "relay.example")
    let client = FakeRelayStateClient(
      deviceResults: [
        .success(DeviceListResponse(devices: [])),
        .success(DeviceListResponse(devices: [])),
      ]
    )
    let credentialStore = FakeRelayCredentialStore(tokens: [
      managed.credentialReference: syntheticOwnerBearer,
      selfHosted.credentialReference: "owner_self_hosted",
    ])
    let defaultsResetter = FakeQuotaBarDefaultsResetter()
    let sleepProbe = RelaySleepProbe()
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([managed, selfHosted])),
      credentialStore: credentialStore,
      defaultsResetter: defaultsResetter,
      officialRelay: nil,
      sleep: { duration in try await sleepProbe.sleep(duration) }
    )
    model.startPolling()
    try await waitForSleepCount(1, probe: sleepProbe)

    try await model.deleteAllQuotaBarData()

    #expect(model.profiles.isEmpty)
    #expect(!model.isPolling)
    #expect(credentialStore.deleteAllCount == 1)
    #expect(defaultsResetter.deleteAllCount == 1)
    #expect(await client.calls == [
      .snapshots(managed.id, syntheticOwnerBearer),
      .devices(managed.id, syntheticOwnerBearer),
      .snapshots(selfHosted.id, "owner_self_hosted"),
      .devices(selfHosted.id, "owner_self_hosted"),
      .deleteOwner(managed.id, syntheticOwnerBearer),
      .deleteOwner(selfHosted.id, "owner_self_hosted"),
    ])
  }

  @Test
  func failedResetCanBeExplicitlyCompletedLocally() async throws {
    let profile = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticOwnerBearer]
    )
    let defaultsResetter = FakeQuotaBarDefaultsResetter()
    let client = FakeRelayStateClient(ownerDeleteResults: [.failure(.unavailable)])
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore,
      defaultsResetter: defaultsResetter,
      officialRelay: nil
    )

    await #expect(throws: RelayStateModelError.self) {
      try await model.deleteAllQuotaBarData()
    }
    #expect(model.profiles == [profile])
    #expect(credentialStore.deleteAllCount == 0)

    try model.deleteAllQuotaBarDataLocally()

    #expect(model.profiles.isEmpty)
    #expect(credentialStore.deleteAllCount == 1)
    #expect(defaultsResetter.deleteAllCount == 1)
    #expect(await client.calls == [.deleteOwner(profile.id, syntheticOwnerBearer)])
  }

  @Test
  func keepsProfileAndReportsPersistenceFailureWhenDeleteMetadataSaveFails() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let profileStore = FakeRelayProfileStore(
      loadedProfiles: .success([profile]),
      saveErrors: [.couldNotSave]
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticOwnerBearer]
    )
    let model = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: profileStore,
      credentialStore: credentialStore
    )

    do {
      try await model.deleteProfile(profile.id)
      Issue.record("Expected metadata deletion to fail.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .persistence)
      #expect(error.errorDescription == "QuotaBar could not save its Relay endpoints.")
    }

    #expect(model.profiles == [profile])
    #expect(
      credentialStore.token(reference: profile.credentialReference) == syntheticOwnerBearer
    )
    #expect(model.state(for: profile.id)?.operationIssue?.category == .persistence)
  }

  @Test
  func retriesCredentialDeletionAfterMetadataWasAlreadyRemoved() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let profileStore = FakeRelayProfileStore(loadedProfiles: .success([profile]))
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticOwnerBearer],
      deleteErrors: [.couldNotDelete]
    )
    let model = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: profileStore,
      credentialStore: credentialStore
    )

    await #expect(throws: RelayStateModelError.self) {
      try await model.deleteProfile(profile.id)
    }

    #expect(model.profiles == [profile])
    #expect(profileStore.savedProfiles == [[]])
    #expect(
      credentialStore.token(reference: profile.credentialReference) == syntheticOwnerBearer
    )

    try await model.deleteProfile(profile.id)

    #expect(model.profiles.isEmpty)
    #expect(profileStore.savedProfiles == [[], []])
    #expect(credentialStore.token(reference: profile.credentialReference) == nil)
  }

  @Test
  func approvesAndDeniesPairingThroughTheBoundProfile() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let client = FakeRelayStateClient()
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticOwnerBearer]
      )
    )

    try await model.approvePairing(profileID: profile.id, userCode: "ABCD-EFGH")
    try await model.denyPairing(profileID: profile.id, userCode: "IJKL-MNOP")

    #expect(await client.calls == [
      .approve(profile.id, "ABCD-EFGH", syntheticOwnerBearer),
      .deny(profile.id, "IJKL-MNOP", syntheticOwnerBearer),
    ])
  }

  @Test
  func pairingFailureUsesFixedSafeIssue() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let client = FakeRelayStateClient(
      approvalResults: [.failure(.permissionDenied)]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticOwnerBearer]
      )
    )

    do {
      try await model.approvePairing(profileID: profile.id, userCode: "ABCD-EFGH")
      Issue.record("Expected pairing approval to fail.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .authorization)
      let message = try #require(error.errorDescription)
      #expect(!message.contains(syntheticOwnerBearer))
      #expect(!message.contains("ABCD-EFGH"))
      #expect(!message.contains(profile.id.uuidString))
      #expect(!message.contains("alice@example.com"))
    }
  }

  @Test
  func operationIssueDoesNotMarkLastKnownQuotaDataStale() {
    let operationIssue = RelayStateIssue(
      category: .authorization,
      message: "QuotaBar's private access to this Relay lacks the required permission."
    )
    let refreshIssue = RelayStateIssue(
      category: .unavailable,
      message: "The Relay is unavailable."
    )
    var state = RelayProfileState(
      lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 1_785_752_430),
      operationIssue: operationIssue
    )

    #expect(!state.isStale)
    state.refreshIssue = refreshIssue
    #expect(state.isStale)
  }

  @Test
  func refreshPreservesLastKnownGoodDataAndMarksItStaleAfterFailure() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let observation = try sampleObservation(deviceID: "device_01", sequence: 4)
    let device = try sampleDevice(deviceID: "device_01", sequence: 4)
    let refreshedAt = Date(timeIntervalSince1970: 1_785_752_430)
    let client = FakeRelayStateClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [observation])),
        .failure(.unavailable),
      ],
      deviceResults: [.success(DeviceListResponse(devices: [device]))]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticOwnerBearer]
      ),
      now: { refreshedAt }
    )

    await model.refreshProfile(profile.id)
    let goodState = try #require(model.state(for: profile.id))
    #expect(goodState.observations == [observation])
    #expect(goodState.devices == [device])
    #expect(goodState.lastSuccessfulRefreshAt == refreshedAt)
    #expect(!goodState.isStale)

    await model.refreshProfile(profile.id)
    let failedState = try #require(model.state(for: profile.id))
    #expect(failedState.observations == [observation])
    #expect(failedState.devices == [device])
    #expect(failedState.lastSuccessfulRefreshAt == refreshedAt)
    #expect(failedState.refreshIssue?.category == .unavailable)
    #expect(failedState.refreshIssue?.message == "The Relay is unavailable.")
    #expect(failedState.isStale)
    #expect(!failedState.isRefreshing)
  }

  @Test
  func refreshReportsMissingAndRejectedCredentialsExplicitly() async throws {
    let missingProfile = try sampleRelayProfile(id: profileID1)
    let missingClient = FakeRelayStateClient()
    let missingModel = RelayStateModel(
      client: missingClient,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([missingProfile])),
      credentialStore: FakeRelayCredentialStore()
    )

    await missingModel.refreshProfile(missingProfile.id)

    #expect(missingModel.state(for: missingProfile.id)?.issue?.category == .credentialMissing)
    #expect(
      missingModel.state(for: missingProfile.id)?.issue?.message
        == "QuotaBar's private access to this Relay is missing."
    )
    #expect(await missingClient.calls.isEmpty)

    let rejectedProfile = try sampleRelayProfile(id: profileID2)
    let rejectedClient = FakeRelayStateClient(
      snapshotResults: [.failure(.credentialRejected)]
    )
    let rejectedModel = RelayStateModel(
      client: rejectedClient,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([rejectedProfile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [rejectedProfile.credentialReference: syntheticOwnerBearer]
      )
    )

    await rejectedModel.refreshProfile(rejectedProfile.id)

    #expect(rejectedModel.state(for: rejectedProfile.id)?.issue?.category == .authentication)
    #expect(
      rejectedModel.state(for: rejectedProfile.id)?.issue?.message
        == "QuotaBar's private access to this Relay is no longer valid."
    )
  }

  @Test
  func revokeRefreshesDevicesAndKeepsSnapshots() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let remainingDevice = try sampleDevice(deviceID: "device_02", sequence: 2)
    let refreshedAt = Date(timeIntervalSince1970: 1_785_752_430)
    let client = FakeRelayStateClient(
      deviceResults: [.success(DeviceListResponse(devices: [remainingDevice]))]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticOwnerBearer]
      ),
      now: { refreshedAt }
    )

    try await model.revokeDevice(profileID: profile.id, deviceID: "device_01")

    #expect(model.state(for: profile.id)?.devices == [remainingDevice])
    #expect(model.state(for: profile.id)?.lastSuccessfulRefreshAt == nil)
    #expect(await client.calls == [
      .revoke(profile.id, "device_01", syntheticOwnerBearer),
      .devices(profile.id, syntheticOwnerBearer),
    ])
  }

  @Test
  func refreshesAllProfilesSequentially() async throws {
    let first = try sampleRelayProfile(id: profileID1)
    let second = try sampleRelayProfile(id: profileID2, host: "relay-two.example")
    let client = FakeRelayStateClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [])),
        .success(OwnerSnapshotListResponse(observations: [])),
      ],
      deviceResults: [
        .success(DeviceListResponse(devices: [])),
        .success(DeviceListResponse(devices: [])),
      ]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([first, second])),
      credentialStore: FakeRelayCredentialStore(tokens: [
        first.credentialReference: syntheticOwnerBearer,
        second.credentialReference: "owner_second_synthetic",
      ])
    )

    await model.refreshAllProfiles()

    #expect(await client.calls == [
      .snapshots(first.id, syntheticOwnerBearer),
      .devices(first.id, syntheticOwnerBearer),
      .snapshots(second.id, "owner_second_synthetic"),
      .devices(second.id, "owner_second_synthetic"),
    ])
  }

  @Test
  func pollingStartIsIdempotentAndStopIsCancellationSafe() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let client = FakeRelayStateClient()
    let sleepProbe = RelaySleepProbe()
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticOwnerBearer]
      ),
      officialRelay: nil,
      pollInterval: .seconds(123),
      sleep: { duration in try await sleepProbe.sleep(duration) }
    )

    model.startPolling()
    model.startPolling()
    try await waitForSleepCount(1, probe: sleepProbe)

    #expect(model.isPolling)
    #expect(await sleepProbe.durations == [.seconds(123)])
    #expect(await client.calls == [
      .snapshots(profile.id, syntheticOwnerBearer),
      .devices(profile.id, syntheticOwnerBearer),
    ])

    model.stopPolling()
    #expect(!model.isPolling)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await sleepProbe.durations.count == 1)

    model.startPolling()
    try await waitForSleepCount(2, probe: sleepProbe)
    model.stopPolling()
    #expect(await client.calls.count == 4)
  }

  @Test
  func releasingPollingModelCancelsSleeperWithoutARetainCycle() async throws {
    let profile = try sampleRelayProfile(id: profileID1)
    let sleepProbe = RelaySleepProbe()
    var model: RelayStateModel? = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticOwnerBearer]
      ),
      officialRelay: nil,
      sleep: { duration in try await sleepProbe.sleep(duration) }
    )
    weak let weakModel = model

    model?.startPolling()
    try await waitForSleepCount(1, probe: sleepProbe)
    model = nil
    try await waitForCancellationCount(1, probe: sleepProbe)

    #expect(weakModel == nil)
    #expect(await sleepProbe.cancellationCount == 1)
  }
}

private enum FakeRelayClientCall: Equatable, Sendable {
  case discover(String)
  case register(String)
  case approve(UUID, String, String)
  case deny(UUID, String, String)
  case snapshots(UUID, String)
  case devices(UUID, String)
  case revoke(UUID, String, String)
  case deleteOwner(UUID, String)
}

private actor FakeRelayStateClient: RelayOwnerClientServing {
  private(set) var calls: [FakeRelayClientCall] = []
  private var discoveryResults: [Result<RelayInfo, RelayClientError>]
  private var registrationResults: [Result<OwnerRegistrationResponse, RelayClientError>]
  private var approvalResults: [Result<Void, RelayClientError>]
  private var denialResults: [Result<Void, RelayClientError>]
  private var snapshotResults: [Result<OwnerSnapshotListResponse, RelayClientError>]
  private var deviceResults: [Result<DeviceListResponse, RelayClientError>]
  private var revokeResults: [Result<Void, RelayClientError>]
  private var ownerDeleteResults: [Result<Void, RelayClientError>]

  init(
    discoveryResults: [Result<RelayInfo, RelayClientError>] = [],
    registrationResults: [Result<OwnerRegistrationResponse, RelayClientError>] = [],
    approvalResults: [Result<Void, RelayClientError>] = [],
    denialResults: [Result<Void, RelayClientError>] = [],
    snapshotResults: [Result<OwnerSnapshotListResponse, RelayClientError>] = [],
    deviceResults: [Result<DeviceListResponse, RelayClientError>] = [],
    revokeResults: [Result<Void, RelayClientError>] = [],
    ownerDeleteResults: [Result<Void, RelayClientError>] = []
  ) {
    self.discoveryResults = discoveryResults
    self.registrationResults = registrationResults
    self.approvalResults = approvalResults
    self.denialResults = denialResults
    self.snapshotResults = snapshotResults
    self.deviceResults = deviceResults
    self.revokeResults = revokeResults
    self.ownerDeleteResults = ownerDeleteResults
  }

  func discover(baseURL: URL) async throws -> RelayInfo {
    calls.append(.discover(baseURL.absoluteString))
    guard !discoveryResults.isEmpty else { throw RelayClientError.unavailable }
    return try discoveryResults.removeFirst().get()
  }

  func registerOwner(baseURL: URL) async throws -> OwnerRegistrationResponse {
    calls.append(.register(baseURL.absoluteString))
    guard !registrationResults.isEmpty else { throw RelayClientError.unavailable }
    return try registrationResults.removeFirst().get()
  }

  func approvePairing(
    userCode: String,
    profile: RelayProfile,
    ownerBearer: String
  ) async throws {
    calls.append(.approve(profile.id, userCode, ownerBearer))
    if !approvalResults.isEmpty {
      try approvalResults.removeFirst().get()
    }
  }

  func denyPairing(
    userCode: String,
    profile: RelayProfile,
    ownerBearer: String
  ) async throws {
    calls.append(.deny(profile.id, userCode, ownerBearer))
    if !denialResults.isEmpty {
      try denialResults.removeFirst().get()
    }
  }

  func fetchLatestSnapshots(
    profile: RelayProfile,
    ownerBearer: String
  ) async throws -> OwnerSnapshotListResponse {
    calls.append(.snapshots(profile.id, ownerBearer))
    guard !snapshotResults.isEmpty else {
      return OwnerSnapshotListResponse(observations: [])
    }
    return try snapshotResults.removeFirst().get()
  }

  func listDevices(
    profile: RelayProfile,
    ownerBearer: String
  ) async throws -> DeviceListResponse {
    calls.append(.devices(profile.id, ownerBearer))
    guard !deviceResults.isEmpty else {
      return DeviceListResponse(devices: [])
    }
    return try deviceResults.removeFirst().get()
  }

  func revokeDevice(
    deviceID: String,
    profile: RelayProfile,
    ownerBearer: String
  ) async throws {
    calls.append(.revoke(profile.id, deviceID, ownerBearer))
    if !revokeResults.isEmpty {
      try revokeResults.removeFirst().get()
    }
  }

  func deleteOwner(
    profile: RelayProfile,
    ownerBearer: String
  ) async throws {
    calls.append(.deleteOwner(profile.id, ownerBearer))
    if !ownerDeleteResults.isEmpty {
      try ownerDeleteResults.removeFirst().get()
    }
  }
}

@MainActor
private final class FakeRelayProfileStore: RelayProfilePersisting {
  private let loadedProfiles: Result<[RelayProfile], RelayProfileStoreError>
  private var saveErrors: [RelayProfileStoreError]
  private let operations: RelayPersistenceRecorder?
  private(set) var savedProfiles: [[RelayProfile]] = []

  init(
    loadedProfiles: Result<[RelayProfile], RelayProfileStoreError> = .success([]),
    saveErrors: [RelayProfileStoreError] = [],
    operations: RelayPersistenceRecorder? = nil
  ) {
    self.loadedProfiles = loadedProfiles
    self.saveErrors = saveErrors
    self.operations = operations
  }

  func load() throws -> [RelayProfile] {
    try loadedProfiles.get()
  }

  func save(_ profiles: [RelayProfile]) throws {
    operations?.record(.metadataSave)
    savedProfiles.append(profiles)
    if !saveErrors.isEmpty {
      throw saveErrors.removeFirst()
    }
  }
}

private final class FakeRelayCredentialStore: RelayOwnerCredentialPersisting, @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String: String]
  private let saveError: RelayOwnerCredentialStoreError?
  private let loadError: RelayOwnerCredentialStoreError?
  private var deleteErrors: [RelayOwnerCredentialStoreError]
  private let reconcileError: RelayOwnerCredentialStoreError?
  private let deleteAllError: RelayOwnerCredentialStoreError?
  private let operations: RelayPersistenceRecorder?
  private(set) var reconciledReferences: Set<String>?
  private(set) var deleteAllCount = 0

  init(
    tokens: [String: String] = [:],
    saveError: RelayOwnerCredentialStoreError? = nil,
    loadError: RelayOwnerCredentialStoreError? = nil,
    deleteErrors: [RelayOwnerCredentialStoreError] = [],
    reconcileError: RelayOwnerCredentialStoreError? = nil,
    deleteAllError: RelayOwnerCredentialStoreError? = nil,
    operations: RelayPersistenceRecorder? = nil
  ) {
    self.tokens = tokens
    self.saveError = saveError
    self.loadError = loadError
    self.deleteErrors = deleteErrors
    self.reconcileError = reconcileError
    self.deleteAllError = deleteAllError
    self.operations = operations
  }

  func save(_ ownerBearer: String, reference: String) throws {
    try lock.withLock {
      operations?.record(.credentialSave(reference))
      if let saveError { throw saveError }
      tokens[reference] = ownerBearer
    }
  }

  func load(reference: String) throws -> String {
    try lock.withLock {
      if let loadError { throw loadError }
      guard let token = tokens[reference] else {
        throw RelayOwnerCredentialStoreError.missingCredential
      }
      return token
    }
  }

  func delete(reference: String) throws {
    try lock.withLock {
      operations?.record(.credentialDelete(reference))
      if !deleteErrors.isEmpty { throw deleteErrors.removeFirst() }
      tokens[reference] = nil
    }
  }

  func reconcile(retaining references: Set<String>) throws {
    try lock.withLock {
      if let reconcileError { throw reconcileError }
      reconciledReferences = references
    }
  }

  func deleteAll() throws {
    try lock.withLock {
      if let deleteAllError { throw deleteAllError }
      deleteAllCount += 1
      tokens.removeAll()
    }
  }

  func token(reference: String) -> String? {
    lock.withLock { tokens[reference] }
  }
}

@MainActor
private final class FakeQuotaBarDefaultsResetter: QuotaBarDefaultsResetting {
  private(set) var deleteAllCount = 0

  func deleteAll() {
    deleteAllCount += 1
  }
}

private enum RelayPersistenceOperation: Equatable, Sendable {
  case credentialSave(String)
  case metadataSave
  case credentialDelete(String)
}

private final class RelayPersistenceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RelayPersistenceOperation] = []

  var values: [RelayPersistenceOperation] {
    lock.withLock { storage }
  }

  func record(_ operation: RelayPersistenceOperation) {
    lock.withLock { storage.append(operation) }
  }
}

private actor RelaySleepProbe {
  private(set) var durations: [Duration] = []
  private(set) var cancellationCount = 0

  func sleep(_ duration: Duration) async throws {
    durations.append(duration)
    do {
      try await Task.sleep(for: .seconds(60))
    } catch is CancellationError {
      cancellationCount += 1
      throw CancellationError()
    }
  }
}

private func waitForCancellationCount(_ expected: Int, probe: RelaySleepProbe) async throws {
  for _ in 0..<100 {
    if await probe.cancellationCount >= expected { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Polling did not cancel its sleeper.")
}

private func waitForSleepCount(_ expected: Int, probe: RelaySleepProbe) async throws {
  for _ in 0..<100 {
    if await probe.durations.count >= expected { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Polling did not reach the expected sleep cycle.")
}

private func sampleRelayProfile(
  id: UUID,
  host: String = "relay.example",
  mode: RelayMode = .selfHosted
) throws -> RelayProfile {
  try RelayProfile(
    id: id,
    name: host,
    baseURL: URL(string: "https://\(host)")!,
    instanceID: "instance_\(id.uuidString.lowercased())",
    mode: mode,
    capabilities: mode == .managed ? sampleManagedRelayCapabilities : sampleRelayCapabilities
  )
}

private func sampleRelayInfo() -> RelayInfo {
  RelayInfo(
    instanceID: "relay_primary",
    mode: .selfHosted,
    version: "0.0.1",
    apiVersions: [1],
    authMethods: ["bearer"],
    capabilities: sampleRelayCapabilities
  )
}

private func sampleObservation(deviceID: String, sequence: Int) throws -> OwnerSnapshotObservation {
  let data = Data(
    #"{"observations":[{"device_id":"\#(deviceID)","sequence":\#(sequence),"captured_at":"2026-08-03T10:20:30Z","snapshot":{"provider":"codex","account":{"fingerprint":"account_synthetic","fingerprint_scope":"global"},"windows":[{"id":"weekly","title":"Weekly","used_percent":20}],"source":"synthetic","status":"available","observed_at":"2026-08-03T10:20:30Z"},"updated_at":"2026-08-03T10:20:31Z"}]}"#.utf8
  )
  let response = try QuotaWireCodec.makeDecoder().decode(
    OwnerSnapshotListResponse.self,
    from: data
  )
  return try #require(response.observations.first)
}

private func sampleDevice(deviceID: String, sequence: Int) throws -> RelayDevice {
  let data = Data(
    #"{"devices":[{"device_id":"\#(deviceID)","display_name":"Synthetic Mac","created_at":"2026-08-03T10:20:30Z","last_seen_at":"2026-08-03T10:20:31Z","last_sequence":\#(sequence),"revoked_at":null}]}"#.utf8
  )
  let response = try QuotaWireCodec.makeDecoder().decode(DeviceListResponse.self, from: data)
  return try #require(response.devices.first)
}

private let profileID1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let profileID2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let syntheticOwnerBearer = "owner_synthetic_0123456789"
private let sampleRelayCapabilities = RelayCapabilities(
  realtime: false,
  persistentSnapshots: true,
  instantDeviceRevocation: true,
  history: false,
  multiTenant: true
)
private let sampleManagedRelayCapabilities = RelayCapabilities(
  realtime: false,
  persistentSnapshots: true,
  instantDeviceRevocation: true,
  history: false,
  multiTenant: true
)
